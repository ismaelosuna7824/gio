/// Legacy prototype identity. Untouched reference for the pre-rewrite stack;
/// the plan's `DisplayID` (CGDirectDisplayID companion) lives in `Display/`.
public struct LegacyDisplayID: Hashable, Sendable, ExpressibleByStringLiteral {
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
