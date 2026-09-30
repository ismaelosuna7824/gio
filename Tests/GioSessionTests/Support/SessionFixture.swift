import CoreGraphics
import Foundation
import GioCore
@testable import GioSession

/// Mutable stand-in for the host's session state, read by component
/// contexts through closures (like `SessionHost` does).
final class SessionFixture: @unchecked Sendable {
    static let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    static let display = DisplayID(1)

    var session = CommandSession()
    var displays = DisplayManager()
    var visibleFrames: [DisplayID: CGRect] = [:]
    var physicalFrames: [WindowID: CGRect] = [:]
    var flightActive = false
    var motionActive = false
    var zoomBusy: Set<WindowID> = []
    var zoomActive = false
    var fullscreen: Set<WindowID> = []
    var shuttingDown = false

    /// One display showing workspace 1 with one single-window column per
    /// frame (pid = element), focus on `focus`.
    init(frames: [CGRect] = [], focus: Int? = nil, pid: (Int) -> pid_t = { pid_t($0 + 1) }) {
        session.manager.syncDisplays([Self.display])
        displays.connect(
            Self.display, frame: Self.screen,
            workspace: session.manager.activeID(on: Self.display) ?? session.manager.currentID
        )
        var workspace = session.manager.currentWorkspace()
        for (index, frame) in frames.enumerated() {
            let id = Self.id(index, pid: pid(index))
            try? session.registry.register(ManagedWindow(
                id: id, pid: id.pid, application: "App\(index)", title: "secret title \(index)",
                frame: frame, mode: .tiled
            ))
            var column = Column(id: ColumnID(UInt64(index + 1)), width: 0, windows: [id])
            column.focusedWindowIndex = 0
            workspace.columns.append(column)
            physicalFrames[id] = frame
        }
        if let focus {
            workspace.focusedColumn = focus
            workspace.focusedWindow = Self.id(focus, pid: pid(focus))
        }
        session.manager.update(workspace)
    }

    static func id(_ index: Int, pid: pid_t) -> WindowID {
        WindowID(pid: pid, elementID: UInt64(index + 1))
    }

    var focusedID: WindowID? {
        session.manager.currentWorkspace().focusedWindow
    }
}

/// Main-hop double: collects the blocks; `drain()` runs them in order.
final class HopRecorder: @unchecked Sendable {
    private(set) var blocks: [@Sendable () -> Void] = []

    var hop: MainHop {
        { [self] block in blocks.append(block) }
    }

    func drain() {
        let pending = blocks
        blocks = []
        pending.forEach { $0() }
    }
}
