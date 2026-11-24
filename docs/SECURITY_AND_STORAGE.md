# Security, Privacy, Credentials & Storage Paths

This guide explains how Overlook validates TLS certificates, stores credentials and preferences, isolates WebRTC media traffic, and organizes configuration, log, and capture files across macOS, Linux, and Windows.

---

## 1. TLS Verification & Trust-On-First-Use (TOFU) Pinning

KVM devices on local networks frequently ship with self-signed HTTPS certificates. Overlook **never** disables TLS certificate validation globally; instead, it combines system trust evaluation with strict per-`host:port` SHA-256 leaf certificate pinning and blocks HTTP redirects on login requests so credentials never leak to another origin.

### Platform Pinning Behavior

| Aspect | macOS ([DeviceTrustStore.swift](../Overlook/DeviceTrustStore.swift)) | Linux ([CertificateStore.swift](../Linux/Sources/OverlookCore/CertificateStore.swift), [Native.c](../Linux/Sources/CNative/Native.c)) | Windows ([CertificateStore.swift](../Windows/Sources/OverlookCore/CertificateStore.swift), [NativeWin.c](../Windows/Sources/CNativeWin/NativeWin.c)) |
| --- | --- | --- | --- |
| **CA-signed certificates** | Evaluated via `SecTrustEvaluateWithError`; accepted automatically without pinning | Accepted by system TLS trust | Accepted by WinHTTP system TLS trust |
| **First unseen self-signed cert** | Automatically pinned in `overlook.trusted_certificates.v1` and logged | Stops and prompts via `AdwAlertDialog`: **Cancel** (default), **Trust Once**, or **Always Trust** | Credential-free, cookie-free `HEAD /` probe first; stops and prompts via `MessageBoxW`: **Yes** (Always), **No** (Once), **Cancel** |
| **Changed pinned cert** | Cancels TLS challenge, sets mismatch state, prompts **Certificate Changed** (`Trust New Certificate`) | Shows **Certificate Changed** (`Replace and Trust`, **Cancel** default) | Shows **Certificate Changed** prompt before retry; never replaces silently |
| **Pin key scope** | `"<lowercase-host>:<port>"` | `"<lowercase-host>:<port>"` | `"<lowercase-host>:<port>"` |
| **In-memory vs persistent** | Unseen self-signed certs persist immediately; `reset(host:port:)` updates the pin | **Trust Once** stays in memory (`ol_native_allow`) for the current session only; **Always Trust** writes `trusted-certificates.json` | **Trust Once** stays in memory (`ol_native_allow`) for the current session only; **Always Trust** writes `trusted-certificates.json` |

### Key Security Safeguards
- **Credential-free pre-probe (Windows)**: Before sending login form data or session cookies on an untrusted WinHTTP connection (`ERROR_WINHTTP_SECURE_FAILURE`), `probe_untrusted_certificate` opens a separate `HEAD /` request with zero credentials or cookies, hashes the peer DER certificate via `BCryptHash` (SHA-256), and aborts immediately if unapproved.
- **Same-policy coverage**: The same TOFU check protects HTTPS REST calls, `/janus/ws` & `/api/stream/h264` signaling WebSockets, `/api/ws` HID WebSockets, and Linux's optional WebKitGTK Web Console.
- **No redirects on login**: Login requests forbid HTTP redirects (`SOUP_MESSAGE_NO_REDIRECT` on Linux; `WINHTTP_DISABLE_REDIRECTS` on Windows).
- **Tamper & corruption protection**: On Linux and Windows, `CertificateStore` refuses to silently wipe or overwrite a corrupt `trusted-certificates.json`; mutations throw until repaired or explicitly cleared with **Forget Trusted Certificates**. Likewise, `DeviceStore.load()` re-validates every saved `address` and `addresses` entry via `DeviceAddress.parse`, rejecting injected `file://` or `javascript:` URLs.
- **Discovery probe exception (macOS)**: During LAN sweeps (`KVMDeviceManager.swift`), ephemeral probing (`GET /api/auth/check`, `/api/init/is_inited`, `/`) temporarily accepts TLS challenges in memory without polluting `DeviceTrustStore` until the user explicitly connects.

---

## 2. Credentials, Passwords & 2FA / TOTP Secrets

- **macOS Keychain**:
  - Auth session tokens: `kSecClassGenericPassword`, service `<bundleID>.kvm-auth-token`, account `"<host>:<port>"` ([KeychainTokenStore.swift](../Overlook/KeychainTokenStore.swift)).
  - Device passwords: `kSecClassGenericPassword`, service `<bundleID>.kvm-password`, account `"<host>:<port>"` ([DevicePasswordStore.swift](../Overlook/DevicePasswordStore.swift)).
  - Stale saved passwords are automatically deleted from Keychain when authentication returns `401`/`403` or HTTP 2xx with `ok=false`. Multi-address lookups search across all addresses of the linked `KVMDevice`.
