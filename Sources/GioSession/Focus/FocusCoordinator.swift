@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore

/// Everything that decides which window is the session focus, apart from the
/// layout: adoption of focus the user changed (clicks settle and are
/// validated against the click point, keyboard-driven events adopt at once),
/// the keyboard/IPC focus intent (HD-01, FI-06) with its centering request
/// and cursor warp (HD-04), the window a sizing action just grew, and
/// focus-follows-mouse (HD-04). Gio's own pid is never a focus.
///
/// Session queue, except the three hand-offs from the main-thread tap:
/// `recordClick`, `pointerMoved` and `focusFollowsMouse`, each behind its own
/// lock together with its data. Logs carry ids, never titles.
public final class FocusCoordinator: @unchecked Sendable {
    public struct Context {
        public var isShuttingDown: () -> Bool
        public var isMouseDown: () -> Bool
        /// Cocoa coordinates.
        public var mouseLocation: () -> CGPoint
        public var frontmostPID: () -> pid_t?
        /// Gio's own pid: never adopted, never read, never hovered.
        public var ownPID: pid_t
        /// Every display's usable area: clicks outside (menu bar, Dock) are
        /// not window clicks.
        public var windowAreas: () -> [CGRect]
        public var currentWorkspace: () -> Workspace
        public var updateWorkspace: (Workspace) -> Void
        public var isMinimized: (WindowID) -> Bool
        /// The registered window behind an AX element, if any.
        public var knownWindow: (AXUIElement, pid_t) -> WindowID?
        /// The app's focused window element (one AX read).
        public var focusedWindowElement: (pid_t) -> AXUIElement?
        /// The window's current AX frame, nil when unreadable.
        public var frame: (WindowID) -> CGRect?
        /// An unknown focused window: single-window admission registers it.
        public var registerAppeared: (AXUIElement, pid_t) -> Void
        /// The viewport move laying out the current workspaces would make.
        public var pendingScroll: () -> (from: CGFloat, to: CGFloat)?
        /// Whether `id` sits inside its display's viewport (nil: not placed).
        public var isVisibleInViewport: (WindowID) -> Bool?
        /// The pid owning the topmost on-screen window at a point.
        public var topWindowOwnerPID: (CGPoint) -> pid_t?
        public var warpCursor: (CGPoint) -> Void
        /// WC-13: the click at this point landed on the Dock or the menu bar
        /// (one WindowServer query, `clickIsOnSystemUI`).
        public var clickOnSystemUI: (CGPoint) -> Bool
        public var mouseFollowsFocus: () -> Bool
        public var centerMode: () -> CenterFocusedColumnMode
        public var publishFocusRing: () -> Void
        public var reflowAll: () -> Void
        public var workspaceFocusPlan: (WindowID) -> WindowFocusPlan?
        /// Focus the workspace and show it; the cause is the motion the
        /// pass carries (MM-01: `.passive` when only the focused display
        /// changes, `.workspaceSwitch` when a display really switches).
        public var showWorkspace: (WorkspaceID, MotionCause) -> Void
        public var log: (LogLevel, String) -> Void
        public var now: () -> TimeInterval
        public var allowsWindowWork: () -> Bool
        /// WC-11: the focused window is a background native tab: it becomes
        /// its group's front tab and takes the slot. True when it switched.
        public var bringTabToFront: (WindowID) -> Bool

