import CoreGraphics
import Foundation

/// TG-03: one display's strip as the scroll gesture sees it, read from
/// session state when the fingers commit to a horizontal swipe.
public struct GestureSurface: Sendable {
    public var display: DisplayID
    public var workspace: Workspace
    public var modes: [WindowID: WindowMode]
    public var engine: ScrollableLayoutEngine
    /// The usable area the strip is laid out on (Cocoa, screen space).
    public var viewport: CGRect
    /// The whole display (parking slivers hang off its edges).
    public var displayFrame: CGRect
    public var otherDisplays: [CGRect]
    /// `center-focused-column = always`: columns snap centered (niri).
    public var centering: Bool

    public init(
        display: DisplayID, workspace: Workspace, modes: [WindowID: WindowMode], engine: ScrollableLayoutEngine,
        viewport: CGRect, displayFrame: CGRect, otherDisplays: [CGRect], centering: Bool
    ) {
        self.display = display
        self.workspace = workspace
        self.modes = modes
        self.engine = engine
        self.viewport = viewport
        self.displayFrame = displayFrame
        self.otherDisplays = otherDisplays
        self.centering = centering
    }
}

/// The display whose strip a scroll moves: the one under the pointer (the
/// trackpad has no position of its own; the pointer is where the user
/// looks), else the focused one.
public func gestureDisplay(at pointer: CGPoint, displays: [DisplayState], focused: DisplayID) -> DisplayState? {
    displays.first { $0.frame.contains(pointer) } ?? displays.first { $0.id == focused }
}

/// TG-03: the tiled columns in content space (x where the viewport offset
/// is 0 at the strip's left edge) and the window each one focuses.
public struct GestureStrip: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var start: CGFloat
        public var end: CGFloat
        /// The column's focused window, else its first tiled one.
        public var focus: WindowID
    }

    public var columns: [Column]
    public var viewportWidth: CGFloat
    public var padding: CGFloat
    public var contentWidth: CGFloat
    /// The offset the state holds (clamped like the layout clamps it).
    public var committedOffset: CGFloat
    public var centering: Bool

    public var maxOffset: CGFloat {
        max(0, contentWidth - viewportWidth)
    }
}

/// The strip under the fingers; nil when there is nothing to scroll, the
/// workspace is a dwindle tree (no strip: its tiles fill the display), or a
/// fullscreen window owns the workspace (its strip is parked behind it).
public func gestureStrip(_ surface: GestureSurface) -> GestureStrip? {
    let workspace = surface.workspace
    guard workspace.layout == .scrolling,
          !workspace.columns.contains(where: { $0.windows.contains { surface.modes[$0] == .fullscreen } })
    else {
        return nil
    }
    let tiled = tilingWorkspace(from: workspace, modes: surface.modes)
    guard !tiled.columns.isEmpty,
          let layout = try? surface.engine.calculate(workspace: tiled, viewport: surface.viewport)
    else {
        return nil
    }
    let toContent = layout.viewportOffset - surface.viewport.minX
    var columns: [GestureStrip.Column] = []
    for column in tiled.columns {
        let frames = column.windows.compactMap { layout.frames[$0] }
        guard !frames.isEmpty else {
            continue
        }
        let owner = workspace.columns.first { $0.windows.contains(column.windows[0]) }
        let focus = owner?.focusedWindowID.flatMap { column.windows.contains($0) ? $0 : nil } ?? column.windows[0]
        columns.append(GestureStrip.Column(
            start: frames.map(\.minX).min()! + toContent, end: frames.map(\.maxX).max()! + toContent, focus: focus
        ))
    }
    return GestureStrip(
        columns: columns, viewportWidth: surface.viewport.width, padding: surface.engine.config.padding,
        contentWidth: layout.contentWidth, committedOffset: layout.viewportOffset, centering: surface.centering
    )
}

/// The frames of one gesture step: the strip laid out at `offset` (no
/// reveal: the fingers own the viewport), columns off the viewport parked
/// and columns that reach it visible, so they un-park as they arrive.
public func gestureFrames(_ surface: GestureSurface, offset: CGFloat) -> ParkingPlan? {
    var tiled = tilingWorkspace(from: surface.workspace, modes: surface.modes)
    tiled.viewportOffset = offset
    guard let layout = try? surface.engine.calculate(workspace: tiled, viewport: surface.viewport) else {
        return nil
    }
    return planParking(
        frames: layout.frames, viewport: surface.viewport, display: surface.displayFrame,
        otherDisplays: surface.otherDisplays
    )
}

/// Finger travel (trackpad widths) to viewport offset (points). Natural:
/// the content follows the fingers, so a swipe left reveals the columns on
/// the right (the offset grows).
public func gestureOffsetDelta(fingerDX: Double, viewportWidth: CGFloat, sensitivity: Double, natural: Bool) -> CGFloat {
    CGFloat(fingerDX * sensitivity) * viewportWidth * (natural ? -1 : 1)
}

