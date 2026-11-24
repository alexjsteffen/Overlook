# PiKVM, GLKVM & NanoKVM API & Protocol Reference

This document details every HTTP REST endpoint, WebSocket signaling protocol, and binary HID wire format implemented across Overlook:

- **macOS client implementation**: [Overlook/GLKVMClient.swift](../Overlook/GLKVMClient.swift)
- **Cross-platform protocol & models**: [Linux/Sources/OverlookCore/KVMModels.swift](../Linux/Sources/OverlookCore/KVMModels.swift), [JanusSignaling.swift](../Linux/Sources/OverlookCore/JanusSignaling.swift), [HIDInput.swift](../Linux/Sources/OverlookCore/HIDInput.swift), [NanoKVM.swift](../Linux/Sources/OverlookCore/NanoKVM.swift), [RemotePaste.swift](../Linux/Sources/OverlookCore/RemotePaste.swift)

---

## 1. Authentication, Schemes & Backend Auto-Detection

### Transport Schemes
- Ports `80` and `8080` default to plain **`http://`** and **`ws://`**.
- All other ports (such as `443`, `8443`, or custom HTTPS ports) use **`https://`** and **`wss://`**.
- Login requests disable HTTP redirects (`SOUP_MESSAGE_NO_REDIRECT` on Linux, `WINHTTP_DISABLE_REDIRECTS` on Windows) so credentials are never forwarded off-host.

### Auth Headers & Cookies
Once logged in, Overlook sends:
- **Session cookie**: `Cookie: auth_token=<token>; nano-kvm-token=<token>` on both HTTP requests and WebSocket upgrades.
- **KVMD direct header fallback (macOS `GLKVMClient`)**: `X-KVMD-User` and `X-KVMD-Passwd` when `kvmdUser` / `kvmdPasswd` credentials are used instead of a cookie token.

### Login & 2FA / TOTP Flow
- **KVMD / GLKVM (`POST /api/auth/login`)**:
  - macOS sends `multipart/form-data`; Linux/Windows send `application/x-www-form-urlencoded`.
  - Both include dual compatibility fields (`user` + `passwd` with appended 6-digit OTP, and NanoKVM `Username` + `Password`) so the server response reveals whether the endpoint is KVMD/GLKVM (`{"ok": Bool, "result": {...}}`) or NanoKVM (`{"code": Int, ...}`).
  - **2FA / TOTP**: Overlook accepts either a manual 6-digit OTP code or an RFC 6238 Base32 TOTP secret (HMAC-SHA1, 30-second period, 6 digits). The TOTP secret is never stored to disk or keychains. On macOS, if `≤ 2` seconds remain in the active 30s window, Overlook waits `2.1s` before computing and submitting the next window's code.
- **Sipeed NanoKVM (`POST /api/auth/login`)**:
  - Detected via `GET /api/auth/account` when `/api/auth/check` returns `404`, or from a `{"code": ...}` login response.
  - Sends JSON `{"username": "<user>", "password": "<encrypted>"}` encrypted with CryptoJS-compatible **AES-256-CBC** (`NanoKVMCrypto`):
    1. Derive a 48-byte buffer (`32`-byte AES key + `16`-byte IV) using OpenSSL `EVP_BytesToKey` (iterative MD5) from passphrase `"nanokvm-sipeed-2024"` and a random 8-byte salt.
    2. Pad UTF-8 password with PKCS#7 (16-byte block) and encrypt with AES-256-CBC.
    3. Prepend `"Salted__"` (`8` bytes) + salt (`8` bytes) + ciphertext, Base64-encode, and apply RFC 3986 percent-encoding (`/` -> `%2F`, `+` -> `%2B`, `=` -> `%3D`).
- **Logout (`POST /api/auth/logout`)**:
  - Revokes the server-side session token on both KVMD/GLKVM (`application/x-www-form-urlencoded`) and NanoKVM (empty JSON/POST) before clearing local session state.

---

## 2. WebRTC Signaling Wire Protocols

### Janus (`ws(s)://<host>/janus/ws`) — PiKVM & GLKVM

Upgraded with subprotocol **`Sec-WebSocket-Protocol: janus-protocol`**.