        public init(
            isShuttingDown: @escaping () -> Bool, isMouseDown: @escaping () -> Bool,
            mouseLocation: @escaping () -> CGPoint, frontmostPID: @escaping () -> pid_t?,
            ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
            windowAreas: @escaping () -> [CGRect],
            currentWorkspace: @escaping () -> Workspace, updateWorkspace: @escaping (Workspace) -> Void,
            isMinimized: @escaping (WindowID) -> Bool,
            knownWindow: @escaping (AXUIElement, pid_t) -> WindowID?,
            focusedWindowElement: @escaping (pid_t) -> AXUIElement?,
            frame: @escaping (WindowID) -> CGRect?,
            registerAppeared: @escaping (AXUIElement, pid_t) -> Void,
            pendingScroll: @escaping () -> (from: CGFloat, to: CGFloat)?,
            isVisibleInViewport: @escaping (WindowID) -> Bool?,
            topWindowOwnerPID: @escaping (CGPoint) -> pid_t?,
            warpCursor: @escaping (CGPoint) -> Void,
            clickOnSystemUI: @escaping (CGPoint) -> Bool = { _ in false },
            mouseFollowsFocus: @escaping () -> Bool,
            centerMode: @escaping () -> CenterFocusedColumnMode,
            publishFocusRing: @escaping () -> Void, reflowAll: @escaping () -> Void,
            workspaceFocusPlan: @escaping (WindowID) -> WindowFocusPlan?,
            showWorkspace: @escaping (WorkspaceID, MotionCause) -> Void,
            log: @escaping (LogLevel, String) -> Void,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            allowsWindowWork: @escaping () -> Bool = { true },
            bringTabToFront: @escaping (WindowID) -> Bool = { _ in false }
        ) {
            self.isShuttingDown = isShuttingDown
            self.isMouseDown = isMouseDown
            self.mouseLocation = mouseLocation
            self.frontmostPID = frontmostPID
            self.ownPID = ownPID
            self.windowAreas = windowAreas
            self.currentWorkspace = currentWorkspace
            self.updateWorkspace = updateWorkspace
            self.isMinimized = isMinimized
            self.knownWindow = knownWindow
            self.focusedWindowElement = focusedWindowElement
            self.frame = frame
            self.registerAppeared = registerAppeared
            self.pendingScroll = pendingScroll
            self.isVisibleInViewport = isVisibleInViewport
            self.topWindowOwnerPID = topWindowOwnerPID
            self.warpCursor = warpCursor
            self.clickOnSystemUI = clickOnSystemUI
            self.mouseFollowsFocus = mouseFollowsFocus
            self.centerMode = centerMode
            self.publishFocusRing = publishFocusRing
            self.reflowAll = reflowAll
            self.workspaceFocusPlan = workspaceFocusPlan
            self.showWorkspace = showWorkspace
            self.log = log
            self.now = now
            self.allowsWindowWork = allowsWindowWork
            self.bringTabToFront = bringTabToFront
        }
    }

    /// One focus signal awaiting adoption. `element` is the window the
    /// event itself carried (focused-window changes), if any.
    struct FocusEvent: Equatable {
        let source: FocusSource
        let pid: pid_t
        let element: AXUIElement?

