// swiftlint:disable line_length
import SwiftUI
import AppKit

/// Chrome for the settings panel: header, the ordered list of section subviews, and the error strip.
struct WebUISettingsPanel: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var captureManager: CaptureManager

    @Binding var isPresented: Bool

    /// Survivable panel state, owned by `ContentView`.
    @ObservedObject var model: WebUISettingsPanelModel

    private typealias ErrorEntry = WebUISettingsPanelModel.ErrorEntry

    private static let panelBackground = Color(NSColor.windowBackgroundColor)

    private var settingsLoadID: String {
        kvmDeviceManager.connectedDevice?.id ?? "none"
    }

    private var actions: WebUISettingsActions {
        WebUISettingsActions(
            model: model,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            kvmDeviceManager: kvmDeviceManager,
            ocrManager: ocrManager,
            captureManager: captureManager
        )
    }

    var body: some View {
        let actions = self.actions
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Settings")
                    .font(.headline)
                Spacer()
                if model.isLoading || model.isApplying || model.isApplyingEdid || model.isApplyingMsd || model.isApplyingGpio || model.isApplyingSwitch {
                    ProgressView()
                        .controlSize(.small)
                }
                if model.isApplyingStreamer {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(action: { Task { await actions.load() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoading || kvmDeviceManager.glkvmClient == nil)
                .help("Refresh device settings")

                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isPresented = false } }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VideoSettingsSection(
                        model: model,
                        isExpanded: $model.isVideoExpanded,
                        actions: actions
                    )

                    RemoteSettingsSection(
                        model: model,
                        isExpanded: $model.isRemoteExpanded,
                        actions: actions
                    )

                    KeyboardSettingsSection(
                        model: model,
                        isExpanded: $model.isKeyboardExpanded,
                        actions: actions
                    )

                    VirtualMediaSettingsSection(
                        model: model,
                        isExpanded: $model.isVirtualMediaExpanded,
                        actions: actions
                    )

                    GpioSettingsSection(
                        model: model,
                        isExpanded: $model.isGpioExpanded,
                        actions: actions
                    )

                    SwitchSettingsSection(
                        model: model,
                        isExpanded: $model.isSwitchExpanded,
                        actions: actions
                    )

                    AudioSettingsSection(
                        model: model,
                        isExpanded: $model.isAudioExpanded,
                        actions: actions
                    )

                    // Local to this Mac (folders, codec); lives in CaptureViews.swift.
                    CaptureSettingsSection(isExpanded: $model.isCaptureExpanded)

                    SystemSettingsSection(
                        model: model,
                        isExpanded: $model.isSystemExpanded,
                        actions: actions
                    )

                    NetworkSettingsSection(
                        model: model,
                        isExpanded: $model.isNetworkExpanded,
                        actions: actions
                    )

                    AdvancedSettingsSection(
                        model: model,
                        isExpanded: $model.isAdvancedExpanded,
                        actions: actions
                    )
                }
                .padding()
            }

            Divider()

            if let visibleError = model.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(visibleError)
                        .foregroundColor(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("History…") {
                            model.showingErrorHistory = true
                        }
                        .buttonStyle(.borderless)

                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(visibleError, forType: .string)
                        }
                        .buttonStyle(.borderless)

                        Button("Dismiss") {
                            model.errorMessage = nil
                        }
                        .buttonStyle(.borderless)

                        Spacer()
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
        }
        .background(Self.panelBackground)
        .sheet(isPresented: $model.showingErrorHistory) {
            ErrorHistorySheet(entries: model.errorHistory)
        }
        .sheet(isPresented: $model.showingDeviceLogSheet) {
            DeviceTextReportSheet(
                title: "KVMD Service Logs (/api/log)",
                text: model.deviceServiceLogText
            )
        }
        .sheet(isPresented: $model.showingPrometheusSheet) {
            DeviceTextReportSheet(
                title: "Prometheus Metrics (/api/export/prometheus/metrics)",
                text: model.prometheusMetricsText
            )
        }
        .task(id: settingsLoadID) {
            await actions.load()
        }
    }

    private struct DeviceTextReportSheet: View {
        let title: String
        let text: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Button("Copy All") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    Button("Close") {
                        dismiss()
                    }
                }

                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding()
            .frame(minWidth: 640, minHeight: 420)
        }
    }

    private struct ErrorHistorySheet: View {
        let entries: [ErrorEntry]
        @Environment(\.dismiss) private var dismiss

        private static let dateFormatter: DateFormatter = {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .medium
            return df
        }()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Errors")
                        .font(.headline)
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Self.dateFormatter.string(from: entry.date))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(entry.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }

                HStack {
                    Button("Copy Latest") {
                        if let latest = entries.first?.message {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(latest, forType: .string)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .frame(minWidth: 520, minHeight: 360)
        }
    }
}
