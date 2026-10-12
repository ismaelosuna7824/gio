import Foundation

/// How motion is drawn. PF-O: `live` (default) moves the real windows: every
/// window that keeps its size through the private WindowServer transport
/// (one SkyLight transaction per display tick), a window that changes size
/// through its app's Accessibility lane. SM-01: `snapshot` animates
/// ScreenCaptureKit window images in an overlay (needs the Screen Recording
/// permission); `ax` moves the real windows through Accessibility every
/// frame (PF-M: hidden and revealed ones through SkyLight).
public enum RendererKind: String, Equatable, Sendable {
    case live
    case snapshot
    case ax
}

/// The renderer actually used: live only while the SkyLight transport is
/// usable (`WindowServerTransportStatus.available`: config on, symbols
/// present, probe not failed), snapshot only when Screen Recording is
/// granted, otherwise the AX motion.
public func effectiveRenderer(config: AnimationsSectionConfig, permission: Bool, windowServer: Bool) -> RendererKind {
    switch config.renderer {
    case .live: windowServer ? .live : .ax
    case .snapshot: permission ? .snapshot : .ax
    case .ax: .ax
    }
}

/// Short, log-safe reason for the choice made by `effectiveRenderer`.
public func rendererReason(config: AnimationsSectionConfig, permission: Bool, windowServer: Bool) -> String {
    switch config.renderer {
    case .live: windowServer ? "configured" : "skylight-unavailable"
    case .snapshot: permission ? "configured" : "screen-recording-missing"
    case .ax: "config-ax"
    }
}

/// Produces the `renderer effective=... reason=...` log line only when the
/// effective renderer or its reason changed since the last call.
public struct RendererLogGate: Sendable {
    private var last: String?

    public init() {}

    public mutating func line(config: AnimationsSectionConfig, permission: Bool, windowServer: Bool) -> String? {
        let kind = effectiveRenderer(config: config, permission: permission, windowServer: windowServer)
        let reason = rendererReason(config: config, permission: permission, windowServer: windowServer)
        let line = "renderer effective=\(kind.rawValue) reason=\(reason)"
        guard line != last else {
            return nil
        }
        last = line
        return line
    }
}