        static func == (lhs: FocusEvent, rhs: FocusEvent) -> Bool {
            lhs.source == rhs.source && lhs.pid == rhs.pid
                && sameElement(lhs.element, rhs.element)
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler

    private var focusSettle = FocusSettle<FocusEvent>()
    /// HD-01: the window keyboard/IPC actions want focused.
    private var focusIntent = FocusIntent()
    /// HD-04: centering asked by the last keyboard/IPC focus change (consumed
    /// by the next reflow), and whether the cursor should follow that focus.
    private var centerRequest: CenterRequest?
    private var warpAfterFocus = false
    /// Focused-grow: the window a sizing action (maximize, width preset) just
    /// resized; already frontmost, so it needs no focus intent. Consumed by the
    /// next reflow.
    private var sizingFocus: WindowID?

    /// The newest mouse-down the tap saw (main thread writes).
    private let clickLock = NSLock()
    private var tappedClick: MouseClick?

    /// HD-04 focus-follows-mouse. `hoverLock` guards the flag and the latest
    /// pointer location the main-thread tap hands over; the rest is on the
    /// session queue.
    private var hoverFocus = HoverFocus()
    /// Visible frames of the last pass: where hover (and the render check) look.
    public private(set) var hoverFrames: [WindowID: CGRect] = [:]
    private let hoverLock = NSLock()
    private var hoverEnabled = false
    private var hoverLocation: CGPoint?
    private var hoverScheduled = false

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    // MARK: Main-thread hand-offs

    /// `focus-follows-mouse` (any thread).
    public var focusFollowsMouse: Bool {
        get {
            hoverLock.withLock { hoverEnabled }
        }
        set {
            hoverLock.withLock { hoverEnabled = newValue }
        }
    }

    /// Tap thread (PF-AB): a mouse-down. A click is the user choosing the
    /// focus: any pending keyboard intent is dropped on the session queue.
    /// WC-13: there, before the activation it causes arrives, the click is
    /// marked when it landed on the Dock or the menu bar (no window click).
    public func recordClick(at location: CGPoint) {
        let click = MouseClick(location: location, time: context.now())
        clickLock.lock()
        tappedClick = click
        clickLock.unlock()
        scheduler.async { [weak self] in
            guard let self else {
                return
            }
            focusIntent.cancel()
            guard context.clickOnSystemUI(location) else {
                return
            }
            clickLock.lock()
            if tappedClick == click {
                tappedClick?.onSystemUI = true
            }
            clickLock.unlock()
            context.log(.debug, "focus click on system UI x=\(Int(location.x)) y=\(Int(location.y))")
        }
    }

    /// Tap thread (PF-AB). Hands the latest pointer location to the session
    /// queue, coalesced to one look per 30 ms.
    public func pointerMoved(_ location: CGPoint) {
        hoverLock.lock()
        guard hoverEnabled else {
            hoverLock.unlock()
            return
        }
        hoverLocation = location
        let schedule = !hoverScheduled
        hoverScheduled = true
        hoverLock.unlock()
        guard schedule else {
            return
        }
        scheduler.asyncAfter(0.03) { [weak self] in
            self?.processPointer()
        }
    }

    // MARK: Adoption

    /// The click explaining a focus event right now, if any: a button is
    /// down or one went down moments ago, at a point inside a window area.
    public func currentClick() -> MouseClick? {
        clickLock.lock()
        let tapped = tappedClick
        clickLock.unlock()
        let click = recentClick(
            pressed: context.isMouseDown(),
            currentLocation: context.mouseLocation(),
            now: context.now(),
            lastTapped: tapped
        )
        return windowAreaClick(click, visibleAreas: context.windowAreas())
    }

    /// Adopt `id` as the session focus (current workspace), logging what it
    /// did to the viewport. True when the focus changed. Callers that adopt
    /// outside a reflow follow up with `reflowAll` when it scrolls.
    @discardableResult
    public func adoptFocus(_ id: WindowID, source: FocusSource) -> Bool {
        guard context.allowsWindowWork() else {
            return false
        }
        let current = context.currentWorkspace()
        let column = current.columns.firstIndex { $0.windows.contains(id) }
        let visibility = context.isVisibleInViewport(id)
        guard let adopted = adoptingFocus(id, in: current), adopted != current else {
            logAdoption(source, id, column, visibility, changed: false)
            return false
        }
        context.updateWorkspace(adopted)
        logAdoption(source, id, column, visibility, changed: true)
        context.publishFocusRing()
        return true
    }

    private func logAdoption(
        _ source: FocusSource, _ id: WindowID, _ column: Int?, _ visible: Bool?, changed: Bool
    ) {
        let scroll = context.pendingScroll().map { "\(Int($0.from))->\(Int($0.to))" } ?? "no scroll"
        let placement = visible.map { $0 ? "visible" : "parked" } ?? "unplaced"
        context.log(
            .debug,
            "focus adopt source=\(source.rawValue) id=\(id.pid):\(id.elementID) "
                + "column=\(column.map(String.init) ?? "none") \(placement) "
                + "changed=\(changed) scroll=\(scroll)"
        )
    }

    /// Light path for a click or app switch: no rescan. Keyboard-driven
    /// events adopt at once; mouse-driven ones coalesce, settle and are
    /// validated against the click (`FocusSettle`). The activation and the
    /// focused-window event of one click therefore adopt once.
    public func requestAdoption(_ source: FocusSource, pid: pid_t, element: AXUIElement?) {
        guard context.allowsWindowWork() else {
            return
        }
        // Gio's own window (main window, launcher) is never a tiling focus.
        guard pid != context.ownPID else {
            return
        }
        // A background app changing its own key window is not the user's focus.
        if source == .focusChanged,
           pid != context.frontmostPID()
        {
            return
        }
        let event = FocusEvent(source: source, pid: pid, element: element)
        switch focusSettle.request(event, click: currentClick()) {
        case .adoptNow(let event):
            if let element = focusedElement(for: event, fresh: false) {
                adoptResolved(element, event: event)
            }
        case .wait(let delay):
            scheduleFocusPoll(after: delay)
        case .coalesced:
            break
        }
    }

    public func discardPendingAdoptions() {
        focusSettle.discard()
    }

    private func scheduleFocusPoll(after delay: TimeInterval) {
        scheduler.asyncAfter(delay) { [weak self] in
            guard let self, !self.context.isShuttingDown() else {
                return
            }
            let poll = self.focusSettle.poll(
                mouseDown: self.context.isMouseDown(),
                now: self.context.now()
            )
            switch poll {
            case .idle:
                break
            case .wait(let next):
                self.scheduleFocusPoll(after: next)
            case .resolve(let event, let click):
                self.validateClickFocus(event, click: click, fresh: false)
            }
        }
    }

    /// The window to adopt: the one the event carried the first time, the
    /// app's current key window when re-reading.
    private func focusedElement(for event: FocusEvent, fresh: Bool) -> AXUIElement? {
        if !fresh, let element = event.element {
            return element
        }
        return context.focusedWindowElement(event.pid)
    }

    private func validateClickFocus(_ event: FocusEvent, click: MouseClick, fresh: Bool) {
        let element = context.frontmostPID() == event.pid
            ? focusedElement(for: event, fresh: fresh) : nil
        let known = element.flatMap { context.knownWindow($0, event.pid) }
        var matches = false
        var frame: CGRect?
        if let known {
            frame = context.frame(known)
            matches = focusMatchesClick(frame: frame, click: click.location)
        } else if element != nil {
            // Unknown window: single-window admission decides, nothing to compare.
            matches = true
        }
        switch focusSettle.judge(matchesClick: matches) {
        case .adopt:
            if let element {
                adoptResolved(element, event: event)
            }
        case .retry(let delay):
            scheduler.asyncAfter(delay) { [weak self] in
                guard let self, !self.context.isShuttingDown(),
                      let (latest, latestClick) = self.focusSettle.resolveAgain()
                else {
                    return
                }
                self.validateClickFocus(latest, click: latestClick, fresh: true)
            }
        case .giveUp:
            let id = known.map { "\($0.pid):\($0.elementID)" } ?? "none"
            let box = frame.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }
                ?? "unreadable"
            context.log(
                .debug,
                "focus dropped source=\(event.source.rawValue) id=\(id) frame=\(box) "
                    + "click=\(Int(click.location.x)),\(Int(click.location.y)) "
                    + "reason=focused window not under click"
            )
        }
    }

