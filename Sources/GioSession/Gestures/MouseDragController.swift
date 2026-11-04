import CoreGraphics
import Foundation
import GioCore

/// MD-01: modifier drags on the session queue (signals from
/// `MouseDragGate`). While the button is down the strip of the display under
/// the pointer is laid out from a workspace the drag computes (a resized
/// column and window, or the window moved to the slot under the pointer;
/// the moved window itself follows the pointer) and written through the
/// reconciler's motion sink, like a trackpad scroll (TG-03): State does not
/// move and passes wait (`isTracking`). The release commits that workspace
/// and runs one pass; a drag that never moved, dropped nowhere, or whose
/// workspace changed meanwhile is abandoned and State lays the strip out
/// again.
public final class MouseDragController: @unchecked Sendable {
    public struct Context {
        /// The strip of the display at a point (Cocoa).
        public var surface: (CGPoint) -> GestureSurface?
        public var physicalFrames: () -> [WindowID: CGRect]
        /// The reconciler (invariant 3); nil before the first pass.
        public var sink: () -> MotionFrameSink?
        public var updateManager: ((inout WorkspaceManager) -> Void) -> Void
        /// The drag took the strip: stop the running motion.
        public var beginTracking: () -> Void
        /// A frame a window is being moved to (physical frame, echo record).
        public var recordSampled: (WindowID, CGRect, TimeInterval) -> Void
        /// A window joined the drag: its frame is unverified from now on.
        public var markUnverified: (WindowID) -> Void
        public var focusedWindow: () -> WindowID?
        public var publishFocusRing: () -> Void
        /// Released: State holds the result, the dragged window focused
        /// (the press was taken from its app); run the settle pass. The flag
        /// says whether the focus moved.
        public var settle: (Set<WindowID>, Bool) -> Void
        /// Abandoned: lay the strip out from State again.
        public var abandon: () -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval

        public init(
            surface: @escaping (CGPoint) -> GestureSurface?, physicalFrames: @escaping () -> [WindowID: CGRect],
            sink: @escaping () -> MotionFrameSink?,
            updateManager: @escaping ((inout WorkspaceManager) -> Void) -> Void,
            beginTracking: @escaping () -> Void,
            recordSampled: @escaping (WindowID, CGRect, TimeInterval) -> Void,
            markUnverified: @escaping (WindowID) -> Void, focusedWindow: @escaping () -> WindowID?,
            publishFocusRing: @escaping () -> Void, settle: @escaping (Set<WindowID>, Bool) -> Void,
            abandon: @escaping () -> Void, log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        ) {
            self.surface = surface
            self.physicalFrames = physicalFrames
            self.sink = sink
            self.updateManager = updateManager
            self.beginTracking = beginTracking
            self.recordSampled = recordSampled
            self.markUnverified = markUnverified
            self.focusedWindow = focusedWindow
            self.publishFocusRing = publishFocusRing
            self.settle = settle
            self.abandon = abandon
            self.log = log
            self.now = now
        }
    }

    /// Pointer travel below this is a click, not a drag.
    public static let dragThreshold: CGFloat = 3

    private final class Drag {
        let kind: MouseDragKind
        let window: WindowID
        let surface: GestureSurface
        let origin: CGPoint
        let pump: GestureFramePump
        let windows: Set<WindowID>
        /// The visible tiles when the drag began (move: the drop zones).
        let startVisible: [WindowID: CGRect]
        let resize: MouseResize?
        var result: Workspace
        var target: MouseDropTarget?
        var moved = false
        var touched: Set<WindowID> = []

        init(
            kind: MouseDragKind, window: WindowID, surface: GestureSurface, origin: CGPoint, pump: GestureFramePump,
            windows: Set<WindowID>, startVisible: [WindowID: CGRect], resize: MouseResize?
        ) {
            self.kind = kind
            self.window = window
            self.surface = surface
            self.origin = origin
            self.pump = pump
            self.windows = windows
            self.startVisible = startVisible
            self.resize = resize
            self.result = resize?.start ?? surface.workspace
        }
    }

    private let context: Context
    private var drag: Drag?

    public init(context: Context) {
        self.context = context
    }

    /// The pointer owns a strip: passes wait for the release.
    public var isTracking: Bool {
        drag != nil
    }

    /// Apps whose moved events are the drag's own writes.
    public var animatingPids: Set<pid_t> {
        drag?.pump.pids ?? []
    }

    /// Session queue: one gate drain.
    public func deliver(_ signals: [MouseDragSignal]) {
        for signal in signals {
            switch signal {
            case .begin(let kind, let window, let point):
                begin(kind, window: window, at: point)
            case .move(let point):
                track(to: point)
            case .end(let point):
                end(at: point)
            }
        }
        render()
    }

