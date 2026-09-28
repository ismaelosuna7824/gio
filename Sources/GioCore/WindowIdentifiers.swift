/// Stable identifiers supplied by the caller; the model never interprets their contents.
public struct DisplayID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}

/// Legacy prototype identity (string session handle). Untouched reference for the
/// pre-rewrite coordinator stack; the plan's `WindowID` (pid + elementID) lives
/// in `Window/` and is the canonical identity going forward.
public struct LegacyWindowID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}
