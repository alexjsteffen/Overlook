import Foundation
import CNativeWin
import OverlookCore

extension SettingsDialog {
    func queryVirtualMedia() {
        guard let session else {
            ad_action_set_subtitle(mediaStatusRow, "Not connected to a device")
            return
        }
        ad_action_set_subtitle(mediaStatusRow, "Querying /api/msd…")
        session.apiRequest(method: "GET", path: "/api/msd") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                let summary = Self.extractJSONSummary(res.data, keys: ["image", "mounted", "state", "status", "drive"])
                ad_action_set_subtitle(self.mediaStatusRow, "HTTP \(res.status): \(summary)")
                self.populateMediaImages(from: res.data)
            case .failure(let err):
                ad_action_set_subtitle(self.mediaStatusRow, err.localizedDescription)
            }
        }
    }

    private func populateMediaImages(from data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let root = (obj["result"] as? [String: Any]) ?? (obj["data"] as? [String: Any]) ?? obj
        let images: [String] = (root["images"] as? [String])
            ?? (root["files"] as? [[String: Any]])?.compactMap { $0["name"] as? String ?? $0["path"] as? String }
            ?? []
        for img in images.prefix(6) {
            let row = ad_action_row(img, "Available on GLKVM storage")
            let mountBtn = ad_button("Mount", "suggested-action")
            ad_row_add_suffix(row, mountBtn)
            ad_row_activatable(row, mountBtn)
            let box = Unmanaged.passRetained(MountActionBox(dialog: self, imageName: img)).toOpaque()
            ol_signal_connect(mountBtn, "clicked", { _, ctx in
                guard let ctx else { return }
                let b = Unmanaged<MountActionBox>.fromOpaque(ctx).takeUnretainedValue()
                b.dialog?.mountVirtualMedia(imageName: b.imageName)
            }, box)
            ad_pref_add(mediaListGroup, row)
        }
    }

    func mountVirtualMedia(imageName: String) {
        guard let session else { return }
        let payload = try? JSONSerialization.data(withJSONObject: ["image": imageName, "connected": true])
        ad_action_set_subtitle(mediaStatusRow, "Mounting \(imageName)…")
        session.apiRequest(method: "POST", path: "/api/msd/connect", contentType: "application/json", body: payload) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.mediaStatusRow, "Mounted \(imageName) (HTTP \(res.status))")
                self.onStatusToast("Mounted virtual media: \(imageName)")
            case .failure(let err):
                ad_action_set_subtitle(self.mediaStatusRow, "Mount failed: \(err.localizedDescription)")
            }
        }
    }

    func unmountVirtualMedia() {
        guard let session else { return }
        let payload = try? JSONSerialization.data(withJSONObject: ["connected": false])
        ad_action_set_subtitle(mediaStatusRow, "Unmounting virtual media…")
        session.apiRequest(method: "POST", path: "/api/msd/disconnect", contentType: "application/json", body: payload) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.mediaStatusRow, "Unmounted (HTTP \(res.status))")
                self.onStatusToast("Virtual media unmounted")
            case .failure(let err):
                ad_action_set_subtitle(self.mediaStatusRow, "Unmount failed: \(err.localizedDescription)")
            }
        }
    }

    func uploadVirtualMedia() {
        guard let session else { return }
        let filePath = readText(mediaUploadEntry)
        guard !filePath.isEmpty else {
            ad_action_set_subtitle(mediaStatusRow, "Enter a local ISO or IMG file path first")
            return
        }
        guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            ad_action_set_subtitle(mediaStatusRow, "Cannot read file at \(filePath)")
            return
        }
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
        ad_action_set_subtitle(mediaStatusRow, "Uploading \(fileName) (\(ConnectionInfoDialog.formatBytes(UInt64(fileData.count))))…")
        session.apiRequest(
            method: "POST",
            path: "/api/msd/upload?image=\(fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileName)",
            contentType: "application/octet-stream",
            body: fileData
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.mediaStatusRow, "Uploaded \(fileName) (HTTP \(res.status))")
                self.onStatusToast("Uploaded \(fileName) to device")
                self.queryVirtualMedia()
            case .failure(let err):
                ad_action_set_subtitle(self.mediaStatusRow, "Upload failed: \(err.localizedDescription)")
            }
        }
    }

    func queryATXState() {
        guard let session else {
            ad_action_set_subtitle(atxStatusRow, "Not connected")
            return
        }
        session.apiRequest(method: "GET", path: "/api/atx") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                let summary = Self.extractJSONSummary(res.data, keys: ["power", "leds", "hdd", "state", "status"])
                ad_action_set_subtitle(self.atxStatusRow, "HTTP \(res.status): \(summary)")
            case .failure(let err):
                ad_action_set_subtitle(self.atxStatusRow, err.localizedDescription)
            }
        }
    }

    func sendATXAction(_ action: String) {
        guard let session else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["action": action, "button": action])
        ad_action_set_subtitle(atxStatusRow, "Sending ATX \(action)…")
        session.apiRequest(method: "POST", path: "/api/atx/click", contentType: "application/json", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.atxStatusRow, "ATX \(action) sent (HTTP \(res.status))")
                self.onStatusToast("Sent ATX action: \(action)")
            case .failure(let err):
                ad_action_set_subtitle(self.atxStatusRow, "ATX error: \(err.localizedDescription)")
            }
        }
    }

    func sendWakeOnLAN() {
        guard let session else { return }
        let mac = readText(wolMacEntry)
        guard !mac.isEmpty else {
            ad_action_set_subtitle(atxStatusRow, "Enter a target MAC address for Wake-on-LAN")
            return
        }
        let body = try? JSONSerialization.data(withJSONObject: ["mac": mac])
        session.apiRequest(method: "POST", path: "/api/wol", contentType: "application/json", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.atxStatusRow, "WoL packet sent to \(mac) (HTTP \(res.status))")
                self.onStatusToast("Wake-on-LAN sent to \(mac)")
            case .failure(let err):
                ad_action_set_subtitle(self.atxStatusRow, "WoL failed: \(err.localizedDescription)")
            }
        }
    }

    func applyEDID() {
        guard let session else { return }
        let idx = Int(ad_combo_get(edidCombo))
        let preset = (idx >= 0 && idx < Self.edidPresets.count) ? Self.edidPresets[idx].value : ""
        let custom = readText(edidCustomEntry)
        let target = custom.isEmpty ? preset : custom
        guard !target.isEmpty else {
            onStatusToast("Select an EDID preset or enter a custom resolution")
            return
        }
        let body = try? JSONSerialization.data(withJSONObject: ["edid": target, "preset": target])
        session.apiRequest(method: "POST", path: "/api/edid", contentType: "application/json", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                self.onStatusToast("Applied EDID \(target) (HTTP \(res.status))")
            case .failure(let err):
                self.onStatusToast("EDID update failed: \(err.localizedDescription)")
            }
        }
    }

    func applyUSBIdentity() {
        guard let session else { return }
        let payload: [String: String] = [
            "vendor_id": readText(usbVendorEntry),
            "product_id": readText(usbProductEntry),
            "manufacturer": readText(usbManufacturerEntry),
            "product": readText(usbProductNameEntry),
            "serial": readText(usbSerialEntry),
        ]
        let body = try? JSONSerialization.data(withJSONObject: payload)
        session.apiRequest(method: "POST", path: "/api/hid/usb", contentType: "application/json", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                self.onStatusToast("Updated USB HID identity (HTTP \(res.status))")
            case .failure(let err):
                self.onStatusToast("USB identity update failed: \(err.localizedDescription)")
            }
        }
    }

    func queryTailscale() {
        guard let session else {
            ad_action_set_subtitle(tailscaleStatusRow, "Not connected")
            return
        }
        session.apiRequest(method: "GET", path: "/api/tailscale/status") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                let summary = Self.extractJSONSummary(res.data, keys: ["status", "ip", "hostname", "running", "state"])
                ad_action_set_subtitle(self.tailscaleStatusRow, "HTTP \(res.status): \(summary)")
            case .failure(let err):
                ad_action_set_subtitle(self.tailscaleStatusRow, err.localizedDescription)
            }
        }
    }

    func setTailscale(enabled: Bool) {
        guard let session else { return }
        let path = enabled ? "/api/tailscale/up" : "/api/tailscale/down"
        let body = try? JSONSerialization.data(withJSONObject: ["enable": enabled])
        session.apiRequest(method: "POST", path: path, contentType: "application/json", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.tailscaleStatusRow, "Tailscale \(enabled ? "enabled" : "disabled") (HTTP \(res.status))")
            case .failure(let err):
                ad_action_set_subtitle(self.tailscaleStatusRow, err.localizedDescription)
            }
        }
    }

    func querySystemInfo() {
        guard let session else {
            ad_action_set_subtitle(firmwareRow, "Not connected")
            return
        }
        session.apiRequest(method: "GET", path: "/api/info") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                let summary = Self.extractJSONSummary(res.data, keys: ["version", "firmware", "model", "hostname", "uptime"])
                ad_action_set_subtitle(self.firmwareRow, "HTTP \(res.status): \(summary)")
            case .failure(let err):
                ad_action_set_subtitle(self.firmwareRow, err.localizedDescription)
            }
        }
    }

    func rebootAppliance() {
        guard let session else { return }
        session.apiRequest(method: "POST", path: "/api/system/reboot") { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.firmwareRow, "Rebooting appliance (HTTP \(res.status))")
                self.onStatusToast("GLKVM appliance is rebooting")
            case .failure(let err):
                ad_action_set_subtitle(self.firmwareRow, "Reboot failed: \(err.localizedDescription)")
            }
        }
    }

    func changeAdminPassword() {
        guard let session else { return }
        let newPwd = readText(newPasswordEntry)
        let confirmPwd = readText(confirmPasswordEntry)
        guard !newPwd.isEmpty else {
            ad_action_set_subtitle(passwordStatusRow, "Password cannot be empty")
            return
        }
        guard newPwd == confirmPwd else {
            ad_action_set_subtitle(passwordStatusRow, "Passwords do not match")
            return
        }
        let body = try? JSONSerialization.data(withJSONObject: ["password": newPwd, "new_password": newPwd])
        session.apiRequest(method: "POST", path: "/api/auth/password", contentType: "application/json", body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let res):
                ad_action_set_subtitle(self.passwordStatusRow, "Password updated (HTTP \(res.status))")
                ad_editable_set(self.newPasswordEntry, "")
                ad_editable_set(self.confirmPasswordEntry, "")
                self.onStatusToast("Updated appliance admin password")
            case .failure(let err):
                ad_action_set_subtitle(self.passwordStatusRow, "Update failed: \(err.localizedDescription)")
            }
        }
    }

    static func extractJSONSummary(_ data: Data, keys: [String]) -> String {
        guard !data.isEmpty else { return "Empty response" }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let root = (obj["result"] as? [String: Any]) ?? (obj["data"] as? [String: Any]) ?? obj
            var parts: [String] = []
            for key in keys {
                if let val = root[key] {
                    parts.append("\(key)=\(val)")
                }
            }
            if !parts.isEmpty {
                return parts.joined(separator: ", ")
            }
        }
        let raw = String(data: data.prefix(160), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Binary payload"
        return raw.isEmpty ? "OK" : raw
    }
}

final class MountActionBox {
    weak var dialog: SettingsDialog?
    let imageName: String
    init(dialog: SettingsDialog, imageName: String) {
        self.dialog = dialog
        self.imageName = imageName
    }
}
