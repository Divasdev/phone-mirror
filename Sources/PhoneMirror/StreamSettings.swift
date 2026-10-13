import Foundation

/// Quality presets shown as radio choices in the menu.
///
/// The Wi-Fi numbers come from measurements on a POCO X4 Pro (Snapdragon 695) over a
/// 2.4 GHz home network (see Tools/latency_bench.py):
///  - Constant bitrate ("CBR") matters most: in variable-bitrate mode the encoder
///    overshoots (6 Mbps asked → ~9.7 Mbps sent while scrolling) and causes lag spikes.
///  - Smaller video = smaller frames = faster delivery: 800 px was ~9 ms faster than 1024 px.
///  - The 60 fps cap must stay: without it the phone tries ~100 fps, the encoder falls
///    behind and latency jumps by ~130 ms.
enum QualityPreset: String, CaseIterable, Identifiable {
    case auto, lowLatency, smooth, lowLag, best
    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:       return "Auto (best for your connection)"
        case .lowLatency: return "Low latency (Wi-Fi)"
        case .smooth:     return "Smooth (Wi-Fi)"
        case .lowLag:     return "Data saver (weak Wi-Fi)"   // stored as "lowLag" for older settings
        case .best:       return "Best (USB)"
        }
    }

    /// Presets meant for Wi-Fi switch audio off when chosen (audio uses extra bandwidth).
    var turnsAudioOff: Bool {
        switch self {
        case .lowLatency, .smooth, .lowLag: return true
        case .auto, .best:                  return false
        }
    }
}

/// Everything needed to launch scrcpy for one mirroring session.
struct StreamSettings {
    /// Shown in the menu while mirroring, e.g. "Low latency (Wi-Fi)".
    var label: String
    /// Plain scrcpy options for this preset.
    var arguments: [String]
    /// Encoder hints (`--video-codec-options`). Dropped automatically if the phone's
    /// encoder rejects them.
    var codecOptions: String?
    /// Ask for the phone's hardware H.264 encoder by name (if one was detected).
    var wantsHardwareEncoder = false

    /// Constant bitrate: steady network traffic instead of bursts.
    static let cbr = "bitrate-mode:int=2"
    /// CBR + Android's standard real-time hints. The hints made no measurable difference on
    /// the Snapdragon 695 (its encoder already outputs each frame immediately) but they are
    /// the documented way to ask other phones for low latency. latency=1 means "hold at most
    /// one frame", the smallest meaningful value.
    static let lowLatencyOptions = "bitrate-mode:int=2,priority:int=0,latency:int=1"

    /// scrcpy's own picture settings, capped at 60 fps. The phone's screen runs faster than
    /// that, and feeding its encoder ~100 fps made it fall behind by ~130 ms when measured;
    /// the Mac can't show more than 60 anyway.
    static let best = StreamSettings(label: "Best (USB)", arguments: ["--max-fps=60"])

    static func lowLatency(bitRate: String = "4M", label: String = "Low latency (Wi-Fi)") -> StreamSettings {
        StreamSettings(label: label,
                       arguments: ["--video-codec=h264", "--max-size=800",
                                   "--video-bit-rate=\(bitRate)", "--max-fps=60"],
                       codecOptions: lowLatencyOptions,
                       wantsHardwareEncoder: true)
    }

    static let smooth = StreamSettings(label: "Smooth (Wi-Fi)",
                                       arguments: ["--max-size=1024", "--video-bit-rate=4M", "--max-fps=60"],
                                       codecOptions: cbr)

    static let dataSaver = StreamSettings(label: "Data saver (weak Wi-Fi)",
                                          arguments: ["--max-size=800", "--video-bit-rate=2M", "--max-fps=30"],
                                          codecOptions: cbr)

    /// The final scrcpy arguments for this preset.
    /// - Parameters:
    ///   - hardwareEncoder: detected encoder name, used only if the preset wants it.
    ///   - safeMode: true after the phone rejected our encoder options: use plain settings.
    func scrcpyArguments(hardwareEncoder: String?, safeMode: Bool) -> [String] {
        var result = arguments
        if !safeMode {
            if let codecOptions { result.append("--video-codec-options=\(codecOptions)") }
            if wantsHardwareEncoder, let hardwareEncoder, Validation.isSafeEncoderName(hardwareEncoder) {
                result.append("--video-encoder=\(hardwareEncoder)")
            }
        }
        return result
    }

