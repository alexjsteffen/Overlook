import Foundation
import CDesktop
import OverlookCore

extension SettingsDialogController {
    // MARK: - Page 3: Media & Hardware

    func buildMediaAndHardwarePage() -> UnsafeMutableRawPointer {
        let page = ad_prefs_page("Media & Hardware", "drive-removable-media-symbolic")!

        // Virtual Media (MSD)
        let msdGroup = ad_group_desc("Virtual Media (MSD /api/msd)", "Mount ISO/IMG images, toggle CD-ROM or Flash Read-Write mode, upload local files, or fetch remote URLs.")!
        msdStatusRow = ad_action_row("Mass Storage Status", "Unavailable or not loaded")
        let refreshMsdBtn = ol_button("Refresh")!
        ad_css(refreshMsdBtn, "flat"); ad_align(refreshMsdBtn, alignFill, alignCenter)
        on(refreshMsdBtn, "clicked") { [unowned self] in refreshMsd() }
        ad_action_row_suffix(msdStatusRow, refreshMsdBtn)
        ad_group_add(msdGroup, msdStatusRow)

        msdMountedRow = ad_action_row("Mounted Image", "None")
        ad_group_add(msdGroup, msdMountedRow)

        msdImageCombo = ad_combo_row("Select Stored Image", nil)
        ad_combo_append(msdImageCombo, "None")
        ad_combo_set(msdImageCombo, 0)
        ad_group_add(msdGroup, msdImageCombo)

        msdTypeCombo = ad_combo_row("Media Type", nil)
        ad_combo_append(msdTypeCombo, "CD-ROM / ISO")
        ad_combo_append(msdTypeCombo, "Flash / USB Drive")
        ad_combo_set(msdTypeCombo, 0)
        ad_group_add(msdGroup, msdTypeCombo)

        msdRwSwitch = ad_switch_row("Read-Write Mode (Flash)", nil, 0)
        ad_group_add(msdGroup, msdRwSwitch)

        let msdActionsRow = ad_action_row("Drive Actions", "Apply parameters, connect/disconnect virtual drive, or remove selected image")!
        let msdBtnBox = ol_box(0, 6)!
        ad_align(msdBtnBox, alignFill, alignCenter)
        let msdApplyBtn = ol_button("Apply Params")!
        on(msdApplyBtn, "clicked") { [unowned self] in applyMsdParams() }
        let msdConnectBtn = ol_button("Connect / Disconnect")!
        ad_css(msdConnectBtn, "suggested-action")
        on(msdConnectBtn, "clicked") { [unowned self] in
            let currentlyConnected = msdState?.drive?.connected == true
            setMsdConnected(!currentlyConnected)
        }
        let msdRemoveBtn = ol_button("Remove Image")!
        ad_css(msdRemoveBtn, "destructive-action")
        on(msdRemoveBtn, "clicked") { [unowned self] in removeSelectedMsdImage() }
        let msdResetBtn = ol_button("Reset MSD")!
        on(msdResetBtn, "clicked") { [unowned self] in resetMsd() }
        for b in [msdApplyBtn, msdConnectBtn, msdRemoveBtn, msdResetBtn] { ol_append(msdBtnBox, b) }
        ad_action_row_suffix(msdActionsRow, msdBtnBox)
        ad_group_add(msdGroup, msdActionsRow)

        msdLocalPathEntry = ad_entry_row("Upload Local Image Path (.iso / .img)")
        let uploadLocalBtn = ol_button("Upload")!
        ad_css(uploadLocalBtn, "flat"); ad_align(uploadLocalBtn, alignFill, alignCenter)
        on(uploadLocalBtn, "clicked") { [unowned self] in uploadLocalMsdFile() }
        ad_entry_suffix(msdLocalPathEntry, uploadLocalBtn)
        ad_group_add(msdGroup, msdLocalPathEntry)

        msdRemoteUrlEntry = ad_entry_row("Remote Image URL (http/https/smb/sftp)")
        msdRemoteNameEntry = ad_entry_row("Optional Remote Filename (e.g. ubuntu.iso)")
        let fetchRemoteBtn = ol_button("Download to KVM")!
        ad_css(fetchRemoteBtn, "flat"); ad_align(fetchRemoteBtn, alignFill, alignCenter)
        on(fetchRemoteBtn, "clicked") { [unowned self] in uploadRemoteMsdByURL() }
        ad_entry_suffix(msdRemoteNameEntry, fetchRemoteBtn)
        ad_group_add(msdGroup, msdRemoteUrlEntry)
        ad_group_add(msdGroup, msdRemoteNameEntry)

        let partRow = ad_action_row("GLKVM Storage Partitions", "Connect or disconnect external storage partition")!
        let partBox = ol_box(0, 6)!
        ad_align(partBox, alignFill, alignCenter)
        let partConnBtn = ol_button("Connect Partition")!
        on(partConnBtn, "clicked") { [unowned self] in msdPartitionAction(connect: true) }
        let partDiscBtn = ol_button("Disconnect Partition")!
        on(partDiscBtn, "clicked") { [unowned self] in msdPartitionAction(connect: false) }
        ol_append(partBox, partConnBtn)
        ol_append(partBox, partDiscBtn)
        ad_action_row_suffix(partRow, partBox)
        ad_group_add(msdGroup, partRow)
        ad_prefs_page_add(page, msdGroup)

        // Power & Advanced (ATX / Redfish)
        let powerGroup = ad_group_desc("Power & Advanced (ATX / Redfish)", "Monitor motherboard power/HDD LEDs, trigger ATX power/front-panel actions, and control Redfish BMC.")!
        atxStatusRow = ad_action_row("ATX Status", "Power LED: — · HDD LED: —")
        let refreshAtxBtn = ol_button("Refresh")!
        ad_css(refreshAtxBtn, "flat"); ad_align(refreshAtxBtn, alignFill, alignCenter)
        on(refreshAtxBtn, "clicked") { [unowned self] in refreshAtxAndRedfish() }
        ad_action_row_suffix(atxStatusRow, refreshAtxBtn)
        ad_group_add(powerGroup, atxStatusRow)

        atxWaitSwitch = ad_switch_row("Wait for ATX Operation Completion", nil, 0)
        ad_group_add(powerGroup, atxWaitSwitch)

        let atxPowerRow = ad_action_row("ATX Power Actions", "/api/atx/power")!
        let atxPowerBox = ol_box(0, 4)!
        ad_align(atxPowerBox, alignFill, alignCenter)
        for act in KVMAtxPowerAction.allCases {
            let b = ol_button(act.displayName)!
            ad_css(b, "flat")
            on(b, "clicked") { [unowned self] in performAtxPower(act) }
            ol_append(atxPowerBox, b)
        }
        ad_action_row_suffix(atxPowerRow, atxPowerBox)
        ad_group_add(powerGroup, atxPowerRow)

        let atxClickRow = ad_action_row("Front Panel Case Buttons", "/api/atx/click")!
        let atxClickBox = ol_box(0, 4)!
        ad_align(atxClickBox, alignFill, alignCenter)
        for btn in KVMAtxButton.allCases {
            let b = ol_button(btn.displayName)!
            ad_css(b, "flat")
            on(b, "clicked") { [unowned self] in performAtxClick(btn) }
            ol_append(atxClickBox, b)
        }
        ad_action_row_suffix(atxClickRow, atxClickBox)
        ad_group_add(powerGroup, atxClickRow)

        redfishStatusRow = ad_action_row("Redfish BMC (/redfish/v1)", "PowerState: Unknown")
        ad_group_add(powerGroup, redfishStatusRow)

        redfishResetCombo = ad_combo_row("Redfish Reset Action", nil)
        for rt in KVMRedfishResetType.allCases { ad_combo_append(redfishResetCombo, rt.rawValue) }
        ad_combo_set(redfishResetCombo, 2)
        let sendRfBtn = ol_button("Send Reset")!
        ad_css(sendRfBtn, "flat"); ad_align(sendRfBtn, alignFill, alignCenter)
        on(sendRfBtn, "clicked") { [unowned self] in performRedfishReset() }
        ad_action_row_suffix(redfishResetCombo, sendRfBtn)
        ad_group_add(powerGroup, redfishResetCombo)

        let resetKvmRow = ad_action_row("Reset KVM Subsystems", "Resets both HID and Streamer (/api/hid/reset + /api/streamer/reset)")!
        let resetKvmBtn = ol_button("Reset KVM")!
        ad_css(resetKvmBtn, "destructive-action"); ad_align(resetKvmBtn, alignFill, alignCenter)
        on(resetKvmBtn, "clicked") { [unowned self] in resetKvmAll() }
        ad_action_row_suffix(resetKvmRow, resetKvmBtn)
        ad_group_add(powerGroup, resetKvmRow)
        ad_prefs_page_add(page, powerGroup)

        // GPIO
        let gpioGroup = ad_group_desc("GPIO Controls (/api/gpio)", "Monitor GPIO input pins and toggle/pulse output channels.")!
        gpioInputsRow = ad_action_row("GPIO Channels", "No user GPIO channels configured")
        let refreshGpioBtn = ol_button("Refresh")!
        ad_css(refreshGpioBtn, "flat"); ad_align(refreshGpioBtn, alignFill, alignCenter)
        on(refreshGpioBtn, "clicked") { [unowned self] in refreshGpio() }
        ad_action_row_suffix(gpioInputsRow, refreshGpioBtn)
        ad_group_add(gpioGroup, gpioInputsRow)
        gpioOutputsGroup = gpioGroup
        ad_prefs_page_add(page, gpioGroup)

        // Multi-Port Switch
        let swGroup = ad_group_desc("Multi-Port Switch (/api/switch)", "Control PiKVM Multi-Port Switch active port, beacons, dummy plugs, and per-port ATX.")!
        switchStatusRow = ad_action_row("Switch Status", "Active Port: —")
        let swNavBox = ol_box(0, 4)!
        ad_align(swNavBox, alignFill, alignCenter)
        let prevPortBtn = ol_button("Prev Port")!
        on(prevPortBtn, "clicked") { [unowned self] in switchPrevNext(next: false) }
        let nextPortBtn = ol_button("Next Port")!
        on(nextPortBtn, "clicked") { [unowned self] in switchPrevNext(next: true) }
        let refSwBtn = ol_button("Refresh")!
        on(refSwBtn, "clicked") { [unowned self] in refreshSwitch() }
        for b in [prevPortBtn, nextPortBtn, refSwBtn] { ad_css(b, "flat"); ol_append(swNavBox, b) }
        ad_action_row_suffix(switchStatusRow, swNavBox)
        ad_group_add(swGroup, switchStatusRow)

        switchPortEntry = ad_entry_row("Target Port (0..19 or unit.port)")
        ol_set_value(switchPortEntry, "0")
        let swPortBtnBox = ol_box(0, 4)!
        ad_align(swPortBtnBox, alignFill, alignCenter)
        let activatePortBtn = ol_button("Switch to Port")!
        on(activatePortBtn, "clicked") { [unowned self] in
            switchSelectPort(String(cString: ol_value(switchPortEntry)))
        }
        let beaconOnBtn = ol_button("Beacon On")!
        on(beaconOnBtn, "clicked") { [unowned self] in
            switchSetBeacon(state: true, port: String(cString: ol_value(switchPortEntry)))
        }
        let beaconOffBtn = ol_button("Beacon Off")!
        on(beaconOffBtn, "clicked") { [unowned self] in
            switchSetBeacon(state: false, port: String(cString: ol_value(switchPortEntry)))
        }
        for b in [activatePortBtn, beaconOnBtn, beaconOffBtn] { ad_css(b, "flat"); ol_append(swPortBtnBox, b) }
        ad_entry_suffix(switchPortEntry, swPortBtnBox)
        ad_group_add(swGroup, switchPortEntry)

        switchPortNameEntry = ad_entry_row("Port Name (e.g. PORT3)")
        switchDummySwitch = ad_switch_row("HDMI Dummy Plug", nil, 0)
        let savePortBtn = ol_button("Save Port Params")!
        ad_css(savePortBtn, "flat"); ad_align(savePortBtn, alignFill, alignCenter)
        on(savePortBtn, "clicked") { [unowned self] in switchApplyPortParams() }
        ad_action_row_suffix(switchDummySwitch, savePortBtn)
        ad_group_add(swGroup, switchPortNameEntry)
        ad_group_add(swGroup, switchDummySwitch)

        switchBeaconEntry = ad_entry_row("Beacon Hex Color (FFA500:BF:0028)")
        ol_set_value(switchBeaconEntry, "FFA500:BF:0028")
        let setColorBtn = ol_button("Set Color")!
        ad_css(setColorBtn, "flat"); ad_align(setColorBtn, alignFill, alignCenter)
        on(setColorBtn, "clicked") { [unowned self] in switchApplyBeaconColors() }
        ad_entry_suffix(switchBeaconEntry, setColorBtn)
        ad_group_add(swGroup, switchBeaconEntry)
        ad_prefs_page_add(page, swGroup)

        return page
    }

