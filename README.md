# Overlook

[![Xcode - Build](https://github.com/rcawston/Overlook/actions/workflows/objective-c-xcode.yml/badge.svg)](https://github.com/rcawston/Overlook/actions/workflows/objective-c-xcode.yml)

Overlook is a macOS-native remote console for **GL.iNet GLKVM / Comet** and **PiKVM (KVMD)** devices.

![Overlook Screenshot](./OverlookScreenshot.png)

It focuses on *fast*, *low-friction* day-to-day “reach over and fix it” workflows:

- **Low-latency WebRTC video streaming** (Janus signaling) plus direct **Streamer HTTP Snapshots** (`/api/streamer/snapshot`).
- **Full keyboard + mouse input capture** (including middle-drag, 5-button mouse support, live keyboard LEDs, and emulated USB/PS2 output selection).
- **Clipboard & Text Entry bridging**:
  - **Local → Remote paste** with `⌘V` or the **Remote Text Typing** tool (`/api/hid/print` with keymap, slow-typing mode, and inter-key delay).
  - **Remote → Local copy via ML OCR & Server OCR**: select text directly from the live video stream using on-device Apple Vision or PiKVM server-side Tesseract OCR (`/api/streamer/snapshot?ocr=true`) and copy it to your Mac clipboard.
- **Full PiKVM & GLKVM Hardware Management**:
  - **2FA / TOTP Authentication** (6-digit OTP code or RFC 6238 Base32 TOTP secret) and session logout (`/api/auth/logout`).
  - **Virtual Media / Mass Storage Drive (MSD)** management (`/api/msd/*`): mount/unmount ISO and flash images, upload local images from Finder, download remote URLs directly to the KVM (`http`, `https`, `smb`, `sftp`, `nbd`), toggle CD-ROM vs. Flash & Read-Write modes, and manage GLKVM storage partitions.
  - **ATX Power & Front-Panel Buttons** (`/api/atx/*`): monitor Power and HDD Activity LEDs, trigger graceful/hard power states, and click physical power/reset header buttons.
  - **User GPIO Control** (`/api/gpio/*`): monitor GPIO input pins and toggle or pulse output relay/switch channels.
  - **PiKVM Multi-Port Switch** (`/api/switch/*`): switch active ports, control port/uplink/downlink beacons and hex colors, configure dummy plugs and port names, and run per-port ATX actions.
  - **Redfish BMC Support** (`/redfish/v1/*`): inspect system power state, send `ComputerSystem.Reset` actions, and manage `VirtualMedia/MSD`.
  - **System Health, KVMD Logs & Prometheus Metrics** (`/api/info`, `/api/log`, `/api/export/prometheus/metrics`): live CPU/GPU temperatures, memory usage, undervoltage/throttling flags, KVMD/ustreamer/kernel versions, service logs, and Prometheus metrics.

If you spend time in BIOS/UEFI, bootloaders, headless servers, or “the machine that’s *just* out of reach”, Overlook makes the remote console feel like a first-class Mac app.

---

## Highlights

### 1) Copy from the remote screen using Local Vision OCR or Server Tesseract OCR

Overlook includes an **OCR Selection Mode** that behaves like “Live Text” for a remote computer:

- Turn on OCR mode from the toolbar, fullscreen bar, or `⌘C` while captured.
- Click a point or drag a box on the video stream.
- Overlook runs on-device Apple Vision OCR (or PiKVM server-side Tesseract OCR via `GET /api/streamer/snapshot?ocr=true` when **Prefer Server OCR** is enabled in **Settings → Video & Streamer**), shows the recognized text, and lets you copy it to your clipboard.

### 2) Paste & Type to the remote machine (`⌘V` & `/api/hid/print`)

- Press `⌘V` while input capture is active to send your macOS clipboard to the remote machine via `/api/hid/print`.
- Or open **Settings → Keyboard & Text Entry** to use the interactive **Type Text Remotely** box with **Slow typing mode** and a configurable **Inter-key delay** (`0.00`–`5.00`s) for BIOS/UEFI and legacy bootloaders.
- Send built-in shortcuts (`Ctrl+Alt+Del`, `Ctrl+Shift+Esc`, `Alt+Tab`, `Alt+F4`, `Meta/Win`, `PrintScreen`, `Ctrl+Alt+F1/F2`), device-configured shortcuts, or arbitrary comma-separated key combinations (`/api/hid/events/send_shortcut`).

### 3) Low-latency WebRTC video & Streamer Snapshots

Overlook uses WebRTC for streaming and collects receiver stats (bitrate, fps, jitter buffer / playout delay, decode time, packet loss, ICE RTT), surfaced in the window title and Connections panel. You can also capture direct JPEG snapshots from the KVM's hardware streamer (`GET /api/streamer/snapshot`) even if WebRTC is offline.

### 4) Comprehensive Settings Panel (GLKVM + PiKVM API Aligned)

The Settings panel (`Overlook/WebUISettingsPanel.swift` and `Overlook/WebUISettingsSections.swift`) provides full control over both GLKVM and standard PiKVM subsystems:

- **Video & Streamer**: Low-latency vs. Smart mode, quality presets (Low/Medium/High/Ultra-high/Insane/Custom), EDID preset catalog and custom hex editor, orientation, cursor toggle, custom streamer FPS/quality/bitrate/GOP/zero-delay/resolution, direct streamer snapshot capture, and server OCR language configuration.
- **Remote device & HID**: Mouse/Keyboard capture toggles, USB HID gadget connection toggle (`/api/hid/set_connected`), emulated Keyboard output (`usb`, `ps2`, `disabled`) and Mouse output (`usb`, `usb_rel`, `usb_win98`, `ps2`, `disabled`), mouse polling/sensitivity/scroll rate/direction, hardware mouse jiggler, Absolute vs. Relative mouse mode, local sensitivity/unaccelerated input, Fingerbot strength, and HID reset.
- **Keyboard & Text Entry**: Live Keyboard LEDs (`CAPS`, `NUM`, `SCROLL`), keymap selector, quick shortcut grid, clickable device shortcuts, custom key chord sender, and remote text typing with slow mode and delay controls.
- **Virtual Media (MSD)**: Live drive status, free/total storage capacity, image selector, CD-ROM/ISO vs. Flash/USB mode, Read-Write mode toggle, Connect/Disconnect virtual drive, local `.iso`/`.img` upload from Finder (`/api/msd/write`), remote URL download to KVM (`/api/msd/write_remote`), stored image download/delete, GLKVM partition connect/disconnect, and MSD reset.
- **GPIO Controls**: Live input pin states (`HIGH`/`LOW` LEDs) and output channel toggles (`/api/gpio/switch`) and pulse buttons (`/api/gpio/pulse`).
- **Multi-Port Switch**: Active port switcher (`Prev`, `Next`, or specific port `0..19` / `unit.port`), port beacon toggles, hex beacon color configuration (`FFA500:BF:0028`), port name and HDMI dummy plug configuration, and per-port ATX power actions.
- **Audio & Capture**: CoreAudio input/output selection, screenshot/recording folders, H.264/HEVC codec picker, and session capture region controls.
- **System & Device Health**: App appearance, WebUI theme/language/timezone, live hardware health from `/api/info` (platform model, serial, KVMD/ustreamer/kernel versions, CPU load, memory usage, CPU/GPU temperature, undervoltage/throttling warnings), and modal viewers for **KVMD Service Logs** (`/api/log`) and **Prometheus Metrics** (`/api/export/prometheus/metrics`).
- **Network**: DHCP/Static IP configuration, Wi-Fi SSID/password/status, and Ethernet link speed/IP/MAC inspection.
- **Power & Advanced (ATX / Redfish)**: Live ATX Power LED and HDD Activity LED indicators, `wait` toggle, ATX power actions (`Power On`, `Graceful Off`, `Hard Off`, `Hard Reset`), front-panel button clicks (`Click Power`, `Hold Power (5s+)`, `Click Reset`), Redfish BMC power state & `ComputerSystem.Reset` controls, and KVM reset.

---

## Keyboard Shortcuts

### In-session shortcuts (while keyboard capture is enabled)

- `⌘C`: toggles OCR selection mode (so you can “copy” from the remote screen).
- `⌘V`: pastes macOS clipboard to the remote.
- `⇧⌘S`: saves a screenshot (WebRTC frame, or falls back to `/api/streamer/snapshot`).
- `⇧⌘R`: starts or stops a recording.
- `⌘Q`: quits Overlook (releases any held keys and hangs up first).

### Menu bar global shortcuts

- `⌘⇧O`: Toggle OCR.
- `⌘⇧D`: Scan for devices.
- `⌘⇧V`: Open Quick Connect.

---

## Supported Devices

- **GL.iNet Comet / GLKVM**
- **PiKVM (v2, v3, v4, DIY)** running KVMD
- Any KVMD-compatible device exposing the PiKVM HTTP/WebSocket API (`/api/*`, `/redfish/v1/*`) and Janus WebRTC signaling (`/janus/ws`)
- **Tailscale peers**: Overlook automatically discovers online KVM nodes in your Tailscale tailnet via the local Tailscale CLI (`/Applications/Tailscale.app/Contents/MacOS/Tailscale`, `/opt/homebrew/bin/tailscale`, or `/usr/local/bin/tailscale`).

---

## Installation & Build

### Linux preview

An experimental **Swift + GTK4 + libadwaita** Linux desktop port is available in [`Linux/`](Linux/README.md). It follows the GNOME HIG, receives native video through GStreamer WebRTC, sends keyboard and mouse input over the KVMD HID WebSocket, and asks before trusting self-signed device certificates (once or permanently, with fingerprint pinning). An optional WebKitGTK device console covers settings the native client does not implement yet. It is not feature parity with the macOS app. See the Linux guide for dependencies, build instructions, and limitations.

### Requirements (macOS)

- macOS 14.0+
- Xcode 15+ (open `Overlook.xcodeproj`)
- Network or Tailscale access to your KVM device

### Build

1. Open `Overlook.xcodeproj` in Xcode.
2. Select the `Overlook` scheme.
3. Build + Run (`⌘R`), or run `./scripts/install-local.sh` to build Release and install to `/Applications/Overlook.app`.

---

## Project Structure

- `Overlook/OverlookApp.swift` — App entry point, scene configuration, and graceful termination handler.
- `Overlook/ContentView.swift` — Main window layout, toolbar, fullscreen HUD, and connection/certificate sheets.
- `Overlook/VideoSurfaceView.swift` — WebRTC Metal video view, mouse/scroll tracking (including middle/auxiliary buttons), OCR gestures, and capture region selection.
- `Overlook/GLKVMClient.swift` — Complete HTTP REST & WebSocket client for GLKVM and PiKVM APIs (Auth + 2FA TOTP, System Info/Logs, HID, ATX, MSD, GPIO, Streamer/Snapshots/OCR, Switch, Redfish, Prometheus, and `/api/ws?stream=0`).
- `Overlook/HardwareControlManager.swift` — Observable coordinator for Virtual Media (MSD), ATX Power, GPIO, Switch, and Redfish state.
- `Overlook/WebUISettingsPanel.swift`, `Overlook/WebUISettingsPanelModel.swift`, `Overlook/WebUISettingsActions.swift`, `Overlook/WebUISettingsSections.swift` — Modular settings panel UI and async action handlers.
- `Overlook/InputManager.swift` — Local keyboard/mouse capture, full ASCII keystroke mapping, relative pointer lock, and ordered HID WebSocket transport.
- `Overlook/OCRManager.swift` + `Overlook/OCRViews.swift` — Dual Apple Vision + PiKVM Server Tesseract OCR pipeline.
- `Overlook/KVMDeviceManager.swift` + `Overlook/TailscaleManager.swift` — mDNS, subnet port scan, common target probing, and Tailscale CLI device discovery.
- `Overlook/MediaCaptureHub.swift`, `Overlook/SessionRecorder.swift`, `Overlook/CaptureManager.swift`, `Overlook/CaptureViews.swift` — Native screenshots, streamer snapshots, and MP4/M4A session recording.
- `Overlook/DeviceTrustStore.swift`, `Overlook/KeychainTokenStore.swift`, `Overlook/DevicePasswordStore.swift` — TOFU certificate pinning and macOS Keychain storage.
- `docs/PIKVM_GLKVM_API_GUIDE.md` — Detailed reference of all PiKVM & GLKVM API endpoints integrated into Overlook.

---

## License

This project is licensed under the **GNU General Public License v3.0**. See [`LICENSE.MD`](./LICENSE.MD).
