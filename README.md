# Phone Mirror

A tiny macOS menu bar app that mirrors your Android phone using **scrcpy** + **adb**, with no Terminal needed.
It can also receive files that the phone sends with **Quick Share**, with no cable and no setup on the phone.
It uses only Apple frameworks: no third-party packages, no internet connections, no analytics.

## Requirements
- macOS 14+ on Apple Silicon
- An Android phone with Developer options → **USB debugging** ON (Xiaomi/POCO: also **USB debugging
  (Security settings)**). The app's **Getting Started…** window walks through this.
- Nothing else: the mirroring engine (scrcpy 5.0 + adb) is inside the app.
- To build it yourself you need the Command Line Tools (Xcode is **not** needed). `./build.sh` downloads the
  official scrcpy release, checks its fingerprint and puts it in the app. `ENGINE=homebrew ./build.sh` makes a
  build that uses Homebrew's copies instead (`brew install scrcpy` and
  `brew install --cask android-platform-tools`); that is also the way back if the built-in engine misbehaves.

## Features
- **Mirror Phone**: picks the phone automatically (USB preferred) and passes its exact serial, so there's never a
  "multiple devices" error. Reconnects to the last known Wi-Fi/hotspot address by itself.
- **Quality presets**:
  | Preset | Settings | Use it for |
  |---|---|---|
  | **Auto** (default) | USB → Best; Wi-Fi → Low latency; weak Wi-Fi → Low latency at 2 Mbps | Everyday use |
  | **Low latency (Wi-Fi)** | 800 px, 4 Mbps constant bitrate, 60 fps, hardware H.264 encoder, real-time encoder hints | Least lag over Wi-Fi |
  | **Smooth (Wi-Fi)** | 1024 px, 4 Mbps constant bitrate, 60 fps | Sharper picture on a good Wi-Fi |
  | **Data saver (weak Wi-Fi)** | 800 px, 2 Mbps constant bitrate, 30 fps | Very weak networks |
  | **Best (USB)** | scrcpy's own picture settings, capped at 60 fps | Cable |
- **Pocket mode**: the phone's own screen goes dark while you use it from the Mac, so it can stay in a pocket
  or bag. See "Pocket mode" below.
- **Phone Files (drag & drop)**: a small window that shows the phone's folders. Drag files in to send them to
  the phone, drag files out to copy them to the Mac. See "Copying files" below.
- **Receive with Quick Share**: tick it in the menu and the Mac shows up in the Quick Share list of Android
  phones on the same Wi-Fi. No cable, no USB debugging, no app on the phone. See "Quick Share" below.
- **Getting Started**: three steps (engine, USB debugging, cable) with live ticks. Opens by itself the first
  time the app runs, and from the menu any time.
- **Go Wireless (home Wi-Fi)**, **Hotspot Mode (direct link)**, **Disconnect Wireless**.
- **Connection quality** in the menu (only measured while the menu is open): the Wi-Fi band of phone and Mac,
  ping and jitter to the phone, a Good / OK / Poor label, and a tip when 2.4 GHz or lag is detected.
- **Show FPS**: the live frame rate (from scrcpy's `--print-fps`) next to the menu bar icon and in the menu.
- If a phone's encoder rejects the low-latency encoder options, mirroring automatically restarts without them.

## Pocket mode
Tick **Pocket mode (phone screen off, use it from the Mac)** in the menu, then click **Mirror Phone**. For a
phone in your bag, connect wirelessly first (**Go Wireless** or **Hotspot Mode**) and unplug the cable.

- The phone's screen goes dark as soon as mirroring starts. The mirror on the Mac keeps working.
- The phone is kept awake, also on battery, so the mirror doesn't go black after a minute. No phone setting
  is changed for this.
- When you stop mirroring, or the connection drops, the phone **locks itself**. It is never left lit and
  unlocked in your bag.
- **Don't press the phone's power button** while mirroring: that really puts it to sleep. If it happens,
  right-click in the mirror window to wake it and type your PIN on the Mac's keyboard.
- Phone locked and still in the bag? If the wireless connection is still on, **Mirror Phone** wakes it; unlock
  with the PIN from the Mac. (Fingerprint and face unlock need the phone itself.)
- It uses the phone's battery (the phone is awake and sending video) and the phone can get warm in a closed
  bag. Keep the phone on the same Wi-Fi or hotspot as the Mac.
- Shortcuts in the mirror window: **⌥O** phone screen off, **⌥⇧O** phone screen on, **⌥P** power button.

## Copying files (drag and drop)
Menu bar icon → **Phone Files (drag & drop)…** opens a window with the phone's shared storage (Downloads,
Camera, Screenshots, …). It works over the cable or Wi-Fi, with or without mirroring. The cable is much faster.