- **Linux System Keyring ([PasswordStore.swift](../Linux/Sources/OverlookGTK/PasswordStore.swift))**:
  - Uses `libsecret` (`SECRET_COLLECTION_DEFAULT`), schema `io.github.overlook.Linux.Password`, keyed by attribute `address`.
  - Disabled unless the user checks **Save device and password in system keyring** (when checked, saves automatically on **Connect** or **Bookmark**; bookmarking clears saved credentials when unchecked, and removing a device clears its keyring entry).
- **Windows Credential Manager ([PasswordStore.swift](../Windows/Sources/OverlookWinUI/PasswordStore.swift), [NativeWin.c](../Windows/Sources/CNativeWin/NativeWin.c))**:
  - Uses Win32 `CredReadW` / `CredWriteW` / `CredDeleteW` (`CRED_TYPE_GENERIC`, `CRED_PERSIST_LOCAL_MACHINE`), target `"io.github.overlook.Windows:<url>"`.
- **2FA OTP & TOTP Secrets**:
  - Never saved to Keychain, `libsecret`, Credential Manager, or JSON config files on any OS. Input state is cleared immediately after sign-in submission or dialog close.
- **Server-side Token Revocation**:
  - Closing a session destroys client-side cookies/tokens in memory. Use **Logout & Disconnect** (macOS / Linux) to invoke `POST /api/auth/logout` and revoke the token on the KVM itself.

---

## 3. Network & ICE Privacy (`Media Addresses`)

Overlook exposes a **Video and audio addresses** (macOS) / **Media Addresses** (Linux & Windows) setting backed by `MediaRoute` ([Overlook/MediaNetwork.swift](../Overlook/MediaNetwork.swift) and [OverlookCore/MediaNetwork.swift](../Linux/Sources/OverlookCore/MediaNetwork.swift)):