1. **Create Session**:
   ```json
   {"janus": "create", "transaction": "<uuid>"}
   ```
   Ignores `{"janus": "ack"}`. On `{"janus": "success", "data": {"id": <sessionID>}}`:
2. **Attach uStreamer Plugin**:
   ```json
   {
     "janus": "attach",
     "session_id": 123456,
     "transaction": "<uuid>",
     "plugin": "janus.plugin.ustreamer"
   }
   ```
3. **Request Video (or Audio on macOS) Stream**:
   - Primary video watch parameters (all platforms):
     ```json
     {
       "janus": "message",
       "session_id": 123456,
       "handle_id": 654321,
       "transaction": "<uuid>",
       "body": {
         "request": "watch",
         "params": {
           "orientation": 0,
           "video": true,
           "audio": false,
           "mic": false,
           "camera": false
         }
       }
     }
     ```
   - macOS audio peer opens a second handle requesting `{"video": false, "audio": true, "mic": <Bool>}` so audio jitter-buffer rules do not add latency to video rendering.
4. **SDP Offer / Answer & Trickle ICE**:
   - Device responds with `{"janus": "event", "sender": 654321, "jsep": {"type": "offer", "sdp": "..."}}`. Overlook filters `a=candidate:` lines inside the SDP according to `MediaRoute` (keeping the full offer if filtering would empty an `m=` section).
   - Client answers with:
     ```json
     {
       "janus": "message",
       "session_id": 123456,
       "handle_id": 654321,
       "transaction": "<uuid>",
       "body": {"request": "start"},
       "jsep": {"type": "answer", "sdp": "..."}
     }
     ```
   - Local ICE candidates send `{"janus": "trickle", ..., "candidate": {"candidate": "...", "sdpMLineIndex": <int>}}`. `JanusSenderFilter` rejects any incoming `event` or `trickle` whose `sender` does not match the active `handle_id` or `session_id`.
5. **Keepalive & Teardown**:
   - Client sends `{"janus": "keepalive", "session_id": 123456, "transaction": "<uuid>"}` every **15 seconds** (session-only, no `handle_id`).
   - Teardown sends `{"janus": "destroy", "session_id": 123456, "transaction": "<uuid>"}`.
6. **`gl_webrtc` Mode Guard**:
   - GLKVM firmware 1.10.0+ reports `"video_mode": "gl_webrtc"` (*WebRTC (Native)*) when Janus is disabled. Overlook checks `/api/system/get_config` and stops with an actionable message (`NativeWebRTCVideoModeError`) rather than looping on `/janus/ws` failures.

### Sipeed NanoKVM (`ws(s)://<host>/api/stream/h264`)

Before connecting WebSockets, Overlook switches the NanoKVM stream mode to H.264:

```http
POST /api/vm/screen
Content-Type: application/json

{"type": "type", "value": 1}
```

Messages on `/api/stream/h264` use a double-encoded JSON envelope `{"event": "<name>", "data": "<JSON string>"}`:
- **Modern firmware**: Server pushes `{"event": "ice-servers", "data": "[{\"urls\":...}]"}`. Overlook creates a client SDP offer, sends `"video-offer"` (with `{sdp, type: "offer"}`), buffers any incoming `"video-candidate"` until `"video-answer"` sets the remote description, and sends `"heartbeat"` every 15s.
- **Legacy firmware fallback**: If `ice-servers` does not arrive within **800 ms**, `NanoKVMSignaling.fallbackOfferIfNeeded()` initiates a client offer using `"offer"`, `"candidate"`, and `"answer"` event names.

---

## 3. HID & Live State WebSocket (`/api/ws`)

All platforms open `ws(s)://<host>/api/ws` **without `?stream=0`** (`stream: true`), ensuring KVMD keeps `ustreamer` capturing video while the console is open.

### KVMD / GLKVM Binary HID Frames

