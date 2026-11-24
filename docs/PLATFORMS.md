# Platforms, Feature Matrix & Keyboard Shortcuts

Overlook ships native implementations for **macOS**, **Linux**, and **Windows**. All three support **GL.iNet Comet / GLKVM**, **PiKVM (KVMD)**, and **Sipeed NanoKVM** devices over low-latency WebRTC video + binary HID WebSockets, while platform UI depth varies by toolkit maturity.

---

## 1. Platform Feature Matrix

| Capability | macOS (`Overlook/`) | Linux (`OverlookGTK` + `CNative`) | Windows (`OverlookWinUI` + `CNativeWin`) |
| --- | --- | --- | --- |
| **UI Toolkit & Media Engine** | SwiftUI + AppKit, `stasel/WebRTC` (`154.0.0`, Metal), CoreAudio HAL | GTK4 + libadwaita (`1.5+`), `libsoup3`, GStreamer `webrtcbin` | Native Win32 Fluent shell (`No WinUI 3/XAML`), WinHTTP, GStreamer `webrtcbin` |
| **Backends (GLKVM / PiKVM / NanoKVM)** | Full (`gl_webrtc` check included) | Full (`gl_webrtc` check included) | Full (`gl_webrtc` check included) |
| **Video Streaming (Janus & NanoKVM H.264)** | Full (auto stall reconnect + wake/network recovery) | Full (manual reload `Ctrl+R`) | Full (manual reconnect) |
| **Audio Playback & USB Microphone** | Full (dual-peer, active/all-windows playback, active-window mic, CoreAudio selector) | Not implemented (video-only) | Not implemented (video-only) |
| **Multi-Window & Menu Bar Icon** | Multi-window (`⌘N`), 1-window-per-device, status bar popover/menu | Single window | Single window |
| **Collapsible Saved-Devices Sidebar** | Collapsible / Connections popover & sidebar | Adaptive `AdwOverlaySplitView` | Top-left toggle or `Ctrl+B` (persisted as `sidebarCollapsed`) |
| **Device Discovery** | Bonjour (`_comet._tcp`, `_kvm._tcp`) + `/24` LAN sweep + manual entry *(Tailscale CLI helper unused)* | Manual entry + bookmarks | Manual entry + bookmarks |
| **Multi-Address (`Connect via`) & Device Linking** | Full (multiple URLs per device + cert-fingerprint link prompt) | Primary saved address only in UI (`Device` model stores `addresses[]`) | Primary saved address only in UI (`Device` model stores `addresses[]`) |
| **HID Keyboard & 5-Button Mouse** | Full (ISO/JIS/F1–F20/Help, Caps Lock sync, relative pointer lock `⌃⌥`, unaccelerated raw option, 120Hz abs) | Full (evdev physical scancodes, GTK shortcut inhibit, 5 buttons, precision scroll; no pointer lock) | Full (`WH_KEYBOARD_LL` Set 1 scancodes, 5 buttons, V/H scroll; no pointer lock) |
| **Fullscreen Toggle & Exit Hotkey** | `⌃⌘F` (hover HUD + 4s hint capsule) | `F11` (uncaptured) & `Ctrl+Alt+F` anytime (hides chrome + toast) | `Ctrl+Alt+F` anytime & `F11` (uncaptured) (4.5s hint banner + tooltip) |
| **Clipboard Paste & Remote Text Typing** | `⇧⌘V` chunked paste + Remote Text Typing UI (slow/delay) | `Ctrl+Shift+V` / menu chunked paste + Remote Text Typing UI | **Paste** toolbar button chunked paste |
| **OCR** | Apple Vision on-device (`⇧⌘C` boxes + `⇧⌘T` direct area snippet) + PiKVM Server Tesseract | PiKVM Server Tesseract (`OCR` action -> dialog) | PiKVM Server Tesseract (`OCR` toolbar button -> read-only dialog) |
| **Screenshots & Streamer Snapshots** | PNG (`⇧⌘S`) + region crop + `/api/streamer/snapshot` JPEG | PNG (`Ctrl+Shift+S`) + `/api/streamer/snapshot` | PNG (**Snapshot** toolbar button) + `/api/streamer/snapshot` |
| **Session Video Recording** | `AVAssetWriter` H.264/HEVC `.mp4` + AAC `.m4a` + region crop (`⇧⌘R`) | VA-API (`/dev/dri/renderD*`) -> FFmpeg VAAPI -> SW H.264/HEVC `.mp4` (`Ctrl+Shift+R`) | Media Foundation (`mfh264enc`/`mfh265enc`) -> SW `.mp4` (**Record** toolbar button) |
| **Interactive Device Settings** | Full side panel (Video/EDID, HID/Jiggler, Keyboard/Typing, MSD + remote URL/partitions, GPIO IN/OUT switch/pulse, Multi-Port Switch + per-port ATX, System/Health/Logs/Prometheus, Network, ATX/Redfish Reset) | Interactive 4-page Adwaita dialog (Video/EDID, HID/Jiggler, Keyboard/Typing, MSD upload-by-path/remote URL/partitions, GPIO **read-only IN/OUT**, Multi-Port Switch **without per-port ATX**, System/Health/Logs/Prometheus, Network, ATX/Redfish Reset) | **Read-only text summary** dialogs rendered before async fetches complete; use browser **Web Console** to change device settings |
| **Embedded / Linked Web Console** | Native UI handles all device controls | Optional ephemeral WebKitGTK 6.0 console (disabled in AppImage) | Opens default web browser (`ShellExecuteW`) |
| **2FA / TOTP & Credential Storage** | 6-digit OTP + Base32 TOTP secret; macOS Keychain | 6-digit OTP + Base32 TOTP secret; `libsecret` keyring | 6-digit OTP + Base32 TOTP secret; Windows Credential Manager |
| **TLS Self-Signed Handling** | Auto-pin on first connect; prompt on change | Upfront **Cancel / Trust Once / Always Trust** + change warning | Pre-auth `HEAD /` probe + **Yes (Always) / No (Once) / Cancel** + change warning |
| **Media Addresses & Wake Display** | Full (`MediaRoute`, DNS + interface enumeration; Wake = `ShiftLeft` tap) | Full (`MediaRoute`, DNS + interface enumeration; Wake = `+1/-1` mouse nudge) | Partial (`HostResolver`/`LocalInterfaceAddress` empty on Win -> hostname fallback; Wake = `+1/-1` nudge) |

