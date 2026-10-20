# Overlook for Linux — Swift / GTK4 preview

The default **Connect native** path uses **GStreamer `webrtcbin`** for WebRTC and
renders decoded video directly in GTK4. Swift owns the desktop UI, authentication
flow, Janus signaling state machine, keepalives, timeouts, and saved devices.
There is no browser or JavaScript in the native media path. A separate **Web
console** button retains the embedded WebKitGTK console for input and settings.

This is a separate Swift Package; the macOS Xcode target is unchanged.

## Build and run

Target: Ubuntu 24.04+, Swift 6.0+, GTK4, GStreamer 1.24+, and WebKitGTK **6.0 API**
(for the optional web console; API 4.1 is GTK3 and is not compatible).
Install Swift from https://www.swift.org/install/linux/ and the system libraries:

```sh
sudo apt-get update
sudo apt-get install libgtk-4-dev libwebkitgtk-6.0-dev pkg-config \
  libgstreamer-plugins-bad1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-nice gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-libav
cd Linux
swift build -c release
.build/release/overlook
```

Both Wayland and X11 are handled by GTK. Other distributions need equivalent
packages exposing `webkitgtk-6.0`, `gstreamer-webrtc-1.0`, `gstreamer-app-1.0`, and
`gstreamer-video-1.0` to pkg-config. `gstreamer1.0-nice` is required at runtime for
ICE, even when the development libraries are installed.

Enter a hostname, IP address, or HTTP(S) URL, plus your username and password.
An optional **six-digit OTP code** is appended to the password, as in the macOS
client. TOTP secrets are not accepted. Select **Connect native** for video.
Password/OTP fields are cleared after submitting. Addresses without a scheme
use HTTPS. Explicit HTTP works for devices configured that way.

**Native mode currently requires a certificate trusted by the Linux system.**
Install your device/CA certificate into the system trust store as appropriate.
Native mode does not inherit WebKit's session certificate exceptions and never
silently disables TLS checks. Login requests do not follow redirects, to avoid
forwarding credentials to another endpoint.

Use **Save address** for bookmarks; selecting one connects natively with the
credentials currently entered. **Web console** instead opens the device web UI
and has its own login and session. It also provides the earlier session-scoped
certificate prompt for self-signed devices. Reload applies to that web console;
for native mode, enter credentials and reconnect.

## Native implementation

- `Sources/OverlookCore/JanusSignaling.swift`: Swift protocol state machine for
  Janus create → attach `janus.plugin.ustreamer` → watch → SDP offer/answer → start,
  plus trickle ICE, keepalive, server errors, and teardown. It follows the same
  video-only watch parameters as `Overlook/WebRTCManager.swift`.
- `Sources/OverlookGTK/NativeSession.swift`: Swift session coordinator. Logs in
  through `/api/auth/login`, opens `/janus/ws` with `janus-protocol`, carries
  cookie or JSON-token authentication, and drives GStreamer through C interop.
- `Sources/CNative/Native.c`: native library adapter. libsoup3 supplies Linux
  HTTP/WebSocket transport; GStreamer supplies SDP/ICE/DTLS/SRTP and codecs.
  Received RTP goes through `decodebin` → RGBA `appsink` → `GdkMemoryTexture` →
  `GtkPicture`. GTK updates are marshalled onto GLib's main loop. At most one
  frame is pending for GTK, so UI delays do not grow an unbounded frame queue.
- Native close cancels network requests, closes signaling, stops pipelines,
  discards session cookies, and suppresses queued callbacks from old sessions.

The GTK bindings are thin C adapters for macros, varargs, and signal callbacks.
The application and signaling logic remain Swift. GStreamer handles native media
rather than wrapping Apple's platform-specific WebRTC XCFramework.

## Current limits

- **Native mode is view-only video.** Keyboard/mouse HID, audio/microphone,
  clipboard, hardware controls, and file operations remain available through
  the separate web console where supported. Native audio is not requested.
- No TURN configuration yet. Native connections currently need a directly
  reachable ICE path (LAN or a suitably routed VPN). No automatic reconnect.
- The GTK path copies RGBA frames into a texture; it is not a zero-copy GPU
  renderer. Hardware decoding depends on installed GStreamer plugins.
- No native OCR, recording, snapshots, discovery/Tailscale scanning, persistent
  credential storage, telemetry, or persistent certificate pinning yet.
- Physical PiKVM/Comet interoperability remains unverified. Local WebRTC tests
  validate the native engine, not firmware authentication or Janus compatibility.
- Web-console microphone/camera permissions, downloads, popups, and external
  URI handlers are not implemented. WebKit keeps its default permission denial.

Both session types keep credentials/cookies in memory. Disconnect destroys the
current client session; it does not revoke already issued server tokens. Use the
device's Logout action when server-side revocation is needed. Bookmarks contain
only names and addresses at `$XDG_CONFIG_HOME/overlook/devices.json` (normally
`~/.config/overlook/devices.json`), mode 0600. A corrupt file disables saving
until repaired and the app restarted.

## Tests

```sh
cd Linux
swift test
sudo apt-get install xvfb xauth dbus-x11
# Three real local peer connections: VP8 → H.264 → VP8, with teardown between.
# Exits successfully only after receiving and displaying a decoded frame each time.
timeout 45s dbus-run-session -- xvfb-run -a .build/debug/overlook --native-smoke-test
# Optional embedded-console regression test:
timeout 45s dbus-run-session -- xvfb-run -a .build/debug/overlook --smoke-test
```

The native smoke test generates a local RTP stream, negotiates two `webrtcbin`
peers, transports video over ICE/DTLS/SRTP, decodes it, and sets a GTK texture.
It does not bypass WebRTC by showing a local test pattern directly. The H.264
sender uses `openh264enc`; the VP8 sender uses `vp8enc`. Both are provided by the
listed plugin packages. Tests also cover Janus ACK/transaction handling,
handle/session routing, server failures, credential form encoding, URLs,
bookmark persistence/permissions, and corrupt/untrusted bookmark files.

```sh
docker build -t overlook-linux Linux
docker run --rm overlook-linux
```

The Docker image runs the native test by default. The optional WebKit smoke test
may require `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` in restricted containers;
that override is confined to CI's disposable local-HTML test and is unnecessary
for native WebRTC. Do not use it for normal browsing.

## Optional desktop installation

With Swift's runtime available on the machine:

```sh
install -Dm755 .build/release/overlook ~/.local/bin/overlook
install -Dm644 packaging/io.github.overlook.Linux.desktop \
  ~/.local/share/applications/io.github.overlook.Linux.desktop
```

Ensure `~/.local/bin` is in the desktop session's PATH. This dynamically links
Swift, GTK, WebKit, GStreamer, and dependencies; it is not a standalone bundle.

## Upstream APIs

- GTK4: https://docs.gtk.org/gtk4/
- Native WebRTC: https://gstreamer.freedesktop.org/documentation/webrtc/
- WebKitGTK6: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/gtk/migrating-to-webkitgtk-6.0.md

## Validation performed

Ubuntu 24.04 ARM64 in a Lima Linux VM, Swift 6.0.3, GTK 4.14.5, and WebKitGTK
2.52.6: Debug and Release builds passed; all seven XCTest cases passed. The
Release native smoke test received VP8, H.264, then VP8 over three successive
local WebRTC connections and passed teardown/recreation between them. The
embedded-console page-loading regression test also passed. Headless rendering
emits expected DRI3 warnings. The x86_64 GitHub workflow has been updated but
has not yet run on GitHub. No physical device was tested.