| Frame Type | Direction | Binary Byte Layout | Notes |
| --- | --- | --- | --- |
| **Key event** | Client -> Device | `[0x01, state, utf8(code)...]` | `state`: `0x01` pressed, `0x00` released; `code` is DOM `KeyboardEvent.code` (e.g., `"KeyA"`, `"ControlLeft"`) |
| **Release all keys** | Client -> Device | `[0x01, 0x00]` | Empty key name releases every held key on blur/disconnect |
| **Mouse button** | Client -> Device | `[0x02, state, utf8(name)...]` | `name`: `"left"`, `"middle"`, `"right"`, `"up"` (back/X1), `"down"` (forward/X2) |
| **Absolute mouse** | Client -> Device | `[0x03, x_hi, x_lo, y_hi, y_lo]` | 5 bytes; **big-endian** signed `Int16` (`-32767..+32767`) mapped onto the active video rectangle |
| **Relative mouse** | Client -> Device | `[0x04, squash, dx_i8, dy_i8]` | 4 bytes per chunk; large deltas split into steps in `[-127, 127]` (`squash` = `0x00` or `0x01`) |
| **Mouse wheel** | Client -> Device | `[0x05, squash, dx_i8, dy_i8]` | 4 bytes; horizontal (`dx`) and vertical (`dy`) clamped to `[-127, 127]` |
| **Ping / Telemetry** | Bidirectional | UTF-8 JSON text frame | Client sends `{"event_type":"ping","event":{}}` every 2s for RTT; server pushes `pong`, `hid`/`hid_state`, `streamer`/`streamer_state`, `atx`/`atx_state`, `msd`/`msd_state`, `gpio`/`gpio_state` |

### NanoKVM Binary HID Reports

| Frame Type | Direction | Binary Byte Layout | Notes |
| --- | --- | --- | --- |
| **Heartbeat** | Client -> Device | `[0x00]` | Sent every 10s |
| **Keyboard (6-KRO)** | Client -> Device | `[0x01, modifier_mask, 0x00, k0, k1, k2, k3, k4, k5]` | **9 bytes**: bitmask `ControlLeft(0x01)..MetaRight(0x80)` + up to 6 USB HID Usage IDs (`0x04..0x8b`) |
| **Mouse (Absolute)** | Client -> Device | `[0x02, buttons, x_lo, x_hi, y_lo, y_hi, wheel_i8]` | **7 bytes**: `buttons` bits `0..4`, **little-endian** `UInt16` in `0x0001..0x7fff`, vertical `wheel` in `[-127, 127]` |
| **Mouse (Relative)** | Client -> Device | `[0x02, buttons, dx_i8, dy_i8, wheel_i8]` | **5 bytes**: chunked in `[-127, 127]` steps |
| **Telemetry** | Device -> Client | UTF-8 JSON text frame | `type == "hid-led-status"` or `"capture-status"` with JSON-encoded `data` string |

> **Side-button mapping note**: In `OverlookCore`'s `HIDFrame.buttonName`, XButton1/Back (`GDK 8` / `Win 4`) maps to `"up"` and XButton2/Forward (`GDK 9` / `Win 5`) maps to `"down"` per KVMD's convention, whereas `NanoKVMHID.mouseButtonBit` maps `"down"` to bit 3 (Back) and `"up"` to bit 4 (Forward), swapping back/forward on NanoKVM in Linux/Windows. On macOS, `InputManager` maps button `3` -> `"down"` and button `4` -> `"up"`.

---

## 4. Complete HTTP REST Endpoint Inventory

### Authentication, System Health & Network

| Method & Path | Purpose | NanoKVM Equivalent / Notes |
| --- | --- | --- |
| `GET /api/init/is_inited` | Initialization check & device probe | GLKVM discovery/init |
| `GET /api/auth/check` | Verify active session | NanoKVM: `GET /api/auth/account` |
| `POST /api/auth/login` | Authenticate session (+ 2FA) | NanoKVM: `POST /api/auth/login` (AES-256-CBC JSON) |
| `POST /api/auth/logout` | Invalidate server session token | Same path on NanoKVM |
| `GET /api/info` | Hardware health, CPU/GPU temp, throttling, versions | NanoKVM: `GET /api/vm/info` + `GET /api/vm/hardware`; optional `?fields=auth,extras,fan,hw,meta,system` |
| `GET /api/log` | Retrieve KVMD service logs (`?seek=3600&follow=0`) | Plain text |
| `GET /api/export/prometheus/metrics` | Export Prometheus metrics | Plain text |
| `GET /api/system/get_config` | Read full GLKVM/PiKVM config | Used for diff-safe writes & `gl_webrtc` detection |
| `POST /api/system/set_config` | Merge partial config JSON updates | Applied via read-merge-write (`changes(from:)` + `merge`) |
| `GET` / `POST /api/network/config` | Read/write DHCP or static IPv4 config | GLKVM |
| `GET` / `POST /api/network/wifi` | Read/write Wi-Fi enablement, SSID & passphrase | GLKVM |
| `GET /api/network/ethernet` | Read link status, speed, IP, MAC | GLKVM |
| `GET /api/turn/get_turn` | TURN credential helper | Defined in `GLKVMClient`; not invoked during WebRTC connect |