    /// The frontmost app's window becomes the session focus; an unknown
    /// window goes through single-window admission; a reflow follows only
    /// when the viewport has to scroll to show the focused column. WC-11: a
    /// background native tab is the tab macOS shows now: it takes its group's
    /// slot first (whatever the intent says) and the slot is written to it.
    private func adoptResolved(_ element: AXUIElement, event: FocusEvent) {
        guard context.allowsWindowWork() else {
            return
        }
        guard event.pid == context.frontmostPID() else {
            return
        }
        guard let id = context.knownWindow(element, event.pid) else {
            // Registration focuses the new window and reflows.
            context.registerAppeared(element, event.pid)
            return
        }
        if context.isMinimized(id) {
            return
        }
        let switchedTab = context.bringTabToFront(id)
        // Trailing activation events of a focus Gio just moved must not undo it.
        if focusIntent.shouldIgnoreAdoption(of: id, now: context.now()) {
            context.log(.debug, "focus adopt ignored (superseded by keyboard intent) id=\(id.pid):\(id.elementID)")
            if switchedTab {
                context.reflowAll()
            }
            return
        }
        if revealOnOtherWorkspace(id, source: event.source) {
            return
        }
        adoptFocus(id, source: event.source)
        if switchedTab || context.pendingScroll() != nil {
            context.reflowAll()
        }
    }

