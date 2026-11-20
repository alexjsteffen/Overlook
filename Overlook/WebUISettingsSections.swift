// swiftlint:disable file_length line_length
import SwiftUI
import AppKit

// Ticket 05: one struct per `DisclosureGroup` section of the settings panel.
// Every section binds through `SessionConnection` (`connection.glkvmClient`), never a shared
// global client, so multi-window sessions act strictly on their own device.

// MARK: - Video

struct VideoSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var captureManager: CaptureManager
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    private static let processingOptions: [(String, String)] = [
        ("low_latency_first", "Low latency"),
        ("quality_first", "Smart"),
    ]

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.video.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                let modeBinding = actions.bindingString(
                    get: { $0.videoProcessing },
                    set: { $0.videoProcessing = $1 },
                    defaultValue: "low_latency_first"
                )
                Picker("Mode", selection: modeBinding) {
                    ForEach(Self.processingOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }
                .onChange(of: modeBinding.wrappedValue) { _, newValue in
                    actions.setPreferLowLatencyPlayout(newValue == "low_latency_first")
                }

                Picker("Quality", selection: $model.selectedVideoQualityPreset) {
                    ForEach(QualityPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                    Text("Custom").tag(WebUISettingsPanelModel.videoQualityCustomTag)
                }
                .disabled(connection.glkvmClient == nil || model.isLoading || model.isApplying || model.isApplyingStreamer || model.isApplyingEdid)
                .onChange(of: model.selectedVideoQualityPreset) { _, newValue in
                    guard model.isLoading == false else { return }
                    Task { await actions.applyVideoQualityPreset(newValue) }
                }

                Picker("EDID", selection: $model.selectedEdidOption) {
                    ForEach(EDIDCatalog.options, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .disabled(connection.glkvmClient == nil || model.isLoading || model.isApplyingEdid)
                .onChange(of: model.selectedEdidOption) { _, newValue in
                    guard model.isProgrammaticEdidSelectionUpdate == false else { return }
                    guard newValue != EDIDCatalog.customOptionID else { return }
                    guard let edid = EDIDCatalog.resolvedEdid(forID: newValue) else { return }
                    Task { await actions.applyEdid(edid) }
                }

                if model.selectedEdidOption == EDIDCatalog.customOptionID {
                    TextEditor(text: $model.customEdidDraft)
                        .font(.body)
                        .frame(minHeight: 90, maxHeight: 160)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                        .disabled(connection.glkvmClient == nil || model.isApplyingEdid)

                    HStack {
                        Button("Apply custom EDID") {
                            Task { await actions.applyEdid(model.customEdidDraft) }
                        }
                        .disabled(
                            connection.glkvmClient == nil ||
                                model.isApplyingEdid ||
                                model.customEdidDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        Spacer()
                    }
                }

                Picker("Orientation", selection: actions.bindingInt(
                    get: { $0.orientation },
                    set: { $0.orientation = $1 },
                    defaultValue: 0
                )) {
                    Text("0°").tag(0)
                    Text("90°").tag(90)
                    Text("180°").tag(180)
                    Text("270°").tag(270)
                }

                Toggle("Show Cursor", isOn: actions.bindingBool(
                    get: { $0.showCursor },
                    set: { $0.showCursor = $1 },
                    defaultValue: true
                ))

                if model.selectedVideoQualityPreset == WebUISettingsPanelModel.videoQualityCustomTag {
                    StreamerParamsSection(model: model, actions: actions)
                }

                Divider()
                    .padding(.vertical, 2)

                Text("Streamer Snapshot & OCR")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    Button("Save Streamer Snapshot") {
                        captureManager.saveDeviceSnapshot(saveOnDevice: true, quality: 95)
                    }
                    .disabled(connection.glkvmClient == nil)
                    .help("Captures a JPEG directly from GET /api/streamer/snapshot")

                    Button("Clear Cached Snapshot") {
                        Task { await actions.deleteCachedStreamerSnapshot() }
                    }
                    .disabled(connection.glkvmClient == nil)
                    .help("Removes the saved snapshot from memory via DELETE /api/streamer/snapshot")
                }

                Toggle("Prefer Server OCR (PiKVM Tesseract)", isOn: $ocrManager.preferRemoteServerOCR)
                    .help("When enabled, OCR selection uses GET /api/streamer/snapshot?ocr=true on the KVM before falling back to local Apple Vision OCR.")

                if ocrManager.preferRemoteServerOCR || ocrManager.remoteOcrEnabledOnDevice {
                    Picker("Server OCR Language", selection: $ocrManager.remoteOcrLanguage) {
                        ForEach(ocrManager.availableRemoteOcrLanguages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Streamer params (nested inside Video)

/// The custom-quality streamer controls. Split out from `VideoSettingsSection` because it owns the
/// `@FocusState` for the numeric text fields; that focus is mirrored into the panel model so the
/// apply/sync logic can keep skipping updates while the user is typing.
struct StreamerParamsSection: View {
    @ObservedObject var model: WebUISettingsPanelModel
    let actions: WebUISettingsActions

    @FocusState private var focusedStreamerField: WebUISettingsPanelModel.StreamerField?

    private var streamerFeatures: GLKVMStreamerState.Features? { actions.streamerFeatures }
    private var streamerLimits: GLKVMStreamerState.Limits? { actions.streamerLimits }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Streamer")
                .font(.subheadline)

            HStack {
                Text("FPS")
                Spacer()
                TextField("", text: $model.streamerDesiredFpsText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .fps)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper(
                    "",
                    value: $model.streamerDesiredFps,
                    in: (streamerLimits?.desiredFps.min ?? 1)...(streamerLimits?.desiredFps.max ?? 60)
                )
                .labelsHidden()
                .disabled(focusedStreamerField == .fps)
            }
            .disabled(model.streamerState == nil)
            .onChange(of: model.streamerDesiredFps) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerDesiredFpsText = String(model.streamerDesiredFps)
                actions.scheduleStreamerApply()
            }

            HStack {
                Text("Quality")
                Spacer()
                TextField("", text: $model.streamerQualityText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .quality)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper("", value: $model.streamerQuality, in: 0...100)
                    .labelsHidden()
                    .disabled(focusedStreamerField == .quality)
            }
            .disabled(model.streamerState == nil || streamerFeatures?.quality == false)
            .onChange(of: model.streamerQuality) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerQualityText = String(model.streamerQuality)
                actions.scheduleStreamerApply()
            }

            HStack {
                Text("Bitrate")
                Spacer()
                TextField("", text: $model.streamerH264BitrateText)
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .bitrate)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper(
                    "",
                    value: $model.streamerH264Bitrate,
                    in: (streamerLimits?.h264Bitrate.min ?? 100)...(streamerLimits?.h264Bitrate.max ?? 20000)
                )
                .labelsHidden()
                .disabled(focusedStreamerField == .bitrate)
            }
            .disabled(model.streamerState == nil || streamerFeatures?.h264 == false)
            .onChange(of: model.streamerH264Bitrate) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerH264BitrateText = String(model.streamerH264Bitrate)
                actions.scheduleStreamerApply()
            }

            HStack {
                Text("GOP")
                Spacer()
                TextField("", text: $model.streamerH264GopText)
                    .frame(width: 70)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedStreamerField, equals: .gop)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
                Stepper(
                    "",
                    value: $model.streamerH264Gop,
                    in: (streamerLimits?.h264Gop.min ?? 1)...(streamerLimits?.h264Gop.max ?? 300)
                )
                .labelsHidden()
                .disabled(focusedStreamerField == .gop)
            }
            .disabled(model.streamerState == nil || streamerFeatures?.h264 == false)
            .onChange(of: model.streamerH264Gop) { _, _ in
                guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                model.streamerH264GopText = String(model.streamerH264Gop)
                actions.scheduleStreamerApply()
            }

            Toggle("Zero delay", isOn: $model.streamerZeroDelay)
                .disabled(model.streamerState == nil || streamerFeatures?.zeroDelay == false)
                .onChange(of: model.streamerZeroDelay) { _, _ in
                    guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                    actions.scheduleStreamerApply()
                }

            Picker("Resolution", selection: actions.streamerResolutionSelection) {
                Text("Auto").tag("")
                Text("1920x1080").tag("1920x1080")
                Text("1600x900").tag("1600x900")
                Text("1280x720").tag("1280x720")
                Text("1024x768").tag("1024x768")
                Text("Custom").tag("custom")
            }
            .disabled(model.streamerState == nil || streamerFeatures?.resolution == false)

            if actions.streamerResolutionSelection.wrappedValue == "custom" {
                TextField("Custom resolution (e.g. 1920x1080)", text: $model.streamerResolution)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.streamerState == nil || streamerFeatures?.resolution == false)
                    .onChange(of: model.streamerResolution) { _, _ in
                        guard model.isProgrammaticStreamerDraftUpdate == false else { return }
                        guard focusedStreamerField == nil else { return }
                        actions.scheduleStreamerApply()
                    }
                    .focused($focusedStreamerField, equals: .resolution)
                    .onSubmit {
                        focusedStreamerField = nil
                    }
            }
        }
        .onChange(of: focusedStreamerField) { old, new in
            actions.setFocusedStreamerField(new)
            if old != nil, new == nil {
                actions.commitStreamerEditsAndApplyIfNeeded()
            }
        }
        .onDisappear {
            actions.setFocusedStreamerField(nil)
        }
    }
}

