@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import GioCore
import GioMacOS

/// Which windows the session manages: the discovery scan and registration of
/// arrivals (rules and admission decide mode and workspace), appeared windows
/// (retried while unreadable), minimize state healing, the purge of windows
/// that are gone (destroyed, dead pid, vanished from a complete scan) and the
/// display topology sync. Gio's own pid is never registered, whatever the
/// discovery hands over. Session queue only. Logs never carry titles.
public final class DiscoveryService: @unchecked Sendable {
    public struct Context {
        /// Gio's own pid: never registered.
        public var ownPID: pid_t
        public var registry: () -> WindowRegistry
        public var manager: () -> WorkspaceManager
        /// Mutates the session's workspace manager in place.
        public var updateManager: ((inout WorkspaceManager) -> Void) -> Void
        public var rules: () -> [WindowRule]
        /// Full scan (nil pid) or one process; nil when the scan failed.
        public var discoverAll: (pid_t?) -> SystemWindowDiscoveryResult?
        /// Classify one element; nil when ignored or not readable yet.
        public var discoverOne: (AXUIElement, pid_t) -> DiscoveredSystemWindow?
        /// The registered window behind an AX element, if any.
        public var knownWindow: (AXUIElement, pid_t) -> WindowID?
        /// Retain the window's AX handles for the actuator.
        public var registerHandles: (WindowID, DiscoveredSystemWindow) -> Void
        /// Subscribe to the new window's own notifications.
        public var watchWindow: (AXUIElement, pid_t) -> Void
        /// Main screen height (AX <-> Cocoa flip).
        public var displayHeight: () -> CGFloat
        public var isRunning: (pid_t) -> Bool
        public var frontmostPID: () -> pid_t?
        /// A click explaining focus right now (the focus events own it then).
        public var currentClick: () -> MouseClick?
        public var adoptFocus: (WindowID, FocusSource) -> Void
        public var invalidateTrust: (WindowID) -> Void
        /// A new id: tileability, learned minimum size and trust start over.
        public var resetWindowState: (WindowID) -> Void
        /// A purged id: every per-window book forgets it (after the registry).
        public var forgetWindow: (WindowID) -> Void
        /// PA-05: tear down a terminated app's write lane and cached name.
        public var forgetApp: (pid_t) -> Void
        public var reflowAll: () -> Void
        // Display topology.
        public var displaySnapshots: () -> [DisplaySnapshot]
        public var knownDisplayIDs: () -> [DisplayID]
        public var connectDisplay: (DisplaySnapshot, WorkspaceID) -> Void
        public var disconnectDisplay: (DisplayID) -> Void
        /// MM-01: usable frame of every connected display (startup windows
        /// land on the display holding most of them).
        public var displayFrames: () -> [DisplayID: CGRect]
        /// The global AX flip height (the primary display's height).
        public var updateDisplayHeight: (CGFloat) -> Void
        /// Topology changed: nothing placed before it is trusted.
        public var displaysChanged: () -> Void
        /// NA-02: a visible (not minimized) window was registered; the next
        /// animated pass lets it enter from below its tile.
        public var windowOpened: (WindowID) -> Void
        /// NA-03: windows about to be purged, while their record, frame and
        /// cached image still exist (the optional close ghost).
        public var windowsClosing: ([WindowID]) -> Void
        /// NW-02: an arrival switched the user to its named workspace; the
        /// host requests the keyboard focus intent (argument: the window
        /// focused before the switch).
        public var followArrival: (WindowID?) -> Void
        /// PF-02: classify one appeared element and say why it failed (an
        /// unreadable frame retries sooner). Nil: `discoverOne` decides and
        /// a failure keeps the original retry schedule.
        public var discoverAttempt: ((AXUIElement, pid_t) -> SingleWindowDiscovery)?
        /// PF-02: session uptime, for the open timeline.
        public var now: () -> TimeInterval
        /// PF-02: a window was registered; its timings start the host's
        /// open timeline (`WindowOpenTimeline`).
        public var windowRegistered: (WindowOpenTiming) -> Void
        /// Required, no default: a test fixture that forgot it used to write
        /// its retry lines (fake `pid=7`) into the user's real log file.
        public var log: (LogLevel, String) -> Void
        public var allowsWindowWork: () -> Bool

