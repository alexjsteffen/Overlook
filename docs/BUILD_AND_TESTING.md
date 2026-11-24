# Building, Packaging, Testing & CI/CD

This guide covers building Overlook on macOS, Linux, and Windows, syncing the shared `OverlookCore` module, running unit and smoke tests, and understanding the CI workflows.

---

## 1. Root `Makefile` Targets

Run `make` from the repository root to build the native target for your current OS (`Darwin` -> `macos`, `Linux` -> `linux`, `Windows`/MINGW/MSYS -> `windows`). Outputs go into `build/` and `dist/` (the checked-in `Overlook.app` is left untouched).

| Target | Purpose | Output |
| --- | --- | --- |
| `make` / `make build` | Auto-select OS build | Platform default below |
| `make macos` | Unsigned Release Xcode build + zip | `dist/Overlook.app`, `dist/Overlook-macOS.zip` |
| `make macos-signed` | Developer ID Archive (`APPLE_TEAM_ID`, `MACOS_BUNDLE_ID`) | `dist/Overlook.app`, `dist/Overlook-macOS-signed.zip` |
| `make macos-notarized` | `macos-signed` + `notarytool` submit + staple + Gatekeeper check | `dist/Overlook-macOS.zip` |
| `make linux` | Static Swift stdlib release build (`Linux/`) | `dist/overlook` |
| `make pacman` / `deb` / `rpm` / `appimage` | Build native Linux package (`PACKAGE_RELEASE`, `VERSION`) | `dist/overlook*` or `dist/Overlook*.AppImage` |
| `make docker` / `make docker-test` | Build & test in Ubuntu 24.04 Swift 6 Docker container | `dist/overlook` |
| `make windows` / `windows-test` / `windows-package` | Invoke `Windows/build.ps1` or `swift test` on Windows | `Windows/.build/.../Overlook.exe`, `dist/Overlook-Windows-x64.zip` |
| `make test` | Run Linux SwiftPM unit tests (`OverlookCoreTests`) | Test report |
| `make clean` | Remove `build/` and `dist/` | — |

Overrides: `VERSION=0.1.1`, `PACKAGE_RELEASE=1`, `DIST_DIR=./dist`, `LINUXDEPLOY=...`, `APPIMAGETOOL=...`.

---

## 2. Platform Build Instructions