    /// True if this launch includes anything the phone's encoder could reject.
    func usesEncoderTweaks(hardwareEncoder: String?) -> Bool {
        codecOptions != nil || (wantsHardwareEncoder && hardwareEncoder != nil)
    }
}

/// The on/off choices from the menu, turned into scrcpy options.
struct MirrorOptions: Equatable {
    /// What every mirror is started with, whatever the preset.
    ///  - `-s <serial>` picks exactly one phone.
    ///  - `--window-title=Phone Mirror` names the window.
    ///  - `--no-terminal-title` stops scrcpy from writing terminal-title codes into its log (the
    ///    log is read live for the FPS line).
    ///  - `--force-adb-forward` makes the Mac connect to the phone instead of the other way round.
    ///    Measured on 2026-10-13 (POCO X4 Pro, scrcpy 5.0): scrcpy's default direction failed with
    ///    "Server connection failed" in 7 of 10 starts over the cable while wireless debugging was
    ///    also on (the state right after "Go Wireless", before the cable is unplugged). With this
    ///    option every start worked: cable, Wi-Fi, and both together.
    static func basics(serial: String) -> [String] {
        ["-s", serial, "--window-title=Phone Mirror", "--no-terminal-title", "--force-adb-forward"]
    }

    var pocketMode = false
    var stayAwake = true
    var realKeyboard = false
    var audio = false
    var showFPS = false
    var overWiFi = false

    var arguments: [String] {
        var result: [String] = []
        if pocketMode {
            // The phone's own screen goes dark but the phone keeps working, so it can sit
            // in a pocket or bag while it is used from the Mac:
            //   --turn-screen-off     darkens the phone's screen (mirroring continues)
            //   --keep-active         stops the phone from dozing off when left alone, also
            //                         on battery, without changing any phone setting
            //   --power-off-on-close  locks the phone when mirroring ends or the connection
            //                         drops, so it is never left lit and unlocked in a bag
            result += ["--turn-screen-off", "--keep-active", "--power-off-on-close"]
        }
        if stayAwake    { result.append("--stay-awake") } // only has an effect while charging
        if realKeyboard { result.append("--keyboard=uhid") }
        if !audio       { result.append("--no-audio") }
        if showFPS      { result.append("--print-fps") }
        // Over Wi-Fi, don't send a message to the phone for every small mouse movement
        // above the window: it only competes with the video for air time. Clicks, drags
        // and scrolling still work as before.
        if overWiFi     { result.append("--no-mouse-hover") }
        return result
    }
}

/// Reading scrcpy's output.
enum ScrcpyOutput {

    /// Finds the first *hardware* H.264 encoder in `scrcpy --list-encoders` output, e.g.
    ///   --video-codec=h264 --video-encoder=c2.qti.avc.encoder   (hw) [vendor]
    /// Software encoders are marked "(sw)" and aliases "(alias for …)"; both are skipped.
    static func hardwareH264Encoder(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard line.contains("--video-codec=h264"), line.contains("(hw)"),
                  !line.contains("(alias"),
                  let range = line.range(of: "--video-encoder=") else { continue }
            let name = String(line[range.upperBound...].prefix { !$0.isWhitespace })
            if Validation.isSafeEncoderName(name) { return name }
        }
        return nil
    }

    /// scrcpy's FPS counter prints lines like "INFO: 60 fps" or
    /// "INFO: 57 fps (+3 frames skipped)". Returns (fps, skipped) or nil.
    static func fps(in line: String) -> (fps: Int, skipped: Int)? {
        guard let marker = line.range(of: " fps") else { return nil }
        let digits = line[..<marker.lowerBound].reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let fps = Int(String(digits.reversed())) else { return nil }

        var skipped = 0
        if let open = line.range(of: "(+"),
           let close = line.range(of: " frames skipped", range: open.upperBound..<line.endIndex) {
            skipped = Int(line[open.upperBound..<close.lowerBound]) ?? 0
        }
        return (fps, skipped)
    }

    /// Does this output look like the phone's video encoder refused our settings?
    static func looksLikeEncoderError(_ text: String) -> Bool {
        let markers = ["Could not create video encoder", "Could not create default video encoder",
                       "Capture/encoding error", "MediaCodec", "IllegalArgumentException",
                       "IllegalStateException", "CodecException"]
        return markers.contains { text.contains($0) }
    }
}