### Video Streamer, EDID, Snapshots & OCR

| Method & Path | Purpose | NanoKVM Equivalent / Notes |
| --- | --- | --- |
| `GET /api/streamer` | Features, limits, current params, source info | NanoKVM: `GET /api/vm/hdmi` |
| `POST /api/streamer/set_params` | Configure `desired_fps`, `quality`, `h264_bitrate`, `h264_gop`, `zero_delay`, `resolution` | NanoKVM: `POST /api/vm/screen` JSON (`type`, `fps`, `quality`, `gop`, `resolution`) |
| `POST /api/streamer/reset` | Restart video streamer | NanoKVM: `POST /api/vm/hdmi/reset` |
| `GET /api/streamer/snapshot` | Direct JPEG capture (`?allow_offline=1`, `save`, `load`, `preview*`) | NanoKVM: first JPEG frame sliced from `GET /api/stream/mjpeg` |
| `DELETE /api/streamer/snapshot` | Remove cached snapshot in KVM memory | KVMD/PiKVM |
| `GET /api/streamer/snapshot?ocr=true` | Server Tesseract OCR (`ocr_langs`, `ocr_left`, `ocr_top`, `ocr_right`, `ocr_bottom`) | PiKVM/KVMD with Tesseract enabled |
| `GET /api/streamer/ocr` | Query OCR availability & languages | PiKVM/KVMD |
| `GET /api/upgrade/get_edid` | Read active EDID hex string | GLKVM |
| `POST /api/upgrade/edid` | Upload custom/catalog EDID (`multipart/form-data` field `edid`) | GLKVM |

### HID Input, Keymaps & Text Typing

| Method & Path | Purpose | NanoKVM Equivalent / Notes |
| --- | --- | --- |
| `GET /api/hid` | HID online state, LEDs, outputs, jiggler, absolute mode | NanoKVM: `GET /api/hid/leds` + `GET /api/vm/mouse-jiggler` |
| `POST /api/hid/set_params` | Set `jiggler`, `keyboard_output`, `mouse_output` | NanoKVM jiggler: `POST /api/vm/mouse-jiggler/` JSON `{"enabled":Bool,"mode":"relative"}` |
| `POST /api/hid/set_connected` | Connect/disconnect USB HID gadget (`?connected=true\|false`) | KVMD |
| `POST /api/hid/reset` | Reset emulated USB HID controller | Same path on NanoKVM |
| `GET /api/hid/keymaps` | List supported remote typing keymaps | NanoKVM uses static `en-us`, `de`, `fr` |
| `POST /api/hid/print` | Type plain text body (`?keymap=...&limit=0&slow=...&delay=...`) | NanoKVM: `POST /api/hid/paste` JSON `{"content":..., "langue":"de"\|"fr"\|""}` |
| `POST /api/hid/events/send_shortcut` | Send key chord (`?keys=ControlLeft,AltLeft,Delete`) | KVMD |
| `POST /api/hid/events/send_key` | Single HTTP key event (`?key=...&state=...&finish=...`) | KVMD |
| `POST /api/hid/events/send_mouse_button` | Single HTTP mouse button (`?button=...&state=...`) | KVMD |
| `POST /api/hid/events/send_mouse_move` | HTTP absolute mouse (`?to_x=...&to_y=...`) | KVMD |
| `POST /api/hid/events/send_mouse_relative` | HTTP relative mouse (`?delta_x=...&delta_y=...`) | KVMD |

### Virtual Media (MSD) & GLKVM Storage Partitions

