#!/usr/bin/env python3
"""
latency_bench.py - measure scrcpy video latency and smoothness on a real phone.

What it does
  * Starts scrcpy's own phone-side server (the same one the scrcpy app uses) with the
    settings you want to test, and reads the video stream through an adb tunnel.
  * Timestamps every video frame when it arrives on the Mac.

What it measures (per configuration)
  * tap->frame  : time from sending a tap to the phone until the first video frame that
                  shows it arrives on the Mac ("Pointer location" is on during the test so
                  the tap is visible). Includes the Mac->phone command, touch handling, rendering,
                  screen capture, encoding and the phone->Mac network. It excludes the Mac's
                  decode + display (~1 frame), which is the same for every configuration.
  * frame delay : while scrolling, how much later than the fastest frame each frame arrived
                  (computed from the phone's capture timestamps). High = stutter/lag spikes.
  * fps, Mbps   : achieved frame rate and bitrate while scrolling.
  * ping        : optional ping round-trip to the phone *while* the video is streaming.

Safety
  * Python standard library only. Mac programs are started with argument lists (no shell).
    The phone-side command is the same one scrcpy itself runs.
  * On the phone it opens the Settings app, scrolls it, taps the status bar, and temporarily
    enables "Pointer location" (restored to its original value at the end, even on error).
    It returns to the home screen when finished.

Usage
  python3 Tools/latency_bench.py -s SERIAL                    # run the default config set
  python3 Tools/latency_bench.py -s SERIAL --only base,lowlat # run some configs
  python3 Tools/latency_bench.py --list                       # show config names
  Add --ping <phone-ip> to also measure ping while streaming (Wi-Fi only).
"""

import argparse
import glob
import os
import random
import re
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time

ADB_CANDIDATES = ["/opt/homebrew/bin/adb"] + sorted(
    glob.glob("/opt/homebrew/Caskroom/android-platform-tools/*/platform-tools/adb"), reverse=True)
SCRCPY = "/opt/homebrew/bin/scrcpy"
PING = "/sbin/ping"
DEVICE_JAR = "/data/local/tmp/scrcpy-server.jar"

# Every configuration is a set of scrcpy *server* options (the phone side).
BASE = {"video_codec": "h264", "max_size": 1024, "video_bit_rate": 6_000_000, "max_fps": 60}
CONFIGS = {
    # scrcpy defaults except resolution (full size fails on this encoder)
    "default":   {"video_codec": "h264", "max_size": 1024},
    "base":      dict(BASE),
    "prio_lat0": dict(BASE, video_codec_options="priority:int=0,latency:int=0"),
    "prio":      dict(BASE, video_codec_options="priority:int=0"),
    "lat1":      dict(BASE, video_codec_options="latency:int=1"),
    "qti_ll":    dict(BASE, video_codec_options="vendor.qti-ext-enc-low-latency.enable:int=1"),
    "cbr":       dict(BASE, video_codec_options="bitrate-mode:int=2"),
    "intra":     dict(BASE, video_codec_options="intra-refresh-period:int=60"),
    "4M":        dict(BASE, video_bit_rate=4_000_000),
    "8M":        dict(BASE, video_bit_rate=8_000_000),
    "800":       dict(BASE, max_size=800),
    "1280":      dict(BASE, max_size=1280),
    "fps120":    {k: v for k, v in BASE.items() if k != "max_fps"},
    # constant bitrate (CBR) variants: steadier traffic, fewer bursts on a weak link
    "cbr8":      dict(BASE, video_bit_rate=8_000_000, video_codec_options="bitrate-mode:int=2"),
    "cbr4":      dict(BASE, video_bit_rate=4_000_000, video_codec_options="bitrate-mode:int=2"),
    "cbr3":      dict(BASE, video_bit_rate=3_000_000, video_codec_options="bitrate-mode:int=2"),
    "cbr4_800":  dict(BASE, video_bit_rate=4_000_000, max_size=800, video_codec_options="bitrate-mode:int=2"),
    "cbr4_1280": dict(BASE, video_bit_rate=4_000_000, max_size=1280, video_codec_options="bitrate-mode:int=2"),
    "cbr2_800":  dict(BASE, video_bit_rate=2_000_000, max_size=800, video_codec_options="bitrate-mode:int=2"),
    "cbr4_intra": dict(BASE, video_bit_rate=4_000_000,
                       video_codec_options="bitrate-mode:int=2,intra-refresh-period:int=60"),
    "cbr4_prio": dict(BASE, video_bit_rate=4_000_000,
                      video_codec_options="bitrate-mode:int=2,priority:int=0"),
    "cbr4_lat1": dict(BASE, video_bit_rate=4_000_000,
                      video_codec_options="bitrate-mode:int=2,latency:int=1"),
    "cbr4_pl0":  dict(BASE, video_bit_rate=4_000_000,
                      video_codec_options="bitrate-mode:int=2,priority:int=0,latency:int=0"),
    "cbr4_qti":  dict(BASE, video_bit_rate=4_000_000,
                      video_codec_options="bitrate-mode:int=2,vendor.qti-ext-enc-low-latency.enable:int=1"),
    "cbr4_120":  dict({k: v for k, v in BASE.items() if k != "max_fps"}, video_bit_rate=4_000_000,
                      video_codec_options="bitrate-mode:int=2"),
}
DEFAULT_SET = ["default", "base", "prio_lat0", "prio", "lat1", "qti_ll", "cbr", "intra",
               "4M", "8M", "800", "1280", "fps120"]


