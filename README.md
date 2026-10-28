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

The repository-root **Makefile** selects the correct native build for the current OS:

```sh
make
```

- **macOS:** builds `dist/Overlook.app` and `dist/Overlook-macOS.zip`.
- **Linux:** builds the executable `dist/overlook`.
- Run `make help` to list every target and its main options.

Build outputs are written to `build/` and `dist/`; the checked-in `Overlook.app` is not overwritten. Run `make clean` to remove those generated directories.

### macOS

Requirements: macOS 14.0+, Xcode 15+, and network or Tailscale access to your KVM device. A normal build does **not** require an Apple Developer account:

```sh
make macos
open dist/Overlook.app
```

The normal Makefile build is unsigned and intended for local development. You can also open `Overlook.xcodeproj`, select the `Overlook` scheme, and press `⌘R`, or run `./scripts/install-local.sh` to install a Release build in `/Applications`.

#### Developer ID signing and notarization

Use a **Developer ID Application** certificate and Apple notarization for a bundle you distribute to other Macs. An Apple Development certificate, an ad-hoc signature, and a Developer ID signature without notarization are not substitutes for a notarized release.

1. **Install the correct certificate.**
   - Join the [Apple Developer Program](https://developer.apple.com/programs/).
   - In Xcode, open **Settings → Accounts**, select your Apple ID and team, then choose **Manage Certificates**.
   - Click **+ → Developer ID Application**. If that option is unavailable, ask the account holder/admin to grant the appropriate access or create the certificate from the [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list) page.
   - Keep the certificate and its private key in your login keychain. Do not commit either one.

2. **Find your Team ID and confirm the identity.** The Team ID is the 10-character value shown on the [Apple Developer membership page](https://developer.apple.com/account/#!/membership). It is not your Apple ID email address or the full certificate name.

   ```sh
   security find-identity -v -p codesigning
   # The OU value in the certificate subject is also your Team ID:
   security find-certificate -c "Developer ID Application" -p \
     | openssl x509 -noout -subject
   ```

   The first command must list `Developer ID Application`. `make macos-signed` checks this before starting an archive.

3. **Choose a bundle identifier.** Use a reverse-DNS name controlled by you or your organization, such as `com.example.Overlook`. A fork that distributes its own app should use its own identifier. Changing an existing app's identifier causes macOS to treat it as a different app and can reset privacy permissions and keychain access.

4. **Build a Developer ID signed app.**

   ```sh
   make macos-signed \
     APPLE_TEAM_ID=ABCDE12345 \
     MACOS_BUNDLE_ID=com.example.Overlook
   ```

   Replace both example values with your own. The Makefile passes them directly to `xcodebuild`, creates a temporary copy of `ExportOptions.plist` with your Team ID, and leaves both the checked-in plist and Xcode project unchanged. Outputs are:

   - `dist/Overlook.app` — Developer ID signed, with hardened runtime.
   - `dist/Overlook-macOS-signed.zip` — signed but **not yet notarized**.

5. **Create notarization credentials.** In App Store Connect, open **Users and Access → Integrations → App Store Connect API** and create or select a team API key permitted to submit notarizations. Record its **Key ID** and **Issuer ID**, and download its `.p8` private key. The key can normally be downloaded only once. Store it outside the repository and restrict its permissions:

   ```sh
   chmod 600 /path/to/AuthKey_ABCDE12345.p8
   ```

6. **Sign, notarize, and staple the release.**

   ```sh
   make macos-notarized \
     APPLE_TEAM_ID=ABCDE12345 \
     MACOS_BUNDLE_ID=com.example.Overlook \
     APPLE_API_KEY_PATH=/path/to/AuthKey_ABCDE12345.p8 \
     APPLE_API_KEY_ID=ABCDE12345 \
     APPLE_API_ISSUER_ID=00000000-0000-0000-0000-000000000000
   ```

   The `.p8` filename and the API Key ID are separate values from your Apple Team ID. Do not paste private keys, certificate passwords, or notarization credentials into the Makefile.

   `macos-notarized` submits the signed zip with `notarytool`, waits for Apple's result, staples the ticket to the app, verifies the signature and Gatekeeper assessment, and writes the distributable **`dist/Overlook-macOS.zip`**. To repeat the final local checks yourself:

   ```sh
   codesign --verify --strict --deep dist/Overlook.app
   xcrun stapler validate dist/Overlook.app
   spctl --assess --verbose=4 --type execute dist/Overlook.app
   ```

### Linux preview

An experimental **Swift + GTK4 + libadwaita** Linux desktop port is available in [`Linux/`](Linux/README.md). It follows the GNOME HIG, receives native video through GStreamer WebRTC, sends keyboard and mouse input over the KVMD HID WebSocket, and asks before trusting self-signed device certificates. An optional WebKitGTK device console covers settings the native client does not implement yet. It is not feature parity with the macOS app.

Install the GTK, WebKitGTK, GStreamer, and Swift build dependencies listed in the [Linux guide](Linux/README.md#build-and-run), then run:

```sh
make linux
./dist/overlook
make test
```

The Makefile links the Swift runtime into the executable, so users do not need a separate Swift installation. GTK, libadwaita, WebKitGTK, GStreamer, and their runtime plugins remain dependencies.

#### Linux packages

Select a format with `PACKAGE`, or use its direct target:

```sh
make package PACKAGE=pacman
make package PACKAGE=deb
make package PACKAGE=rpm
make package PACKAGE=appimage

# Equivalent direct targets:
make pacman
make deb
make rpm
make appimage
```

| Target | Intended build environment and tools | Output in `dist/` |
| --- | --- | --- |
| `pacman` | Arch Linux; `makepkg` | `overlook-VERSION-RELEASE-x86_64.pkg.tar.zst` (or `aarch64`) |
| `deb` | Ubuntu/Debian; `dpkg-deb` and `dpkg-shlibdeps` (`dpkg-dev`) | `overlook_VERSION-RELEASE_amd64.deb` (or `arm64`) |
| `rpm` | Fedora/RPM-based distribution; `rpmbuild` | `overlook-VERSION-RELEASE.x86_64.rpm` (or `aarch64`) |
| `appimage` | Ubuntu 24.04 recommended; `linuxdeploy`, `appimagetool`, `patchelf`, GTK/GStreamer linuxdeploy plugins | `Overlook-VERSION-x86_64.AppImage` (or `aarch64`) |

Build each native package **on its target distribution and architecture**. The Makefile packages the current checkout; it does not cross-compile or relabel a binary built for another distribution. Packages install the executable, desktop entry, application icons, and license. Their runtime dependencies differ by distribution, so use the native package targets rather than manually renaming an existing package.

The default package version is `0.1.1`, with package release `1`. Override either without editing the Makefile:

```sh
make deb VERSION=0.1.2 PACKAGE_RELEASE=1
```

AppImage packaging does not silently download tools. Install `linuxdeploy`, `appimagetool`, the [GTK plugin](https://github.com/linuxdeploy/linuxdeploy-plugin-gtk), and the [GStreamer plugin](https://github.com/linuxdeploy/linuxdeploy-plugin-gstreamer), placing the plugins next to `linuxdeploy` or on `PATH`. On Ubuntu 24.04, the plugins also need these support packages in addition to Overlook's native build dependencies:

```sh
sudo apt-get install dpkg-dev file findutils librsvg2-dev libgirepository1.0-dev patchelf
```

If the AppImage tools are not on `PATH`, pass their paths:

```sh
make appimage \
  LINUXDEPLOY=/path/to/linuxdeploy-x86_64.AppImage \
  APPIMAGETOOL=/path/to/appimagetool-x86_64.AppImage
```

Build on the oldest distribution you intend to support and test native WebRTC from the completed image on a clean system. **The AppImage disables the optional Web Console**: production WebKitGTK builds embed a non-relocatable helper-process path, so shipping the console could otherwise fail or launch incompatible host helpers. Use the DEB, RPM, or Pacman package when Web Console support is required. The AppImage's GTK launcher currently requires X11 or XWayland, even though native packages also support Wayland.

On Ubuntu 24.04, install `libfuse2t64` to run AppImages directly, or use the built-in no-FUSE fallback:

```sh
./dist/Overlook-0.1.1-x86_64.AppImage --appimage-extract-and-run
```

#### Compile Linux with Docker

The repository-root **Dockerfile** provides an Ubuntu 24.04 / Swift 6 build without installing build dependencies on the host. Docker is the only host requirement for this option:

```sh
# Run unit tests and compile in Docker, then export only the executable:
make docker
./dist/overlook

# Build the test image and run its native WebRTC smoke test:
make docker-test
```

`make docker` uses BuildKit's local output and produces the same `dist/overlook` path as the native Linux target. The exported binary still needs the Linux desktop runtime libraries when run outside the container.

---

## Project Structure

- `Makefile` — Native macOS/Linux builds, Linux package formats, Docker builds, and Apple release signing.
- `Dockerfile` — Ubuntu 24.04 Linux build, test, and binary-export stages.
- `Linux/packaging/` — Shared Linux packaging script, desktop integration, and Arch package metadata.
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
