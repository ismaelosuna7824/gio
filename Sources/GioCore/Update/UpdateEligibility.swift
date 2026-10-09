import Foundation

/// UP-03: why the running copy of Gio cannot replace itself. Every case
/// still checks and notifies; installing is left to the user.
public enum UpdateIneligibility: String, CaseIterable, Equatable, Sendable {
    /// A bare executable (`swift run`), not a `.app` bundle.
    case notAppBundle
    /// Xcode DerivedData or a SwiftPM/xcodebuild output folder.
    case buildFolder
    /// macOS App Translocation: opened from Downloads or a DMG without moving.
    case translocated
    /// The folder holding Gio.app is not writable (a mounted DMG, a locked folder).
    case readOnlyLocation
    /// A local build stamped `0.0.0-dev` or `<tag>+dev`.
    case developmentBuild
    /// Ad-hoc or unsigned: no team identity to check the new app against.
    case unsignedBuild

    public var message: String {
        switch self {
        case .notAppBundle: return "Gio is not running from an app bundle."
        case .buildFolder: return "This copy of Gio runs from a build folder."
        case .translocated: return "macOS is running Gio from a temporary location."
        case .readOnlyLocation: return "Gio's folder is read-only."
        case .developmentBuild: return "This is a development build."
        case .unsignedBuild: return "This copy of Gio has no team signature to check updates against."
        }
    }

    public var suggestion: String {
        switch self {
        case .notAppBundle, .buildFolder, .developmentBuild, .unsignedBuild:
            return "Download the release DMG and drag Gio to /Applications."
        case .translocated, .readOnlyLocation:
            return "Move Gio to /Applications and open it from there to enable updates."
        }
    }
}

public enum InstallEligibility: Equatable, Sendable {
    /// The bundle at `target` can be replaced in place.
    case installable(target: String)
    case notifyOnly(UpdateIneligibility)
}

/// Facts about the running copy, gathered by the adapter.
public struct InstallLocationFacts: Equatable, Sendable {
    public var bundlePath: String
    public var parentWritable: Bool
    public var runningVersion: String
    /// The team identifier of the running app's signature; nil when ad-hoc.
    public var teamIdentifier: String?

    public init(bundlePath: String, parentWritable: Bool, runningVersion: String, teamIdentifier: String?) {
        self.bundlePath = bundlePath
        self.parentWritable = parentWritable
        self.runningVersion = runningVersion
        self.teamIdentifier = teamIdentifier
    }
}

public func installEligibility(_ facts: InstallLocationFacts) -> InstallEligibility {
    var path = facts.bundlePath
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    guard path.hasSuffix(".app") else {
        return .notifyOnly(.notAppBundle)
    }
    if path.contains("/AppTranslocation/") {
        return .notifyOnly(.translocated)
    }
    if path.contains("/DerivedData/") || path.contains("/.build/") || path.contains("/Build/Products/") {
        return .notifyOnly(.buildFolder)
    }
    if isDevBuildVersion(facts.runningVersion) {
        return .notifyOnly(.developmentBuild)
    }
    guard let team = facts.teamIdentifier, !team.isEmpty else {
        return .notifyOnly(.unsignedBuild)
    }
    guard facts.parentWritable else {
        return .notifyOnly(.readOnlyLocation)
    }
    return .installable(target: path)
}

/// The code requirement a downloaded Gio.app must satisfy: the running app's
/// designated requirement (so Accessibility and Screen Recording grants,
/// which macOS ties to it, carry over) and, explicitly, the same bundle
/// identifier and an Apple-issued certificate of the same team. Nil when
/// the running app has no team (ad-hoc) or a value would need quoting.
public func updateCodeRequirement(designated: String?, teamIdentifier: String?, bundleIdentifier: String) -> String? {
    guard let team = teamIdentifier, !team.isEmpty, !team.contains("\""), !bundleIdentifier.isEmpty,
          !bundleIdentifier.contains("\"") else {
        return nil
    }
    let base = "identifier \"\(bundleIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    guard let designated, !designated.isEmpty else {
        return base
    }
    return "(\(designated)) and \(base)"
}

/// UP-16: the requirement the release DMG's own signature must satisfy
/// before Gio mounts it: an Apple-issued certificate of the same team with
/// the same common name as the running app's signing certificate. No
/// identifier clause (codesign names a disk image after its file). Nil when
/// a value is missing or would need quoting.
public func updateImageRequirement(teamIdentifier: String?, leafCommonName: String?) -> String? {
    guard let team = teamIdentifier, !team.isEmpty, !team.contains("\""),
          let name = leafCommonName, !name.isEmpty, !name.contains("\"") else {
        return nil
    }
    return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        + " and certificate leaf[subject.CN] = \"\(name)\""
}

/// `kSecCodeSignatureRuntime` (0x10000, `codesign -dv` shows `flags=0x10000(runtime)`).
public let codeSignatureRuntimeFlag: UInt32 = 0x10000

/// UP-13: a new version must be signed with the Hardened Runtime, so no
/// same-user process can inject code into it (DYLD_INSERT_LIBRARIES,
/// unsigned libraries) and borrow Gio's Accessibility and Screen Recording
/// grants. The code requirement language cannot express signature flags, so
/// the verifier checks them next to the requirement.
public func codeSignatureHasHardenedRuntime(_ flags: UInt32) -> Bool {
    flags & codeSignatureRuntimeFlag != 0
}

/// The new bundle's Info.plist must name Gio's bundle identifier and the
/// version the release announced (a stale or mislabeled asset is refused).
public func checkUpdateBundle(
    bundleIdentifier: String?, shortVersion: String?, expectedBundleIdentifier: String,
    expectedVersion: SemanticVersion
) -> UpdateFailure? {
    guard let bundleIdentifier else {
        return .bundleMismatch("bundle identifier missing")
    }
    guard bundleIdentifier == expectedBundleIdentifier else {
        return .bundleMismatch("bundle identifier \(bundleIdentifier)")
    }
    guard let shortVersion, SemanticVersion(shortVersion) == expectedVersion else {
        return .bundleMismatch("version \(shortVersion ?? "missing"), expected \(expectedVersion)")
    }
    return nil
}
