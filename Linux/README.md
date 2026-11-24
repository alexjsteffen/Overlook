# Overlook for Linux — Swift / GTK4 / libadwaita

A native GNOME client for GL.iNet Comet / GLKVM, PiKVM, and Sipeed NanoKVM devices. **Connect**
signs in, receives video over **GStreamer `webrtcbin`** (both Janus `/janus/ws` and NanoKVM `/api/stream/h264`), renders it directly in
GTK4, and sends **keyboard and mouse** input over the KVMD or NanoKVM HID WebSocket (`/api/ws`). Swift
owns the desktop UI, authentication flow, Janus and NanoKVM signaling state machines, HID
protocols, certificate approvals, keepalives, timeouts, VA-API/software recording controls, and saved devices. There
is no browser or JavaScript in the native path. An optional **Web Console**
button opens the device's own web UI in WebKitGTK when needed.

This is a separate Swift Package; the macOS Xcode target is unchanged.

## Build and run

Target: Ubuntu 24.04+, Swift 6.0+, GTK 4.12+, **libadwaita 1.5+**, GStreamer
1.24+, and WebKitGTK **6.0 API** (for the optional web console; API 4.1 is GTK3
and is not compatible). Install Swift from https://www.swift.org/install/linux/
and the system libraries:

```sh
sudo apt-get update
sudo apt-get install libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev pkg-config \
  libgstreamer-plugins-bad1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-nice gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-libav libsecret-1-dev

# Recommended: build from the repository root. The Swift runtime is linked in.
make linux
./dist/overlook

# Or invoke SwiftPM directly from Linux/:
cd Linux
swift build -c release --static-swift-stdlib
.build/release/overlook
```

