# Overlook for Windows (WinUI 3)

Overlook for Windows is a native Swift + WinUI 3 desktop client for GLKVM / GL.iNet Comet IP-KVM devices, engineered for full feature parity with the macOS and Linux ports.

## Architecture & Feature Parity

| Capability | Windows Implementation (`Windows/`) | Linux Counterpart (`Linux/`) |
| :--- | :--- | :--- |
| **Native UI Framework** | **WinUI 3** (`thebrowsercompany/swift-winui` / Windows App SDK) | GTK4 + libadwaita |
| **Video Streaming** | WebRTC (`gstwebrtc`) + H.264/HEVC over WebSocket (`WinHTTP` + GStreamer `d3d11h264dec` / `mfh264dec` / `avdec_h264` → `WriteableBitmap`) | WebRTC + H.264/HEVC (`libsoup-3.0` + GStreamer `gtksink` / `appsink`) |
| **HID Keyboard & Mouse** | Windows Set 1 Scancode & Virtual-Key to Web `KeyboardEvent.code` mapping, Absolute/Relative mouse, Scroll wheel | X11/evdev keycode mapping, Absolute/Relative mouse, Scroll wheel |
| **System Shortcut Capture** | Low-level keyboard hook (`SetWindowsHookExW(WH_KEYBOARD_LL)`) with `ScrollLock` / `Right Ctrl + Right Alt` release hotkey | `gdk_toplevel_inhibit_system_shortcuts` |
| **Password Storage** | **Windows Credential Manager** (`Advapi32.dll` `CredWriteW` / `CredReadW` / `CredDeleteW`) | `libsecret-1` (freedesktop Secret Service) |
| **TLS Security** | Trust-on-First-Use (TOFU) SHA-256 certificate pinning (`BCrypt` + `WinHTTP`) | TOFU SHA-256 certificate pinning (`GLib` + `libsoup`) |
| **Hardware Recording & GPU Probe** | `DXGI` adapter enumeration + MediaFoundation (`mfh264enc`/`mfh265enc`), NVENC (`nvh264enc`), AMF (`amfh264enc`), QSV (`qsvh264enc`), or `x264enc` fallback | `libva` probe + VAAPI (`vah264enc`/`vaapih264enc`) or `x264enc` fallback |
| **Web Console** | Native **WebView2** (`WinUI.WebView2`) | `WebKitGTK 6.0` |
| **4-Page Settings & Hardware** | Video & Capture, Input & HID, Media & Hardware (MSD ISO/IMG mount/upload, ATX power, WoL, EDID, USB identity, Tailscale), System & Security | Identical 4-page Preferences & Hardware dialog |
| **Screenshots & OCR** | One-click PNG capture to `%USERPROFILE%\Pictures\Overlook` + `tesseract.exe` OCR to Windows Clipboard | PNG capture to `~/Pictures` + `tesseract` OCR |

---

## Prerequisites on Windows 10 / 11

1. **Visual Studio 2022** (Community, Professional, or Enterprise) with:
   - **Desktop development with C++** workload
   - **Windows 10/11 SDK (10.0.19041.0 or newer)**
2. **Swift for Windows** (via Scoop):
   ```powershell
   scoop install swift
   ```
3. **Optional Runtime Dependencies**:
   - **GStreamer MSVC 64-bit Runtime** (optional, dynamically loaded at runtime from `C:\gstreamer\1.0\msvc_x86_64\bin` or `$env:GSTREAMER_1_0_ROOT_MSVC_X86_64\bin` for hardware-accelerated H.264/HEVC decoding, WebRTC, and MP4 recording):
     ```powershell
     winget install GStreamerProject.GStreamer.MSVC.x86_64
     ```
   - **Tesseract OCR** (optional, for `Ctrl+Shift+O` Copy Screen Text):
     ```powershell
     winget install UB-Mannheim.TesseractOCR
     ```

---

## Building, Testing & Packaging

Open PowerShell and run the included `build.ps1` script from `Windows\`:

```powershell
cd Windows

# Build Release binary + run unit tests
.\build.ps1 -Configuration release -Test

# Run UI smoke tests
.\build.ps1 -Configuration release -SmokeTest

# Create portable zip package in ..\dist\Overlook-Windows-x64.zip
.\build.ps1 -Configuration release -Test -Package
```

Or build directly with Swift Package Manager from a **x64 Native Tools Command Prompt for VS 2022**:

```powershell
cd Windows
swift build -c release
swift test
```

---

## Configuration & Data Locations on Windows

- **Saved Devices**: `%APPDATA%\Overlook\devices.json`
- **Trusted TLS Certificates (TOFU)**: `%APPDATA%\Overlook\trusted-certificates.json`
- **Capture & Input Preferences**: `%APPDATA%\Overlook\preferences.json`
- **Connection Audit Log**: `%LOCALAPPDATA%\Overlook\connection.log`
- **Saved Device Passwords**: Windows Credential Manager (`Overlook (<host:port>)`)
- **Screenshots**: `%USERPROFILE%\Pictures\Overlook\`
- **Recordings**: `%USERPROFILE%\Videos\Overlook\`