---

## 2. Keyboard Shortcuts Across Platforms

### macOS

| Context | Shortcut | Action |
| --- | --- | --- |
| **In-session (keyboard captured)** | `⇧⌘C` | Toggle OCR Selection Mode |
| **In-session (keyboard captured)** | `⇧⌘T` | Copy Text from Area (one-shot Vision OCR -> clipboard) |
| **In-session (keyboard captured)** | `⇧⌘V` | Paste Mac clipboard to target (chunked) |
| **In-session (keyboard captured)** | `⇧⌘S` | Save screenshot (WebRTC frame or streamer snapshot) |
| **In-session (keyboard captured)** | `⇧⌘R` | Start or stop recording |
| **In-session (keyboard captured)** | `⌃⌘F` | Enter or exit full screen |
| **In-session (keyboard captured)** | `⌘Q` | Quit Overlook (releases held keys first) |
| **In-session (relative mouse)** | `⌃⌥` (`Control+Option`) | Release captured pointer |
| **In-session (passed through)** | `⌘C`, `⌘V`, `⌘Tab`, etc. | Forwarded directly to remote host |
| **Main Menu Bar** | `⌘N` | Open new console window |
| **Main Menu Bar** | `⌘,` | Open Overlook Mac Settings |
| **Status Bar Menu (when open)** | `⌘K`, `⇧⌘D`, `⌘O` | Quick Connect, Scan for Devices, Toggle OCR *(Note: `⌘,` in status menu brings the main window forward)* |

All intercepted macOS chords follow the active keyboard layout's characters (`ShortcutKeyLayout`), trigger once per key press (no repeat), and require exact modifiers.

### Linux (`OverlookGTK`)

| Context | Shortcut | Action |
| --- | --- | --- |
| **Captured OR Uncaptured** | `Ctrl + Left Alt + F` | Toggle or exit fullscreen anytime (`AltGr+F` still passes through to target; exiting releases held modifiers & capture) |
| **While keyboard captured** | `Left Ctrl + Left Alt` (alone) | Release keyboard capture |
| **While keyboard NOT captured** | `F11` | Toggle fullscreen |
| **While keyboard NOT captured** | `Ctrl+N`, `Ctrl+R`, `Ctrl+W` | New connection, Reload/reconnect, Disconnect |
| **While keyboard NOT captured** | `Ctrl+I`, `Ctrl+L`, `Ctrl+,` | Connection Information, Connection Log, Settings |
| **While keyboard NOT captured** | `Ctrl+Shift+S`, `Ctrl+Shift+R` | Save screenshot (PNG), Start/stop recording (VA-API / SW MP4) |
| **While keyboard NOT captured** | `Ctrl+Shift+V` | Paste Linux clipboard to target (chunked) |
| **While keyboard NOT captured** | `Ctrl+Q` | Quit Overlook |