        public init(
            ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
            registry: @escaping () -> WindowRegistry, manager: @escaping () -> WorkspaceManager,
            updateManager: @escaping ((inout WorkspaceManager) -> Void) -> Void,
            rules: @escaping () -> [WindowRule],
            discoverAll: @escaping (pid_t?) -> SystemWindowDiscoveryResult?,
            discoverOne: @escaping (AXUIElement, pid_t) -> DiscoveredSystemWindow?,
            knownWindow: @escaping (AXUIElement, pid_t) -> WindowID?,
            registerHandles: @escaping (WindowID, DiscoveredSystemWindow) -> Void,
            watchWindow: @escaping (AXUIElement, pid_t) -> Void,
            displayHeight: @escaping () -> CGFloat, isRunning: @escaping (pid_t) -> Bool,
            frontmostPID: @escaping () -> pid_t?, currentClick: @escaping () -> MouseClick?,
            adoptFocus: @escaping (WindowID, FocusSource) -> Void,
            invalidateTrust: @escaping (WindowID) -> Void, resetWindowState: @escaping (WindowID) -> Void,
            forgetWindow: @escaping (WindowID) -> Void, forgetApp: @escaping (pid_t) -> Void,
            reflowAll: @escaping () -> Void,
            displaySnapshots: @escaping () -> [DisplaySnapshot], knownDisplayIDs: @escaping () -> [DisplayID],
            connectDisplay: @escaping (DisplaySnapshot, WorkspaceID) -> Void,
            disconnectDisplay: @escaping (DisplayID) -> Void, displayFrames: @escaping () -> [DisplayID: CGRect],
            updateDisplayHeight: @escaping (CGFloat) -> Void, displaysChanged: @escaping () -> Void,
            windowOpened: @escaping (WindowID) -> Void = { _ in },
            windowsClosing: @escaping ([WindowID]) -> Void = { _ in },
            followArrival: @escaping (WindowID?) -> Void = { _ in },
            discoverAttempt: ((AXUIElement, pid_t) -> SingleWindowDiscovery)? = nil,
            now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            windowRegistered: @escaping (WindowOpenTiming) -> Void = { _ in },
            log: @escaping (LogLevel, String) -> Void,
            allowsWindowWork: @escaping () -> Bool = { true }
        ) {
            self.allowsWindowWork = allowsWindowWork
            self.followArrival = followArrival
            self.discoverAttempt = discoverAttempt
            self.now = now
            self.windowRegistered = windowRegistered
            self.log = log
            self.ownPID = ownPID
            self.registry = registry
            self.manager = manager
            self.updateManager = updateManager
            self.rules = rules
            self.discoverAll = discoverAll
            self.discoverOne = discoverOne
            self.knownWindow = knownWindow
            self.registerHandles = registerHandles
            self.watchWindow = watchWindow
            self.displayHeight = displayHeight
            self.isRunning = isRunning
            self.frontmostPID = frontmostPID
            self.currentClick = currentClick
            self.adoptFocus = adoptFocus
            self.invalidateTrust = invalidateTrust
            self.resetWindowState = resetWindowState
            self.forgetWindow = forgetWindow
            self.forgetApp = forgetApp
            self.reflowAll = reflowAll
            self.displaySnapshots = displaySnapshots
            self.knownDisplayIDs = knownDisplayIDs
            self.connectDisplay = connectDisplay
            self.disconnectDisplay = disconnectDisplay
            self.displayFrames = displayFrames
            self.updateDisplayHeight = updateDisplayHeight
            self.displaysChanged = displaysChanged
            self.windowOpened = windowOpened
            self.windowsClosing = windowsClosing
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var nextElementID: UInt64 = 0
    /// NW-06: apps launched moments ago (their first window may appear
    /// before they are frontmost).
    private var recentLaunches = RecentLaunches()
    /// NW-06: `when-active` arrivals placed silently, awaiting their app's
    /// activation.
    private var pendingFollows = PendingFollowBook()
    /// PF-B: elements whose registration retries all failed, and when they
    /// may be classified again (`WindowRegistrationRetry.abandonCooldown`).
    /// Matched with `CFEqual`; expired entries are dropped on every check.
    private var abandoned: [(element: AXUIElement, until: TimeInterval)] = []
    /// WR-01: untitled arrivals awaiting their one title re-check.
    private var titleRechecks = TitleRecheckBook()
    /// MM-04: the latest screen-parameter notification; only its one-shot syncs.
    private var displayChangeGeneration = 0

    /// MM-04: macOS posts several screen-parameter notifications per
    /// connect, disconnect or arrangement change; the burst syncs once,
    /// this long after its last notification.
    public static let displayChangeDelay: TimeInterval = 0.25

    public init(context: Context, scheduler: SessionScheduler) {
        self.context = context
        self.scheduler = scheduler
    }

    // MARK: Scan

    /// Enumerate, register arrivals (rules decide mode and workspace),
    /// refresh handles. Identity is stable across scans: retained handles
    /// matched with `CFEqual` reuse their IDs (and refresh metadata);
    /// only genuinely new windows get fresh IDs and placed columns.
    /// Add-only: disappearance is handled by reaping dead pids below,
    /// never by absence alone.
    ///
    /// `onlyPID` restricts the scan to one process (a freshly launched app):
    /// the dead-pid reap is skipped then, since absence from a partial
    /// scan proves nothing.
    public func enumerateAndPlace(onlyPID: pid_t? = nil) {
        guard context.allowsWindowWork() else {
            return
        }
        guard let found = context.discoverAll(onlyPID) else {
            return
        }
        let registry = context.registry()
        let flip = AXVerticalFlip(displayHeight: context.displayHeight())
        // MM-01: a full scan (startup, resync) places each new window on the
        // display it sits on; a launch scan is a live arrival (focused display).
        let placement = onlyPID == nil ? context.displayFrames() : nil
        var liveIDs = Set<WindowID>()
        var focusCandidates: [FocusCandidate] = []
        // Minimized windows are candidates too: they stay registered (and
        // keep their column) but sit out of the layout.
        for candidate in found.windows + found.floating {
            if let known = context.knownWindow(candidate.element, candidate.window.pid) {
                liveIDs.insert(known)
                if var record = registry.find(known) {
                    if !candidate.window.isMinimized {
                        record.frame = flip.toCocoa(candidate.window.frame)
                    }
                    if let title = candidate.window.title, !title.isEmpty {
                        record.title = title
                    }
                    try? registry.update(record)
                    // A missed minimize/deminimize event heals here.
                    if record.isMinimized != candidate.window.isMinimized {
                        applyMinimized(candidate.window.isMinimized, to: known)
                    }
                }
                focusCandidates.append(FocusCandidate(
                    id: known, isFocused: candidate.window.isFocused,
                    isMinimized: candidate.window.isMinimized
                ))
                continue
            }
            // NW-02: a launched app's windows may take the user to their
            // workspace; a full scan (startup, resync) only places them.
            if let id = registerNew(candidate, mayFollow: onlyPID != nil, placement: placement) {
                liveIDs.insert(id)
            }
        }
        // Clicks change macOS focus behind our back: adopt the observed
        // focus instead of fighting it on the next reflow. Every app reports
        // a focused window; only the frontmost app's is the user's.
        // A click in flight is the focus events' business (they validate
        // it against the click point), never the rescan's.
        if context.currentClick() == nil,
           let focusedID = adoptableFocus(
               among: focusCandidates,
               frontmostPID: context.frontmostPID()
           )
        {
            context.adoptFocus(focusedID, .rescan)
        }
        if onlyPID == nil {
            reapDeadPids(live: liveIDs)
        }
        // Fallback for destroyed events whose element match failed: windows
        // of a fully-read pid that the scan no longer lists are gone.
        purge(vanishedWindowIDs(
            registered: registry.managedWindows(),
            scannedPIDs: found.completePIDs,
            present: liveIDs
        ))
    }

    /// A launched app's observer attached: register its windows, reflow.
    public func appAttached(_ pid: pid_t) {
        guard context.allowsWindowWork() else {
            return
        }
        enumerateAndPlace(onlyPID: pid)
        context.reflowAll()
    }

    /// NW-06: an app was launched (its first windows may take the user to
    /// their named workspace even before it is frontmost).
    public func appLaunched(_ pid: pid_t) {
        recentLaunches.record(pid, at: context.now())
    }

    /// NW-06: an app became active. Its window placed silently on a hidden
    /// named workspace moments ago takes the user there now, unless the
    /// user moved (workspace or focus) since, or the window is minimized.
    public func appActivated(_ pid: pid_t) {
        guard context.allowsWindowWork(),
              let pending = pendingFollows.activated(pid: pid, now: context.now()),
              context.registry().find(pending.id)?.isMinimized == false
        else {
            return
        }
        var previousFocus: WindowID?
        var followed = false
        context.updateManager { manager in
            guard pendingFollowStillWanted(
                pending, currentWorkspace: manager.currentID, currentFocus: manager.currentWorkspace().focusedWindow
            ),
                let dest = manager.workspace(id: pending.workspace),
                let focused = adoptingFocus(pending.id, in: dest)
            else {
                return
            }
            previousFocus = manager.currentWorkspace().focusedWindow
            manager.update(focused)
            followed = manager.focus(pending.workspace)
        }
        guard followed else {
            context.log(.debug, "window follow cancelled id=\(pending.id.pid):\(pending.id.elementID) reason=userMoved")
            return
        }
        context.log(.info, "window follow deferred id=\(pending.id.pid):\(pending.id.elementID) reason=activated")
        context.followArrival(previousFocus)
        context.reflowAll()
    }

    /// Terminate is proof of death (the observer is already detached): reap
    /// the app's windows and its write lane, reflow now.
    public func appTerminated(_ pid: pid_t) {
        let ids = context.registry().managedWindows().map(\.id).filter { $0.pid == pid }
        // PA-05: tear down the app's persistent write lane and cached name.
        context.forgetApp(pid)
        purge(ids)
        context.reflowAll()
    }

    public func applyMinimized(_ minimized: Bool, to id: WindowID) {
        context.invalidateTrust(id)
        let registry = context.registry()
        context.updateManager { manager in
            if minimized {
                minimizeWindow(id, registry: registry, manager: &manager)
            } else {
                restoreWindow(id, registry: registry, manager: &manager)
            }
        }
    }

    // MARK: Registration

    /// A window appeared after startup (created or deminiaturized): classify
    /// it with the admission rules, register it, reflow at once. Attributes
    /// of a brand-new window are often unreadable for a moment, so an
    /// unclassifiable element is retried a few times. Minimized windows
    /// register too (out of the layout until deminimized).
    /// PF-02: `deliveredAt` is when the created event reached the main
    /// thread (nil: unknown, e.g. focus adoption); the open timeline starts
    /// there, and the wait for the session queue and the classification
    /// time are measured apart. An element whose frame alone is unreadable
    /// retries sooner, and every retry is logged.
    public func registerAppeared(_ element: AXUIElement, pid: pid_t, deliveredAt: TimeInterval? = nil) {
        let start = context.now()
        let clock = RegistrationClock(
            createdAt: deliveredAt ?? start,
            queueWait: deliveredAt.map { max(0, start - $0) } ?? 0,
            classify: 0
        )
        attemptRegistration(element, pid: pid, attempt: 0, clock: clock)
    }

    /// PF-02: the open timeline of one appeared element across its attempts.
    private struct RegistrationClock: Sendable {
        var createdAt: TimeInterval
        var queueWait: TimeInterval
        var classify: TimeInterval
    }

    private func attemptRegistration(_ element: AXUIElement, pid: pid_t, attempt: Int, clock: RegistrationClock) {
        // Gio's own windows are never classified, registered or retried.
        guard pid != context.ownPID, context.allowsWindowWork() else {
            return
        }
        if context.knownWindow(element, pid) != nil {
            return
        }
        var clock = clock
        if attempt == 0, isAbandoned(element) {
            context.log(.debug, "window register skipped pid=\(pid) reason=recentlyAbandoned")
            return
        }
        let classifyStarted = context.now()
        let outcome: SingleWindowDiscovery
        if let discoverAttempt = context.discoverAttempt {
            outcome = discoverAttempt(element, pid)
        } else {
            outcome = context.discoverOne(element, pid).map { .found($0) } ?? .unclassified
        }
        clock.classify += max(0, context.now() - classifyStarted)
        let reason: WindowRegistrationFailure
        switch outcome {
        case .found(let candidate):
            registerNew(
                candidate, mayFollow: true, createdAt: clock.createdAt, retries: attempt,
                queueWait: clock.queueWait, classify: clock.classify
            )
            context.reflowAll()
            return
        case .frameUnreadable:
            reason = .frameUnreadable
        case .unclassified:
            reason = .unclassified
        case .gone:
            dropFinal(element, pid: pid, reason: .gone, attempts: attempt + 1)
            return
        case .rejected:
            dropFinal(element, pid: pid, reason: .rejected, attempts: attempt + 1)
            return
        }
        // A pid that is no longer (or never was) a running app has no window
        // to wait for: one debug line, no retry schedule.
        guard context.isRunning(pid) else {
            context.log(.debug, "window register dropped pid=\(pid) reason=notRunning attempts=\(attempt + 1)")
            return
        }
        guard let delay = WindowRegistrationRetry.delay(afterFailedAttempt: attempt, reason: reason) else {
            context.log(.info, "window register gave up pid=\(pid) attempts=\(attempt + 1) reason=\(reason.rawValue)")
            abandoned.append((element, context.now() + WindowRegistrationRetry.abandonCooldown))
            return
        }
        context.log(
            .info,
            "window register retry pid=\(pid) attempt=\(attempt + 1) reason=\(reason.rawValue)"
                + " delay ms=\(Int((delay * 1000).rounded()))"
        )
        scheduler.asyncAfter(delay) { [weak self, clock] in
            self?.attemptRegistration(element, pid: pid, attempt: attempt + 1, clock: clock)
        }
    }

    private func isAbandoned(_ element: AXUIElement) -> Bool {
        let now = context.now()
        abandoned.removeAll { $0.until <= now }
        return abandoned.contains { CFEqual($0.element, element) }
    }

    /// PF-E: a destroyed element or a readable rejection: one debug line and
    /// the cooldown, no retry round.
    private func dropFinal(_ element: AXUIElement, pid: pid_t, reason: WindowRegistrationFailure, attempts: Int) {
        context.log(.debug, "window register dropped pid=\(pid) reason=\(reason.rawValue) attempts=\(attempts)")
        abandoned.append((element, context.now() + WindowRegistrationRetry.abandonCooldown))
    }

    /// Register a genuinely new window: fresh ID, retained AX handles,
    /// rules and admission decide mode and workspace, a new column on the
    /// target workspace, and a per-window observer subscription. Nil (and
    /// nothing registered) for Gio's own pid. NW-02: an `open-on-workspace`
    /// rule sends it to that named workspace; when `mayFollow` (a live
    /// arrival) and the rule's follow policy agrees, the user goes there too.
    /// MM-01: with `placement` (a full scan's display frames), a window no
    /// rule routes lands on the display holding most of it, not the focused one.
    @discardableResult
    func registerNew(
        _ candidate: DiscoveredSystemWindow, mayFollow: Bool = false,
        placement: [DisplayID: CGRect]? = nil,
        createdAt: TimeInterval? = nil, retries: Int = 0,
        queueWait: TimeInterval = 0, classify: TimeInterval = 0
    ) -> WindowID? {
        // Discovery already filters Gio's own pid; never trust that alone.
        guard candidate.window.pid != context.ownPID else {
            return nil
        }
        nextElementID += 1
        let id = WindowID(pid: candidate.window.pid, elementID: nextElementID)
        context.registerHandles(id, candidate)
        var window = ManagedWindow(
            id: id, pid: candidate.window.pid,
            application: candidate.window.appName,
            bundleID: candidate.window.bundleID,
            title: candidate.window.title ?? "",
            frame: AXVerticalFlip(displayHeight: context.displayHeight()).toCocoa(candidate.window.frame),
            mode: .tiled,
            isMinimized: candidate.window.isMinimized
        )
        let rules = context.rules()
        let outcome = evaluateRules(rules, app: window.application, bundleID: window.bundleID, title: window.title)
        window.mode = outcome.mode ?? .tiled
        window.widthLimits = outcome.widthLimits
        if outcome.mode == .floating {
            window.floatReason = .rule
        } else if let admitted = candidate.floatReason {
            // Discovery floated it (dialog, panel, fixed size): managed
            // and visible, never moved by the layout.
            window.mode = .floating
            window.floatReason = admitted
        }
        context.resetWindowState(id)
        try? context.registry().register(window)
        let minimized = window.isMinimized
        let now = context.now()
        if titleRecheckWanted(rules: rules, title: window.title) {
            titleRechecks.arm(id, at: now)
        }
        // NW-02/NW-06: only a live, visible arrival routed to a named
        // workspace may take the user there; WR-04: never one that must
        // not take focus.
        let decision: ArrivalFollowDecision = mayFollow && !minimized && outcome.openFocused
            && outcome.openOnWorkspace != nil
            ? decideArrivalFollow(
                outcome.follow, windowPID: window.pid, frontmostPID: context.frontmostPID(),
                launchedAt: recentLaunches.launchedAt(window.pid, now: now), now: now
            )
            : .stay
        var previousFocus: WindowID?
        var followed = false
        var pending: PendingArrivalFollow?
        var destinationShown = false
        var workspaceLabel = ""
        context.updateManager { manager in
            let display = placement.flatMap { displayFor(frame: window.frame, displays: $0) }
            // A floating arrival (a dialog, or a transient popup such as
            // Chrome's address-bar suggestions, re-created on every key) must
            // not take the strip's focus: closing it would leave the focus on
            // the last column. If the OS focuses it, focus adoption follows.
            // WR-04: neither does an `open-focused = false` arrival.
            let destID = placeArrival(
                id, outcome: outcome,
                takesFocus: arrivalTakesFocus(outcome, mode: window.mode, minimized: minimized),
                onDisplay: display, manager: &manager
            )
            destinationShown = manager.activeIDs.contains(destID)
            workspaceLabel = manager.workspace(id: destID)?.name
                ?? manager.location(of: destID).map { "\($0.index + 1)" } ?? "?"
            guard decision != .stay,
                  manager.namedWorkspaceID(outcome.openOnWorkspace!) == destID, destID != manager.currentID
            else {
                return
            }
            if case .follow = decision {
                previousFocus = manager.currentWorkspace().focusedWindow
                followed = manager.focus(destID)
            } else {
                pending = PendingArrivalFollow(
                    id: id, workspace: destID, placedAt: now,
                    fromWorkspace: manager.currentID, fromFocus: manager.currentWorkspace().focusedWindow
                )
            }
        }
        if let pending {
            pendingFollows.add(pending)
        }
        if followed {
            if decision == .follow(.launched) {
                context.log(.info, "window follow deferred id=\(id.pid):\(id.elementID) reason=launched")
            }
            // PF-02: the switch starts in the pass this registration runs.
            context.followArrival(previousFocus)
        }
        context.watchWindow(candidate.element, candidate.window.pid)
        // PF-02: only an arrival on the shown workspace enters from below; a
        // hidden one is parked, a followed one rides the workspace switch.
        if planWindowOpenArrival(
            destinationShown: destinationShown, followed: followed, minimized: minimized
        ) == .enter {
            context.windowOpened(id)
        }
        // A live arrival only; a full scan (startup, resync) is not an open.
        guard mayFollow else {
            return id
        }
        let registeredAt = context.now()
        var timing = WindowOpenTiming(
            id: id, app: window.application, createdAt: createdAt ?? registeredAt, registeredAt: registeredAt,
            retries: retries, workspace: workspaceLabel, follow: followed
        )
        timing.queueWait = queueWait
        timing.classify = classify
        context.windowRegistered(timing)
        return id
    }

    /// WR-01: a registered window's title changed (the record already holds
    /// it). An arrival registered untitled is re-checked once, when its
    /// title first becomes non-empty within `TitleRecheckBook.window`: a
    /// title rule that now wins moves or reshapes it and sets its mode and
    /// width limits, never focusing or following. Logs carry the id only.
    public func titleChanged(_ id: WindowID) {
        guard context.allowsWindowWork(), let window = context.registry().find(id), !window.title.isEmpty,
              titleRechecks.take(id, now: context.now()),
              let outcome = titleRecheckOutcome(context.rules(), window: window)
        else {
            return
        }
        let registry = context.registry()
        context.updateManager { manager in
            applyTitleRecheck(id, outcome: outcome, registry: registry, manager: &manager)
        }
        context.log(.info, "window rule recheck id=\(id.pid):\(id.elementID) reason=titleArrived")
        context.reflowAll()
    }

    // MARK: Purge

    /// Remove records whose process is gone (proof, not absence) from the
    /// registry and every workspace. Present-but-unlisted windows survive:
    /// enumeration gaps must never read as deaths.
    private func reapDeadPids(live: Set<WindowID>) {
        let livePIDs = Set(live.map(\.pid))
        let dead = context.registry().managedWindows()
            .map(\.id)
            .filter { !livePIDs.contains($0.pid) && !context.isRunning($0.pid) }
        guard !dead.isEmpty else {
            return
        }
        purge(dead)
    }

    /// Forget windows everywhere: registry, every workspace and every
    /// per-window book (tileability, sizes, echoes, trust, render checks,
    /// physical frames, zoom, probes, snapshots, fullscreen, AX handles).
    public func purge(_ ids: [WindowID]) {
        guard !ids.isEmpty else {
            return
        }
        let idSet = Set(ids)
        let registry = context.registry()
        context.windowsClosing(ids.sorted())
        for id in ids.sorted() {
            registry.remove(id)
            pendingFollows.forget(id)
            titleRechecks.forget(id)
            context.forgetWindow(id)
        }
        context.updateManager { manager in
            for candidate in manager.allWorkspaces {
                var workspace = candidate
                let before = workspace
                workspace.stripWindows(idSet)
                if workspace != before {
                    manager.update(workspace)
                }
            }
        }
    }

    // MARK: Displays

    /// MM-04: a screen-parameter notification (session queue). Coalesced:
    /// the displays sync, and the session relays out, once the burst is
    /// `displayChangeDelay` old.
    public func noteDisplayChange() {
        displayChangeGeneration += 1
        let generation = displayChangeGeneration
        scheduler.asyncAfter(Self.displayChangeDelay) { [weak self] in
            guard let self, generation == self.displayChangeGeneration else {
                return
            }
            self.syncDisplays()
            self.context.reflowAll()
        }
    }

    /// Each display owns a workspace stack: register them first so a
    /// vanished display's windows merge into a survivor before anything is
    /// laid out. MM-01: displays register in position order, and the
    /// primary display (Cocoa origin) is both the main display and the AX
    /// flip reference.
    public func syncDisplays() {
        let raw = context.displaySnapshots()
        let byID = Dictionary(raw.map { ($0.id, $0) }) { first, _ in first }
        let snapshot = displaysByPosition(byID.mapValues(\.frame)).compactMap { byID[$0] }
        // MM-04: macOS may list no screen for a moment mid-reconfiguration;
        // the manager ignores that, so the connected displays stay too.
        guard !snapshot.isEmpty else {
            context.log(.info, "displays count=0 ignored")
            return
        }
        let seen = Set(snapshot.map(\.id))
        let primary = primaryDisplayIndex(snapshot.map(\.frame)).map { snapshot[$0] }
        context.updateManager { $0.syncDisplays(snapshot.map(\.id), main: primary?.id) }
        for display in snapshot {
            let manager = context.manager()
            context.connectDisplay(display, manager.activeID(on: display.id) ?? manager.currentID)
        }
        for known in context.knownDisplayIDs() where !seen.contains(known) {
            context.disconnectDisplay(known)
        }
        if let primary {
            context.updateDisplayHeight(primary.frame.height)
        }
        logDisplays(snapshot, primary: primary)
        // A topology change can move windows behind our back and changes
        // every parking target: nothing placed before it is trusted.
        context.displaysChanged()
    }

    /// MM-04: the configuration every sync ends with (startup and each
    /// display change), and at debug the flip height the AX conversion uses.
    private func logDisplays(_ snapshot: [DisplaySnapshot], primary: DisplaySnapshot?) {
        let manager = context.manager()
        let numbers = displaysByNumber(Dictionary(snapshot.map { ($0.id, $0.frame) }) { first, _ in first })
        let entries = snapshot.map { display in
            DisplayLogEntry(
                id: display.id, frame: display.frame, visibleFrame: display.visibleFrame,
                scale: display.scale, refreshRate: display.refreshRate, isPrimary: display.id == primary?.id,
                number: (numbers.firstIndex(of: display.id) ?? 0) + 1,
                shownWorkspace: manager.activeID(on: display.id),
                stack: manager.stack(on: display.id).map(\.id)
            )
        }
        for line in displayConfigurationLog(entries) {
            context.log(.info, line)
        }
        if let primary {
            context.log(.debug, displayFlipLogLine(primaryHeight: primary.frame.height, primary: primary.id))
        }
    }
}