| You want to… | Do this |
|---|---|
| Send files or folders **to the phone** | Drag them from Finder into the window. They land in the folder you are looking at; drop them on a folder row to put them inside that folder. Or click **Send Files…** |
| Copy files or folders **to the Mac** | Drag rows out of the window to the Desktop, a Finder window or another app. Or select them and click **Save to Downloads** |
| Look around | Double-click a folder, **‹** goes back, the folder button jumps to common places, **↻** (⌘R) reads the folder again |

- **Nothing is ever replaced or deleted.** If a name is already taken, the copy is called `photo (2).jpg`.
- **Stop** ends the running copy and removes the half-copied file.
- The first time you copy to or from the Desktop, Documents or Downloads, macOS may ask whether Phone Mirror
  may use that folder. Click **Allow**.
- You can also drop files straight onto the **mirror window**: scrcpy copies them to the phone's Download
  folder. Careful: an `.apk` file dropped there is *installed* on the phone. (Dropped on the Phone Files
  window, an `.apk` is only copied.)
- Files can't be dragged out of the mirror picture itself: it is a live video of the screen, so the Mac
  doesn't know which file is under the pointer. Use the Phone Files window for that.

## Quick Share (phone → Mac, no cable)
Tick **Receive with Quick Share** in the menu. The line under it shows the name the Mac is visible under.
On the phone: **Share → Quick Share →** your Mac. A small card appears in the top-right corner of the Mac's
screen; click **Accept** and the file is saved in Downloads.

