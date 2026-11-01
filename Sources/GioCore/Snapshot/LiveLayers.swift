import CoreGraphics
import Foundation

public let liveLayerMaxStreams = 4
public let liveLayerFrameRate = 60

public func liveLayerCandidates(
    ids: Set<WindowID>, excluded: Set<WindowID>, starts: [WindowID: CGRect], targets: [WindowID: CGRect],
    displays: [CGRect], limit: Int = liveLayerMaxStreams
) -> [WindowID] {
    let streamable = ids.subtracting(excluded).compactMap { id -> (id: WindowID, landsOnScreen: Bool)? in
        guard let start = starts[id], let target = targets[id],
              snapshotFrameMoves(from: start, to: target), !snapshotResized(from: start.size, to: target.size),
              overlayDisplayIndex(from: start, to: target, displays: displays) != nil
        else {
            return nil
        }
        let landsOnScreen = overlayDisplayIndex(from: target, to: target, displays: displays) != nil
        return (id, landsOnScreen)
    }
    let ordered = streamable.sorted { first, second in
        first.landsOnScreen != second.landsOnScreen ? first.landsOnScreen : first.id < second.id
    }
    return ordered.prefix(limit).map(\.id)
}

public func liveLayerStartLine(count: Int) -> String {
    "live layer start count=\(count)"
}

public func liveLayerFirstFrameLine(_ id: WindowID, milliseconds: Int) -> String {
    "live layer first frame id=\(id.pid):\(id.elementID) ms=\(milliseconds)"
}

public func liveLayerStopLine(count: Int, frames: Int) -> String {
    "live layer stop count=\(count) frames=\(frames)"
}