    // MARK: - Page 4: System & Network

    func buildSystemAndNetworkPage() -> UnsafeMutableRawPointer {
        let page = ad_prefs_page("System & Network", "preferences-system-symbolic")!

        // Appearance & Regional
        let appGroup = ad_group_desc("Appearance & Regional", "Configure Overlook GTK color scheme and remote WebUI theme, language, and timezone.")!
        appearanceCombo = ad_combo_row("App Appearance", "Follow desktop theme or force Light/Dark")
        for label in ["System Default", "Light", "Dark"] { ad_combo_append(appearanceCombo, label) }
        let appIdx = Self.appearances.firstIndex(of: desktop.preferences.appAppearance) ?? 0
        ad_combo_set(appearanceCombo, Int32(appIdx))
        on(appearanceCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(appearanceCombo))
            if idx >= 0 && idx < Self.appearances.count {
                desktop.preferences.appAppearance = Self.appearances[idx]
                desktop.applyAppearance()
                desktop.savePreferences()
            }
        }
        ad_group_add(appGroup, appearanceCombo)

        webThemeCombo = ad_combo_row("Device WebUI Color Mode", nil)
        ad_combo_append(webThemeCombo, "Light")
        ad_combo_append(webThemeCombo, "Dark")
        on(webThemeCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let val = ad_combo_get(webThemeCombo) == 1 ? "1" : "0"
            mutateConfig { $0.themeMode = val }
        }
        ad_group_add(appGroup, webThemeCombo)