The root Makefile can also build Pacman, DEB, RPM, and AppImage packages, or
compile in Docker. See [Build and package from the repository root](../README.md#linux-packages)
for the target-specific prerequisites and commands.

Fedora: `gtk4-devel libadwaita-devel libsecret-devel webkitgtk6.0-devel gstreamer1-plugins-bad-free-devel
gstreamer1-plugins-base-devel libnice-gstreamer1 gstreamer1-plugins-good
gstreamer1-plugin-openh264`. Enable Fedora's `fedora-cisco-openh264` repository
if it is not already enabled; it provides the OpenH264 plugin used for H.264.
Other distributions need packages exposing `libadwaita-1`, `libsecret-1`, `webkitgtk-6.0`,
`gstreamer-webrtc-1.0`, `gstreamer-app-1.0`, and `gstreamer-video-1.0` to
pkg-config. `gstreamer1.0-nice` is required at runtime for ICE. Native packages
handle both Wayland and X11 through GTK. The AppImage currently requires X11 or
XWayland and disables the optional Web Console; use a native package for that
feature or for a pure-Wayland session.

## Using the app

The window follows the GNOME HIG: an adaptive sidebar of saved devices (it
collapses into an overlay on narrow windows), a header bar with the device name
and connection state, toasts for notifications, and Adwaita dialogs. Light,
dark, and accent preferences come from the desktop through libadwaita.

1. Enter a hostname, IP address, or HTTP(S) URL. Addresses without a scheme use
   HTTPS; explicit HTTP works for devices configured that way.
2. Enter the username and password. An optional **2FA OTP or TOTP secret** field
   accepts either a 6-digit one-time code or an RFC 6238 Base32 TOTP secret (never
   written to disk or the keyring). Password/code fields are cleared after submitting.
3. Select **Connect** (or press Enter) for the native session, or **Web Console**
   for the device's web UI.

Save a device with the bookmark button next to **Name**. To save credentials in your
desktop keyring, check **Save device and password in system keyring**; when checked,
Overlook stores the username and password in `libsecret` (not in `devices.json`)
automatically on both **Connect** and **Bookmark**. The checkbox is off by default and
2FA OTP/TOTP values are never saved. Selecting a saved device with a keyring entry
signs in automatically; otherwise it focuses the password field. Uncheck the box and
save again to forget the password, or remove the device with its trash button to remove
its keyring entry too. A working desktop keyring is required for password saving.

### Keyboard and mouse

- **Mouse** input is sent whenever the pointer is over the video: moves, left /
  middle / right buttons, back/forward buttons, and wheel or touchpad scrolling.
  Absolute positioning maps the pointer onto the letterboxed video, so it lines
  up at any window size. If the device reports relative mouse mode, motion
  deltas are sent instead and the local cursor is hidden (there is no pointer
  lock yet, so the pointer can leave the window).
- **Click the video to capture the keyboard.** While captured, every key,
  including Tab, F11, Alt+Tab, and Super, goes to the remote machine. GTK asks
  the compositor to stop handling its own system shortcuts. The app's
  accelerators are disabled while captured.
- **Press and release Left Ctrl + Left Alt** (with no other key) to release the
  keyboard. The Ctrl/Alt press is still sent to the remote machine.
- **Press Ctrl+Alt+F** (using Left Alt, so `AltGr+F` still goes to the target) to
  toggle or exit fullscreen at any time, even while keyboard capture is active;
  exiting fullscreen releases any held remote modifiers and keyboard capture.
- The **keyboard** menu in the header bar has *Capture Keyboard*, *Release All
  Keys*, and *Send Ctrl+Alt+Delete / Ctrl+Alt+Backspace / Print Screen*.
- Keys are sent by physical position (evdev scancode → KVMD key name), so the
  remote machine's keyboard layout decides which character is typed.
- Held keys and buttons are released when the keyboard is released, the window
  loses focus, or the session ends.

Shortcuts when the keyboard is not captured: **Ctrl+N** new connection,
**Ctrl+R** reload/reconnect, **Ctrl+I** connection information, **Ctrl+L**
connection log, **Ctrl+,** settings, **Ctrl+Shift+S** save screenshot,
**Ctrl+Shift+R** start/stop VAAPI recording, **Ctrl+Shift+V** paste clipboard to
remote, **F11** or **Ctrl+Alt+F** fullscreen (header bar and sidebar are hidden,
and a toast states the exit hotkey), **Ctrl+W** disconnect, **Ctrl+Q** quit.

### Connection Information & Telemetry

Select the **Connection Information** button in the header bar (or press **Ctrl+I**)
to inspect live session and stream diagnostics:

- **Session**: connection status, session uptime, reconnect history, reconnect,
  server-side token logout (`POST /api/auth/logout`), and disconnect.
- **Device & HID**: HID WebSocket link status and USB gadget state, live
  ping/pong **HID RTT (ms)**, keyboard LEDs (`CAPS`, `NUM`, `SCROLL`), ATX
  motherboard LEDs (`Power`, `HDD`), and HDMI capture source resolution/FPS.
- **WebRTC Stream**: decoded video resolution, rendered FPS, bitrate (kbps),
  codec, jitter, packet loss, PLI/NACK repair counts, ICE RTT, candidate path,
  and remote peer address.
- **Connection Log**: rotating log at `$XDG_STATE_HOME/overlook/connection.log`
  with an interactive viewer filterable by severity level and subsystem category.

### Device & App Settings

Select the **Settings** button in the header bar (or press **Ctrl+,**) to open
the multi-page libadwaita preferences dialog matching the macOS configuration
options:

- **Video & Capture**: low-latency vs. smart processing mode, quality presets
  (Low, Medium, High, Ultra-high, Lossless with automatic 4K EDID GOP halving, Custom),
  full EDID preset catalog and custom hex editor (`/api/upgrade/edid`), orientation
  (`0°`–`270°`), cursor visibility, custom ustreamer FPS/quality/bitrate/GOP/zero-delay/resolution
  (`/api/streamer/set_params`), direct hardware streamer JPEG snapshots
  (`/api/streamer/snapshot`), PiKVM server Tesseract OCR, and local screenshot /
  VAAPI recording settings.
- **Input & HID**: mouse and keyboard capture toggles, emulated USB HID gadget
  connection (`/api/hid/set_connected`), keyboard (`usb`, `ps2`, `disabled`) and
  mouse (`usb`, `usb_rel`, `usb_win98`, `ps2`, `disabled`) output modes,
  absolute vs. relative mouse mode, polling rate, device and local relative
  sensitivity, scroll rate and reverse scroll direction, hardware mouse jiggler,
  fingerbot strength, HID reset, keymap selector (`/api/hid/keymaps`), quick and
  custom shortcuts, and remote text typing (`/api/hid/print`) with slow mode and
  inter-key delay.
- **Media & Hardware**: Virtual Media / Mass Storage Drive (`/api/msd/*` and NanoKVM
  `/api/storage/media/*`) image selection, CD-ROM vs. Flash Read-Write mode, drive
  connect/disconnect, local ISO/IMG upload by file path, remote URL download to KVM,
  GLKVM partition connect/disconnect, ATX power actions (`/api/atx/power`) and
  front-panel buttons (`/api/atx/click`), Redfish BMC (`ComputerSystem.Reset`),
  read-only GPIO channel monitoring (`GET /api/gpio`), and PiKVM Multi-Port Switch
  (`/api/switch/*`) port selection, beacons, dummy plugs, and hex colors (per-port
  Switch ATX actions are macOS-only).
- **System & Network**: app appearance (`System`, `Light`, `Dark`), **Media Addresses**
  (`Chosen network only` vs. `All addresses`), **Wake Display on Connect** mouse nudge,
  device WebUI theme/language/timezone, live hardware health from `/api/info` (platform,
  serial, KVMD/ustreamer/kernel versions, CPU/memory usage, temperatures,
  throttling/undervoltage flags), modal viewers for KVMD service logs (`/api/log`)
  and Prometheus metrics (`/api/export/prometheus/metrics`), and IPv4 DHCP/Static,
  Wi-Fi, and Ethernet configuration (`/api/network/*`).

### Screenshots & VAAPI Recording

- **Screenshots** (**Ctrl+Shift+S** or the camera button in the header bar) save
  the current WebRTC video frame directly as a PNG in `~/Pictures/Overlook` (or
  fall back to `GET /api/streamer/snapshot` if no WebRTC frame has arrived).
- **Recordings** (**Ctrl+Shift+R** or the record button in the header bar) encode
  MP4 (`H.264` or `HEVC`) in `~/Videos/Overlook` using **VA-API** hardware
  acceleration. Overlook automatically probes `/dev/dri/renderD*` via `libva` /
  `libva-drm` for `VAEntrypointEncSlice` / `VAEntrypointEncSliceLP` so multi-GPU
  systems select the render node with hardware encoding support, falling back to
  software encoding if no VAAPI encoder is present.

### Self-signed certificates

KVM devices usually ship with a self-signed certificate. When the system does
not trust the device certificate, Overlook stops and shows an **Unverified
Certificate** dialog with the reason and the certificate's SHA-256 fingerprint:

- **Cancel** stops the connection (the default).
- **Trust Once** accepts that exact certificate for this host and port until you
  disconnect.
- **Always Trust** also pins its fingerprint in
  `$XDG_CONFIG_HOME/overlook/trusted-certificates.json` (mode 0600), so future
  connections proceed without asking.

If a pinned device later presents a **different** certificate, a
**Certificate Changed** warning is shown instead; it is never replaced silently.
*Forget Trusted Certificates* in the main menu clears every pin.

The same approval applies to the login request, the Janus signaling socket, and
the HID socket in native mode, and to the WebKit web console. Overlook never
disables TLS verification globally: only the approved fingerprint is accepted,
and only for that host and port. Login requests do not follow redirects, to
avoid forwarding credentials to another endpoint.

## Native implementation

- `Sources/OverlookCore/JanusSignaling.swift`: Swift protocol state machine for
  Janus create → attach `janus.plugin.ustreamer` → watch → SDP offer/answer → start,
  plus trickle ICE, keepalive, server errors, and teardown. It follows the same
  video-only watch parameters as `Overlook/WebRTCManager.swift`.
- `Sources/OverlookCore/HIDInput.swift`: KVMD `/api/ws` binary HID frames (key,
  mouse button, absolute move, relative move, wheel), the evdev → KVMD key-name
  map, letterbox coordinate mapping, wheel sign conversion, and HID state parsing.
- `Sources/OverlookCore/CertificateStore.swift`: SHA-256 fingerprints and the
  persistent trust-on-first-use pin store.
- `Sources/OverlookGTK/NativeSession.swift`: Swift session coordinator. Logs in
  through `/api/auth/login`, opens `/janus/ws` with `janus-protocol` and `/api/ws`
  for HID, carries cookie or JSON-token authentication, resumes after a
  certificate approval, translates GTK input into HID frames, and drives
  GStreamer through C interop.
- `Sources/CNative/Native.c`: native library adapter. libsoup3 supplies Linux
  HTTP/WebSocket transport and certificate checks (`accept-certificate`, matched
  against approved fingerprints); GStreamer supplies SDP/ICE/DTLS/SRTP and codecs.
  Received RTP goes through `decodebin` → RGBA `appsink` → `GdkMemoryTexture` →
  `GtkPicture`. GTK event controllers on the picture capture key, click, motion,
  scroll, and focus events and request system-shortcut inhibition while focused.
  At most one frame is pending for GTK, so UI delays do not grow a frame queue.
- `Sources/OverlookCore/NanoKVM.swift`, `KVMModels.swift`, `MediaNetwork.swift`,
  `RemotePaste.swift`, `CaptureConfig.swift`, `EDIDCatalog.swift`,
  `StreamTelemetry.swift`, `ConnectionLog.swift`, `Device.swift`: shared protocol
  and core models (also synced verbatim to `Windows/Sources/OverlookCore/`).
- `Sources/OverlookGTK/main.swift`, `ConnectionInfoDialog.swift`,
  `SettingsDialog*.swift`, `PasswordStore.swift`: libadwaita window, sidebar,
  connect page, connection diagnostics, 4-page settings dialogs, `libsecret`
  keyring store, and optional WebKitGTK web console.
- `Sources/CDesktop/shim.h`, `adw.h`: thin C adapters for GTK, WebKitGTK, and
  libadwaita macros, casts, and signal callbacks. `CAdwaita` only contributes the
  `libadwaita-1` pkg-config flags.
- Native close cancels network requests, releases held keys, closes both sockets,
  stops pipelines, discards session cookies and session-only certificate
  approvals, and suppresses queued callbacks from old sessions.

## Current limits

- **No audio playback or USB microphone**: WebRTC streams video only (`audio: false`, `mic: false`).
- **OCR**: Only PiKVM server-side Tesseract (`GET /api/streamer/snapshot?ocr=true`) is available; there is no on-device local OCR or box-selection overlay like macOS Apple Vision.
- **Hardware UI gaps vs. macOS**: User GPIO displays read-only pin state (`GET /api/gpio`) without output switching/pulsing controls, Multi-Port Switch omits per-port ATX actions, MSD local uploads enter a file path rather than opening a GTK file chooser, and Redfish VirtualMedia is not exposed in the UI.
- **Single-window / primary address UI**: Opens one console window at a time; while `Device` stores multiple addresses, the Linux UI connects to the saved device's primary `address`.
- **No discovery**: No mDNS/Bonjour, subnet sweep, or Tailscale CLI peer discovery; enter hostnames/IPs or `*.ts.net` addresses directly and bookmark them.
- **No pointer lock for relative mouse**: Absolute mode (the KVMD default) is recommended so the pointer cannot drift outside the window.
- **No TURN configuration or auto-reconnect**: Native connections require a directly reachable ICE path (LAN or routed VPN/Tailscale), and interrupted streams require reloading with `Ctrl+R`.
- **Rendering & AppImage**: GTK copies RGBA frames into `GdkMemoryTexture` (not zero-copy DMA-BUF). The AppImage bundle disables WebKitGTK (`OVERLOOK_DISABLE_WEB_CONSOLE=1`) and requires X11/XWayland; use native DEB/RPM/Pacman packages for pure Wayland or the embedded Web Console.
- **Web Console restrictions**: Microphone/camera permissions, downloads, popups, and external URI handlers stay denied under WebKit's defaults.

Both session types keep active cookies/tokens in memory. Closing or disconnecting ends only the local client session; use **Log Out and Disconnect** (in the menu or Connection Information dialog, backed by `POST /api/auth/logout`) when you want to revoke the server-side token immediately. Bookmarks contain only names and addresses at `$XDG_CONFIG_HOME/overlook/devices.json` (normally `~/.config/overlook/devices.json`), mode 0600. A corrupt JSON file disables saving until repaired and the app restarted.

## Tests

```sh
cd Linux
swift test
sudo apt-get install xvfb xauth dbus-x11
# Three real local peer connections: VP8 -> H.264 -> VP8, with teardown between.
# Exits successfully only after receiving and displaying a decoded frame each time.
timeout 45s dbus-run-session -- xvfb-run -a .build/debug/overlook --native-smoke-test
# H.264 loopback + dialogs + PNG screenshot & MP4 recording smoke check:
timeout 45s dbus-run-session -- xvfb-run -a .build/debug/overlook --capture-smoke-test
# Optional embedded-console regression test:
timeout 45s dbus-run-session -- xvfb-run -a .build/debug/overlook --smoke-test
```

The native smoke test generates a local RTP stream, negotiates two `webrtcbin`
peers, transports video over ICE/DTLS/SRTP, decodes it, and sets a GTK texture.
It does not bypass WebRTC by showing a local test pattern directly. The H.264
sender uses `openh264enc`; the VP8 sender uses `vp8enc`. The `OverlookCoreTests`
suite comprises **42 XCTest cases across 7 test files** covering Janus signaling,
`JanusSenderFilter`, NanoKVM crypto/signaling/HID/models, `MediaRoute` ICE filtering,
`RemotePasteChunker`, TOTP RFC 6238 vectors, `EDIDCatalog`, `StreamTelemetry`,
`ConnectionLog`, bookmark persistence/corruption checks, HID key maps/scroll
accumulation/`HIDCaptureChordTracker` (`Ctrl+Alt+F` and capture release), SHA-256
vectors, and the TOFU certificate store.

From the repository root, use the root Dockerfile through the Makefile:

```sh
# Compile and run unit tests in Docker, then export dist/overlook:
make docker

# Build the test image and run the native WebRTC smoke test:
make docker-test
```

The Docker test image runs the native test by default. The optional WebKit smoke test
may require `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` in restricted containers;
that override is confined to CI's disposable local-HTML test and is unnecessary
for native WebRTC. Do not use it for normal browsing.

## Optional desktop installation

After a direct SwiftPM build as shown above:

```sh
install -Dm755 .build/release/overlook ~/.local/bin/overlook
install -Dm644 packaging/io.github.overlook.Linux.desktop \
  ~/.local/share/applications/io.github.overlook.Linux.desktop
```

Ensure `~/.local/bin` is in the desktop session's PATH. With
`--static-swift-stdlib` (used by `make linux`), no separate Swift runtime is
needed. GTK, libadwaita, WebKit, GStreamer, and their other dependencies are
still dynamically linked; this is not a standalone desktop-library bundle.

## Upstream APIs

- GTK4: https://docs.gtk.org/gtk4/
- libadwaita: https://gnome.pages.gitlab.gnome.org/libadwaita/doc/1-latest/
- GNOME HIG: https://developer.gnome.org/hig/
- KVMD HID WebSocket: https://github.com/pikvm/kvmd (`kvmd/apps/kvmd/api/hid.py`)
- Native WebRTC: https://gstreamer.freedesktop.org/documentation/webrtc/
- WebKitGTK6: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/gtk/migrating-to-webkitgtk-6.0.md

## Validation & CI

CI runs on Ubuntu 24.04 (`swift:6.0-noble`) in [linux.yml](../.github/workflows/linux.yml)
and [build.yml](../.github/workflows/build.yml), building the release binary, executing
all **42 `OverlookCoreTests`**, running `--smoke-test` (WebKitGTK) and
`--native-smoke-test` (3-cycle VP8/H.264 GStreamer WebRTC loopback), and linting the
Arch `PKGBUILD` via `makepkg --printsrcinfo` / `namcap`. Local desktop builds on
Arch/Ubuntu have also verified `--capture-smoke-test` (PNG + VA-API/software MP4)
and Broadway/X11 self-signed certificate trust flows against simulated KVMD endpoints.

## Further Documentation

- [Architecture — How Overlook Works](../docs/ARCHITECTURE.md)
- [PiKVM, GLKVM & NanoKVM API Guide](../docs/PIKVM_GLKVM_API_GUIDE.md)
- [Platforms, Parity & Shortcuts](../docs/PLATFORMS.md)
- [Security, Privacy & Storage Paths](../docs/SECURITY_AND_STORAGE.md)
- [Building, Packaging & Testing](../docs/BUILD_AND_TESTING.md)
