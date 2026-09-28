/// Stable identifiers supplied by the caller; the model never interprets their contents.
public struct DisplayID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}

public struct WindowID: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ value: String) { rawValue = value }
    public init(stringLiteral value: String) { self.init(value) }
}