### macOS
- **Requirements**: macOS 14.0+, Xcode 15+.
- **Local install**: Run `./scripts/install-local.sh` to build Release (`Overlook.xcodeproj`, scheme `Overlook`), verify signature, gracefully quit any running instance, and copy to `/Applications/Overlook.app`.
- **Stable local signing**: Copy [Config/Local.xcconfig.example](../Config/Local.xcconfig.example) to gitignored `Config/Local.xcconfig` and set your `DEVELOPMENT_TEAM` (OU field of your certificate) to avoid repeated Keychain and Microphone prompts on rebuilds.
- **Full Developer ID signing & notarization**: See [README.md](../README.md#developer-id-signing-and-notarization).

### Linux
- **Requirements**: Ubuntu 24.04+ (or Fedora/Arch equivalents), Swift 6.0+, GTK 4.12+, libadwaita 1.5+, WebKitGTK 6.0 (`webkitgtk-6.0`), `libsecret-1`, GStreamer 1.24+ (`webrtc`, `app`, `video`, `sdp`, `nice`, `plugins-good`, `plugins-bad`, `libav`).
- See [Linux/README.md](../Linux/README.md#build-and-run) for exact `apt-get` / `dnf` commands and AppImage prerequisites (`linuxdeploy`, `appimagetool`, GTK/GStreamer plugins, `patchelf`).
- **Docker option**: `make docker` exports `dist/overlook` without installing host compilers (`make docker-test` runs the headless WebRTC loopback smoke test).
- *Note on packaging scripts*: [Linux/packaging/build-package.sh](../Linux/packaging/build-package.sh) packages with `--static-swift-stdlib`, desktop entry, 6 PNG icon sizes from `Overlook/Assets.xcassets`, and sets `OVERLOOK_DISABLE_WEB_CONSOLE=1` in AppImage `apprun-hooks`. The standalone [Linux/packaging/PKGBUILD](../Linux/packaging/PKGBUILD) builds without `--static-swift-stdlib` or hicolor icons and uses `pkgver()` prefix `0.1.0.r<N>.g<sha>`.

### Windows
- **Requirements**: 64-bit Windows (Windows 11 recommended), PowerShell 5.1+, Visual Studio 2022 C++ Build Tools + Windows 10/11 SDK (`rc.exe`, tested `10.0.26100.0`), Swift 6 (`scoop install swift git`, tested `6.4.2`), GStreamer 1.0 MSVC x86_64 runtime + devel MSIs (tested `1.26.11`), and optionally NSIS 3 (`scoop bucket add extras && scoop install nsis`) for `Setup.exe`.
- **Commands**:
  ```powershell
  # Build release + run OverlookCoreTests
  .\Windows\build.ps1 -Configuration release -Test

  # Also run all 5 non-interactive Windows smoke tests
  .\Windows\build.ps1 -Configuration release -Test -SmokeTest

  # Bundle transitive Swift/VC++/GStreamer DLLs + gstreamer-plugins into dist\Overlook-Windows-x64.zip
  .\Windows\build.ps1 -Configuration release -Test -Package

  # Preflight check + build NSIS per-user Setup.exe
  .\Windows\build-installer.ps1 -CheckOnly
  .\Windows\build-installer.ps1 -Test -Version 1.0.2
  ```
- See [Windows/README.md](../Windows/README.md) for custom `-GStreamerRoot`, `-SkipBuild`, and troubleshooting execution policies.

---

## 3. Shared `OverlookCore` Sync Workflow

`Linux/Sources/OverlookCore/` (12 `.swift` files) and `Linux/Tests/OverlookCoreTests/` (7 `.swift` files) are the canonical source of truth shared between Linux and Windows.

- [Windows/build.ps1](../Windows/build.ps1) copies `*.swift` from `..\Linux\Sources\OverlookCore` and `..\Linux\Tests\OverlookCoreTests` into `Windows\` at build time.
- **Maintenance rule**: Edit shared core and core test files in `Linux/` (or update both intentionally) and commit both trees together. Because `Copy-Item -Force *.swift` never deletes removed files, if a file is renamed or deleted in `Linux/`, manually remove the stale copy from `Windows/`.

---

## 4. Test Suite & Smoke Tests

### Automated Unit Tests

| Suite | Framework | Files | Test Cases | Coverage Highlights |
| --- | --- | --- | --- | --- |
| **macOS (`OverlookTests/`)** | Swift Testing (`@Test`) | `49` (`48` test files + `TestSupport.swift`) | **888** | Audio routing/setup, CaptureManager, ConnectVia, ConnectionLog store/tagging, ConsoleSession/Window lifecycle, Device catalog/edit/identity/link/model, Discovery, Display names, HID socket/focus/mapping/scroll/scancodes, Intercepted & layout chords, JSONValue, Janus sender/signaling/transactions, MacPreferences, MediaNetwork, Mouse jiggler, Multi-address catalog, OCRManager/OCRSnippet, Panel presentation, PeerConnectionRoles, QualityPreset, RemotePaste, SessionConnect/Lifetime/Registry, SettingsDebounce/SettingsWindow, StatusMenu, StreamStats, SystemConfigWrite, VideoTrackTeardown, WakeDisplay |
| **Shared Core (`OverlookCoreTests`)** | XCTest | `7` (mirrored on Linux & Windows) | **42** | `CertificateStoreTests` (6), `DeviceTests` (5), `HIDTests` (9), `JanusTests` (3), `KVMModelsTests` (7), `NanoKVMTests` (5), `UpstreamCongruenceTests` (7) — SHA-256 vectors, TOFU pin corruption checks, URL normalization, evdev/Win32 scancodes, `HIDCaptureChordTracker` (`Ctrl+Alt+F` / release), Janus state machine, TOTP RFC 6238 vectors, Lossless 4K GOP halving, NanoKVM AES-256-CBC & binary HID, `MediaRoute` ICE filtering, `RemotePasteChunker` grapheme safety, legacy config migration & `sidebarCollapsed` |

### Built-in CLI & Smoke-Test Flags (Linux & Windows)

Run on Linux under headless Xvfb/DBus (`timeout 45s dbus-run-session -- xvfb-run -a .build/release/overlook <flag>`) or directly on Windows (`Overlook.exe <flag>`):

| Flag / Env Var | Linux | Windows | What It Exercises |
| --- | --- | --- | --- |
| `--help` | Yes | Yes | Prints CLI help and exits |
| `--smoke-test` | Yes | Yes | Linux: loads local HTML in WebKitGTK (unless `OVERLOOK_DISABLE_WEB_CONSOLE=1`). Windows: exercises `ol_html` adapter load callbacks |
| `--native-smoke-test` | Yes | Yes | 3 sequential in-process GStreamer `webrtcbin` ICE/DTLS/SRTP loopback peers (`VP8 -> H.264 -> VP8`) verifying real frame decode to viewport |
| `--capture-smoke-test` | Yes | Yes | H.264 loopback + opens Info/Settings dialogs + writes & validates PNG screenshot and MP4 recording (`--non-interactive` on Windows skips modal dialogs) |
| `--certificate-response-smoke-test` | No | Yes | Tests Win32 cert response mapping (`Always`/`Once`/`Cancel`), SHA-256 display, and `CertificateStore` persistence |
| `--sidebar-smoke-test` | No | Yes | Tests Windows sidebar collapse/expand, `sidebarCollapsed` persistence, fullscreen restoration, `AltGr+F` passthrough, and `Ctrl+Alt+F` exit while captured |
| `OVERLOOK_DISABLE_WEB_CONSOLE=1` | Yes | No | Disables WebKitGTK Web Console (used by Linux AppImage) |

---

## 5. CI/CD Workflows (`.github/workflows/`)

| Workflow | File | Triggers | Runner(s) | What Runs Today | Notable Gaps |
| --- | --- | --- | --- | --- | --- |
| **Build Downloads** | [build.yml](../.github/workflows/build.yml) | Push/PR `main`, manual | `ubuntu-24.04` (`swift:6.0-noble`), `archlinux:base-devel`, `macos-latest` | Linux release build + `swift test` + `--native-smoke-test` tarball; Arch `makepkg --printsrcinfo` & `namcap`; unsigned macOS Release zip | Linux built without `--static-swift-stdlib`; omits `--smoke-test` / `--capture-smoke-test`; no Windows job |
| **Linux GTK4** | [linux.yml](../.github/workflows/linux.yml) | Push `main` / `codex/linux-*`, PR `main`, manual | `ubuntu-24.04` (`swift:6.0-noble`) | `swift build -c release`, `swift test`, `--smoke-test` (with `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`), `--native-smoke-test` | Does not run `--capture-smoke-test` |
| **Windows Build** | [windows.yml](../.github/workflows/windows.yml) | Push/PR touching `Windows/**` or `OverlookCore*`, manual | `windows-2022` (`Swift 6.0`) | Runs `swift test --filter OverlookCoreTests` only | Does not install GStreamer, build `Overlook.exe` (`CNativeWin`/`OverlookWinUI`), or run `build.ps1` / Windows smoke tests |
| **Xcode - Build** | [objective-c-xcode.yml](../.github/workflows/objective-c-xcode.yml) | Push/PR `main` | `macos-latest` | Resolves SPM packages + unsigned Debug/Release `xcodebuild build` | Builds target only; does not execute `OverlookTests` |
| **Signed Release** | [release.yml](../.github/workflows/release.yml) | Tags `v*`, manual | `macos-latest` | Signs with Developer ID (`com.rcawston.Overlook` override), notarizes, staples, verifies Gatekeeper, publishes GitHub Release `Overlook.zip` | macOS-only; uses upstream `BUNDLE_ID: com.rcawston.Overlook` instead of `com.ajhs.Overlook` |

---

## 6. Version Identifiers Across Targets

Version strings are currently maintained separately per target rather than from one single source:

| Target / Artifact | Current Version | Source File |
| --- | --- | --- |
| **macOS Xcode project** | `MARKETING_VERSION = 1.1`, Build `2` | [Overlook.xcodeproj/project.pbxproj](../Overlook.xcodeproj/project.pbxproj) |
| **Checked-in `Overlook.app`** | `1.1` (build `1`) | [Overlook.app/Contents/Info.plist](../Overlook.app/Contents/Info.plist) |
| **Root Makefile Linux packaging** | `VERSION = 0.1.1`, `PACKAGE_RELEASE = 1` | [Makefile](../Makefile) |
| **Linux `PKGBUILD`** | `pkgver = 0.1.1` (`pkgver()` -> `0.1.0.r<N>.g<sha>`) | [Linux/packaging/PKGBUILD](../Linux/packaging/PKGBUILD) |
| **Linux About dialog** | `"0.3 Preview"` | [Linux/Sources/OverlookGTK/main.swift](../Linux/Sources/OverlookGTK/main.swift) |
| **Windows build, manifest, RC, User-Agent & About** | `1.0.2` (`1.0.2.0`) | [Windows/build.ps1](../Windows/build.ps1), [build-installer.ps1](../Windows/build-installer.ps1), [Overlook.rc](../Windows/packaging/Overlook.rc), [Overlook.exe.manifest](../Windows/packaging/Overlook.exe.manifest), [NativeWin.c](../Windows/Sources/CNativeWin/NativeWin.c), [main.swift](../Windows/Sources/OverlookWinUI/main.swift) |
