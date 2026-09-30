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
        public var mainScreenFrame: () -> CGRect?
        public var updateDisplayHeight: (CGFloat) -> Void
        /// Topology changed: nothing placed before it is trusted.
        public var displaysChanged: () -> Void
        /// NA-02: a visible (not minimized) window was registered; the next
        /// animated pass lets it enter from below its tile.
        public var windowOpened: (WindowID) -> Void

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
            disconnectDisplay: @escaping (DisplayID) -> Void, mainScreenFrame: @escaping () -> CGRect?,
            updateDisplayHeight: @escaping (CGFloat) -> Void, displaysChanged: @escaping () -> Void,
            windowOpened: @escaping (WindowID) -> Void = { _ in }
        ) {
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
            self.mainScreenFrame = mainScreenFrame
            self.updateDisplayHeight = updateDisplayHeight
            self.displaysChanged = displaysChanged
            self.windowOpened = windowOpened
        }
    }

    private let context: Context
    private let scheduler: SessionScheduler
    private var nextElementID: UInt64 = 0

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
        guard let found = context.discoverAll(onlyPID) else {
            return
        }
        let registry = context.registry()
        let flip = AXVerticalFlip(displayHeight: context.displayHeight())
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
            if let id = registerNew(candidate) {
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
        enumerateAndPlace(onlyPID: pid)
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
    public func registerAppeared(_ element: AXUIElement, pid: pid_t, attempt: Int = 0) {
        if context.knownWindow(element, pid) != nil {
            return
        }
        if let candidate = context.discoverOne(element, pid) {
            registerNew(candidate)
            context.reflowAll()
        } else if let delay = WindowRegistrationRetry.delay(afterFailedAttempt: attempt) {
            scheduler.asyncAfter(delay) { [weak self] in
                self?.registerAppeared(element, pid: pid, attempt: attempt + 1)
            }
        }
    }

    /// Register a genuinely new window: fresh ID, retained AX handles,
    /// rules and admission decide mode and workspace, a new column on the
    /// target workspace, and a per-window observer subscription. Nil (and
    /// nothing registered) for Gio's own pid.
    @discardableResult
    func registerNew(_ candidate: DiscoveredSystemWindow) -> WindowID? {
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
            title: candidate.window.title ?? "",
            frame: AXVerticalFlip(displayHeight: context.displayHeight()).toCocoa(candidate.window.frame),
            mode: .tiled,
            isMinimized: candidate.window.isMinimized
        )
        let outcome = evaluateRules(context.rules(), app: window.application)
        window.mode = outcome.mode ?? .tiled
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
        context.updateManager { manager in
            if let wanted = outcome.workspace,
               let destID = manager.ruleTarget(wanted),
               destID != manager.currentID
            {
                var dest = manager.workspace(id: destID)!
                Self.appendColumn(id, to: &dest, focus: !minimized)
                manager.update(dest)
            } else {
                var current = manager.currentWorkspace()
                Self.appendColumn(id, to: &current, focus: !minimized)
                manager.update(current)
            }
        }
        context.watchWindow(candidate.element, candidate.window.pid)
        if !minimized {
            context.windowOpened(id)
        }
        return id
    }

    private static func appendColumn(_ id: WindowID, to workspace: inout Workspace, focus: Bool) {
        var column = Column(
            id: ColumnID((workspace.columns.map(\.id.rawValue).max() ?? 0) + 1),
            width: 0, windows: [id]
        )
        column.focusedWindowIndex = 0
        workspace.columns.append(column)
        if focus {
            workspace.focusedColumn = workspace.columns.count - 1
            workspace.focusedWindow = id
        }
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
        for id in ids.sorted() {
            registry.remove(id)
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

    /// Each display owns a workspace stack: register them first so a
    /// vanished display's windows merge into a survivor before anything is
    /// laid out.
    public func syncDisplays() {
        let snapshot = context.displaySnapshots()
        let seen = Set(snapshot.map(\.id))
        context.updateManager { $0.syncDisplays(snapshot.map(\.id)) }
        for display in snapshot {
            let manager = context.manager()
            context.connectDisplay(display, manager.activeID(on: display.id) ?? manager.currentID)
        }
        for known in context.knownDisplayIDs() where !seen.contains(known) {
            context.disconnectDisplay(known)
        }
        if let main = context.mainScreenFrame() {
            context.updateDisplayHeight(main.height)
        }
        // A topology change can move windows behind our back and changes
        // every parking target: nothing placed before it is trusted.
        context.displaysChanged()
    }
}
