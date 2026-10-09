import Foundation

/// Version reported when no app bundle declares one: SwiftPM builds of the
/// CLI and tools, and test runners. Dev builds of the app report it too when
/// the repository has no `v*` tag (RL-01, `odd/tasks/release.md`).
public let gioBuildVersion = "0.0.0-dev"

/// The version an Info.plist dictionary declares in `CFBundleShortVersionString`
/// (fed by the `MARKETING_VERSION` build setting, the tag without `v` in
/// releases), or `gioBuildVersion` when it is missing, blank, not a string or
/// an unexpanded `$(...)` build setting.
public func resolveGioVersion(infoDictionary: [String: Any]?) -> String {
    guard let raw = infoDictionary?["CFBundleShortVersionString"] as? String else {
        return gioBuildVersion
    }
    let version = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if version.isEmpty || version.contains("$(") {
        return gioBuildVersion
    }
    return version
}

/// True for builds that did not come from a release tag: the `0.0.0-dev` default
/// and local builds stamped `<last tag>+dev` by `scripts/stamp-dev-version.sh`.
public func isDevBuildVersion(_ version: String) -> Bool {
    version == gioBuildVersion || version.hasSuffix("+dev")
}

/// Single version source: the running bundle's version, else the build-time constant.
public var gioVersion: String {
    resolveGioVersion(infoDictionary: Bundle.main.infoDictionary)
}
