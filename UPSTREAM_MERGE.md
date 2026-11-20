# Upstream Merge Summary (`locnar/Overlook` `23870c2..7952799`)

This document describes the integration of upstream commits from `locnar/Overlook` (`Forked/Overlook`, 86 commits across 103 files in range `23870c2..7952799`) into this fork across macOS (`Overlook/`, `OverlookTests/`, `Overlook.xcodeproj`), the shared core (`OverlookCore`), Linux (`OverlookGTK`), and Windows (`OverlookWinUI`), while preserving all fork capabilities without breaking changes.

> **Repository state**: `Forked/` was used strictly as a read-only reference and left unmodified. All edits remain uncommitted in the working tree as requested.

---

## 1. Preserved Fork Capabilities & Compatibility Guarantees

Every fork-specific feature, identifier, and persisted format was kept intact:

- **Device & Protocol Support**:
  - **Sipeed NanoKVM (Cube / PCIe / Lite / Full)**: AES-256-CBC auth (`/api/auth/login` with `nano-kvm-token`), `/api/stream/h264` native H.264 WebRTC signaling, `/api/ws` binary HID keyboard/mouse, `/api/hid/paste`, `/api/hid/leds`, `/api/vm/mouse-jiggler`, `/api/vm/gpio`, `/api/vm/screen`, `/api/storage/media`.
  - **PiKVM & GLKVM Extended Hardware APIs**: 2FA / TOTP authentication (6-digit code or RFC 6238 Base32 secret), session logout (`/api/auth/logout`), Language/Timezone/Network config (`/api/network/*`), Virtual Media MSD (`/api/msd/*`), ATX Power (`/api/atx/*`), Redfish BMC (`/redfish/v1/*`), GPIO (`/api/gpio/*`), Multi-Port Switch (`/api/switch/*`), System Info/Logs/Prometheus (`/api/info`, `/api/log`, `/api/export/prometheus/metrics`), Streamer Snapshots (`/api/streamer/snapshot`), Server Tesseract OCR (`?ocr=true`), and 5-button mouse support.
- **macOS App Identity & Signing**: Preserved `PRODUCT_BUNDLE_IDENTIFIER = com.ajhs.Overlook`, `DEVELOPMENT_TEAM = 56ULVRLK6L`, `MARKETING_VERSION = 1.1`, and `CURRENT_PROJECT_VERSION = 2` on Debug and Release targets in `Overlook.xcodeproj/project.pbxproj`.
- **Backward-Compatible Persistence**:
  - `Device` / `KVMDevice` decoders migrate legacy single-`address` entries into multi-address `addresses` seamlessly.
  - `AppPreferences` / `MacPreferences` decoders supply `.chosenNetwork` and `wakeDisplayOnConnect = true` defaults when older `preferences.json` / `UserDefaults` lack those keys.
  - Existing Keychain token/password lookups, CLI paths, and menu item hooks remain compatible.

---

## 2. macOS Application & Test Suite (`Overlook/`, `OverlookTests/`, `Overlook.xcodeproj`)

### Upstream Architecture & Reliability Improvements Merged
- **Multi-window Console & Device Catalog**: Integrated `ConsoleSession.swift`, `ConsoleWindow.swift`, `SessionRegistry.swift`, `WindowDelegateInterposer.swift`, `StatusMenuModel.swift`, `DeviceViews.swift`, `DeviceIdentity.swift`, and `ConnectionsPopoverView` (in `ContentView.swift`) with multi-address linking (`via`, `preferredAddress`, `"Edit…"` sheet, `"Connect via"`).
- **WebRTC, Signaling & Network Scope**:
  - Upgraded `WebRTC` package dependency in `Package.resolved` to `stasel/WebRTC 154.0.0`.
  - Merged `MediaNetwork.swift` (`MediaRoute`: `chosenNetwork` vs. `all`, LAN/Tailscale classification, STUN suppression on local/Tailscale hosts, remote SDP candidate filtering with whole-offer fallback, and local/remote ICE candidate filtering).
  - Merged `JanusSignaling.swift` (`JanusSignalingSender` serialized send queue with deadlines and `JanusSenderFilter` per-leg video/audio handle verification) into `WebRTCManager.swift` alongside NanoKVM signaling and track-isolation fixes.
  - Added `GLKVMVideoMode` (`gl_webrtc` check with `NativeWebRTCVideoModeError`) and `GLKVMSystemConfig` non-destructive partial updates (`changes(from:)` + `merge(changes:into:)` + superseded-write generation guard).