- **`Chosen network only` (default)**:
  - Determines whether the target address belongs to **LAN** (RFC 1918 private IPv4 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) or **Tailscale** (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`).
  - Suppresses public STUN (`stun:stun.l.google.com:19302`) so LAN/Tailscale peers do not trigger external STUN queries.
  - Filters both remote SDP/trickled candidates and local ICE candidates to stay on the selected network. If filtering would empty any `m=` media section in a remote SDP offer, Overlook preserves the unmodified offer as a fail-safe.
  - On macOS, also enables `ignoreVPNNetworkAdapter` and `ignoreLoopbackNetworkAdapter` when routing strictly over `.lan`.
  - *Windows limitation*: Because `HostResolver` and `LocalInterfaceAddress` rely on `Darwin`/`Glibc` socket enumeration, they return empty sets on Windows; non-IP, non-`.ts.net` hostnames fall back to `All addresses`, and literal LAN IPs drop Tailscale/loopback candidates without per-adapter subnet matching.
- **`All addresses`**:
  - Allows ICE negotiation over any shared interface, still suppressing public STUN whenever `MediaNetworkRules.isDirectlyReachable(host:)` classifies the target as private LAN, Tailscale, loopback, link-local, `*.local`, `localhost`, or a single-label hostname.

---

## 4. macOS Entitlements & Signing Notes

- **Entitlements ([Overlook/Overlook.entitlements](../Overlook/Overlook.entitlements))**:
  - `com.apple.security.app-sandbox = false`
  - `com.apple.security.cs.disable-library-validation = true` — required because the embedded `WebRTC.framework` (`stasel/WebRTC`) carries its upstream signature rather than the builder's certificate when locally/ad-hoc built. Keeps Hardened Runtime enabled and remains notarizable.
  - `com.apple.security.device.audio-input = true` — required under Hardened Runtime so macOS can prompt for Microphone access.
- **Bundle ID & Team Stability ([Config/Signing.xcconfig](../Config/Signing.xcconfig), [Config/Local.xcconfig.example](../Config/Local.xcconfig.example))**:
  - Checking out the repo builds with `PRODUCT_BUNDLE_IDENTIFIER = com.ajhs.Overlook` and `DEVELOPMENT_TEAM = 56ULVRLK6L` unless overridden in gitignored `Config/Local.xcconfig` or CI command-line arguments.
  - Signing with a stable Team ID avoids per-build ad-hoc `cdhash` changes, preventing repeated macOS Keychain ACL and TCC Microphone prompts across local rebuilds.

---

## 5. Complete Storage, Configuration, Log & Media Paths

| Data Item | macOS Location | Linux Location | Windows Location |
| --- | --- | --- | --- |
| **Saved devices** | `UserDefaults` (`overlook.saved_devices.v2`) | `$XDG_CONFIG_HOME/overlook/devices.json` (`~/.config/overlook/devices.json`, mode `0600`) | `%APPDATA%\Overlook\devices.json` |
| **Trusted TLS pins** | `UserDefaults` (`overlook.trusted_certificates.v1`) | `$XDG_CONFIG_HOME/overlook/trusted-certificates.json` (mode `0600`) | `%APPDATA%\Overlook\trusted-certificates.json` |
| **Preferences** | `UserDefaults` (`overlook.*` keys listed below) | `$XDG_CONFIG_HOME/overlook/preferences.json` (mode `0600`) | `%APPDATA%\Overlook\preferences.json` |
| **Passwords / Tokens** | macOS Keychain (`<bundleID>.kvm-password`, `<bundleID>.kvm-auth-token`) | `libsecret` (`io.github.overlook.Linux.Password`, attr `address`) | Credential Manager (`io.github.overlook.Windows:<url>`) |
| **Connection audit log** | `~/Library/Logs/Overlook/connection.log` (rotates `.1.log`–`.3.log` at 4 MiB) + `os.Logger` | `$XDG_STATE_HOME/overlook/connection.log` (`~/.local/state/overlook/connection.log`, 4 MiB × 3, mode `0600`) | `%LOCALAPPDATA%\Overlook\connection.log` (4 MiB × 3) |
| **GStreamer plugin cache** | N/A (`WebRTC.framework`) | System GStreamer cache | `%LOCALAPPDATA%\Overlook\gstreamer-registry-1.0.bin` |
| **Default screenshots** | `~/Pictures/Overlook/` | `~/Pictures/Overlook/` | `%USERPROFILE%\Pictures\Overlook\` |
| **Default recordings** | `~/Movies/Overlook/` | `~/Videos/Overlook/` (falls back to `~/Movies/Overlook` if only `~/Movies` exists) | `%USERPROFILE%\Videos\Overlook\` (or `Movies\Overlook`) |
| **App install dir (Windows NSIS)** | `/Applications/Overlook.app` (manual / script) | `/usr/bin/overlook` or `~/.local/bin/overlook` | `%LOCALAPPDATA%\Programs\Overlook\app\` (uninstall keeps `%APPDATA%` / `%LOCALAPPDATA%` logs & CredMan entries) |

### Key `UserDefaults` Preferences (macOS)

| Key | Type & Default | Controlled By |
| --- | --- | --- |
| `overlook.appAppearance` | `"system"` \| `"light"` \| `"dark"` | Settings › General |
| `overlook.connection.wakeDisplayOnConnect` | `Bool` (`false`) | Settings › General |
| `overlook.audio.enabled` | `Bool` (`false`) | Settings › Audio |
| `overlook.audio.micEnabled` | `Bool` (`false`) | Settings › Audio |
| `overlook.audio.playbackScope` | `"activeWindow"` \| `"allWindows"` | Settings › Audio |
| `overlook.audio.inputDeviceUID` / `outputDeviceUID` | `String` (`""` System Default) | Settings › Audio |
| `overlook.capture.recordingMode` | `"videoAndAudio"` \| `"videoOnly"` \| `"audioOnly"` | Settings › Capture / Capture Menu |
| `overlook.capture.videoCodec` | `"h264"` \| `"hevc"` | Settings › Capture / Capture Menu |
| `overlook.capture.screenshotsFolder` / `recordingsFolder` | Path strings (`~/Pictures/Overlook`, `~/Movies/Overlook`) | Settings › Capture |
| `overlook.capture.showsRegionOutline` | `Bool` (`true`) | Settings › Capture |
| `overlook.input` (`relativeSensitivity`, `unacceleratedInput`) | `1.0` (`0.25...4.0`), `false` | Settings › Input |
| `overlook.network.mediaAddresses` | `"chosenNetwork"` \| `"all"` | Settings › Network |
| `overlook.ocr.preferRemoteServer`, `remoteLanguage` | `false`, `"eng"` | Device Settings › Video / OCR |
| `overlook.declined_links.v1` | `[String]` (`host:port\|deviceID`) | Device certificate linking |
| `OverlookPanelWidth`, `OverlookVerboseLogging` | `440.0` (`300...1000`), `false` | Side panels / Debug logging |

### Unit Test Host Isolation (macOS)
When `AppEnvironment.isHostingTests` detects XCTest/Swift Testing environment variables, macOS switches to an isolated `Overlook.TestHost` `UserDefaults` suite, an in-memory credential store (`InMemoryDeviceCredentials`), an in-memory `ConnectionLog`, and a no-op clipboard writer so automated tests never touch user defaults, Keychain entries, or log files.