    private func revealOnOtherWorkspace(_ id: WindowID, source: FocusSource) -> Bool {
        guard let plan = context.workspaceFocusPlan(id), plan.switchesWorkspace else {
            return false
        }
        focusIntent.cancel()
        context.showWorkspace(plan.workspace.id, plan.revealCause)
        context.updateWorkspace(plan.workspace)
        context.log(
            .info,
            "focus reveal id=\(id.pid):\(id.elementID) workspace=\(plan.index) source=\(source.rawValue)"
        )
        context.publishFocusRing()
        context.reflowAll()
        return true
    }

    // MARK: Keyboard / IPC intent

    /// Ask the next reflow to focus and raise the current workspace's focused
    /// window (after its frame lands; at the end of an animation).
    public func requestIntent(if carries: Bool, previous: WindowID?) {
        guard carries else {
            return
        }
        // Keyboard/IPC focus changes may center the column and warp the
        // cursor (HD-04); passive and hover focus never do.
        centerRequest = CenterRequest(mode: context.centerMode(), previouslyFocused: previous)
        warpAfterFocus = true
        focusIntent.request(context.currentWorkspace().focusedWindow, now: context.now())
    }

    /// TG-03: a trackpad scroll settled on another column: the next pass
    /// raises its window like a keyboard focus change (niri moves the focus
    /// with the gesture), without centering (the snap chose the offset) or a
    /// cursor warp (the hand is on the trackpad, not on the pointer).
    public func requestGestureIntent() {
        focusIntent.request(context.currentWorkspace().focusedWindow, now: context.now())
    }

    /// A sizing action grew the focused window (nil: nothing).
    public func noteSizingFocus(_ id: WindowID?) {
        sizingFocus = id
    }

    // MARK: Reflow hand-offs

    /// The centering the next pass applies (consumed).
    public func takeCenterRequest() -> CenterRequest {
        defer { centerRequest = nil }
        return centerRequest ?? .none
    }

    /// The window a sizing action just grew (consumed).
    public func takeSizingFocus() -> WindowID? {
        defer { sizingFocus = nil }
        return sizingFocus
    }

    /// The window the keyboard is about to raise, not consumed.
    public func pendingIntentTarget(parked: Set<WindowID>) -> WindowID? {
        focusIntent.pendingTarget(parked: parked)
    }

    /// The visible frames of the pass just planned.
    public func setHoverFrames(_ frames: [WindowID: CGRect]) {
        hoverFrames = frames
    }

    /// FI-06: at motion start the keyboard follows the logical focus right
    /// away instead of after the animation; the final pass only re-asserts a
    /// drift. PF-Q: `focusNow` hands the raise off (the reconciler runs it on
    /// its focus queue) and returns at once, so the motion's ticks are not
    /// held; a refusal is logged by the reconciler (`focus failed`).
    public func focusAtMotionStart(
        parked: Set<WindowID>, plans: [ParkingPlan], focusNow: (WindowID) -> Void
    ) {
        if let target = focusIntent.takeImmediate(parked: parked, now: context.now()) {
            focusNow(target)
            context.log(.debug, "focus now id=\(target.pid):\(target.elementID) async=true")
            if warpAfterFocus {
                warpCursorToFocus(target, plans: plans)
            }
        }
        warpAfterFocus = false
    }