- **HID Input & Clipboard**:
  - Integrated serialized deadline-enforced `HIDSocket` and `WebSocketClient` inside `GLKVMClient.swift` (replacing standalone `WebSocketSendQueue.swift`).
  - Merged `InputFocusGate.swift`, `ShortcutKeyLayout.swift` (layout-aware chords with exact modifiers and once-per-press behavior), `ScrollAccumulator.swift` (fixed horizontal pan direction, touchpad scaling, spike capping, idle reset), `RemotePaste.swift` (512-scalar grapheme-safe `/api/hid/print?limit=0` chunking cancelling on disconnect), and `wakeDisplayOnConnect`.
  - Preserved 5-button mouse handling (`otherMouseDown` / `Up` / `Dragged`) and `getDetailedHidState()` fallback in `VideoSurfaceView.swift` and `InputManager.swift`.
- **OCR, Capture, Audio & Logs**:
  - Merged `OCRSnippet.swift` (one-shot `⇧⌘T` **Copy Text from Area** directly to clipboard, reading-order line sorting, `"No text found"` handling) alongside fork Server Tesseract OCR in `OCRManager.swift`.
  - Merged `CaptureManager.swift`, `CaptureViews.swift`, `MediaCaptureHub.swift`, `SessionRecorder.swift`, `CoreAudioDevices.swift`, `WebRTCAudioDevice.swift`, `AudioPreferences.swift`, and `ConnectionLogPanel.swift` / `ConnectionLogView.swift`.
- **Settings Split**:
  - Separated macOS-local preferences into `SettingsWindow.swift` (`⌘,`) and removed Mac-local rows from `WebUISettingsPanel.swift`, resolving `SettingsWindowTests` while keeping all fork KVM hardware tabs/sections and `Lossless` (bitrate 20000, 4K GOP halving) + driven mouse jiggler controls in `WebUISettingsPanelModel.swift`, `WebUISettingsActions.swift`, and `WebUISettingsSections.swift`.
- **Cleanup & Discovery**: Removed dead `HardwareControlManager.swift`, `ContentControlBar.swift`, and `WebSocketSendQueue.swift`; removed the menu bar global key monitor; kept `DiscoveryRules.swift`, two-stage local interface sweep, Tailscale CLI integration, and preserved NanoKVM HTTP probe compatibility within `KVMDeviceManager.swift`.
- **Test Coverage**: Imported upstream `OverlookTests/` suite (49 `.swift` files including tests, mocks, and `TestSupport.swift`), adapting `DeviceModelTests.swift` and `SettingsWindowTests.swift` to reflect merged fork extensions.

---

## 3. Cross-Platform Shared Core (`OverlookCore`)

Mirrored identically across `Linux/Sources/OverlookCore/` and `Windows/Sources/OverlookCore/`:

