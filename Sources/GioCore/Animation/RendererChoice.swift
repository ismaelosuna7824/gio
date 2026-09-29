import Foundation

/// SM-01: how motion is drawn. `snapshot` animates ScreenCaptureKit window
/// images in an overlay (needs the Screen Recording permission); `ax` moves
/// the real windows through Accessibility every frame.
public enum RendererKind: String, Equatable, Sendable {
    case snapshot
    case ax
}

/// The renderer actually used: snapshot only when it is configured and the
/// Screen Recording permission is granted, otherwise the AX motion.
public func effectiveRenderer(config: AnimationsSectionConfig, permission: Bool) -> RendererKind {
    config.renderer == .snapshot && permission ? .snapshot : .ax
}

/// Short, log-safe reason for the choice made by `effectiveRenderer`.
public func rendererReason(config: AnimationsSectionConfig, permission: Bool) -> String {
    if config.renderer == .ax {
        return "config-ax"
    }
    return permission ? "configured" : "screen-recording-missing"
}

/// Produces the `renderer effective=... reason=...` log line only when the
/// effective renderer or its reason changed since the last call.
public struct RendererLogGate: Sendable {
    private var last: String?

    public init() {}

    public mutating func line(config: AnimationsSectionConfig, permission: Bool) -> String? {
        let kind = effectiveRenderer(config: config, permission: permission)
        let line = "renderer effective=\(kind.rawValue) reason=\(rendererReason(config: config, permission: permission))"
        guard line != last else {
            return nil
        }
        last = line
        return line
    }
}