### Windows (`OverlookWinUI` / Win32)

| Context | Shortcut | Action |
| --- | --- | --- |
| **Captured OR Uncaptured** | `Ctrl + Left Alt + F` | Toggle or exit fullscreen anytime (`AltGr+F` still passes through to target; exiting releases held modifiers & capture) |
| **While keyboard captured** | `Left Ctrl + Left Alt` (alone) | Release keyboard capture |
| **While keyboard NOT captured** | `F11` | Toggle fullscreen |
| **While keyboard NOT captured** | `Ctrl+B` | Collapse or expand left saved-devices sidebar |
| **Connection Form** | `Enter`, `Tab` / `Shift+Tab` | Connect (`Enter`), move focus (`Tab` / `Shift+Tab`) |

> **Windows shortcut note**: Menu accelerators from the GTK port (`Ctrl+N`, `Ctrl+R`, `Ctrl+W`, `Ctrl+I`, `Ctrl+L`, `Ctrl+,`, `Ctrl+Shift+S/R/V`, `Ctrl+Q`) are not currently wired in the Win32 shell. Use the toolbar buttons (**Snapshot**, **Record**, **Paste**, **OCR**, **Settings**, **Info**, **Fullscreen (F11)**) and header buttons instead.

---

## 3. Platform-Specific Notes & Known Quirks

### macOS
- **Tailscale CLI helper**: [Overlook/TailscaleManager.swift](../Overlook/TailscaleManager.swift) is present in the project, but automatic Tailscale peer scanning is not wired into [KVMDeviceManager.swift](../Overlook/KVMDeviceManager.swift). Manually added or bookmarked `*.ts.net` and `100.64.0.0/10` hosts work normally and get Tailscale-scoped ICE filtering.
- **Server OCR region bounds**: In OCR Selection Mode, `OCRManager` sends width/height to `ocr_right`/`ocr_bottom` when **Prefer Server OCR** is active.
- **Redfish VirtualMedia**: Client methods exist in [GLKVMClient.swift](../Overlook/GLKVMClient.swift) (`getRedfishVirtualMedia`, `redfishInsertMedia`, `redfishEjectMedia`), while only Redfish System Power/Reset is exposed in `WebUISettingsSections.swift`.

### Linux
- **GPIO Monitoring Only**: `SettingsDialogActions.swift` reads `GET /api/gpio` and displays channel state text; output toggle/pulse actions are not wired in GTK yet.
- **MSD Local Upload**: Accepts a file path string in the entry field rather than opening a native GTK file chooser dialog.
- **AppImage Constraints**: Sets `OVERLOOK_DISABLE_WEB_CONSOLE=1` (disabling embedded WebKitGTK to avoid non-relocatable helper binary mismatches) and launches via X11/XWayland. Native `.deb`, `.rpm`, and `.pkg.tar.zst` packages support both Wayland and Web Console.
- **Rendering & Pointer Lock**: Copies RGBA frames into `GdkMemoryTexture` (not zero-copy DMA-BUF) and has no Wayland/X11 pointer lock for relative mouse mode (absolute mode is recommended).

### Windows
- **Read-Only Settings & Connection Info Dialogs**: [WinUIAdapter.swift](../Windows/Sources/OverlookWinUI/WinUIAdapter.swift) renders Settings and Connection Info dialogs by flattening the virtual widget tree into plain text inside `ol_win_gui_show_dialog` (`ES_READONLY` edit box) before async network fetches return. Interactive controls inside Settings (MSD, ATX, Redfish, GPIO, Switch, Network, Streamer, OCR language, or `preferences.json` toggles) are not editable from those dialogs yet; use **Web Console** for KVM settings or edit `%APPDATA%\Overlook\preferences.json` manually for local options.
- **Leftover GTK strings**: The About dialog (`v1.0.2`), a few UI labels (`AppImage` / `system keyring`), and `Settings` summary wording still reflect its shared GTK origin.
- **No Auto-Reconnect / TURN**: Dropped WebRTC or signaling connections require manually clicking **Disconnect** / **Connect**, and direct ICE connectivity (LAN or routed VPN/Tailscale) is expected without TURN relays.