- **`MediaNetwork.swift` (new)**: Pure-Swift IPv4/IPv6 parser (`IPAddress`, no extra C socket library required on Windows), `MediaAddressesPreference` (`.chosenNetwork` / `.all`), `MediaRoute`, `ICECandidateLine`, `RemoteOfferFilterResult`, `LocalInterfaceAddress`, and `HostResolver` (`Darwin`/`Glibc` DNS + interface enumeration with safe fallback on Windows).
- **`RemotePaste.swift` (new)**: `RemotePasteChunker.parts(of:maxScalars:)` (max 512 scalars, never splitting grapheme clusters) and `queryItems(keymap:limit:)`.
- **`JanusSignaling.swift`**: Added `JanusLeg` and `JanusSenderFilter` and wired sender validation into `JanusSignaling.receive(_:)` while preserving session-level error/hangup behavior.
- **`HIDInput.swift`**: Fixed horizontal scroll polarity so positive `dx` pans right on both GTK (`wheelDelta(gtkDX:gtkDY:)`) and Windows (`wheelDelta(windowsDX:windowsDY:)`); added `HIDScrollAccumulator` (spike cap `5`, `0.25s` idle reset).
- **`KVMModels.swift`**:
  - Added `KVMSystemConfig.jsonObject()`, `changes(from:)`, and `merge(changes:into:)` for non-destructive config updates.
  - Added `KVMHidState.Jiggler.isAvailable` (`enabled`) and `isActive` (`active`) alongside `NanoKVMMapper.mapHidState` fix (`enabled: jiggler != nil`).
  - Renamed `.insane` to `.lossless` (retaining static compatibility alias `.insane`), updated `streamerParams(is4K:)` (sending `h264_bitrate` & `h264_gop`, halving GOP on 4K EDIDs `E3840x2160` / `E3840x2160RM4PE`), updated `detect(config:streamer:)` for `stream_quality == 4` and `"Auto"` (`5` -> `.custom`).
  - Added `KVMVideoMode` (`gl_webrtc`) and `KVMNativeWebRTCVideoModeError`.
- **`EDIDCatalog.swift`**: Updated upstream catalog labels (`"2560x1440/GLKVM/59.95Hz"`, `"1920x1200/Epson/59.95Hz"`, `"2560x1664/AOC/49.95Hz"`, `"3840x2160/GLKVM/30Hz"`), restored AOC serial byte, and expanded the 4K GLKVM EDID to the full 256-byte blob.
- **`Device.swift`, `CaptureConfig.swift`, `ConnectionLog.swift`**: Added multi-address `Device` (`addresses`, `lastUsedAddress`, `nickname`, `via(_:)`, `http://` port `80` default, `"NanoKVM @ "` generated prefix), `AppPreferences.mediaAddresses` + `wakeDisplayOnConnect` (with backward-compatible `Codable`), and `ConnectionLog.activeDeviceLabel`.

---

## 4. Linux (`OverlookGTK`) & Windows (`OverlookWinUI`) Ports

Applied congruently across `Linux/Sources/OverlookGTK/` and `Windows/Sources/OverlookWinUI/` while preserving each port's platform bindings (`CDesktop`/`CNative` vs. `CNativeWin`, GTK vs. Win32 scancodes/buttons, and vertical wheel sign):

- **`NativeSession.swift`**:
  - Computes `MediaRoute` on `connect`, logs `connectDescription`, filters remote SDP offers/answers (`filterRemoteOffer`) and remote/local ICE candidates (`keepsRemote` / `keepsLocal`), and omits public STUN on NanoKVM (`addsPublicSTUN`) when on LAN/Tailscale.
  - Detects `video_mode == "gl_webrtc"` during connect and reports `KVMNativeWebRTCVideoModeError` instead of timing out with a generic error.
  - Sends a subtle `+1 / -1` relative mouse wake nudge on `hid-open` when `wakeDisplayOnConnect` is enabled.
  - Replaces raw scroll rounding with `HIDScrollAccumulator` and fixed horizontal pan sign; resets accumulator on focus loss and release.
  - Adds cancellation-aware chunked `sendRemoteText(_:keymap:slow:delay:)` backed by `RemotePasteChunker`.
- **`SettingsDialog.swift`, `SettingsDialogHardware.swift`, `SettingsDialogActions.swift`**:
  - Switched preset list to `.lossless` and passed 4K EDID awareness into `streamerParams(is4K:)`.
  - Added **Media Addresses** (`Chosen network only` / `All addresses`) and **Wake Display on Connect** controls under System & Network.
  - Fixed jiggler switch state & availability binding (`hid.jiggler.isActive` + `ad_sensitive(..., hid.jiggler.isAvailable ? 1 : 0)`).
  - Updated `mutateConfig` to fetch raw config, apply `changes(from:)` + `merge(changes:into:)`, and guard against superseded concurrent writes with `configWriteGeneration`.
  - Routed remote typed text through `sendRemoteText`.