def find_adb():
    for path in ADB_CANDIDATES:
        real = os.path.realpath(path)
        if real.startswith("/opt/homebrew/") and os.access(real, os.X_OK):
            return real
    sys.exit("adb not found in /opt/homebrew")


def scrcpy_version_and_server():
    real = os.path.realpath(SCRCPY)
    out = subprocess.run([real, "--version"], capture_output=True, text=True).stdout
    match = re.search(r"scrcpy (\S+)", out)
    if not match:
        sys.exit("could not read scrcpy version")
    server = os.path.join(os.path.dirname(os.path.dirname(real)), "share", "scrcpy", "scrcpy-server")
    return match.group(1), server


def pct(values, p):
    """Nearest-rank percentile (values need not be sorted)."""
    if not values:
        return float("nan")
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(p / 100 * len(s) + 0.5)) - 1))
    return s[k]


class Bench:
    def __init__(self, adb, serial, version, server_path, inject_serial=None, debug=False):
        self.adb, self.serial, self.version, self.server_path = adb, serial, version, server_path
        self.inject_serial = inject_serial or serial
        self.debug = debug

    def adb_run(self, *args, serial=None, timeout=20):
        return subprocess.run([self.adb, "-s", serial or self.serial, *args],
                              capture_output=True, text=True, timeout=timeout)

    # ---------- phone preparation (always undone in restore()) ----------
    def prepare_phone(self):
        # "Pointer location" draws crosshairs for injected taps ("Show taps" only shows
        # physical touches), so a tap produces a visible change in the video.
        self.original_pointer_location = self.adb_run("shell", "settings", "get", "system",
                                                      "pointer_location").stdout.strip()
        self.adb_run("shell", "settings", "put", "system", "pointer_location", "1")
        self.adb_run("shell", "am", "start", "-a", "android.settings.SETTINGS")
        time.sleep(1.5)

    def restore_phone(self):
        value = getattr(self, "original_pointer_location", "0")
        if value not in ("0", "1"):
            value = "0"
        self.adb_run("shell", "settings", "put", "system", "pointer_location", value)
        self.adb_run("shell", "input", "keyevent", "KEYCODE_HOME")

    # ---------- one measurement run ----------
    def run_config(self, name, options, taps=12, motion_seconds=8.0, ping_ip=None):
        push = self.adb_run("push", self.server_path, DEVICE_JAR)
        if push.returncode != 0:
            return {"name": name, "error": "push failed: " + push.stderr.strip()}

        scid = "%08x" % random.randrange(1 << 31)
        socket_name = "scrcpy_" + scid
        fwd = self.adb_run("forward", "tcp:0", "localabstract:" + socket_name)
        port = int(fwd.stdout.strip())

        server_args = ["CLASSPATH=" + DEVICE_JAR, "app_process", "/", "com.genymobile.scrcpy.Server",
                       self.version, "scid=" + scid, "log_level=info", "tunnel_forward=true",
                       "audio=false", "control=false", "send_device_meta=false",
                       "send_dummy_byte=false", "send_stream_meta=false",
                       "downsize_on_error=false"]
        server_args += ["%s=%s" % (k, v) for k, v in options.items()]
        server = subprocess.Popen([self.adb, "-s", self.serial, "shell", *server_args],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        server_log = []
        threading.Thread(target=lambda: [server_log.append(l.rstrip()) for l in server.stdout],
                         daemon=True).start()

        frames = []          # (arrival_time, pts_us, size, is_config)
        stop = threading.Event()
        sock = self._connect(port, server)
        result = {"name": name}
        injector = None
        try:
            if sock is None:
                result["error"] = "could not connect: " + " | ".join(server_log[-5:])
                return result
            reader = threading.Thread(target=self._reader, args=(sock, frames, stop), daemon=True)
            reader.start()

            injector = subprocess.Popen([self.adb, "-s", self.inject_serial, "shell"],
                                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, text=True)
            # Warm-up: after the first key frame the encoder keeps sending "quality refinement"
            # frames for a few seconds; wait until the stream settles to small idle repeats.
            time.sleep(3.5)
            if not frames:
                result["error"] = "no video: " + " | ".join(server_log[-5:])
                return result

            tap_times = []
            for i in range(taps):
                t0 = time.perf_counter()
                # Alternate positions so the "Pointer location" crosshair visibly moves.
                injector.stdin.write("cmd input tap %d 45\n" % (250 if i % 2 == 0 else 830))
                injector.stdin.flush()
                tap_times.append(t0)
                time.sleep(0.75 + random.random() * 0.25)

            ping_proc = None
            if ping_ip:
                ping_proc = subprocess.Popen([PING, "-c", str(int(motion_seconds / 0.1)), "-i", "0.1",
                                              "-t", str(int(motion_seconds) + 3), ping_ip],
                                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            motion_start = time.perf_counter()
            direction = 0
            while time.perf_counter() - motion_start < motion_seconds:
                y1, y2 = (1700, 700) if direction == 0 else (700, 1700)
                injector.stdin.write("cmd input swipe 540 %d 540 %d 250\n" % (y1, y2))
                injector.stdin.flush()
                direction ^= 1
                time.sleep(0.6)
            motion_end = time.perf_counter()
            time.sleep(0.5)
            ping_out = ping_proc.communicate(timeout=15)[0] if ping_proc else ""
        finally:
            stop.set()
            if sock:
                sock.close()
            if injector:
                injector.stdin.close()
                injector.terminate()
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
            self.adb_run("forward", "--remove", "tcp:%d" % port)

        errors = [l for l in server_log if "ERROR" in l or "Exception" in l]
        if errors:
            result["error"] = " | ".join(errors[:3])

        video = [f for f in frames if not f[3]]
        # "offset" = arrival time on the Mac minus capture time on the phone (different clocks,
        # so only differences between frames are meaningful). The smallest offset in the run is
        # the fastest capture->arrival trip; "excess" is how much slower a frame was.
        offsets = [f[0] - f[1] / 1e6 for f in video]
        base_offset = min(offsets) if offsets else 0

        # --- tap -> frame latency ---
        # A tap redraws the "Pointer location" overlay, so the answering frame is several times
        # bigger than the idle frames just before the tap.
        tap_lat, tap_vid = [], []
        threshold = 0
        for t0 in tap_times:
            before = [f[2] for f in video if t0 - 0.4 <= f[0] <= t0]
            threshold = max(3 * (statistics.median(before) if before else 400), 1500)
            hit = next((f for f in video if f[0] > t0 and f[2] >= threshold), None)
            if hit and hit[0] - t0 < 0.7:
                tap_lat.append((hit[0] - t0) * 1000)
                tap_vid.append((hit[0] - hit[1] / 1e6 - base_offset) * 1000)
            if self.debug:
                near = [(round((f[0] - t0) * 1000), f[2], round((f[0] - f[1] / 1e6 - base_offset) * 1000))
                        for f in video if -0.1 < f[0] - t0 < 0.3]
                print("   tap (ms after tap, bytes, excess ms):", near[:10])

        # --- frame delay while scrolling ---
        motion = [f for f in video if motion_start <= f[0] <= motion_end]
        excess = [(f[0] - f[1] / 1e6 - base_offset) * 1000 for f in motion]
        duration = motion_end - motion_start

        result.update({
            "threshold": threshold,
            "tap_n": len(tap_lat), "taps": taps,
            "tap_med": statistics.median(tap_lat) if tap_lat else float("nan"),
            "tap_min": min(tap_lat) if tap_lat else float("nan"),
            "tap_p90": pct(tap_lat, 90),
            "tap_vid": statistics.median(tap_vid) if tap_vid else float("nan"),
            "fps": len(motion) / duration if duration else 0,
            "mbps": sum(f[2] for f in motion) * 8 / duration / 1e6 if duration else 0,
            "delay_p50": pct(excess, 50), "delay_p95": pct(excess, 95),
            "delay_max": max(excess) if excess else float("nan"),
            "stalls": sum(1 for e in excess if e > 50),
            # raw (clock-offset included) values; only differences between runs of the same
            # session mean anything, see print_pipeline()
            "off_min": min(offsets) if offsets else float("nan"),
            "off_p50": statistics.median([f[0] - f[1] / 1e6 for f in motion]) if motion else float("nan"),
        })
        if ping_out:
            rtts = [float(x) for x in re.findall(r"time=([0-9.]+)", ping_out)]
            if rtts:
                result.update({"ping_med": statistics.median(rtts), "ping_p95": pct(rtts, 95),
                               "ping_loss": 1 - len(rtts) / int(motion_seconds / 0.1)})
        return result

    def _connect(self, port, server, timeout=8.0):
        """adb accepts the TCP connection immediately and closes it if the phone side isn't
        listening yet, so retry until the first video bytes arrive."""
        deadline = time.time() + timeout
        while time.time() < deadline and server.poll() is None:
            try:
                sock = socket.create_connection(("127.0.0.1", port), timeout=2)
                sock.settimeout(2)
                first = sock.recv(12, socket.MSG_PEEK)
                if first:
                    sock.settimeout(None)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                    return sock
                sock.close()
            except OSError:
                pass
            time.sleep(0.1)
        return None

    @staticmethod
    def _recv_exact(sock, n):
        buf = bytearray(n)
        view = memoryview(buf)
        got = 0
        while got < n:
            k = sock.recv_into(view[got:], n - got)
            if k == 0:
                raise EOFError
            got += k
        return buf

    def _reader(self, sock, frames, stop):
        try:
            while not stop.is_set():
                header = self._recv_exact(sock, 12)
                pts_flags, size = struct.unpack(">QI", header)
                if size > 20_000_000:
                    print("   ! unexpected frame header, stream format differs")
                    return
                payload = self._recv_exact(sock, size)
                now = time.perf_counter()
                # scrcpy 4.x packet header: bit 62 = codec config, bit 61 = key frame,
                # low 61 bits = capture timestamp in microseconds.
                is_config = bool(pts_flags >> 62 & 1)
                if not frames and not (is_config and payload[:4] == b"\x00\x00\x00\x01"):
                    print("   ! first packet is not a codec config packet; format differs")
                frames.append((now, pts_flags & ((1 << 61) - 1), size, is_config))
        except (EOFError, OSError):
            pass


def fmt(r):
    if "tap_med" not in r:
        return "%-10s ERROR %s" % (r["name"], r.get("error", ""))
    line = ("%-10s tap med %5.0f  min %5.0f  p90 %5.0f ms (%d/%d, video part +%.0f) | delay p50 %4.0f p95 %5.0f max %5.0f ms"
            " stalls %2d | %5.1f fps %5.2f Mbps" % (
                r["name"], r["tap_med"], r["tap_min"], r["tap_p90"], r["tap_n"], r["taps"], r["tap_vid"],
                r["delay_p50"], r["delay_p95"], r["delay_max"], r["stalls"], r["fps"], r["mbps"]))
    if "ping_med" in r:
        line += " | ping med %.0f p95 %.0f loss %.0f%%" % (r["ping_med"], r["ping_p95"], r["ping_loss"] * 100)
    if r.get("error"):
        line += "  [server: %s]" % r["error"][:120]
    return line


def print_pipeline(all_runs):
    """Capture->arrival time of each run relative to the fastest frame of the whole session.
    Both clocks are monotonic, so within one session a config that holds frames longer in
    the encoder (or network) shows a higher value."""
    ok = [r for r in all_runs if "off_min" in r]
    if len(ok) < 2:
        return
    ref = min(r["off_min"] for r in ok)
    print("\nPipeline (capture->arrival, ms above the session's fastest frame):")
    by_name = {}
    for r in ok:
        by_name.setdefault(r["name"], []).append(r)
    for name, runs in by_name.items():
        mins = ["%4.0f" % ((r["off_min"] - ref) * 1000) for r in runs]
        meds = ["%4.0f" % ((r["off_p50"] - ref) * 1000) for r in runs]
        print("%-10s fastest frame %s | typical scrolling frame %s" % (name, " ".join(mins), " ".join(meds)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-s", "--serial", help="adb serial (USB serial or ip:port)")
    ap.add_argument("--inject-serial", help="send taps via this adb serial (default: same as -s)")
    ap.add_argument("--only", help="comma-separated config names")
    ap.add_argument("--repeat", type=int, default=1, help="run the whole set N times (interleaved)")
    ap.add_argument("--taps", type=int, default=12)
    ap.add_argument("--motion", type=float, default=8.0, help="seconds of scrolling per config")
    ap.add_argument("--ping", help="phone IP to ping while streaming")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--options", help="extra ad-hoc config as key=value;key=value")
    args = ap.parse_args()

    if args.list:
        for name in CONFIGS:
            print("%-10s %s" % (name, CONFIGS[name]))
        return
    if not args.serial:
        ap.error("-s/--serial is required")

    names = args.only.split(",") if args.only else DEFAULT_SET
    configs = {n: CONFIGS[n] for n in names if n in CONFIGS}
    if args.options:
        configs["custom"] = dict(kv.split("=", 1) for kv in args.options.split(";"))

    version, server = scrcpy_version_and_server()
    bench = Bench(find_adb(), args.serial, version, server, args.inject_serial, args.debug)
    print("scrcpy server %s, device %s, %d config(s) x %d" % (version, args.serial, len(configs), args.repeat))
    results = {n: [] for n in configs}
    bench.prepare_phone()
    try:
        for rep in range(args.repeat):
            for name, opts in configs.items():
                r = bench.run_config(name, opts, taps=args.taps, motion_seconds=args.motion,
                                     ping_ip=args.ping)
                results[name].append(r)
                print(fmt(r), flush=True)
    finally:
        bench.restore_phone()

    print_pipeline([r for runs in results.values() for r in runs])
    if args.repeat > 1:
        print("\nSummary (median over %d runs):" % args.repeat)
        for name, runs in results.items():
            ok = [r for r in runs if "tap_med" in r]
            if not ok:
                continue
            merged = {"name": name, "taps": sum(r["taps"] for r in ok), "tap_n": sum(r["tap_n"] for r in ok)}
            for key in ("tap_med", "tap_min", "tap_p90", "tap_vid", "delay_p50", "delay_p95", "delay_max", "fps", "mbps"):
                merged[key] = statistics.median(r[key] for r in ok)
            merged["stalls"] = sum(r["stalls"] for r in ok)
            print(fmt(merged))


if __name__ == "__main__":
    main()
