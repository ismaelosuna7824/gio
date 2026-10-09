import Foundation

/// UP-02: a release Gio can install: a semver tag plus the paired DMG and
/// checksum assets (`Gio-<version>.dmg`, `Gio-<version>.dmg.sha256`).
public struct AvailableUpdate: Equatable, Sendable {
    public var version: SemanticVersion
    public var tag: String
    /// Markdown release notes (the release body).
    public var notes: String
    public var isPrerelease: Bool
    /// The release page on GitHub, for "download it yourself".
    public var pageURL: String?
    public var dmg: GitHubReleaseAsset
    public var checksum: GitHubReleaseAsset

    public init(
        version: SemanticVersion, tag: String, notes: String, isPrerelease: Bool, pageURL: String?,
        dmg: GitHubReleaseAsset, checksum: GitHubReleaseAsset
    ) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.isPrerelease = isPrerelease
        self.pageURL = pageURL
        self.dmg = dmg
        self.checksum = checksum
    }
}

public enum UpdateSelection: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
}

/// The release contract's asset names for one version.
public func updateAssetNames(for version: SemanticVersion) -> (dmg: String, checksum: String) {
    let dmg = "Gio-\(version).dmg"
    return (dmg, dmg + ".sha256")
}

/// The DMG and its checksum, or nil when either is missing (an incomplete
/// release is never offered).
public func pairUpdateAssets(
    in release: GitHubRelease, version: SemanticVersion
) -> (dmg: GitHubReleaseAsset, checksum: GitHubReleaseAsset)? {
    let names = updateAssetNames(for: version)
    guard let dmg = release.assets.first(where: { $0.name == names.dmg }),
          let checksum = release.assets.first(where: { $0.name == names.checksum }) else {
        return nil
    }
    return (dmg, checksum)
}

/// Prereleases are offered when the user opted into betas, or when the
/// running version is itself a prerelease (a beta user stays on the beta
/// train until a newer release ships). Local development builds
/// (`0.0.0-dev`, `<tag>+dev`) are not a beta opt-in.
public func includesPrereleases(runningVersion: String, includeBetas: Bool) -> Bool {
    if includeBetas {
        return true
    }
    guard !isDevBuildVersion(runningVersion), let running = SemanticVersion(runningVersion) else {
        return false
    }
    return running.isPrerelease
}

/// The newest non-draft release (prereleases only when allowed) with a
/// semver tag and paired assets, if it is newer than `running`.
public func selectUpdate(
    from releases: [GitHubRelease], running: SemanticVersion, includePrereleases: Bool
) -> UpdateSelection {
    var best: AvailableUpdate?
    for release in releases where !release.draft && (includePrereleases || !release.prerelease) {
        guard let version = SemanticVersion(release.tagName),
              includePrereleases || !version.isPrerelease,
              let assets = pairUpdateAssets(in: release, version: version) else {
            continue
        }
        if let best, best.version >= version {
            continue
        }
        best = AvailableUpdate(
            version: version, tag: release.tagName, notes: release.body ?? "",
            isPrerelease: release.prerelease || version.isPrerelease, pageURL: release.htmlURL,
            dmg: assets.dmg, checksum: assets.checksum
        )
    }
    guard let best, best.version > running else {
        return .upToDate
    }
    return .available(best)
}

/// The lowercase hex digest from a `shasum -a 256` line (`<hex>  <name>`,
/// binary marker `*` allowed, the name optional). Nil when malformed or
/// when it names another file.
public func parseChecksumFile(_ text: String, expectedFileName: String) -> String? {
    guard let line = text.split(whereSeparator: \.isNewline).first else {
        return nil
    }
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard let digest = fields.first?.lowercased(), digest.count == 64,
          digest.allSatisfy({ $0.isHexDigit }), fields.count <= 2 else {
        return nil
    }
    if fields.count == 2 {
        var name = Substring(fields[1])
        if name.first == "*" {
            name = name.dropFirst()
        }
        guard name == expectedFileName else {
            return nil
        }
    }
    return digest
}