/// Where the strip really is when the fingers take it: a motion may still
/// be carrying it, so the offset follows a visible window's physical frame
/// (`prefer` first) rather than the committed state; no known window, the
/// committed offset.
public func gestureVisualOffset(
    committed: CGFloat, visible: [WindowID: CGRect], physical: [WindowID: CGRect], prefer: WindowID?
) -> CGFloat {
    for id in [prefer].compactMap({ $0 }) + visible.keys.sorted() {
        if let target = visible[id], let actual = physical[id] {
            return committed + (target.minX - actual.minX)
        }
    }
    return committed
}

/// The offset under the fingers, kept inside the strip. Pushing past an end
/// re-bases it there, so reversing moves the strip at once.
public struct GestureScrollTracker: Equatable, Sendable {
    public private(set) var offset: CGFloat
    public let maxOffset: CGFloat

    public init(base: CGFloat, maxOffset: CGFloat) {
        self.maxOffset = max(0, maxOffset)
        offset = min(max(base, 0), self.maxOffset)
    }

    public mutating func apply(_ delta: CGFloat) {
        offset = min(max(offset + delta, 0), maxOffset)
    }
}

/// niri's touchpad deceleration (`SwipeTracker::projected_end_pos`, rate
/// 0.997 per millisecond): a release at `v` points per second would coast
/// `v * gestureProjectionSeconds` points.
public let gestureProjectionSeconds = -1 / (1000 * log(0.997))

/// Where a released strip settles and which column takes the focus.
public struct GestureSnap: Equatable, Sendable {
    public var offset: CGFloat
    /// Index into `GestureStrip.columns`.
    public var column: Int

    public init(offset: CGFloat, column: Int) {
        self.offset = offset
        self.column = column
    }
}

/// niri `view_offset_gesture_end`: project the release with its velocity,
/// then take the nearest snap point: a column's left edge or right edge
/// against the viewport (with the padding), never past the first column's
/// left or the last column's right; with centering, each column centered.
/// Without centering, the focus then moves on to the furthest column that
/// is still fully visible in the swipe's direction.
public func snapGestureScroll(_ strip: GestureStrip, offset: CGFloat, velocity: CGFloat) -> GestureSnap? {
    guard let last = strip.columns.indices.last else {
        return nil
    }
    let target = offset + velocity * CGFloat(gestureProjectionSeconds)
    let width = strip.viewportWidth
    let pad = strip.padding
    func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), strip.maxOffset)
    }
    var points: [GestureSnap] = []
    if strip.centering {
        for (index, column) in strip.columns.enumerated() {
            points.append(GestureSnap(offset: clamped((column.start + column.end - width) / 2), column: index))
        }
    } else {
        let leftmost = clamped(strip.columns[0].start - pad)
        let rightmost = clamped(strip.columns[last].end + pad - width)
        points = [GestureSnap(offset: leftmost, column: 0), GestureSnap(offset: rightmost, column: last)]
        for (index, column) in strip.columns.enumerated() {
            for edge in [column.start - pad, column.end + pad - width] where leftmost < edge && edge < rightmost {
                points.append(GestureSnap(offset: edge, column: index))
            }
        }
    }
    var best = points[0]
    for point in points.dropFirst() where abs(point.offset - target) < abs(best.offset - target) {
        best = point
    }
    guard !strip.centering else {
        return best
    }
    var column = best.column
    if target >= offset {
        for index in strip.columns.indices where index > best.column {
            guard strip.columns[index].end + pad <= best.offset + width else {
                break
            }
            column = index
        }
    } else {
        for index in strip.columns.indices.reversed() where index < best.column {
            guard strip.columns[index].start - pad >= best.offset else {
                break
            }
            column = index
        }
    }
    return GestureSnap(offset: best.offset, column: column)
}

/// TG-13: travel, as a fraction of the start column's width, that pages a
/// slow armed two-finger stroke to the neighbour.
public let gesturePageTravel: CGFloat = 0.2
/// TG-13: release speed (viewport points per second) that pages whatever
/// the travel; a flick's direction wins over its travel. Live flicks
/// measured 2000-3000.
public let gesturePageVelocity: CGFloat = 500

/// TG-13: the column a paging stroke starts from: the focused window's,
/// else the first column fully in view at the committed offset, else the
/// first.
public func gesturePageStartColumn(_ strip: GestureStrip, focused: WindowID?) -> Int {
    if let focused, let index = strip.columns.firstIndex(where: { $0.focus == focused }) {
        return index
    }
    let left = strip.committedOffset
    let right = left + strip.viewportWidth
    return strip.columns.firstIndex { $0.start - strip.padding >= left && $0.end + strip.padding <= right } ?? 0
}

