import Foundation
import GioCore
import Security

/// UP-08: is this app signed by the same developer as the running Gio?
public protocol CodeSignatureVerifying: Sendable {
    /// The app inside the image and its staged copy: requirement plus Hardened Runtime.
    func verify(appAt url: URL) -> Result<Void, UpdateFailure>
    /// UP-16: the release disk image's own signature, checked before it is mounted.
    func verify(imageAt url: URL) -> Result<Void, UpdateFailure>
}

/// `SecStaticCodeCheckValidity` against a requirement string: the whole app
/// bundle (nested code, every architecture, strict) plus the Hardened
/// Runtime flag (UP-13), or the disk image (strict).
///
/// No `kSecCSEnforceRevocationChecks` (UP-13 decision): it passed online
/// for a real release build and DMG, but it forces a definite revocation
/// answer, and whether a valid update still passes when ocsp.apple.com is
/// unreachable (while GitHub is not) could not be tested; an update must
/// never be refused for that. Key misuse is contained upstream (protected
/// `release` environment, docs/RELEASING.md).
public struct RequirementSignatureVerifier: CodeSignatureVerifying {
    public let requirement: String
    public let imageRequirement: String

    public init(requirement: String, imageRequirement: String) {
        self.requirement = requirement
        self.imageRequirement = imageRequirement
    }

    public func verify(appAt url: URL) -> Result<Void, UpdateFailure> {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        switch check(url, against: requirement, flags: flags, subject: "") {
        case .failure(let failure):
            return .failure(failure)
        case .success(let code):
            var info: CFDictionary?
            SecCodeCopySigningInformation(code, [], &info)
            let signatureFlags = ((info as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            guard codeSignatureHasHardenedRuntime(signatureFlags) else {
                return .failure(.signatureRejected("no hardened runtime"))
            }
            return .success(())
        }
    }

    public func verify(imageAt url: URL) -> Result<Void, UpdateFailure> {
        check(url, against: imageRequirement, flags: SecCSFlags(rawValue: kSecCSStrictValidate), subject: "disk image ")
            .map { _ in () }
    }

    private func check(
        _ url: URL, against requirement: String, flags: SecCSFlags, subject: String
    ) -> Result<SecStaticCode, UpdateFailure> {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return .failure(.signatureRejected("\(subject)unreadable code"))
        }
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled else {
            return .failure(.signatureRejected("invalid requirement"))
        }
        let status = SecStaticCodeCheckValidity(code, flags, compiled)
        switch status {
        case errSecSuccess:
            return .success(code)
        case errSecCSUnsigned:
            return .failure(.signatureRejected("\(subject)unsigned"))
        case errSecCSReqFailed:
            return .failure(.signatureRejected("\(subject)different developer or bundle"))
        default:
            return .failure(.signatureRejected("\(subject)invalid signature (\(status))"))
        }
    }
}

/// The running app's signing facts, read from its own signature (the team
/// is never hard-coded).
public struct RunningSignature: Equatable, Sendable {
    public var teamIdentifier: String?
    public var designatedRequirement: String?
    public var bundleIdentifier: String?
    /// Common name of the signing certificate (UP-16: the DMG must carry the same).
    public var leafCommonName: String?
}

public func runningAppSignature(bundleURL: URL = Bundle.main.bundleURL) -> RunningSignature {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess, let code else {
        return RunningSignature()
    }
    var info: CFDictionary?
    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let dictionary = info as? [String: Any] ?? [:]
    var designated: SecRequirement?
    var requirementText: CFString?
    if SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess, let designated {
        SecRequirementCopyString(designated, [], &requirementText)
    }
    var commonName: CFString?
    if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
       let leaf = certificates.first {
        SecCertificateCopyCommonName(leaf, &commonName)
    }
    return RunningSignature(
        teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
        designatedRequirement: requirementText as String?,
        bundleIdentifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
        leafCommonName: commonName as String?
    )
}
