# Overlook for Windows

Overlook for Windows is a Swift desktop client with a native Win32 shell styled around Windows 11 Fluent conventions. The `OverlookWinUI` target name is historical: this build does not use WinUI 3 / XAML or swift-winui. Device and session logic remain in Swift; HWND controls and rendering live in `Sources/CNativeWin/NativeWin.c`.

## Install the build tools

Use **64-bit Windows**, preferably Windows 11. The tested toolchain is
**Swift 6.4.2**, Visual Studio C++ tools, and **Windows SDK 10.0.26100.0**.

1. Install **Visual Studio 2022** (Community, Professional, or Enterprise), or
   **Build Tools for Visual Studio 2022**. Select **Desktop development with C++**,
   **MSVC x64/x86 build tools**, and a **Windows 10/11 SDK** in Visual Studio
   Installer. The SDK must include `rc.exe` and `mt.exe`.
2. Install **Swift 6 for Windows**. Follow the official
   [Swift Scoop setup guide](https://www.swift.org/install/windows/scoop/) for
   the Visual Studio prerequisites and toolchain installation. With
   [Scoop](https://scoop.sh/) installed, run `scoop install swift git`.
3. Install **64-bit Python 3.10+** (for example `scoop install python`), then from
   the repository root run `python -m pip install -r Windows/Helpers/requirements.txt`.
   This installs aiortc and PyInstaller for building the self-contained video helper.
4. Use **PowerShell 5.1 or newer**. Reopen the terminal after installing tools.

No WinUI 3, Windows App SDK, Pillow, or image-generation service is needed
for compilation. The icon assets are checked in. There are no external Swift
package dependencies.

## Build, test, and package

From the repository root, after closing any running `Overlook.exe`:

```powershell
# Release build and core unit tests.
.\Windows\build.ps1 -Configuration release -Test

# UI and capture checks; dismiss the information and Settings dialogs.
.\Windows\build.ps1 -Configuration release -SmokeTest

# Portable executable and Swift runtime DLLs in a ZIP under dist/.
.\Windows\build.ps1 -Configuration release -Test -Package
```

The script locates Scoop's Swift toolchain/runtime, sets `SDKROOT` when needed,
and imports the Visual Studio x64 environment. An official Swift installation
on `PATH` is also supported. It compiles `packaging/Overlook.rc`, links the icon,
and embeds the Per-Monitor V2 DPI manifest. It freezes `Helpers/overlook_webrtc.py`
with PyInstaller into `webrtc/overlook-webrtc.exe`, including the Python interpreter,
aiortc, PyAV and codec libraries. Python is a build dependency only. It copies shared core sources and
tests from `Linux/` into their Windows counterparts before compiling.

The script currently uses `--build-system native` to work around Scoop's
flattened Swift toolchain layout. Swift 6.4.2 emits a deprecation warning for
that option. Prefer the script over a bare `swift build` so the icon, manifest,
and runtime paths are handled too.

- Release executable: `Windows\.build\x86_64-unknown-windows-msvc\release\Overlook.exe`
  relative to the repository root.
- Package: `dist\Overlook-Windows-x64.zip` relative to the repository root.
- Debug build: use `-Configuration debug` instead of `release`.

### Troubleshooting

- **Script execution is disabled:** from the repository root, run
  `powershell -NoProfile -ExecutionPolicy Bypass -File .\Windows\build.ps1 -Configuration release -Test`.
  The policy override applies only to this process.
- **Missing headers, libraries, or SDK tools:** add the C++ workload and SDK
  components above through Visual Studio Installer. Try an **x64 Native Tools**
  terminal if automatic environment setup is unavailable.
- **Linker permission denied for Overlook.exe:** close the running app and retry;
  Windows locks executable files while they are running.
- **Missing Swift DLLs on another computer:** distribute the portable ZIP and
  keep the included DLLs alongside the executable.

## Bundled WebRTC video

Both incoming offers (Janus/PiKVM/Comet) and locally generated offers (NanoKVM)
use the bundled aiortc receiver for SDP, ICE, DTLS/SRTP and VP8/H.264 decoding.
Decoded BGRA frames pass through a bounded queue to the native viewport. Signaling,
authentication and HID remain in Swift/WinHTTP; device credentials are not passed
to the helper. The helper is terminated when its session closes.

Extract the complete portable ZIP and keep `webrtc/` beside `Overlook.exe`.
Users do **not** need Python, pip, GStreamer, or system codecs to receive video.
The helper uses software decoding. HEVC reception and audio playback are not
implemented. The runtime reports real transport byte counts and decoded frame
rates; the old fabricated connection statistics have been removed.

The native smoke test now sends actual encoded video over local WebRTC and
receives/decodes it through the bundled helper. An additional integration test
covers VP8/H.264, both offer directions, and incoming trickle ICE with the helper's
Python search path isolated:

```powershell
python Windows/Tests/webrtc_integration.py --helper Windows/.build/x86_64-unknown-windows-msvc/release/webrtc/overlook-webrtc.exe
```

These tests validate local interoperability, not live device firmware. aiortc's
[API documentation](https://aiortc.readthedocs.io/en/latest/api.html) describes the
peer connection implementation used by the helper.

## Runtime tools and current scope

MP4 recording invokes `ffmpeg.exe` on `PATH`, using the `h264_mf` or `hevc_mf`
Media Foundation encoders. Install an FFmpeg build with the desired encoder
support and check it with `ffmpeg -encoders`. Local OCR can use `tesseract.exe`
on `PATH`. Neither tool is required for compilation or bundled in the ZIP.
The current Windows package has no GStreamer build dependency.

Settings use read-only summary dialogs, and the web console opens externally.
Windows settings feature parity with macOS and Linux is not complete.

## Configuration & Data Locations on Windows

- **Saved Devices**: `%APPDATA%\Overlook\devices.json`
- **Trusted TLS Certificates (TOFU)**: `%APPDATA%\Overlook\trusted-certificates.json`
- **Capture & Input Preferences**: `%APPDATA%\Overlook\preferences.json`
- **Connection Audit Log**: `%LOCALAPPDATA%\Overlook\connection.log`
- **Saved Device Passwords**: Windows Credential Manager (`Overlook (<host:port>)`)
- **Screenshots**: `%USERPROFILE%\Pictures\Overlook\`
- **Recordings**: `%USERPROFILE%\Videos\Overlook\`

## Windows appearance

The shell follows the Windows app theme, including live theme changes, or the
stored light/dark appearance preference. High Contrast uses Windows system colors.
The connection card, device list, focus outlines, and buttons share one palette.
Fonts, spacing, and device rows scale with each monitor's DPI. Session commands
occupy a separate wrapping toolbar and are hidden on the connection screen.

Tab / Shift+Tab navigate native controls; Enter in a connection field connects.
F11 toggles fullscreen when remote keyboard capture is inactive. The existing
remote input path is preserved while the viewport has focus.

This is a Fluent-style Win32 shell, not a migration to WinUI 3. Settings and information use themed, scrollable summary dialogs backed by
the existing adapter (settings are still read-only), and the web console opens
externally. A future XAML migration would require a separate Windows App SDK host.

### Visual verification

Build with `./build.ps1 -Configuration release -Test`, then launch the resulting
`Overlook.exe`. Check light/dark and High Contrast, keyboard focus, 100% / 150% /
200% scaling, the minimum window size, and fullscreen restoration. A local
`--native-smoke-test` exercises the video surface without connecting to a device.

The Windows build embeds `packaging/Overlook.ico` using the Windows SDK resource
compiler. The app uses an integrated Fluent title bar with custom caption glyphs,
native window system commands, resizing, and double-click maximize/restore.
Icon generation provenance is recorded in `packaging/ICON.md`.