| Method & Path | Purpose | NanoKVM Equivalent / Notes |
| --- | --- | --- |
| `GET /api/msd` | Drive state, storage capacity, image list | NanoKVM: `GET /api/storage/media` + `GET /api/storage/media/state` |
| `POST /api/msd/set_params` | Select `image`, `cdrom` (`true`/`false`), `rw` (`true`/`false`), `user`, `passwd`, `verify` | NanoKVM: `POST /api/storage/media/mount` |
| `POST /api/msd/set_connected` | Mount or unmount drive (`?connected=true\|false`) | NanoKVM eject: `POST /api/storage/media/eject` `{"force":false}` |
| `GET /api/msd/read` | Download stored image (`?image=...&compress=...`) | macOS UI |
| `POST /api/msd/write` | Stream image upload (`application/octet-stream`, `?image=...&prefix=...&remove_incomplete=...`) | Finder picker on macOS; file path input on Linux |
| `POST /api/msd/write_remote` | Fetch URL onto KVM (`http`, `https`, `smb`, `sftp`, `nbd`; streams NDJSON progress) | KVMD/GLKVM |
| `POST /api/msd/remove` | Delete stored image (`?image=...`) | NanoKVM: `POST /api/storage/media/delete` |
| `POST /api/msd/reset` | Reset MSD subsystem | NanoKVM: `POST /api/storage/media/eject` `{"force":true}` |
| `GET /api/msd/partition_show` | List GLKVM storage partitions | Client helper in `GLKVMClient` / `OverlookCore` |
| `POST /api/msd/partition_connect` | Mount GLKVM internal partition to target | macOS & Linux interactive UI |
| `POST /api/msd/partition_disconnect` | Unmount GLKVM internal partition | macOS & Linux interactive UI |
| `POST /api/msd/partition_format` | Format GLKVM partition (`?path=...`) | Defined in `GLKVMClient` |

### ATX Power, GPIO, PiKVM Switch & Redfish BMC

| Method & Path | Purpose | Platform UI & Notes |
| --- | --- | --- |
| `GET /api/atx` | ATX Power/HDD LEDs & enablement | NanoKVM: `GET /api/vm/gpio` (`pwr`, `hdd`) |
| `POST /api/atx/power` | `action=on\|off\|off_hard\|reset_hard`, `wait=true\|false` | NanoKVM: `POST /api/vm/gpio` `{"type":"power"\|"reset","duration":800\|8000}` |
| `POST /api/atx/click` | `button=power\|power_long\|reset`, `wait=true\|false` | NanoKVM maps `power_long` to `duration: 8000` |
| `GET /api/gpio` | User GPIO scheme & live pin states | Interactive on macOS; read-only display on Linux |
| `POST /api/gpio/switch` | Set GPIO output (`?channel=...&state=1\|0&wait=...`) | **macOS UI only** |
| `POST /api/gpio/pulse` | Pulse GPIO output (`?channel=...&delay=...&wait=...`) | **macOS UI only** |
| `GET /api/switch` | Multi-port switch topology, ports, EDIDs | Interactive on macOS & Linux |
| `POST /api/switch/set_active_prev` / `set_active_next` / `set_active` | Change active switch port (`?port=...`) | Interactive on macOS & Linux |
| `POST /api/switch/set_beacon` | Toggle port / uplink / downlink LED beacon | Interactive on macOS & Linux |
| `POST /api/switch/set_port_params` | Update port name & dummy plug state | Interactive on macOS & Linux |
| `POST /api/switch/set_colors` | Set hex beacon colors (`?beacon=FFA500:BF:0028` + `text/plain` body) | Interactive on macOS & Linux |
| `POST /api/switch/reset`, `/api/switch/edids/*`, `/api/switch/atx/*` | Switch unit reset, EDID CRUD, per-port ATX | Switch ATX exposed in **macOS UI** (`GLKVMClient` also implements unit reset & EDID endpoints) |
| `GET /redfish/v1/Systems/0` | Inspect Redfish `PowerState` & allowable reset types | macOS & Linux interactive UI |
| `POST /redfish/v1/Systems/0/Actions/ComputerSystem.Reset` | `On`, `ForceOff`, `GracefulShutdown`, `ForceRestart`, `ForceOn`, `PushPowerButton` | macOS & Linux interactive UI |
| `GET /redfish/v1/Managers/BMC/VirtualMedia/MSD` (+ `InsertMedia` / `EjectMedia`) | Redfish VirtualMedia control | Implemented in `GLKVMClient.swift` (no UI exposed) |