        languageCombo = ad_combo_row("Device Language", nil)
        for l in Self.languages { ad_combo_append(languageCombo, l) }
        on(languageCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(languageCombo))
            if idx >= 0 && idx < Self.languages.count {
                mutateConfig { $0.language = Self.languages[idx] }
            }
        }
        ad_group_add(appGroup, languageCombo)

        timezoneCombo = ad_combo_row("Device Timezone", nil)
        for tz in Self.timezones { ad_combo_append(timezoneCombo, tz) }
        on(timezoneCombo!, "notify::selected") { [unowned self] (_: UnsafeMutableRawPointer?) in
            guard !isSyncing else { return }
            let idx = Int(ad_combo_get(timezoneCombo))
            if idx >= 0 && idx < Self.timezones.count {
                mutateConfig { $0.timezone = Self.timezones[idx] }
            }
        }
        ad_group_add(appGroup, timezoneCombo)
        ad_prefs_page_add(page, appGroup)

        // Hardware & System Health (/api/info)
        let hwGroup = ad_group_desc("Hardware & System Health (/api/info)", "Live platform info, KVMD/ustreamer/kernel versions, CPU/memory load, and thermal/power flags.")!
        hwPlatformRow = ad_action_row("Platform & Serial", "—")
        let refInfoBtn = ol_button("Refresh")!
        ad_css(refInfoBtn, "flat"); ad_align(refInfoBtn, alignFill, alignCenter)
        on(refInfoBtn, "clicked") { [unowned self] in refreshSystemInfo() }
        ad_action_row_suffix(hwPlatformRow, refInfoBtn)
        hwVersionsRow = ad_action_row("KVMD & Kernel", "—")
        hwCpuMemRow = ad_action_row("CPU & Memory Load", "—")
        hwTempFlagsRow = ad_action_row("Temperature & Power Flags", "—")
        for r in [hwPlatformRow!, hwVersionsRow!, hwCpuMemRow!, hwTempFlagsRow!] {
            ad_group_add(hwGroup, r)
        }

        let diagRow = ad_action_row("KVMD Diagnostics", "Inspect service logs (/api/log) or Prometheus metrics (/api/export/prometheus/metrics)")!
        let diagBox = ol_box(0, 6)!
        ad_align(diagBox, alignFill, alignCenter)
        let logsBtn = ol_button("Service Logs…")!
        on(logsBtn, "clicked") { [unowned self] in fetchAndShowDeviceLogs() }
        let promBtn = ol_button("Prometheus Metrics…")!
        on(promBtn, "clicked") { [unowned self] in fetchAndShowPrometheus() }
        ol_append(diagBox, logsBtn)
        ol_append(diagBox, promBtn)
        ad_action_row_suffix(diagRow, diagBox)
        ad_group_add(hwGroup, diagRow)
        ad_prefs_page_add(page, hwGroup)

        // Network Configuration (/api/network/*)
        let netGroup = ad_group_desc("Network Configuration (/api/network)", "Configure IPv4 DHCP/Static settings, Wi-Fi connection, and inspect Ethernet status.")!
        netModeCombo = ad_combo_row("IP Mode", nil)
        ad_combo_append(netModeCombo, "DHCP")
        ad_combo_append(netModeCombo, "Static IP")
        netIpEntry = ad_entry_row("IP Address")
        ol_set_value(netIpEntry, "192.168.8.1")
        netMaskEntry = ad_entry_row("Subnet Mask")
        ol_set_value(netMaskEntry, "255.255.255.0")
        netGwEntry = ad_entry_row("Gateway")
        ol_set_value(netGwEntry, "192.168.8.1")
        netDnsEntry = ad_entry_row("DNS Server")
        ol_set_value(netDnsEntry, "8.8.8.8")
        let applyNetBtn = ol_button("Apply IP Settings")!
        ad_css(applyNetBtn, "suggested-action"); ad_align(applyNetBtn, alignFill, alignCenter)
        on(applyNetBtn, "clicked") { [unowned self] in applyNetworkConfig() }
        ad_entry_suffix(netDnsEntry, applyNetBtn)

        wifiEnableSwitch = ad_switch_row("Enable Wi-Fi", nil, 1)
        wifiSsidEntry = ad_entry_row("Wi-Fi SSID")
        wifiPassEntry = ad_password_row("Wi-Fi Password")
        let applyWifiBtn = ol_button("Apply Wi-Fi")!
        ad_css(applyWifiBtn, "flat"); ad_align(applyWifiBtn, alignFill, alignCenter)
        on(applyWifiBtn, "clicked") { [unowned self] in applyWifiConfig() }
        ad_entry_suffix(wifiPassEntry, applyWifiBtn)
        wifiStatusRow = ad_action_row("Wi-Fi Status", "—")
        ethStatusRow = ad_action_row("Ethernet Status", "—")
        for r in [netModeCombo!, netIpEntry!, netMaskEntry!, netGwEntry!, netDnsEntry!, wifiEnableSwitch!, wifiSsidEntry!, wifiPassEntry!, wifiStatusRow!, ethStatusRow!] {
            ad_group_add(netGroup, r)
        }
        ad_prefs_page_add(page, netGroup)

        return page
    }
}