- Phone and Mac must be on the **same Wi-Fi** (or the Mac on the phone's hotspot). A guest network keeps
  devices apart, so it won't work there.
- It needs nothing on the phone: no USB debugging, no cable, and it works with a phone that has never been
  plugged in.
- It is **off until you tick it**. While it is off the app does not listen on the network at all.
- **Nothing is saved until you click Accept**, for every share. The card shows who is sending, what, and a
  4-digit code; if the phone shows a code too, the two should match. The card never takes the keyboard away
  from the app you are typing in, and Return never accepts.
- Files go to Downloads. A file that is already there is never replaced ("photo (2).jpg"), and a transfer that
  breaks off, is stopped or is cancelled leaves no half file behind.
- Shared text and links are put on the clipboard; web links get an **Open Link** button.
- Received files are marked as downloads, so macOS checks an app or script before its first run.
- It goes one way, phone → Mac. To put files on the phone use **Phone Files**.
- Not taken: Wi-Fi passwords and apps shared with Quick Share.

How it works, in one paragraph: the Mac announces itself with Bonjour (service `_FC9F5ED42C8A._tcp`) and
listens on a port macOS picks. The phone connects, both sides do Google's UKEY2 key exchange (P-256), and
everything after that is encrypted (AES-256-CBC) and signed (HMAC-SHA256). The code is in the
`QuickShare*.swift` files; the protocol is described in the notes of the open-source NearDrop project
(https://github.com/grishka/NearDrop, public domain), which this was written from.

## Why these settings? (measured)
Measured on a POCO X4 Pro (Snapdragon 695, Android 13) with `Tools/latency_bench.py`, over a 2.4 GHz home router:
- The phone's **hardware encoder** (`c2.qti.avc.encoder`) is used. It can encode at most 1920×1088, so scrcpy's
  full-size default (1080×2400) fails once and scrcpy falls back to a smaller size by itself.
- The biggest lag cause was the **network**: phone → router → Mac is two wireless trips on the same crowded 2.4 GHz
  channel. Usable speed was only ~15–18 Mbps, and ping to the phone jumped between 5 ms and 190 ms.
- **Constant bitrate** made the most difference: in variable mode, "6 Mbps" actually sent ~9.7 Mbps while
  scrolling and caused lag spikes (37 late frames vs 4 at 4 Mbps constant).
- **Smaller is faster**: at 4 Mbps, frames arrived ~5 ms after capture at 800 px vs ~14 ms at 1024 px and
  ~20–27 ms at 1280 px (typical scrolling frame, relative to the fastest frame).
- **Keep the 60 fps cap**: without it the phone tries ~100 fps, the encoder falls behind, and latency grows by ~130 ms.
- The encoder hints (`priority=0`, `latency=1`, Qualcomm's low-latency mode) made no measurable difference on this
  phone (its encoder already sends each frame immediately); they're kept because they help on other phones.

Added later, following from the same measurements (not yet re-measured on the phone):
- **Best (USB)** is capped at 60 fps too, for the same reason as above.
- Over Wi-Fi, mouse movement above the window without a click is no longer sent to the phone
  (`--no-mouse-hover`): those messages used the same crowded air as the video. Clicks, drags and scrolling are
  unchanged.

## Getting the lowest lag
1. **USB cable** is always best.
2. **Hotspot Mode** is the best wireless option: the phone talks to the Mac directly (one wireless trip, no
   router). Set the phone's hotspot band to **5 GHz** (Settings → Connection & sharing → Portable hotspot →
   Set up portable hotspot → AP band). Note: the Mac uses the phone's mobile data while on its hotspot.
3. On a home router, use a **5 GHz** network for both phone and Mac.
4. Macs pause Wi-Fi briefly and regularly for AirDrop/Handoff (small periodic spikes). If you see regular
   stutters, setting AirDrop to "Receiving Off" in Control Center may help.

## Rebuild / reinstall
```bash
cd ~/PhoneMirror
./build.sh
```
This compiles (`swift build -c release`), makes `build/Phone Mirror.app` with its icon and the engine inside,
signs it ad-hoc with the hardened runtime, and copies it to `/Applications` (or `~/Applications`).

## The download and the website
```bash
./release.sh               # → dist/Phone-Mirror.dmg, the file other people download
Scripts/serve_site.sh      # builds the website and shows it at http://localhost:8080 (this Mac only)
```
- `release.sh` builds the app with the engine inside: it downloads the official scrcpy release (which
  includes adb), checks its SHA-256 fingerprint, and puts it in `Contents/Helpers`. To move to a newer scrcpy,
  change the version and fingerprint at the top of `Scripts/fetch_engine.sh`.
- The website is made for **phonemirror.in**. Its pages are in `website/pages/` (home, download, setup guide,
  privacy and security), the shared top and bottom in `website/layout.html`, the look in
  `website/static/assets/site.css`. `website/build.py` puts them together, fills in the version, size and
  fingerprint of the current download, and writes the finished site, download included, to `dist/site/`.
  That folder is what gets uploaded to a web host. No trackers, no outside files. The look is off-white
  paper with frosted-glass panels; the colours and the glass are the variables at the top of `site.css`.
  Headings use the Instrument Serif typeface, hosted with the site (`assets/fonts/`, with its open licence).
- After changing the app: `./release.sh`, then `Scripts/serve_site.sh` (or `python3 website/build.py`), so the
  site shows the new version and fingerprint.
- The video at the top of the home page is two files in `website/static/assets/video/`: `hero-loop` (short,
  silent, plays by itself) and `film-720p.mp4` (the full film with music, loaded only when someone presses
  "Play with sound"). Replace a file and rebuild to change it.
- The download is **not notarized by Apple** (that needs the paid Apple Developer Program). People who
  download it approve it once in System Settings → Privacy & Security → Open Anyway; the site's download page
  shows the steps and the security page explains how to check the file. If a Developer ID is ever added:
  `SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE="phone-mirror" ./release.sh`
  signs it and sends it to Apple, and the approval steps can come off the site.
- The link-preview picture is `website/static/assets/og.png`, made from `website/_og.html` with:
  `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars
  --window-size=1200,630 --screenshot=website/static/assets/og.png "file://$PWD/website/_og.html"`

To check the code without a phone, run `swift test`. The tests use a pretend phone (a small script that answers
adb's file commands from a temporary folder), so they never touch a real one.

### Putting the website online
The site is plain files, so any static host works. This repository is set up for Vercel:

1. `Scripts/publish_site.sh` builds the site and copies the finished result into `public/`.
2. Commit and push. Vercel serves the `public/` folder as it is (`vercel.json` says so: no framework,
   no build step), and updates about a minute after every push.

The pages load Vercel Web Analytics (`/_vercel/insights/script.js`, in `website/layout.html`), which counts
visits anonymously once it is switched on in the Vercel dashboard (Analytics → Enable). The app itself
has no analytics of any kind.

The download (`public/download/Phone-Mirror.dmg`) is part of that folder, because it can only be built
on a Mac. After a new version of the app: `./release.sh`, then `Scripts/publish_site.sh`, then commit
and push.

## Uninstall
1. Menu bar icon → turn off **Launch at login** → **Quit Phone Mirror**
2. Delete the app and its settings:
```bash
rm -rf "/Applications/Phone Mirror.app"
defaults delete in.phonemirror.app
```

## Project layout
| File | What it does |
|---|---|
| `Sources/PhoneMirror/PhoneMirrorApp.swift` | Menu bar icon and the dropdown menu |
| `Sources/PhoneMirror/AppState.swift` | Status, saved settings, Mirror action, Auto preset, encoder fallback |
| `Sources/PhoneMirror/AppState+Wireless.swift` | Go Wireless, Hotspot Mode, Disconnect Wireless |
| `Sources/PhoneMirror/AppState+Quality.swift` | When and how the connection quality is measured |
| `Sources/PhoneMirror/StreamSettings.swift` | Presets → scrcpy options; parsing encoder lists and FPS lines |
| `Sources/PhoneMirror/ConnectionQuality.swift` | Good/OK/Poor rules, ping parsing, safe `/sbin/ping` runner |
| `Sources/PhoneMirror/MacNetwork.swift` | The Mac's Wi-Fi band and router address (read locally from macOS) |
| `Sources/PhoneMirror/ADB.swift` | Safe wrappers around adb commands and output parsing |
| `Sources/PhoneMirror/ScrcpyRunner.swift` | Starts/stops scrcpy; reads its log live (for FPS) |
| `Sources/PhoneMirror/FilesWindow.swift` | The Phone Files window: the file list and its drag and drop |
| `Sources/PhoneMirror/FileBrowser.swift` | What that window shows: the current folder, the copy status |
| `Sources/PhoneMirror/FileTransfers.swift` | Copies files one at a time; never replaces a file; Stop |
| `Sources/PhoneMirror/PhoneFiles.swift` | Phone folders and files; the adb file commands (list, push, pull) |
| `Sources/PhoneMirror/ProcessRunner.swift` | Runs programs without a shell, with timeouts |
| `Sources/PhoneMirror/ToolLocator.swift` | Finds adb/scrcpy: inside the app (if its code seal is intact), else Homebrew; ping from `/sbin` |
| `Sources/PhoneMirror/SetupWindow.swift` | The Getting Started window |
| `Sources/PhoneMirror/QuickShareReceiver.swift` | Quick Share: the listener, the Bonjour announcement, who is let in |
| `Sources/PhoneMirror/QuickShareConnection.swift` | Quick Share: one phone's share from connecting to the saved files; cleaning of names |
| `Sources/PhoneMirror/QuickShareCrypto.swift` | Quick Share: the key exchange and the encrypted channel (CryptoKit, CommonCrypto) |
| `Sources/PhoneMirror/QuickShareMessages.swift` | Quick Share: the messages that are read and written |
| `Sources/PhoneMirror/QuickShareWire.swift` | Quick Share: the small Protocol Buffers reader and writer |
| `Sources/PhoneMirror/QuickShareWindow.swift` | Quick Share: the accept / progress / result card |
| `Sources/PhoneMirror/AppState+QuickShare.swift` | Quick Share: the switch in the menu |
| `Sources/PhoneMirror/Validation.swift` | Private-LAN IP, port, serial, encoder-name and phone-path checks |
| `Sources/PhoneMirror/FriendlyError.swift` | Plain-English error alerts and "Show Details" |
| `Scripts/make_icon.swift` | Draws the app icon |
| `Scripts/fetch_engine.sh` | Downloads the official scrcpy release and checks its fingerprint |
| `release.sh` | Builds the download for other people (`dist/Phone-Mirror.dmg`) |
| `website/` | The website for phonemirror.in: pages, layout, styles, and `build.py` that assembles them |
| `Scripts/serve_site.sh` | Builds the website and serves it on localhost |
| `Resources/THIRD-PARTY-NOTICES.txt` | Credits and licences for scrcpy and adb, shipped inside the download |
| `Tests/PhoneMirrorTests/` | Checks that run on the Mac without a phone (`swift test`) |
| `Tools/latency_bench.py` | Developer tool: measures latency/jitter of scrcpy settings on a real phone |
| `Tools/quickshare_fake_phone.py` | Developer tool: a pretend Android phone that sends with Quick Share, written separately from the app (Python, Google's own message definitions) |
| `website/make_images.py` | Makes the small and WebP copies of the site's pictures (needs Pillow) |

## Troubleshooting

**"Phone not found"**
- Plug in the cable, unlock the phone, and check for an "Allow USB debugging?" popup.
- For Wi-Fi: Mac and phone must be on the *same* network (not a guest network). After the phone restarts,
  wireless mode is off, so plug in once and click **Go Wireless** (or **Connect via Hotspot**) again.
- Try a different cable/port. Some cables are charge-only.

**Hotspot Mode won't connect**
- The Mac must be joined to the phone's hotspot (Wi-Fi icon in the Mac's menu bar), not your home Wi-Fi.
- Wireless debugging must be on: plug in the cable, then click **Connect via Hotspot**.

**The mirror shows, but clicks/typing don't work (Xiaomi / POCO / HyperOS)**
- Developer options → turn ON **USB debugging (Security settings)**. Xiaomi requires a SIM card and a Mi account
  sign-in for this switch. Then stop and start mirroring again.
- If it turns itself off, toggle it again after a reboot.

**Lag or stutter**
- Look at the **Connection** line in the menu. "Poor" or a 💡 tip means the network is the problem.
- Use the cable, or Hotspot Mode on 5 GHz, or a 5 GHz router network (see "Getting the lowest lag").
- Keep the **Auto** or **Low latency** preset. Turn Audio off.
- Turn on **Show FPS** to compare settings: steady ~60 fps with few "skipped" frames is smooth.

**The Mac doesn't show up in the phone's Quick Share list**
- Is **Receive with Quick Share** ticked, and does the line under it start with 📥? If it starts with ⚠️ it
  says what is wrong.
- Phone and Mac on the same Wi-Fi, and not a guest network.
- System Settings → Privacy & Security → **Local Network**: Phone Mirror must be switched on.
- If the Mac's firewall is on, allow incoming connections for Phone Mirror when macOS asks.

**A file won't copy**
- The bottom of the Phone Files window says why; **Details…** lists every file that failed.
- "macOS blocked that folder": System Settings → Privacy & Security → Files and Folders → allow Phone Mirror.
- The phone's `Android/data` and `Android/obb` folders are closed to adb on Android 11 and newer.

**"Launch at login" won't stay on**
- Check System Settings → General → Login Items and allow Phone Mirror.

**See the raw error**
- Menu → **Show details of last error…** or **Show scrcpy output…** (kept in memory only).

## Measuring latency yourself (developer tool)
`Tools/latency_bench.py` (Python standard library only) runs scrcpy's phone-side server with different settings,
times every video frame, and measures tap-to-frame latency and frame-delay jitter. During a run it opens the
phone's Settings app, scrolls it, taps the status bar, and turns on "Pointer location" (restored afterwards).
```bash
python3 Tools/latency_bench.py --list                         # available settings
python3 Tools/latency_bench.py -s <serial or ip:5555> --only cbr4,cbr4_800 --repeat 2
```

## Security notes
- adb, scrcpy and ping are started with `Process` + an arguments array (no shell), from verified paths only:
  for adb/scrcpy the app's own `Contents/Helpers` or Homebrew, for ping the SIP-protected `/sbin`.
- The copies inside the app are only used while the app is exactly as it was signed. At launch macOS checks
  the whole app against its code signature; if any file in it was swapped, added or edited, the built-in tools
  are refused. The built-in adb keeps Google's own signature.
- Every IP (saved address, hotspot router, ping target) must be a private LAN address (10.x, 172.16–31.x,
  192.168.x); port 5555 or 1024–65535.
- The app makes no internet requests. The only network traffic it starts itself is a short ping to the phone
  while the menu is open. Wi-Fi band and router address are read locally from macOS; network names are never
  read.
- It opens a network port in one case only: while **Receive with Quick Share** is ticked (off by default).
  Then it announces the Mac's name on the local network and listens on one port. Only devices on the same
  local network are let in (private IPv4 ranges, link-local and private IPv6, or the Mac's own IPv6 network);
  everything else is dropped before a single message is read. What a device sends is treated as untrusted:
  message sizes are capped, file names are cleaned (no "../", no hidden or control characters), nothing is
  written before Accept, a file is created only under a free name (never opened if it exists), and at most
  six devices are served at a time.
- Settings (phone IP + UI choices) live in UserDefaults; nothing else is written to disk, apart from the
  files you copy yourself or accept from Quick Share, which go only where you drop them or to your Downloads
  folder.
- Phone Files stays inside the phone's shared storage (`/sdcard`): every path is checked before adb gets it.
  It lists and copies through adb's file service, so no shell runs on the phone and a strange file name can't
  act as a command. It never replaces or deletes a file, on either side.
- **Wireless debugging lets anyone on the same network try to connect to your phone.** Use it only on your
  home Wi-Fi or your own hotspot and click **Disconnect Wireless** when done (or keep "Auto-disable wireless when
  I quit" on). If connecting fails, the app switches wireless debugging back off.
