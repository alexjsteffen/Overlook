import SwiftUI

// Both sheets hand the password (and optional 2FA / TOTP code or secret) to `onConnect` as values
// and clear the bound fields on submit, cancel, and dismissal, so secrets do not sit in view state
// between prompts. A sheet can submit once: Enter and the Connect button can otherwise both fire
// for a single keystroke.

struct ManualConnectSheet: View {
    @Binding var isPresented: Bool
    @Binding var hostPort: String
    @Binding var port: String
    @Binding var password: String
    @Binding var twoFactorCode: String
    @Binding var savePassword: Bool

    let onConnect: (String, String) -> Void

    @State private var hasSubmitted = false

    init(
        isPresented: Binding<Bool>,
        hostPort: Binding<String>,
        port: Binding<String>,
        password: Binding<String>,
        twoFactorCode: Binding<String> = .constant(""),
        savePassword: Binding<Bool>,
        onConnect: @escaping (String, String) -> Void
    ) {
        self._isPresented = isPresented
        self._hostPort = hostPort
        self._port = port
        self._password = password
        self._twoFactorCode = twoFactorCode
        self._savePassword = savePassword
        self.onConnect = onConnect
    }

    private var canConnect: Bool {
        !hostPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canConnect, !hasSubmitted else { return }
        hasSubmitted = true
        let submittedPassword = password
        let submittedTwoFactor = twoFactorCode
        password = ""
        twoFactorCode = ""
        onConnect(submittedPassword, submittedTwoFactor)
        isPresented = false
    }

    private func cancel() {
        password = ""
        twoFactorCode = ""
        isPresented = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Connect")
                .font(.headline)

            TextField("Host or IP (optionally host:port)", text: $hostPort)
                .textFieldStyle(.roundedBorder)

            TextField("Port", text: $port)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            TextField("2FA Code or TOTP Secret (optional)", text: $twoFactorCode)
                .textFieldStyle(.roundedBorder)
                .help("If 2FA is enabled on PiKVM/GLKVM, enter the 6-digit OTP code or Base32 TOTP secret.")

            Toggle("Save password for this device", isOn: $savePassword)

            HStack {
                Spacer()
                Button("Cancel") {
                    cancel()
                }
                Button("Connect") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding()
        .frame(width: 420)
        .onSubmit(submit)
        .onAppear {
            hasSubmitted = false
        }
        .onDisappear {
            password = ""
            twoFactorCode = ""
        }
    }
}

struct PasswordPromptSheet: View {
    @Binding var isPresented: Bool
    @Binding var password: String
    @Binding var twoFactorCode: String
    @Binding var savePassword: Bool

    let onCancel: () -> Void
    let onConnect: (String, String) -> Void

    @State private var hasSubmitted = false

    init(
        isPresented: Binding<Bool>,
        password: Binding<String>,
        twoFactorCode: Binding<String> = .constant(""),
        savePassword: Binding<Bool>,
        onCancel: @escaping () -> Void,
        onConnect: @escaping (String, String) -> Void
    ) {
        self._isPresented = isPresented
        self._password = password
        self._twoFactorCode = twoFactorCode
        self._savePassword = savePassword
        self.onCancel = onCancel
        self.onConnect = onConnect
    }

    private var canConnect: Bool {
        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canConnect, !hasSubmitted else { return }
        hasSubmitted = true
        let submittedPassword = password
        let submittedTwoFactor = twoFactorCode
        password = ""
        twoFactorCode = ""
        onConnect(submittedPassword, submittedTwoFactor)
        isPresented = false
    }

    private func cancel() {
        password = ""
        twoFactorCode = ""
        onCancel()
        isPresented = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Password Required")
                .font(.headline)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            TextField("2FA Code or TOTP Secret (optional)", text: $twoFactorCode)
                .textFieldStyle(.roundedBorder)
                .help("If 2FA is enabled on PiKVM/GLKVM, enter the 6-digit OTP code or Base32 TOTP secret.")

            Toggle("Save password for this device", isOn: $savePassword)

            HStack {
                Spacer()
                Button("Cancel") {
                    cancel()
                }
                Button("Connect") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
        .padding()
        .frame(width: 420)
        .onSubmit(submit)
        .onAppear {
            hasSubmitted = false
        }
        .onDisappear {
            password = ""
            twoFactorCode = ""
        }
    }
}