/// TG-13: the armed two-finger stroke pages like a macOS Space switch: at
/// most one column from `start`. A release faster than
/// `gesturePageVelocity` goes to the neighbour in its direction, else a
/// `travel` (offset points since the stroke began) of `gesturePageTravel`
/// of the start column's width does, else the strip goes back. Clamped at
/// the strip's ends. The target is revealed from the committed offset like
/// a keyboard focus move (minimal scroll; centered with centering).
public func pageGestureScroll(_ strip: GestureStrip, from start: Int, travel: CGFloat, velocity: CGFloat) -> GestureSnap? {
    guard let last = strip.columns.indices.last else {
        return nil
    }
    let origin = min(max(start, 0), last)
    let width = strip.columns[origin].end - strip.columns[origin].start
    var step = 0
    if abs(velocity) >= gesturePageVelocity {
        step = velocity > 0 ? 1 : -1
    } else if abs(travel) >= gesturePageTravel * width {
        step = travel > 0 ? 1 : -1
    }
    let index = min(max(origin + step, 0), last)
    let column = strip.columns[index]
    let pad = strip.padding
    let viewport = strip.viewportWidth
    let offset: CGFloat
    if strip.centering {
        offset = (column.start + column.end - viewport) / 2
    } else {
        offset = min(max(strip.committedOffset, column.end + pad - viewport), column.start - pad)
    }
    return GestureSnap(offset: min(max(offset, 0), strip.maxOffset), column: index)
}

/// TG-13: the settings of the pass that settles a released gesture. A
/// settle the fingers started always springs from the release velocity,
/// like a native Space switch, even with the Fast preset (`enabled =
/// false`) or `horizontal-view-movement` off: that kind becomes an active
/// spring (its own spring when it was active, niri's otherwise; a 0 ms
/// duration becomes the default). Every other kind keeps exactly its
/// on/off state, so the rest of the pass stays as instant as configured.
public func gestureSettleAnimations(_ settings: AnimationsSectionConfig) -> AnimationsSectionConfig {
    let scroll = settings.resolved(.horizontalViewMovement)
    var settled = settings
    settled.enabled = true
    for kind in AnimationKind.allCases where kind != .horizontalViewMovement {
        var custom = settings.overrides[kind] ?? AnimationOverride()
        custom.enabled = settings.resolved(kind).enabled
        settled.overrides[kind] = custom
    }
    let spring = scroll.isActive ? scroll.spring : SpringParameters.niri
    settled.overrides[.horizontalViewMovement] = AnimationOverride(
        enabled: true, curve: .spring, springDampingRatio: spring.dampingRatio, springStiffness: spring.stiffness,
        durationMilliseconds: scroll.durationMilliseconds > 0
            ? scroll.durationMilliseconds : AnimationsSectionConfig().durationMilliseconds
    )
    return settled
}

/// The settle in State (invariant 1): the workspace takes the snapped offset
/// and focuses the snapped column's window, and the display the fingers
/// moved takes the focus when it shows that workspace. True when the
/// focused window changed (the session then raises it, like a keyboard
/// focus change). A workspace that vanished meanwhile changes nothing.
@discardableResult
public func commitGestureScroll(
    _ manager: inout WorkspaceManager, display: DisplayID, workspace id: WorkspaceID,
    strip: GestureStrip, snap: GestureSnap
) -> Bool {
    guard var workspace = manager.workspace(id: id) else {
        return false
    }
    let before = manager.currentWorkspace().focusedWindow
    workspace.viewportOffset = snap.offset
    if strip.columns.indices.contains(snap.column) {
        let target = strip.columns[snap.column].focus
        if let index = workspace.columns.firstIndex(where: { $0.windows.contains(target) }),
           let row = workspace.columns[index].windows.firstIndex(of: target)
        {
            workspace.focusedColumn = index
            workspace.focusedWindow = target
            workspace.columns[index].focusedWindowIndex = row
        }
    }
    manager.update(workspace)
    if manager.activeID(on: display) == id {
        manager.focusDisplay(display)
    }
    return manager.currentWorkspace().focusedWindow != before
}

/// The release velocity (points per second along x, the windows' direction)
/// becomes the starting velocity of the settle's springs, for the windows
/// of the swiped workspace: the strip keeps moving instead of restarting
/// from rest. Eased flights have no velocity to take.
public func handingOffGestureVelocity(
    _ animations: [WindowAnimation], windows: Set<WindowID>, velocity: CGFloat
) -> [WindowAnimation] {
    animations.map { animation in
        guard windows.contains(animation.id), let spring = animation.spring else {
            return animation
        }
        return animation.springing(spring, velocity: CGPoint(x: velocity, y: 0))
    }
}

/// A vertical swipe as a workspace action. Natural: the content follows the
/// fingers, so swiping up shows the workspace below.
public func workspaceSwipeAction(_ direction: SwipeDirection, natural: Bool) -> HotkeyAction {
    (direction == .up) == natural ? .focusWorkspaceDown : .focusWorkspaceUp
}
