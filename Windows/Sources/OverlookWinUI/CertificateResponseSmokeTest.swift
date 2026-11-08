import Foundation
import OverlookCore

/// Exercises the actual Windows alert adapter and Desktop.askTrust callback.
/// No network requests or changes to the user's certificate store are made.
func runCertificateResponseSmokeTest() throws {
    let registry = WinUIAdapterRegistry.shared
    let originalPrompt = registry.certificatePrompt
    defer { registry.certificatePrompt = originalPrompt }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("overlook-certificate-response-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let desktop = Desktop()
    let sha256 = String(repeating: "ab", count: 32)
    func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "CertificateResponseSmokeTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
    let cases: [(Int32, Desktop.TrustDecision)] = [(2, .always), (1, .once), (0, .cancel), (-1, .cancel)]
    for (index, test) in cases.enumerated() {
        let (nativeResult, expected) = test
        let key = "certificate-smoke-\(index).invalid:443"
        let url = folder.appendingPathComponent("pins-\(index).json")
        let store = CertificateStore(url: url)
        var receivedFingerprint = ""
        registry.certificatePrompt = { _, _, fingerprint in
            receivedFingerprint = fingerprint
            return nativeResult
        }
        var decisions: [Desktop.TrustDecision] = []
        desktop.askTrust(host: key, sha256: sha256, reason: "Local response mapping test.") {
            decisions.append($0)
        }
        try require(decisions.count == 1, "Native result \(nativeResult) must complete exactly once")
        try require(decisions.first == expected, "Wrong decision for native result \(nativeResult)")
        try require(receivedFingerprint == CertificateFingerprint.display(sha256), "Prompt lost its nested SHA-256 fingerprint")
        // This is the persistence branch used by the session's .always decision.
        if decisions.first == .always { try store.trust(key, sha256: sha256) }
        let reloaded = CertificateStore(url: url)
        try require(reloaded.pinned(key) == (expected == .always ? sha256 : nil),
                    "Only Always Trust should persist a pin across store instances")
    }
    print("Certificate responses passed: Yes/Always, No/Once, Cancel, unexpected result, fingerprint, pin persistence.")
}