    private func begin(_ kind: MouseDragKind, window: WindowID, at point: CGPoint) {
        guard drag == nil else {
            return
        }
        guard let surface = context.surface(point), gestureStrip(surface) != nil,
              (surface.modes[window] ?? .tiled) == .tiled,
              surface.workspace.columns.contains(where: { $0.windows.contains(window) }),
              let sink = context.sink(),
              let plan = gestureFrames(surface, offset: surface.workspace.viewportOffset)
        else {
            context.log(.info, "mouse \(kind.rawValue) ignored id=\(window.pid):\(window.elementID) reason=no-strip")
            return
        }
        var resize: MouseResize?
        if kind == .resize {
            resize = beginMouseResize(surface, window: window, at: point)
            guard resize != nil else {
                context.log(.info, "mouse resize ignored id=\(window.pid):\(window.elementID) reason=not-tiled")
                return
            }
        }
        context.beginTracking()
        let physical = context.physicalFrames()
        let windows = Set(tilingWorkspace(from: surface.workspace, modes: surface.modes).columns.flatMap(\.windows))
        var start: [WindowID: CGRect] = [:]
        for id in windows {
            start[id] = physical[id] ?? plan.visible[id] ?? plan.parked[id]?.frame
        }
        drag = Drag(
            kind: kind, window: window, surface: surface, origin: point,
            pump: GestureFramePump(sink: sink, start: start), windows: windows,
            startVisible: plan.visible, resize: resize
        )
        context.log(
            .info,
            "mouse \(kind.rawValue) begin id=\(window.pid):\(window.elementID) display=\(surface.display.rawValue) columns=\(surface.workspace.columns.count)"
        )
    }

    private func track(to point: CGPoint) {
        guard let drag else {
            return
        }
        if !drag.moved {
            guard hypot(point.x - drag.origin.x, point.y - drag.origin.y) >= Self.dragThreshold else {
                return
            }
            drag.moved = true
        }
        if let resize = drag.resize {
            drag.result = mouseResized(resize, surface: drag.surface, to: point)
        } else {
            drag.target = mouseDropTarget(at: point, dragged: drag.window, frames: drag.startVisible)
            drag.result = drag.target.map { movingWindow(drag.window, to: $0, in: drag.surface.workspace) }
                ?? drag.surface.workspace
        }
        renderPoint = point
    }

    /// The pointer position the next render draws (nil: nothing new).
    private var renderPoint: CGPoint?

    /// Writes the strip as the drag has it, once per drain.
    private func render() {
        guard let drag, let point = renderPoint else {
            return
        }
        renderPoint = nil
        var surface = drag.surface
        surface.workspace = drag.result
        guard let plan = gestureFrames(surface, offset: drag.result.viewportOffset) else {
            return
        }
        var targets = plan.visible
        for (id, parked) in plan.parked {
            targets[id] = parked.frame
        }
        if drag.kind == .move, let grabbed = drag.startVisible[drag.window] {
            // The moved window follows the pointer at its own size.
            targets[drag.window] = grabbed.offsetBy(dx: point.x - drag.origin.x, dy: point.y - drag.origin.y)
        }
        let written = drag.pump.pump(targets)
        let now = context.now()
        for id in written.keys.sorted() {
            if drag.touched.insert(id).inserted {
                context.markUnverified(id)
            }
            context.recordSampled(id, written[id]!, now)
        }
        if let focused = context.focusedWindow(), written[focused] != nil {
            context.publishFocusRing()
        }
    }

    private func end(at point: CGPoint) {
        guard let drag else {
            return
        }
        track(to: point)
        render()
        self.drag = nil
        let label = "mouse \(drag.kind.rawValue) end id=\(drag.window.pid):\(drag.window.elementID)"
        guard drag.moved, drag.result != drag.surface.workspace else {
            context.log(.info, "\(label) result=none")
            context.abandon()
            return
        }
        var committed = false
        var focusChanged = false
        let id = drag.surface.workspace.id
        context.updateManager { manager in
            guard manager.workspace(id: id) == drag.surface.workspace else {
                return
            }
            let before = manager.currentWorkspace().focusedWindow
            var result = drag.result
            if let column = result.columns.firstIndex(where: { $0.windows.contains(drag.window) }),
               let row = result.columns[column].windows.firstIndex(of: drag.window)
            {
                result.focusedColumn = column
                result.columns[column].focusedWindowIndex = row
                result.focusedWindow = drag.window
            }
            manager.update(result)
            if manager.activeID(on: drag.surface.display) == id {
                manager.focusDisplay(drag.surface.display)
            }
            focusChanged = manager.currentWorkspace().focusedWindow != before
            committed = true
        }
        guard committed else {
            context.log(.info, "\(label) result=stale")
            context.abandon()
            return
        }
        context.log(.info, "\(label) result=\(describe(drag)) focusChanged=\(focusChanged)")
        context.settle(drag.windows, focusChanged)
    }

    private func describe(_ drag: Drag) -> String {
        switch drag.target {
        case .swap(let other):
            return "swap with=\(other.pid):\(other.elementID)"
        case .newColumn(let other, let after):
            return "column \(after ? "after" : "before")=\(other.pid):\(other.elementID)"
        case .stack(let other, let below):
            return "stack \(below ? "below" : "above")=\(other.pid):\(other.elementID)"
        case nil:
            let width = drag.result.columns.first { $0.windows.contains(drag.window) }?.widthSpec
            return "resized width=\(width.map { "\($0)" } ?? "?")"
        }
    }
}