// MARK: - Remote device

struct RemoteSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    private static let integerFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.generatesDecimalNumbers = false
        return nf
    }()

    private static let reverseScrollingOptions: [(String, String)] = [
        ("STANDARD", "Standard"),
        ("VERTICAL", "Vertical"),
        ("HORIZONTAL", "Horizontal"),
        ("BOTH", "Both"),
    ]

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.remote.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Mouse Control", isOn: actions.bindingBool(
                    get: { $0.mouseControl },
                    set: { $0.mouseControl = $1 },
                    defaultValue: true
                ))

                Toggle("Keyboard Control", isOn: actions.bindingBool(
                    get: { $0.keyboardControl },
                    set: { $0.keyboardControl = $1 },
                    defaultValue: true
                ))

                if let hid = model.hidState {
                    Toggle("USB HID Gadget Connected", isOn: Binding(
                        get: { hid.connected ?? hid.online },
                        set: { connected in
                            Task { await actions.setHidConnected(connected) }
                        }
                    ))
                    .disabled(connection.glkvmClient == nil || model.isApplyingHid)
                    .help("Connects or disconnects emulated USB keyboard/mouse via POST /api/hid/set_connected")

                    if let kbOutputs = hid.keyboard?.outputs, !kbOutputs.available.isEmpty {
                        Picker("Keyboard Output", selection: Binding(
                            get: { kbOutputs.active },
                            set: { newOutput in
                                Task { await actions.setHidOutput(keyboard: newOutput) }
                            }
                        )) {
                            ForEach(kbOutputs.available, id: \.self) { opt in
                                Text(opt).tag(opt)
                            }
                        }
                        .disabled(connection.glkvmClient == nil || model.isApplyingHid)
                    }

                    if let mouseOutputs = hid.mouse?.outputs, !mouseOutputs.available.isEmpty {
                        Picker("Mouse Output", selection: Binding(
                            get: { mouseOutputs.active },
                            set: { newOutput in
                                Task { await actions.setHidOutput(mouse: newOutput) }
                            }
                        )) {
                            ForEach(mouseOutputs.available, id: \.self) { opt in
                                Text(opt).tag(opt)
                            }
                        }
                        .disabled(connection.glkvmClient == nil || model.isApplyingHid)
                    }
                }

                HStack {
                    Text("Mouse Polling")
                    Spacer()
                    let polling = actions.bindingInt(
                        get: { $0.mousePolling },
                        set: { $0.mousePolling = $1 },
                        defaultValue: 10
                    )
                    TextField("", value: polling, formatter: Self.integerFormatter)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: polling, in: 1...60)
                        .labelsHidden()
                }

                HStack {
                    Text("Sensitivity")
                    Spacer()
                    let sensitivity = actions.bindingInt(
                        get: { $0.relativeSense },
                        set: { $0.relativeSense = $1 },
                        defaultValue: 10
                    )
                    TextField("", value: sensitivity, formatter: Self.integerFormatter)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: sensitivity, in: 1...60)
                        .labelsHidden()
                }

                HStack {
                    Text("Scroll rate")
                    Spacer()
                    let scrollRate = actions.bindingInt(
                        get: { $0.scrollRate },
                        set: { $0.scrollRate = $1 },
                        defaultValue: 5
                    )
                    TextField("", value: scrollRate, formatter: Self.integerFormatter)
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: scrollRate, in: 1...30)
                        .labelsHidden()
                }

                Picker("Scroll direction", selection: actions.bindingString(
                    get: { $0.reverseScrolling },
                    set: { $0.reverseScrolling = $1 },
                    defaultValue: "STANDARD"
                )) {
                    ForEach(Self.reverseScrollingOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                MouseJigglerToggle(model: model, actions: actions)

                Picker("Mouse mode", selection: actions.bindingBool(
                    get: { $0.isAbsoluteMouse },
                    set: { $0.isAbsoluteMouse = $1 },
                    defaultValue: true
                )) {
                    Text("Relative").tag(false)
                    Text("Absolute").tag(true)
                }

                Stepper(
                    "Fingerbot strength: \(actions.bindingIntValue(get: { $0.fingerbotStrength }, defaultValue: 0))",
                    value: actions.bindingInt(
                        get: { $0.fingerbotStrength },
                        set: { $0.fingerbotStrength = $1 },
                        defaultValue: 0
                    ),
                    in: 0...100
                )

                HStack {
                    Button("Reset HID Devices") {
                        Task { await actions.resetHidOnly() }
                    }
                    .disabled(connection.glkvmClient == nil || model.isApplyingHid)
                    .help("Resets HID keyboard and mouse state via POST /api/hid/reset")
                    Spacer()
                }
            }
            .padding(.top, 6)
        }
    }
}

