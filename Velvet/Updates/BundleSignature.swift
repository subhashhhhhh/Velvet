// Proves a downloaded Velvet is ours before it replaces the running one. Releases are signed
// with the "Velvet Self-Signed" certificate, whose private key only the maintainer holds
// (docs/signing.md). A download is trusted when its signature is intact and it was signed
// with exactly the certificate the running app was signed with.

import Foundation
import Security

nonisolated enum BundleSignature {
    static func isTrusted(_ bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }

        // An unsealed bundle can claim anything.
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else { return false }

        guard let running = runningCertificate(), let candidate = certificate(of: staticCode) else {
            return false
        }
        return running == candidate
    }

    static let identity = "Velvet Self-Signed"

    /// Whether the running app is signed with Velvet's release certificate. An ad-hoc or
    /// development build can't vouch for a download, so it offers the release page instead.
    static var canVerifyUpdates: Bool {
        guard let data = runningCertificate(),
              let certificate = SecCertificateCreateWithData(nil, data as CFData) else { return false }
        return SecCertificateCopySubjectSummary(certificate) as String? == identity
    }

    private static func runningCertificate() -> Data? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return certificate(of: staticCode)
    }

    /// The leaf certificate's bytes.
    private static func certificate(of code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }
}