    /// The instant pass's focus target: only a keyboard/IPC intent focuses
    /// anything (HD-01; passive reflows get nil and never steal focus), or
    /// the one reassert of a focus the motion start delivered. `warp` says
    /// whether the cursor follows it once the pass landed (consumed).
    public func takeSettleFocus(parked: Set<WindowID>) -> (target: WindowID?, warp: Bool) {
        var target = focusIntent.take(motionStarting: false, parked: parked, now: context.now())
        if target == nil,
           let reassert = focusIntent.takeReassert(
               logicalFocus: context.currentWorkspace().focusedWindow,
               frontmostPID: context.frontmostPID(),
               frontmostFocusedWindow: { [context] in
                   // Never reads Gio's own pid: a target is never Gio's.
                   guard let pid = context.frontmostPID(),
                         pid != context.ownPID,
                         let element = context.focusedWindowElement(pid) else {
                       return nil
                   }
                   return context.knownWindow(element, pid)
               }
           ) {
            context.log(
                .debug,
                "focus reassert id=\(reassert.id.pid):\(reassert.id.elementID) reason=\(reassert.reason.rawValue)"
            )
            target = reassert.id
        }
        let warp = warpAfterFocus
        warpAfterFocus = false
        return (target, warp)
    }

    /// `mouse-follows-focus`: after a keyboard focus change landed, put the
    /// cursor in the middle of the focused window (unless already inside).
    public func warpCursorToFocus(_ id: WindowID, plans: [ParkingPlan]) {
        guard let frame = plans.lazy.compactMap({ $0.visible[id] }).first,
              let target = mouseFollowsFocusTarget(
                  enabled: context.mouseFollowsFocus(), frame: frame,
                  pointer: context.mouseLocation()
              )
        else {
            return
        }
        hoverFocus.noteWarp(now: context.now())
        context.warpCursor(target)
        context.log(.debug, "cursor warped to focus id=\(id.pid):\(id.elementID)")
    }

    /// MM-02 `mouse-follows-focus` for `focus-monitor-*` onto a display with
    /// no window to focus: put the cursor in the middle of its usable frame
    /// (unless already on it), so the cursor follows the focused display.
    public func warpCursor(toDisplay frame: CGRect) {
        guard let target = mouseFollowsFocusTarget(
            enabled: context.mouseFollowsFocus(), frame: frame, pointer: context.mouseLocation()
        ) else {
            return
        }
        hoverFocus.noteWarp(now: context.now())
        context.warpCursor(target)
        context.log(.debug, "cursor warped to the focused display")
    }

    // MARK: Focus follows mouse (HD-04)

    private func processPointer() {
        hoverLock.lock()
        let location = hoverLocation
        hoverScheduled = false
        hoverLock.unlock()
        guard let location, !context.isShuttingDown() else {
            return
        }
        let now = context.now()
        let target = hoveredWindow(at: location)
        if let delay = hoverFocus.pointerMoved(over: target, now: now) {
            scheduler.asyncAfter(delay + 0.01) { [weak self] in
                self?.fireHoverFocus()
            }
        }
    }

    private func hoveredWindow(at location: CGPoint) -> WindowID? {
        // PF-AA: cheap geometry first; the WindowServer lookup only when a
        // managed window other than the focused one is under the pointer.
        guard hoverNeedsLookup(at: location, frames: hoverFrames, focused: hoverFocused()) else {
            return nil
        }
        return hoverTarget(
            at: location, frames: hoverFrames, topWindowPID: context.topWindowOwnerPID(location),
            ownPID: context.ownPID
        )
    }

    /// The focused window as hover sees it: the logical focus, when its app
    /// is frontmost.
    private func hoverFocused() -> WindowID? {
        let frontPID = context.frontmostPID()
        return context.currentWorkspace().focusedWindow.flatMap { $0.pid == frontPID ? $0 : nil }
    }

    private func fireHoverFocus() {
        guard !context.isShuttingDown() else {
            return
        }
        let focused = hoverFocused()
        guard let id = hoverFocus.due(
            now: context.now(),
            buttonDown: context.isMouseDown(), focused: focused
        ), hoveredWindow(at: context.mouseLocation()) == id else {
            return
        }
        adoptFocus(id, source: .hover)
        focusIntent.request(id, now: context.now())
        context.reflowAll()
    }
}

/// Same AX element (CFEqual), or both absent.
private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (let lhs?, let rhs?): return CFEqual(lhs, rhs)
    default: return false
    }
}