- **`main.swift`**:
  - Passed `mediaAddresses` and `wakeDisplayOnConnect` to `NativeSession`, maintained `ConnectionLog.shared.activeDeviceLabel` across connect/disconnect, and routed clipboard paste (`pasteClipboardToRemote`) through `sendRemoteText`.

---

## 5. Verification

Verified on Windows 11 x64 (`Swift 6.4.2`):

- **Windows Build, Unit Tests & Smoke Tests** (`.\Windows\build.ps1 -Configuration debug -Test -SmokeTest`):
  - **`OverlookCoreTests` (XCTest)**: **40 / 40 tests passed, 0 failures**:
    - `CertificateStoreTests`: 6 passed
    - `DeviceTests`: 5 passed
    - `HIDTests`: 8 passed (including updated horizontal wheel tests and new `testHIDScrollAccumulator`)
    - `JanusTests`: 3 passed
    - `KVMModelsTests`: 7 passed (including `testLosslessPresetConfigDiffAndVideoMode` and updated `testEDIDCatalogMatchingAndResolution`)
    - `NanoKVMTests`: 5 passed
    - `UpstreamCongruenceTests`: 6 passed (`MediaRoute`, `RemotePasteChunker`, `JanusSenderFilter`, `ConnectionLog.activeDeviceLabel`, legacy `Device` / `AppPreferences` decoding)
  - **`Overlook.exe` build**: Built cleanly (`Build complete!`) and staged 61 runtime DLLs and 23 GStreamer plugins.
  - **Smoke tests**: Certificate response check (`Yes/Always`, `No/Once`, `Cancel`, fingerprint, pin persistence), Web Console smoke test, native WebRTC VP8 + H.264 decode smoke test, and PNG + Media Foundation H.264 MP4 capture smoke test all passed (`exit 0`).
- **Swift Syntax Parsing (`swiftc -parse` per target)**:
  - `Overlook/` (57 files): exit 0
  - `OverlookTests/` (49 files): exit 0
  - `Linux/Sources/OverlookCore/` (12 files): exit 0
  - `Linux/Sources/OverlookGTK/` (7 files): exit 0
  - `Linux/Tests/OverlookCoreTests/` (7 files): exit 0
  - `Windows/Sources/OverlookCore/` (12 files): exit 0
  - `Windows/Sources/OverlookWinUI/` (9 files): exit 0
  - `Windows/Tests/OverlookCoreTests/` (7 files): exit 0
- **Static Congruence & Integrity Checks**:
  - 0 references to deleted `HardwareControlManager`, `ContentControlBar`, or `WebSocketSendQueue` across `Overlook/`, `OverlookTests/`, and `Overlook.xcodeproj/project.pbxproj`.
  - Every active `.swift` file in `Overlook/` (56 active files; `ConnectionsPopoverView.swift` is an `#if false` stub in both upstream and fork) and all 49 `.swift` files in `OverlookTests/` are referenced in `Overlook.xcodeproj/project.pbxproj`, with `com.ajhs.Overlook` (2 matches) and `56ULVRLK6L` (2 matches) preserved.
  - 0 SHA-256 differences across all 12 `OverlookCore` source files and 7 `OverlookCoreTests` files mirrored between `Linux/` and `Windows/`.
  - `Forked/` remains completely unmodified (`git status --short -- Forked` shows only untracked `?? Forked/`).
- **Not Executed on This Host**: Full `xcodebuild` compilation/XCTest execution on macOS (`Overlook`, `OverlookTests`) and full Linux GTK4/libadwaita/GStreamer build (`make linux`) require macOS/Xcode and Linux desktop environments respectively and were not run on this Windows host.
