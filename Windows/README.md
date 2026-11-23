# Overlook for Windows

Overlook for Windows is a Swift desktop client with a native Win32 shell styled around Windows 11 Fluent conventions and an in-process **GStreamer (`webrtcbin`)** WebRTC video and capture engine. The `OverlookWinUI` target name is historical: this build does not use WinUI 3 / XAML or swift-winui. Device and session logic remain in Swift; HWND controls, WinHTTP transport, and rendering live in `Sources/CNativeWin/NativeWin.c`, while WebRTC streaming, decoding, stats, and MP4 recording live in `Sources/CNativeWin/GStreamerWebRTC.c`.

## Install the build tools

Use **64-bit Windows**, preferably Windows 11. The tested toolchain is
**Swift 6.4.2**, Visual Studio C++ tools, **Windows SDK 10.0.26100.0**, and
**GStreamer 1.0 MSVC x86_64 (1.26.11)**.

1. Install **Visual Studio 2022** (or newer / Build Tools for Visual Studio).
   Select **Desktop development with C++**, **MSVC x64/x86 build tools**, and a
   **Windows 10/11 SDK** including `rc.exe`.
2. Install **Swift 6 for Windows**. Follow the official
   [Swift Scoop setup guide](https://www.swift.org/install/windows/scoop/) for
   the Visual Studio prerequisites and toolchain installation. With
   [Scoop](https://scoop.sh/) installed, run `scoop install swift git`.
3. Install **GStreamer 1.0 MSVC x86_64** (both the **runtime** and **development**
   MSIs from [gstreamer.freedesktop.org](https://gstreamer.freedesktop.org/download/)),
   or extract both MSIs locally into `Windows\.deps\gstreamer` (or pass
   `-GStreamerRoot <path>` to the build scripts).
4. Use **PowerShell 5.1 or newer**. Reopen the terminal after installing tools.

No Python, WinUI 3, Windows App SDK, FFmpeg, or external image-generation
service is needed for compilation or runtime WebRTC/MP4 capture.

## Build, test, and package

From the repository root, after closing any running `Overlook.exe`:

```powershell
# Release build and core unit tests.
.\Windows\build.ps1 -Configuration release -Test

# UI and capture checks; dismiss the information and Settings dialogs.
.\Windows\build.ps1 -Configuration release -SmokeTest

# Portable executable, Swift runtime DLLs, and bundled GStreamer plugins/DLLs in a ZIP under dist/.
.\Windows\build.ps1 -Configuration release -Test -Package
```

The script locates Scoop's Swift toolchain/runtime, sets `SDKROOT` when needed,
imports the Visual Studio x64 environment, locates GStreamer 1.0 MSVC x86_64,
compiles `packaging/Overlook.rc` (embedding the icon, Per-Monitor V2 DPI manifest,
and version info cleanly without post-link binary mutation), builds `Overlook.exe`
as a Windows GUI-subsystem executable, copies required GStreamer plugins into
`gstreamer-plugins\` alongside the exact transitive Swift, VC++, and GStreamer
runtime DLLs, and copies shared core sources and tests from `Linux/` before
compiling.

- Release executable: `Windows\.build\x86_64-unknown-windows-msvc\release\Overlook.exe`
  relative to the repository root.
- Package: `dist\Overlook-Windows-x64.zip` relative to the repository root.
- Debug build: use `-Configuration debug` instead of `release`.

## Build a Windows installer

Install **NSIS 3** in addition to the build tools above. With Scoop:

```powershell
scoop bucket add extras
scoop install nsis
```

Alternatively install NSIS from its [official site](https://nsis.sourceforge.io/).
The script finds and validates `makensis.exe` in Scoop, on `PATH`, or under
Program Files (skipping broken shims).

From the repository root, use the installer build script:

```powershell
# Report ALL missing tools with installation instructions.
# Exits nonzero if any check fails; does not compile or install dependencies.
.\Windows\build-installer.ps1 -CheckOnly

# Compile app + bundled GStreamer runtime, run core tests, stage ZIP, build Setup.exe.
.\Windows\build-installer.ps1 -Test -Version 1.0.2

# Rebuild only the installer from the existing complete dist payload.
.\Windows\build-installer.ps1 -SkipBuild -Version 1.0.2
```

Output: `dist\Overlook-1.0.2-Windows-x64-Setup.exe`. `-Configuration debug`,
`-GStreamerRoot <path>`, and `-SmokeTest` are forwarded to the application build.
Version accepts three or four numeric components.

Preflight checks 64-bit PowerShell 5.1+, Swift, Visual Studio's C++ x64 tools,
Windows SDK `rc.exe`, GStreamer 1.0 MSVC x86_64 (runtime + devel), NSIS 3, and
whether the app is closed.

The installer is **per-user**, defaults to `%LOCALAPPDATA%\Programs\Overlook`,
and needs no administrator elevation. It installs the app under an `app`
subdirectory (including `Overlook.exe`, transitive Swift/VC++/GStreamer DLLs,
and `gstreamer-plugins\`), cleanly runs any prior uninstaller on upgrade while
preserving user-added files, creates a Start menu shortcut, offers an optional
desktop shortcut, and registers an uninstaller in Windows Installed apps. End
users do not need Swift, GStreamer, Python, or FFmpeg installed.

Uninstall removes only installer-owned payload files and shortcuts. It preserves
saved devices, preferences, trusted certificates, logs, Credential Manager
entries, and files users added to the install directory. Builds are unsigned;
code signing is a separate release step.

## Native GStreamer WebRTC & Recording

Both incoming offers (Janus/PiKVM/Comet) and locally generated offers (NanoKVM)
use GStreamer's native `webrtcbin` pipeline directly in-process:

- **Signaling & Auth**: WinHTTP HTTPS/WebSocket with strict TOFU certificate
  pinning (certificates are probed credential-free via `HEAD /` before any
  login credentials or session cookies are sent).
- **Video Decode & Rendering**: `decodebin` (supporting D3D11 hardware decode via
  `d3d11convert` / `d3d11download` with software fallback) -> BGRA `appsink` ->
  bounded UI-thread frame delivery -> Win32 `StretchDIBits` viewport.
- **MP4 Recording**: Native GStreamer `appsrc` -> Media Foundation hardware
  encoders (`mfh264enc` / `mfh265enc`) with NVENC/OpenH264 fallback -> `mp4mux`
  (`faststart=true`). No external `ffmpeg.exe` is required.
- **Local Verification**: `--native-smoke-test` exercises real VP8 and H.264
  encoded RTP/ICE/DTLS loopback end-to-end; `--capture-smoke-test --non-interactive`
  verifies valid PNG screenshot and GStreamer MP4 recording output.

Settings use read-only summary dialogs, and the web console opens in your
default browser. Windows settings editability parity with macOS and Linux is not
complete.

## Configuration & Data Locations on Windows

- **Saved Devices**: `%APPDATA%\Overlook\devices.json`
- **Trusted TLS Certificates (TOFU)**: `%APPDATA%\Overlook\trusted-certificates.json`
- **Capture & Input Preferences**: `%APPDATA%\Overlook\preferences.json`
- **Connection Audit Log**: `%LOCALAPPDATA%\Overlook\connection.log`
- **GStreamer Plugin Cache**: `%LOCALAPPDATA%\Overlook\gstreamer-registry-1.0.bin`
- **Saved Device Passwords**: Windows Credential Manager (`io.github.overlook.Windows:<url>`)
- **Screenshots**: `%USERPROFILE%\Pictures\Overlook\`
- **Recordings**: `%USERPROFILE%\Videos\Overlook\`

## Windows appearance

The shell follows the Windows app theme, including live theme changes, or the
stored light/dark appearance preference. High Contrast uses Windows system colors.
The connection card, device list, focus outlines, and buttons share one palette.
Fonts, spacing, and device rows scale with each monitor's DPI. Session commands
occupy a separate wrapping toolbar and are hidden on the connection screen.

The left saved-devices sidebar can be collapsed and expanded using the top-left
sidebar toggle button or `Ctrl+B` (when not in fullscreen or capturing keyboard
input for the remote viewport). When collapsed, the connection card and active
session video viewport expand across the full window width. The collapsed state
is saved as `sidebarCollapsed` in `%APPDATA%\Overlook\preferences.json`,
restored on launch, and preserved across fullscreen toggling.

Tab / Shift+Tab navigate native controls; Enter in a connection field connects.
F11 toggles fullscreen when remote keyboard capture is inactive. The existing
remote input path is preserved while the viewport has focus.

### Visual verification

Build with `.\Windows\build.ps1 -Configuration release -Test`, then launch
`Overlook.exe`. Check light/dark and High Contrast, sidebar collapse/expand on
both the connection screen and an active session, keyboard focus,
100% / 150% / 200% scaling, minimum window size, and fullscreen restoration.
Local `--sidebar-smoke-test` checks sidebar toggling, persistence, and
fullscreen restoration; `--native-smoke-test` exercises the GStreamer WebRTC
pipeline and video surface without connecting to a device.

The Windows build embeds `packaging/Overlook.ico`, `packaging/Overlook.exe.manifest`,
and version info using the Windows SDK resource compiler (`Overlook.rc`). Icon
generation provenance is recorded in `packaging/ICON.md`.