// MARK: - Mouse jiggler

/// The device's mouse jiggler. It shows what the device reports rather than the config's
/// `mouse_jiggle`, which only records the web UI's switch: kvmd starts and stops the jiggler on
/// `hid/set_params` alone.
struct MouseJigglerToggle: View {
    @EnvironmentObject var inputManager: InputManager
    @ObservedObject var model: WebUISettingsPanelModel
    let actions: WebUISettingsActions

    var body: some View {
        let jiggler = inputManager.deviceJiggler
        Toggle("Mouse Jiggle", isOn: actions.mouseJigglerBinding)
            .disabled(jiggler?.isAvailable != true || model.isApplyingJiggler)
            .help(jiggler.map { state in
                state.isAvailable
                    ? "Moves the target's mouse slightly after \(state.interval.map { "\($0) s" } ?? "a while") without input, so it does not sleep or lock."
                    : "This device has no mouse jiggler."
            } ?? "Waiting for the device to report its mouse jiggler.")
    }
}

// MARK: - Keyboard & Text Entry

struct KeyboardSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    private static let builtInShortcuts: [(label: String, keys: [String])] = [
        ("Ctrl+Alt+Del", ["ControlLeft", "AltLeft", "Delete"]),
        ("Ctrl+Shift+Esc", ["ControlLeft", "ShiftLeft", "Escape"]),
        ("Alt+Tab", ["AltLeft", "Tab"]),
        ("Alt+F4", ["AltLeft", "F4"]),
        ("Meta / Win", ["MetaLeft"]),
        ("PrintScreen", ["PrintScreen"]),
        ("Ctrl+Alt+F1", ["ControlLeft", "AltLeft", "F1"]),
        ("Ctrl+Alt+F2", ["ControlLeft", "AltLeft", "F2"]),
    ]

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.keyboard.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let leds = model.hidState?.keyboard?.leds {
                    HStack(spacing: 12) {
                        Text("Keyboard LEDs")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        KeyboardLEDBadge(label: "CAPS", isOn: leds.caps)
                        KeyboardLEDBadge(label: "NUM", isOn: leds.num)
                        KeyboardLEDBadge(label: "SCROLL", isOn: leds.scroll)
                    }
                }

                Picker("Keymap", selection: actions.bindingString(
                    get: { $0.keymap },
                    set: { $0.keymap = $1 },
                    defaultValue: "en-us"
                )) {
                    ForEach(actions.availableKeymaps(), id: \.self) { keymap in
                        Text(keymap).tag(keymap)
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                Text("Quick Shortcuts")
                    .font(.subheadline.weight(.semibold))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Self.builtInShortcuts, id: \.label) { item in
                        Button(item.label) {
                            Task { await actions.sendShortcut(item.keys) }
                        }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .disabled(connection.glkvmClient == nil || model.isSendingHidTextOrShortcut)
                    }
                }

                if let shortcuts = model.config?.shortcuts, !shortcuts.isEmpty {
                    Text("Shortcuts")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)

                    ForEach(shortcuts, id: \.self) { shortcut in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shortcut.label)
                                    .font(.callout)
                                Text(shortcut.keys.joined(separator: "+"))
                                    .foregroundColor(.secondary)
                                    .font(.caption2)
                            }
                            Spacer()
                            Button("Send") {
                                Task { await actions.sendShortcut(shortcut.keys) }
                            }
                            .controlSize(.small)
                            .disabled(connection.glkvmClient == nil || model.isSendingHidTextOrShortcut)
                        }
                    }
                }

                HStack(spacing: 6) {
                    TextField("Comma-separated keys (e.g. ControlLeft,KeyL)", text: $model.customShortcutKeysDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Send") {
                        let keys = model.customShortcutKeysDraft.split(separator: ",").map(String.init)
                        Task { await actions.sendShortcut(keys) }
                    }
                    .controlSize(.small)
                    .disabled(
                        connection.glkvmClient == nil ||
                            model.isSendingHidTextOrShortcut ||
                            model.customShortcutKeysDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                Divider()
                    .padding(.vertical, 2)

                Text("Type Text Remotely (/api/hid/print)")
                    .font(.subheadline.weight(.semibold))

                TextEditor(text: $model.remoteTypeTextDraft)
                    .font(.body)
                    .frame(minHeight: 64, maxHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )

                Toggle("Slow typing mode", isOn: $model.remoteTypeSlowMode)
                    .font(.caption)

                if model.remoteTypeSlowMode {
                    HStack {
                        Text("Inter-key delay")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f s", model.remoteTypeDelaySeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $model.remoteTypeDelaySeconds, in: 0.0...1.0, step: 0.01)
                }

                HStack {
                    Button("Paste Clipboard") {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            model.remoteTypeTextDraft = clip
                        }
                    }
                    .controlSize(.small)

                    Spacer()

                    Button("Type on Remote") {
                        Task { await actions.sendRemoteTypedText() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        connection.glkvmClient == nil ||
                            model.isSendingHidTextOrShortcut ||
                            model.remoteTypeTextDraft.isEmpty
                    )
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct KeyboardLEDBadge: View {
    let label: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOn ? Color.green : Color.gray.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(isOn ? .primary : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Virtual Media (Mass Storage Drive /api/msd)

struct VirtualMediaSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.virtualMedia.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let msd = model.msdState {
                    HStack {
                        Circle()
                            .fill((msd.drive?.connected == true) ? Color.green : (msd.online ? Color.orange : Color.gray))
                            .frame(width: 8, height: 8)
                        Text((msd.drive?.connected == true) ? "Connected to Host" : (msd.online ? "Disconnected from Host" : "MSD Offline"))
                            .font(.caption.weight(.medium))
                        Spacer()
                        if let storage = msd.storage, storage.size > 0 {
                            let freeStr = ByteCountFormatter.string(fromByteCount: storage.free, countStyle: .file)
                            let totalStr = ByteCountFormatter.string(fromByteCount: storage.size, countStyle: .file)
                            Text("\(freeStr) free / \(totalStr)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let drive = msd.drive {
                        HStack {
                            Text("Mounted Image")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(drive.imageName ?? "None")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    let images = msd.storage?.images ?? []
                    Picker("Select Image", selection: $model.msdSelectedImage) {
                        Text("None").tag("")
                        ForEach(images) { img in
                            let sizeLabel = ByteCountFormatter.string(fromByteCount: img.size, countStyle: .file)
                            Text("\(img.name) (\(sizeLabel))").tag(img.name)
                        }
                    }
                    .disabled(model.isApplyingMsd || msd.drive?.connected == true)

                    Picker("Media Type", selection: $model.msdCdromMode) {
                        Text("CD-ROM / ISO").tag(true)
                        Text("Flash / USB Drive").tag(false)
                    }
                    .disabled(model.isApplyingMsd || msd.drive?.connected == true)

                    if !model.msdCdromMode {
                        Toggle("Read-Write Mode", isOn: $model.msdReadWriteMode)
                            .disabled(model.isApplyingMsd || msd.drive?.connected == true)
                    }

                    HStack(spacing: 8) {
                        Button("Apply Params") {
                            Task { await actions.applyMsdParams() }
                        }
                        .controlSize(.small)
                        .disabled(model.isApplyingMsd || msd.drive?.connected == true)

                        let isConnected = msd.drive?.connected == true
                        Button(isConnected ? "Disconnect Drive" : "Connect Drive") {
                            Task { await actions.setMsdConnected(!isConnected) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isApplyingMsd || (!isConnected && model.msdSelectedImage.isEmpty && msd.drive?.imageName == nil))

                        Spacer()

                        Button("Reset MSD") {
                            Task { await actions.resetMsd() }
                        }
                        .controlSize(.small)
                        .disabled(model.isApplyingMsd)
                    }

                    Divider()
                        .padding(.vertical, 2)

                    Text("Upload or Fetch Image")
                        .font(.subheadline.weight(.semibold))

                    HStack {
                        Button("Upload Local Image (.iso / .img)…") {
                            actions.chooseAndUploadLocalMsdImage()
                        }
                        .controlSize(.small)
                        .disabled(model.isApplyingMsd)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Remote Image URL (http/https/smb/sftp/nbd)", text: $model.msdRemoteURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        HStack(spacing: 6) {
                            TextField("Optional filename (e.g. ubuntu.iso)", text: $model.msdRemoteImageNameDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                            Button("Download to KVM") {
                                Task { await actions.uploadRemoteMsdImageByURL() }
                            }
                            .controlSize(.small)
                            .disabled(model.isApplyingMsd || model.msdRemoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if !images.isEmpty {
                        Divider()
                            .padding(.vertical, 2)

                        Text("Stored Images (\(images.count))")
                            .font(.subheadline.weight(.semibold))

                        ForEach(images) { img in
                            HStack(spacing: 6) {
                                Text(img.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: img.size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Button("Save") {
                                    actions.downloadMsdImage(img.name)
                                }
                                .controlSize(.mini)
                                .disabled(model.isApplyingMsd)
                                if img.removable {
                                    Button(role: .destructive) {
                                        Task { await actions.removeMsdImage(img.name) }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .controlSize(.mini)
                                    .disabled(model.isApplyingMsd || msd.drive?.imageName == img.name)
                                }
                            }
                        }
                    }

                    if let partitions = model.msdPartitions, !partitions.devices.isEmpty {
                        Divider()
                            .padding(.vertical, 2)

                        Text("GLKVM Storage Partitions")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 8) {
                            Button("Connect Partition") {
                                Task { await actions.connectMsdPartition() }
                            }
                            .controlSize(.small)
                            .disabled(model.isApplyingMsd)

                            Button("Disconnect Partition") {
                                Task { await actions.disconnectMsdPartition() }
                            }
                            .controlSize(.small)
                            .disabled(model.isApplyingMsd)
                        }
                    }
                } else {
                    HStack {
                        Text("Mass Storage Drive state unavailable or not supported.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Refresh") {
                            Task { await actions.refreshMsd() }
                        }
                        .controlSize(.small)
                        .disabled(connection.glkvmClient == nil)
                    }
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, model.msdState == nil else { return }
            Task { await actions.refreshMsd() }
        }
    }
}

// MARK: - GPIO (/api/gpio)

struct GpioSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.gpio.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let gpio = model.gpioState, (!gpio.inputChannels.isEmpty || !gpio.outputSchemes.isEmpty) {
                    if !gpio.inputChannels.isEmpty {
                        Text("Inputs")
                            .font(.subheadline.weight(.semibold))

                        ForEach(gpio.inputChannels, id: \.self) { ch in
                            let runtime = gpio.inputs[ch]
                            HStack {
                                Circle()
                                    .fill((runtime?.state == true) ? Color.green : Color.gray.opacity(0.45))
                                    .frame(width: 8, height: 8)
                                Text(ch)
                                    .font(.caption)
                                Spacer()
                                Text((runtime?.state == true) ? "HIGH" : "LOW")
                                    .font(.caption2.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    let sortedOutputs = gpio.outputSchemes.values.sorted { $0.channel < $1.channel }
                    if !sortedOutputs.isEmpty {
                        Text("Outputs")
                            .font(.subheadline.weight(.semibold))

                        ForEach(sortedOutputs) { scheme in
                            let runtime = gpio.outputs[scheme.channel]
                            let isOn = runtime?.state ?? false
                            let isBusy = runtime?.busy ?? false
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(isOn ? Color.green : Color.gray.opacity(0.45))
                                    .frame(width: 8, height: 8)
                                Text(scheme.channel)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                if scheme.switchEnabled {
                                    Toggle("", isOn: Binding(
                                        get: { isOn },
                                        set: { newState in
                                            Task { await actions.switchGpio(channel: scheme.channel, state: newState) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .disabled(model.isApplyingGpio || isBusy)
                                }
                                if scheme.maxDelay > 0 || scheme.pulseDelay > 0 {
                                    Button(scheme.pulseDelay > 0 ? String(format: "Pulse (%.1fs)", scheme.pulseDelay) : "Pulse") {
                                        Task {
                                            await actions.pulseGpio(
                                                channel: scheme.channel,
                                                delay: scheme.pulseDelay > 0 ? scheme.pulseDelay : nil
                                            )
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(model.isApplyingGpio || isBusy)
                                }
                            }
                        }
                    }
                } else {
                    HStack {
                        Text("No user GPIO channels configured on this device.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Refresh") {
                            Task { await actions.refreshGpio() }
                        }
                        .controlSize(.small)
                        .disabled(connection.glkvmClient == nil)
                    }
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, model.gpioState == nil else { return }
            Task { await actions.refreshGpio() }
        }
    }
}

// MARK: - PiKVM Switch (/api/switch)

struct SwitchSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.switchControl.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button("Prev Port") {
                        Task { await actions.switchSelectPrevPort() }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)

                    Button("Next Port") {
                        Task { await actions.switchSelectNextPort() }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)

                    Spacer()

                    if let active = model.switchState?.activePort {
                        Text("Active: Port \(active)")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }
                }

                if let ports = model.switchState?.ports, !ports.isEmpty {
                    ForEach(ports) { port in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(model.switchState?.activePort == port.port ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 8, height: 8)
                            Text("\(port.name) (#\(port.port))")
                                .font(.caption)
                            Spacer()
                            Button("Activate") {
                                Task { await actions.switchSelectPort(port.port) }
                            }
                            .controlSize(.mini)
                            .disabled(model.isApplyingSwitch)
                            Button(port.beacon ? "Beacon Off" : "Beacon On") {
                                Task { await actions.switchSetBeacon(state: !port.beacon, port: port.port) }
                            }
                            .controlSize(.mini)
                            .disabled(model.isApplyingSwitch)
                        }
                    }
                }

                HStack(spacing: 6) {
                    TextField("Port (0..19 or unit.port)", text: $model.switchTargetPortDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .font(.caption)
                    Button("Switch to Port") {
                        Task { await actions.switchSelectPort(model.switchTargetPortDraft) }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)

                    Button("Beacon On") {
                        Task { await actions.switchSetBeacon(state: true, port: model.switchTargetPortDraft) }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)

                    Button("Beacon Off") {
                        Task { await actions.switchSetBeacon(state: false, port: model.switchTargetPortDraft) }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)
                }

                Divider()
                    .padding(.vertical, 2)

                Text("Port Configuration & ATX")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    TextField("Port Name (e.g. PORT3)", text: $model.switchPortNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Toggle("Dummy Plug", isOn: $model.switchPortDummyDraft)
                        .font(.caption)
                    Button("Save Port") {
                        Task { await actions.switchApplyPortParams() }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)
                }

                HStack(spacing: 6) {
                    ForEach(GLKVMClient.AtxPowerAction.allCases, id: \.rawValue) { action in
                        Button(action.displayName) {
                            Task {
                                await actions.switchPerformAtxPower(
                                    port: model.switchTargetPortDraft,
                                    action: action
                                )
                            }
                        }
                        .controlSize(.mini)
                        .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)
                    }
                }

                HStack(spacing: 6) {
                    TextField("Beacon Hex (FFA500:BF:0028)", text: $model.switchBeaconColorDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Set Beacon Color") {
                        Task { await actions.switchApplyBeaconColors() }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isApplyingSwitch)
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, model.switchState == nil else { return }
            Task { await actions.refreshSwitch() }
        }
    }
}

// MARK: - System

struct SystemSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    private static let themeOptions: [(String, String)] = [
        ("0", "System"),
        ("1", "Dark mode"),
        ("2", "Light mode"),
    ]

    private static let languageOptions: [(String, String)] = [
        ("auto", "Auto"),
        ("en", "English"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
    ]

    private static let timezoneOptions: [(String, String)] = [
        ("UTC", "UTC"),
        ("America/New_York", "America/New_York (EST/EDT)"),
        ("America/Chicago", "America/Chicago (CST/CDT)"),
        ("America/Denver", "America/Denver (MST/MDT)"),
        ("America/Los_Angeles", "America/Los_Angeles (PST/PDT)"),
        ("Europe/London", "Europe/London (GMT/BST)"),
        ("Europe/Paris", "Europe/Paris (CET/CEST)"),
        ("Asia/Tokyo", "Asia/Tokyo (JST)"),
        ("Asia/Shanghai", "Asia/Shanghai (CST)"),
        ("Australia/Sydney", "Australia/Sydney (AEST/AEDT)"),
    ]

    private static let section = WebUISettingsPanel.PanelSection.system

    var body: some View {
        DisclosureGroup(Self.section.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(Self.section.rows[0], selection: actions.bindingString(
                    get: { $0.themeMode },
                    set: { $0.themeMode = $1 },
                    defaultValue: "0"
                )) {
                    ForEach(Self.themeOptions, id: \.0) { value, label in
                        Text(label).tag(value)
                    }
                }

                if model.config?.language != nil {
                    Picker(Self.section.rows[1], selection: actions.bindingString(
                        get: { $0.language ?? "auto" },
                        set: { $0.language = $1 },
                        defaultValue: "auto"
                    )) {
                        ForEach(Self.languageOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                } else {
                    NotImplementedRow(title: Self.section.rows[1])
                }

                if model.config?.timezone != nil {
                    Picker(Self.section.rows[2], selection: actions.bindingString(
                        get: { $0.timezone ?? "UTC" },
                        set: { $0.timezone = $1 },
                        defaultValue: "UTC"
                    )) {
                        ForEach(Self.timezoneOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                } else {
                    NotImplementedRow(title: Self.section.rows[2])
                }

                if let info = model.systemInfo {
                    Divider()
                        .padding(.vertical, 2)

                    HStack {
                        Text("Hardware & Software Info")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Refresh") {
                            Task { await actions.refreshSystemInfo() }
                        }
                        .controlSize(.mini)
                    }

                    if let base = info.hw?.platform?.base {
                        InfoKeyValueRow(label: "Platform", value: base)
                    }
                    if let serial = info.hw?.platform?.serial, !serial.isEmpty {
                        InfoKeyValueRow(label: "Serial", value: serial)
                    }
                    if let kvmdVer = info.system?.kvmd?.version {
                        let streamerVer = info.system?.streamer?.version.map { " · ustreamer \($0)" } ?? ""
                        InfoKeyValueRow(label: "KVMD", value: "\(kvmdVer)\(streamerVer)")
                    }
                    if let kernel = info.system?.kernel {
                        let kText = [kernel.system, kernel.release, kernel.machine].compactMap { $0 }.joined(separator: " ")
                        if !kText.isEmpty {
                            InfoKeyValueRow(label: "Kernel", value: kText)
                        }
                    }
                    if let cpuPercent = info.hw?.health?.cpu?.percent {
                        InfoKeyValueRow(label: "CPU Load", value: String(format: "%.1f%%", cpuPercent))
                    }
                    if let mem = info.hw?.health?.mem, let pct = mem.percent {
                        InfoKeyValueRow(label: "Memory Usage", value: String(format: "%.1f%%", pct))
                    }
                    if let cpuTemp = info.hw?.health?.temp?.cpu {
                        let gpuTempStr = info.hw?.health?.temp?.gpu.map { String(format: " · GPU %.1f°C", $0) } ?? ""
                        InfoKeyValueRow(label: "Temperature", value: String(format: "CPU %.1f°C%@", cpuTemp, gpuTempStr))
                    }
                    if let flags = info.hw?.health?.throttling?.parsedFlags {
                        let undervolt = flags.undervoltage?.now == true || flags.undervoltage?.past == true
                        let throttled = flags.throttled?.now == true || flags.throttled?.past == true
                        let capped = flags.freqCapped?.now == true || flags.freqCapped?.past == true
                        if undervolt || throttled || capped {
                            let warnings = [
                                undervolt ? "Undervoltage" : nil,
                                throttled ? "Throttled" : nil,
                                capped ? "Freq Capped" : nil,
                            ].compactMap { $0 }.joined(separator: ", ")
                            InfoKeyValueRow(label: "Power Flags", value: warnings, valueColor: .orange)
                        } else {
                            InfoKeyValueRow(label: "Power Flags", value: "Healthy", valueColor: .green)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                Text("KVMD Diagnostics")
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 8) {
                    Button("View KVMD Service Logs…") {
                        Task { await actions.fetchDeviceServiceLog() }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isFetchingLogs)

                    Button("Prometheus Metrics…") {
                        Task { await actions.fetchPrometheusMetrics() }
                    }
                    .controlSize(.small)
                    .disabled(connection.glkvmClient == nil || model.isFetchingLogs)
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, model.systemInfo == nil else { return }
            Task { await actions.refreshSystemInfo() }
        }
    }
}

private struct InfoKeyValueRow: View {
    let label: String
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Network

struct NetworkSettingsSection: View {
    @ObservedObject var model: WebUISettingsPanelModel
    @EnvironmentObject var connection: SessionConnection

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    @State private var isModifyExpanded = false
    @State private var isWifiExpanded = false
    @State private var isEthernetExpanded = false

    private static let section = WebUISettingsPanel.PanelSection.network

    var body: some View {
        DisclosureGroup(Self.section.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup(Self.section.rows[0], isExpanded: $isModifyExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("IP Mode", selection: $model.networkMode) {
                            Text("DHCP").tag("dhcp")
                            Text("Static IP").tag("static")
                        }

                        if model.networkMode == "static" {
                            HStack {
                                Text("IP Address")
                                    .frame(width: 90, alignment: .leading)
                                TextField("192.168.8.1", text: $model.networkIP)
                            }

                            HStack {
                                Text("Subnet Mask")
                                    .frame(width: 90, alignment: .leading)
                                TextField("255.255.255.0", text: $model.networkNetmask)
                            }

                            HStack {
                                Text("Gateway")
                                    .frame(width: 90, alignment: .leading)
                                TextField("192.168.8.1", text: $model.networkGateway)
                            }

                            HStack {
                                Text("DNS")
                                    .frame(width: 90, alignment: .leading)
                                TextField("8.8.8.8", text: $model.networkDNS)
                            }
                        } else {
                            HStack {
                                Text("Current IP")
                                Spacer()
                                Text(model.networkIP)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }

                        HStack {
                            Spacer()
                            Button("Apply IP Settings") {
                                Task { await actions.applyNetworkConfig() }
                            }
                            .disabled(model.isApplyingNetwork || connection.glkvmClient == nil)
                        }
                    }
                    .padding(.top, 4)
                }

                DisclosureGroup(Self.section.rows[1], isExpanded: $isWifiExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable Wi-Fi", isOn: $model.wifiEnabled)

                        if model.wifiEnabled {
                            HStack {
                                Text("SSID")
                                    .frame(width: 80, alignment: .leading)
                                TextField("Network Name", text: $model.wifiSSID)
                            }

                            HStack {
                                Text("Password")
                                    .frame(width: 80, alignment: .leading)
                                SecureField("Password", text: $model.wifiPassword)
                            }

                            HStack {
                                Text("Status")
                                Spacer()
                                Text(model.wifiStatus)
                                    .foregroundColor(model.wifiStatus == "Connected" ? .green : .secondary)
                                    .font(.caption)
                            }

                            HStack {
                                Spacer()
                                Button("Apply Wi-Fi") {
                                    Task { await actions.applyWifiConfig() }
                                }
                                .disabled(model.isApplyingWifi || connection.glkvmClient == nil)
                            }
                        }
                    }
                    .padding(.top, 4)
                }

                DisclosureGroup(Self.section.rows[2], isExpanded: $isEthernetExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Status")
                            Spacer()
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(model.ethernetConnected ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(model.ethernetConnected ? "Connected" : "Disconnected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("Speed")
                            Spacer()
                            Text(model.ethernetSpeed)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("IP Address")
                            Spacer()
                            Text(model.ethernetIP)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        HStack {
                            Text("MAC Address")
                            Spacer()
                            Text(model.ethernetMAC)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.top, 6)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, model.networkConfig == nil else { return }
            Task { await actions.loadNetworkSettings() }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsSection: View {
    @EnvironmentObject var connection: SessionConnection
    @ObservedObject var model: WebUISettingsPanelModel

    @Binding var isExpanded: Bool
    let actions: WebUISettingsActions

    var body: some View {
        DisclosureGroup(WebUISettingsPanel.PanelSection.advanced.title, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let atxState = model.atxState, atxState.enabled {
                    Text("ATX Power & Case Controls")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(atxState.leds.power ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(atxState.leds.power ? "Power LED On" : "Power LED Off")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack(spacing: 6) {
                            Circle()
                                .fill(atxState.leds.hdd ? Color.orange : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(atxState.leds.hdd ? "HDD LED Active" : "HDD LED Idle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    Toggle("Wait for ATX operation to complete", isOn: $model.atxWaitForCompletion)
                        .font(.caption)

                    Text("Power State Actions (/api/atx/power)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(GLKVMClient.AtxPowerAction.allCases, id: \.rawValue) { action in
                            Button(action.displayName) {
                                Task { await actions.performAtxAction(action) }
                            }
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(atxState.busy || model.isApplyingAtx)

                    Text("Front Panel Case Buttons (/api/atx/click)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        ForEach(GLKVMClient.AtxButton.allCases, id: \.rawValue) { button in
                            Button(button.displayName) {
                                Task { await actions.performAtxButtonClick(button) }
                            }
                            .controlSize(.small)
                        }
                    }
                    .disabled(atxState.busy || model.isApplyingAtx)

                    Divider()
                        .padding(.vertical, 2)
                }

                if let rf = model.redfishSystem {
                    Text("Redfish BMC (/redfish/v1)")
                        .font(.subheadline.weight(.semibold))

                    HStack {
                        Text("Host: \(rf.hostName ?? "System 0")")
                            .font(.caption)
                        Spacer()
                        Text("PowerState: \(rf.powerState ?? "Unknown")")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        Picker("ResetType", selection: $model.redfishSelectedResetType) {
                            ForEach(GLKVMClient.RedfishResetType.allCases, id: \.rawValue) { rt in
                                Text(rt.rawValue).tag(rt)
                            }
                        }
                        .labelsHidden()
                        Button("Send Redfish Reset") {
                            Task { await actions.performRedfishReset(model.redfishSelectedResetType) }
                        }
                        .controlSize(.small)
                        .disabled(model.isApplyingRedfish)
                    }

                    Divider()
                        .padding(.vertical, 2)
                }

                Button("Reset KVM") {
                    Task { await actions.resetKVM() }
                }
                .disabled(connection.glkvmClient == nil)
            }
            .padding(.top, 6)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded, model.atxState == nil else { return }
            Task { await actions.refreshPowerAndAdvanced() }
        }
    }
}

// MARK: - Shared rows

struct NotImplementedRow: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("Not implemented yet")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .opacity(0.7)
        .allowsHitTesting(false)
    }
}
