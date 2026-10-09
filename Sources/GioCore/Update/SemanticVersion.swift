import Foundation

/// UP-01: a Semantic Versioning 2.0 version as release tags carry it
/// (`v0.2.0`, `v0.2.0-beta.1`). The `v` is optional, build metadata (`+...`)
/// is accepted and ignored (it has no precedence), and the parser is strict
/// otherwise so a stray tag is never mistaken for a release.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers (`["beta", "1"]`); empty for a release.
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ text: String) {
        var body = Substring(text)
        if body.first == "v" || body.first == "V" {
            body = body.dropFirst()
        }
        if let plus = body.firstIndex(of: "+") {
            let metadata = body[body.index(after: plus)...]
            guard Self.validIdentifiers(metadata, numericRule: false) else {
                return nil
            }
            body = body[..<plus]
        }
        var prerelease: [String] = []
        if let dash = body.firstIndex(of: "-") {
            let identifiers = body[body.index(after: dash)...]
            guard Self.validIdentifiers(identifiers, numericRule: true) else {
                return nil
            }
            prerelease = identifiers.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            body = body[..<dash]
        }
        let core = body.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else {
            return nil
        }
        var numbers: [Int] = []
        for part in core {
            guard Self.isNumeric(part), let value = Int(part) else {
                return nil
            }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    public var isPrerelease: Bool {
        !prerelease.isEmpty
    }

    /// `0.2.0-beta.1`.
    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    /// `v0.2.0-beta.1`, the release tag naming convention.
    public var tag: String {
        "v" + description
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A release outranks every prerelease of the same version.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        default: break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// Digits only, without a leading zero (except `0` itself).
    private static func isNumeric(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isASCIIDigit) && (part.count == 1 || part.first != "0")
    }

    /// Non-empty `[0-9A-Za-z-]` identifiers; prerelease numerics carry no leading zero.
    private static func validIdentifiers(_ text: Substring, numericRule: Bool) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }) else {
                return false
            }
            return !numericRule || !part.allSatisfy(\.isASCIIDigit) || isNumeric(part)
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }

    var isASCIILetter: Bool {
        isASCII && isLetter
    }
}
