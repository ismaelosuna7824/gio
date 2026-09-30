@preconcurrency import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import GioCore
import GioMacOS
import GioSession
import GioUI

/// The unified Gio session: persistent registry, workspaces, displays and
/// actuator behind one serial queue, serving IPC, AX events, display
/// changes and hotkeys. All mutations and reflows happen on `queue` —
/// callers hop on (async from UI/tap, sync from the IPC thread) and never
/// touch state directly. Nesting sync calls deadlocks: don't.
///
/// `@unchecked Sendable`: all session state mutates on `queue`; start/stop
/// run once on the main thread. Weak captures in `@Sendable` closures rely
/// on this discipline — review before adding shared state.
final class SessionHost: @unchecked Sendable {
    /// The session queue, reached through the scheduler seam components use.
    private let scheduler = QueueScheduler(queue: DispatchQueue(label: "gio.session"))
    private var queue: DispatchQueue {
        scheduler.queue
    }
    /// Mouse, frontmost app, main screen, running apps and the on-screen
    /// window list, read through one seam (concrete type: static dispatch).
    private let probe = LiveSystemProbe()
    private var session = CommandSession()
    private var displays = DisplayManager()
    private var actuator: AXWindowActuator?
    private var reconciler: WindowReconciler<AXWindowActuator>?
    private var server: IPCServer?
    private let instanceLock = SingleInstanceLock()
    private var eventObserver: SystemWindowObserver?
    /// The tap is created and restarted from the main thread but read from
    /// the session queue (`hotkeyTap == nil` checks), so it has its own lock.
    private var tapStorage: HotkeyTap?
    private let tapLock = NSLock()
    private var hotkeyTap: HotkeyTap? {
        get {
            tapLock.lock()
            defer { tapLock.unlock() }
            return tapStorage
        }
        set {
            tapLock.lock()
            tapStorage = newValue
            tapLock.unlock()
        }
    }
    /// Latest snapshot for the main thread. The session queue publishes it
    /// (start, config changes, every `snapshot()` request); main only reads,
    /// so it never waits behind a slow reflow (tap timeouts, dead hotkeys).
    private let snapshotCell = PublishedValue(SessionSnapshot())
    /// PA-02: menu bar state, pushed (deduplicated) after reflows and IPC
    /// commands instead of being polled over IPC.
    private var barPublisher: GatedStatePublisher<BarStateGate>!
    /// Overview facts (windows, displays, permissions) for the snapshot.
    private var factsBuilder: SessionFactsBuilder!
    /// Menu bar hook, always invoked on the main thread.
    var onBarState: ((BarSessionState?) -> Void)?
    private var displayObserver: NSObjectProtocol?
    private var pendingReflow: DispatchWorkItem?
    private var nextElementID: UInt64 = 0
    private var observationBook = ObservationBook()
    private var echoGate = WriteEchoGate()
    private var pendingFull = false
    private var tileability = TileabilityCache()
    /// FI-02: minimum sizes learned from clamped writes (session queue only).
    private var minimumSizes = MinimumSizeBook()
    /// PA-06: which apps take size writes during motion (keyed by app name).
    private var resizeCapability = ResizeCapability()
    private var fullscreen = FullscreenBook()
    private var visibleFrames: [DisplayID: CGRect] = [:]
    /// Config reload and edits, the hotkey table (its own lock) and the
    /// config messages for the Overview.
    private var configCoordinator: ConfigCoordinator!
    /// IPC requests on the session queue.
    private var ipcRouter: IPCRouter!
    private var isShuttingDown = false
    private var reflowDeferral = ReflowDeferral()
    /// MO-04: where each window physically is (last applied or sampled
    /// frame), the frame player and its display-rate timer. All on `queue`.
    private var physicalFrames: [WindowID: CGRect] = [:]
    private var player: MotionPlayer?
    private var motionTimer: DispatchSourceTimer?
    /// Diagnostics: the latest flight's animations (to find the FI-03 grows at
    /// the final pass), the sizes each window already reached and the live
    /// resize-latency probes, one short-lived timer each (session queue only).
    private var lastMotionAnimations: [WindowAnimation] = []
    private var resizeHistory = ResizeSizeHistory()
    private var resizeProbes: [WindowID: (size: CGSize, started: CGSize?, timer: DispatchSourceTimer)] = [:]
    /// Windows the resize probe learned to ignore (fixed size, not settable).
    private var resizeProbeGate = ResizeProbeGate()
    /// Native zoom: windows mid-zoom (not written by Gio), waiting for a
    /// verdict, or sitting at an accepted frame; the maximize toggle's pending
    /// request; the settle pollers, one short-lived timer per window (session queue).
    private var nativeZoom = NativeZoomBook()
    private var pendingZoomRequest: NativeZoomRequest?
    private var nativeZoomTimers: [WindowID: DispatchSourceTimer] = [:]
    /// Post-correction checks of native zooms (session queue only).
    private var zoomVerifications: [WindowID: ZoomVerification] = [:]
    private var zoomWindowServerIDs: [WindowID: UInt32] = [:]
    /// The next pass is written without motion: armed for the session's
    /// first layout (launch, `gio restart`), Accessibility regained, and a
    /// mouse-abandoned motion (session queue only).
    private var instantPlacement = InstantPlacementGate()
    /// FI-05: render verification: candidates, settled frames, nudges.
    private var renderVerifier: RenderVerifier!
    /// PA-04: frames Gio placed and verified; the final pass skips their AX
    /// read. Invalidated by non-echo frame events, minimize/restore, purge,
    /// failures, motions and display changes (session queue only).
    private var trustedFrames = TrustedFrames()
    /// SM-02: caches ScreenCaptureKit content between debug captures.
    private let snapshotCapturer = SnapshotCapturer()
    /// SM-02b: managed set the shareable content was last prefetched for, and
    /// whether a prefetch is running (session queue only).
    private var lastPrefetchedWindows: Set<WindowID>?
    private var prefetchInFlight = false
    /// SM-04: pre-captured window images, refreshed once after each settle
    /// (no periodic timer), the running overlay flight and its bookkeeping.
    /// All on the session queue.
    private var snapshotCache = SnapshotCache<CGImage>()
    private var flightGate = SnapshotFlightGate()
    private var flightIDs: Set<WindowID> = []
    private var flightDisplays: Set<Int> = []
    private var flightStartedAt: TimeInterval = 0
    private var flightWindows: Set<WindowID> = []
    private var flightCacheAgeMilliseconds = 0
    private var flightReflowScheduled = false
    private var cacheRefreshToken = 0
    private var cacheRefreshBusy = false
    private var cacheRefreshAgain = false
    /// SM-04 overlay hooks, set once by the app before `start()`. They are
    /// invoked on the session queue and hop to the main thread themselves.
    var overlayBegin: ((Int, SpringParameters, [SnapshotDisplayFlight]) -> Void)?
    var overlayRetarget: ((Int, [WindowID: CGRect], [SnapshotDisplayFlight]) -> Void)?
    var overlayEnd: ((Bool) -> Void)?
    /// Main thread: removes a running flight at once (mouse down); true when one ran.
    var overlayAbortForMouseDown: (() -> Bool)?
    /// Wallpaper backdrops, readable from any thread.
    var overlayWallpapers: WallpaperCache?
    /// Screens as the capture needs them (id, frame, scale), read on main.
    private var captureScreens: [SnapshotDisplay] = []
    private var capturePrimaryHeight: CGFloat = 1169
    /// PA-04: pids with windows in the running motion; their moved/resized
    /// events are our own writes and are dropped before any lookup.
    private var animatingPids: Set<pid_t> = []
    /// PA-04: parking plan of hidden windows, recomputed only when its inputs change.
    private struct InactiveParkKey: Equatable {
        var frames: [WindowID: CGRect]
        var display: CGRect
        var others: [CGRect]
    }
    private var inactiveParking = PlanMemo<InactiveParkKey, [WindowID: ParkedTarget]>()
    /// NC-06: the pre-hide frames of floating windows.
    private var hiddenBook = HiddenWindowBook()
    /// PA-03: screen frames + refresh rates, read on main (AppKit) at start
    /// and on every screen-parameter change; the session queue only reads
    /// this copy when a motion starts and never queries AppKit for it.
    private let refreshLock = NSLock()
    private var displayRefreshes: [DisplayRefresh] = []
    private var focusSettle = FocusSettle<FocusEvent>()
    /// HD-01: the window keyboard/IPC actions want focused (session queue only).
    private var focusIntent = FocusIntent()
    /// FI-06: rapid actions during a motion merge into one reflow per tick.
    private var reflowCoalescer = ReflowCoalescer()
    private let clickLock = NSLock()
    private var tappedClick: MouseClick?
    /// HD-04: centering asked by the last keyboard/IPC focus change (consumed
    /// by the next reflow), and whether the cursor should follow that focus.
    private var centerRequest: CenterRequest?
    private var warpAfterFocus = false
    /// Focused-grow: the window a sizing action (maximize, width preset) just
    /// resized; already frontmost, so it needs no focus intent. Consumed by the
    /// next reflow.
    private var sizingFocus: WindowID?
    /// HD-04 focus-follows-mouse. `hoverLock` guards the flag and the latest
    /// pointer location the main-thread tap hands over; the rest is on `queue`.
    private var hoverFocus = HoverFocus()
    private var hoverFrames: [WindowID: CGRect] = [:]
    private let hoverLock = NSLock()
    private var hoverEnabled = false
    private var hoverLocation: CGPoint?
    private var hoverScheduled = false

    /// One focus signal awaiting adoption. `element` is the window the
    /// event itself carried (focused-window changes), if any.
    private struct FocusEvent: Equatable {
        let source: FocusSource
        let pid: pid_t
        let element: AXUIElement?

        static func == (lhs: FocusEvent, rhs: FocusEvent) -> Bool {
            lhs.source == rhs.source && lhs.pid == rhs.pid
                && sameElement(lhs.element, rhs.element)
        }
    }

    /// NF-01: the focus ring. The session queue posts (reflow, focus
    /// adoption, every motion frame); at most one main-queue block pending.
    private var focusRing: FocusRingPublisher!
    /// Focus ring hook, always invoked on the main thread.
    var onFocusRing: ((FocusRingState) -> Void)?
    /// NF-06: the dim overlay, same hand-off as the ring; one coalesced
    /// recompute (one on-screen CGWindowList query), no timer at rest.
    private var focusDim: FocusDimPublisher!
    /// Dim overlay hook, always invoked on the main thread.
    var onFocusDim: ((FocusDimState) -> Void)?
    /// UI hook, always invoked on the main thread.
    var onSummonLauncher: (() -> Void)?
    /// `gio restart` (HD-05): invoked on the main thread shortly after the
    /// IPC reply left; the app shuts the session down and relaunches itself.
    var onRestart: (() -> Void)?

    /// Builds the components. Their contexts read host state on the session
    /// queue; `unowned` is safe because the host owns them and lives as long
    /// as the app.
    init() {
        focusRing = FocusRingPublisher(context: .init(
            session: { [unowned self] in session },
            physicalFrame: { [unowned self] in physicalFrames[$0] },
            displayFrames: { [unowned self] in displays.allDisplays().map(\.frame) },
            isFlightActive: { [unowned self] in flightGate.isActive },
            isZoomBusy: { [unowned self] in nativeZoom.isBusy($0) },
            isFullscreen: { [unowned self] in fullscreen.isFullscreen($0) },
            mainHop: mainQueueHop,
            deliver: { [unowned self] in onFocusRing?($0) }
        ))
        focusDim = FocusDimPublisher(
            context: .init(
                session: { [unowned self] in session },
                physicalFrame: { [unowned self] in physicalFrames[$0] },
                displays: { [unowned self] in displays.allDisplays() },
                isMotionActive: { [unowned self] in player?.isActive == true },
                isFlightActive: { [unowned self] in flightGate.isActive },
                isNativeZoomActive: { [unowned self] in
                    nativeZoom.hasInFlight || nativeZoom.hasResolved || !zoomVerifications.isEmpty
                },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                isShuttingDown: { [unowned self] in isShuttingDown },
                frontToBack: { [unowned self] in probe.windowServerWindows(displayHeight: mainHeight()) },
                mainHop: mainQueueHop,
                deliver: { [unowned self] in onFocusDim?($0) }
            ),
            scheduler: scheduler
        )
        barPublisher = GatedStatePublisher(gate: BarStateGate(), initial: nil, context: .init(
            isObserved: { [unowned self] in onBarState != nil },
            makeValue: { [unowned self] in parseBarStatus(queryStatus(session: session)) },
            mainHop: mainQueueHop,
            deliver: { [unowned self] in onBarState?($0) }
        ))
        factsBuilder = SessionFactsBuilder(context: .init(
            session: { [unowned self] in session },
            displays: { [unowned self] in displays.allDisplays() },
            visibleFrame: { [unowned self] in visibleFrames[$0] },
            configMessages: { [unowned self] in configCoordinator.messages },
            engine: { [unowned self] in engine() },
            tileableModes: { [unowned self] in tileableModes() },
            screenRecordingGranted: { hasScreenRecordingPermission() },
            accessibilityGranted: { hasAXPermission() },
            configFileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: { FileManager.default.homeDirectoryForCurrentUser.path },
            prefetchSnapshotContent: { [unowned self] in prefetchSnapshotContentIfNeeded(permissionGranted: $0) },
            log: { GioLog.record($0, $1) }
        ))
        renderVerifier = RenderVerifier(
            context: .init(
                isShuttingDown: { [unowned self] in isShuttingDown },
                isMotionActive: { [unowned self] in player?.isActive == true },
                isFlightActive: { [unowned self] in flightGate.isActive },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                isReady: { [unowned self] in reconciler != nil },
                visibleTargets: { [unowned self] in hoverFrames },
                viewports: { [unowned self] in displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame } },
                serverWindows: { [unowned self] in probe.windowServerWindows(displayHeight: mainHeight()) },
                nudge: { [unowned self] in reconciler?.nudge(steps: $0) ?? [] },
                recordEcho: { [unowned self] in echoGate.recordApplied($0, frame: $1, at: $2) },
                appName: { [unowned self] in appName($0) },
                log: { GioLog.record($0, $1) }
            ),
            scheduler: scheduler
        )
        configCoordinator = ConfigCoordinator(
            context: .init(
                session: { [unowned self] in session },
                reloadSession: { [unowned self] in dispatch(.reload, session: &session) },
                loadMessages: { loadGioConfig().messages },
                patchFile: { GioCore.applyConfigEdits($0) },
                applyLogLevel: { [unowned self] level in
                    GioLog.minimumLevel = level
                    actuator?.countsCalls = GioLog.minimumLevel <= .debug
                },
                invalidateConfigCaches: { [unowned self] in
                    inactiveParking.invalidate()
                    focusRing.resetGate()
                },
                setFocusFollowsMouse: { [unowned self] wanted in
                    hoverLock.lock()
                    hoverEnabled = wanted
                    hoverLock.unlock()
                },
                tapObservesMouseMoved: { [unowned self] in hotkeyTap?.observesMouseMoved },
                requestTapRestart: { [unowned self] in
                    DispatchQueue.main.async { [weak self] in
                        self?.restartTapForMouseSetting()
                    }
                },
                reapplyRules: { [unowned self] in reapplyRules() },
                reflow: { [unowned self] in reflowAll() },
                publishSnapshot: { [unowned self] in publishSnapshot() },
                publishFocusRing: { [unowned self] in publishFocusRing() },
                log: { GioLog.record($0, $1) }
            ),
            scheduler: scheduler
        )
        ipcRouter = IPCRouter(context: .init(
            focusedWindow: { [unowned self] in session.manager.currentWorkspace().focusedWindow },
            dispatch: { [unowned self] in dispatchIPC($0, session: &session, restartAvailable: true) },
            applyReloadedConfig: { [unowned self] in configCoordinator.applyReloadedConfig() },
            requestFocusIntent: { [unowned self] in requestFocusIntent(if: $0, previous: $1) },
            reflow: { [unowned self] in reflowAll() },
            publishBar: { [unowned self] in barPublisher.publish() },
            mainAfter: { delay, block in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) },
            restart: { [weak self] in self?.onRestart?() },
            log: { GioLog.record($0, $1) }
        ))
    }

    // MARK: - Lifecycle

    /// Starts everything. Returns an error message instead of starting when
    /// another instance holds the lock or the socket cannot bind.
    private var guardian: GuardianHandle?

    func start() -> String? {
        // A relaunched instance waits a few seconds for its predecessor's lock.
        guard instanceLock.acquire(
            path: defaultLockPath(), wait: .forLaunch(arguments: CommandLine.arguments)
        ) else {
            return "another Gio instance is running"
        }
        let (config, configMessages) = loadGioConfig()
        session.config = config
        GioLog.minimumLevel = config.logging.level
        publishDisplayRefreshes()
        configCoordinator.refreshDispatcher()
        configCoordinator.setMessages(configMessages)
        for message in configMessages {
            print("[gio] config: \(message)")
        }
        if !hasAXPermission() {
            print("[gio] requesting Accessibility permission…")
            _ = requestAXPermission()
        }
        let server = IPCServer(socketPath: defaultSocketPath()) { [weak self] argv in
            guard let self else {
                return IPCResponse(ok: false, error: "shutting down")
            }
            return self.queue.sync {
                self.ipcRouter.handle(argv)
            }
        }
        do {
            try server.start()
        } catch {
            return "cannot serve IPC: \(error)"
        }
        self.server = server
        GioLog.record(.info, "session started")
        guardian = spawnGuardian()
        queue.sync {
            self.initialSync()
        }
        watchDisplays()
        queue.sync {
            self.rebuildEventObservation()
            self.publishSnapshot()
        }
        startTap()
        return nil
    }

    /// Gio is exiting (Quit, SIGTERM/SIGINT/SIGHUP): stop laying out, bring
    /// every parked or off-screen window back on screen through the
    /// reconciler, release the socket and lock. Idempotent and synchronous,
    /// so it is safe to call from both the terminate hook and a signal.
    func shutdown() {
        queue.sync {
            guard !isShuttingDown else {
                return
            }
            isShuttingDown = true
            pendingReflow?.cancel()
            stopMotion()
            endSnapshotFlight(fadeOut: false)
            snapshotCache.removeAll()
            reconciler?.waitForMotionIdle(timeout: 0.3)
            restoreOffscreenWindows(session.registry.managedWindows().filter { !$0.isMinimized }.map(\.id))
        }
        server?.stop()
        instanceLock.release()
        // Windows are back on screen: the guardian has nothing to rescue.
        guardian?.signalClean()
        GioLog.flush()
    }

    @discardableResult
    private func restoreOffscreenWindows(_ ids: [WindowID]) -> ReconcileReport? {
        guard let actuator, !ids.isEmpty else {
            return nil
        }
        return WindowReconciler(actuator: actuator)
            .restoreOffscreen(ids: ids, displays: restoreDisplays())
    }

    /// Diagnostics action: same restore the quit path runs, without
    /// quitting. Tiling stays active, so the next reflow re-parks
    /// off-viewport columns; this is a rescue, not a pause. Asynchronous:
    /// the main thread never waits on the session queue. `completion` gets
    /// how many windows were moved, on the main queue.
    func restoreAllWindows(completion: @escaping @Sendable (Int) -> Void = { _ in }) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            pendingReflow?.cancel()
            stopMotion()
            endSnapshotFlight(fadeOut: false)
            reconciler?.waitForMotionIdle(timeout: 0.3)
            let ids = session.registry.managedWindows().filter { !$0.isMinimized }.map(\.id)
            let moved = restoreOffscreenWindows(ids)?.applied.count ?? 0
            GioLog.record(.info, "restore-all requested from the app moved=\(moved)")
            publishSnapshot()
            DispatchQueue.main.async {
                completion(moved)
            }
        }
    }

    /// SM-02b: refreshes the ScreenCaptureKit content in the background at
    /// session start and whenever the managed window set changes, so motion
    /// requests do not pay the fetch inside their budget. Must run on `queue`.
    private func prefetchSnapshotContentIfNeeded(permissionGranted: Bool) {
        let managed = Set(session.registry.managedWindows().map(\.id))
        guard shouldPrefetchShareableContent(
            managed: managed, lastPrefetched: lastPrefetchedWindows,
            permissionGranted: permissionGranted, inFlight: prefetchInFlight
        ) else {
            return
        }
        lastPrefetchedWindows = managed
        prefetchInFlight = true
        Task.detached { [snapshotCapturer, weak self] in
            await snapshotCapturer.prefetch(managed: managed)
            self?.queue.async { self?.prefetchInFlight = false }
        }
    }

    /// SM-02 debug action (Diagnostics): captures the visible managed windows
    /// and a backdrop once, logs the summary and hands it back on the main
    /// queue. Never runs from a motion; images are released on return. The
    /// session queue only reads bookkeeping, the capture runs in a task.
    func testSnapshotCapture(completion: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            guard hasScreenRecordingPermission() else {
                DispatchQueue.main.async { completion("Screen Recording is missing: grant it first.") }
                return
            }
            let displayFrames = displays.allDisplays().map(\.frame)
            var frames: [WindowID: CGRect] = [:]
            for window in session.registry.managedWindows() where !window.isMinimized {
                if let frame = physicalFrames[window.id], displayFrames.contains(where: { $0.intersects(frame) }) {
                    frames[window.id] = frame
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                let screens = NSScreen.screens.compactMap { screen -> SnapshotDisplay? in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                    else {
                        return nil
                    }
                    return SnapshotDisplay(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
                }
                let request = SnapshotCaptureRequest(
                    windows: frames, displays: screens,
                    primaryDisplayHeight: NSScreen.screens.first?.frame.height ?? 1169,
                    measure: true
                )
                Task.detached { [snapshotCapturer] in
                    let result = await snapshotCapturer.capture(request)
                    let summary = result.summary
                    let detail = result.measurement.map { "\n" + $0.report } ?? ""
                    DispatchQueue.main.async { completion(summary.logLine + detail) }
                }
            }
        }
    }

    /// Launcher / window-id focus (HD-06): switch to the window's workspace if
    /// needed, adopt it as the focus, and let the reflow reveal it and apply
    /// the keyboard focus intent. False when the window is gone or minimized.
    func focusWindow(_ text: String) -> Bool {
        // The verdict comes from the published snapshot so the main thread
        // never waits on the session queue; the queue re-checks for real.
        guard let id = WindowID(text: text),
              snapshotCell.read().facts?.windows.contains(where: {
                  $0.id == text && !$0.isMinimized
              }) == true
        else {
            return false
        }
        queue.async { [weak self] in
            guard let self, !isShuttingDown,
                  let plan = planFocusWindow(id, in: session.manager),
                  session.registry.find(id)?.isMinimized != true
            else {
                return
            }
            let previous = session.manager.currentWorkspace().focusedWindow
            if plan.switchesWorkspace {
                _ = session.manager.focus(plan.workspace.id)
                syncShownWorkspace()
            }
            session.manager.update(plan.workspace)
            requestFocusIntent(if: true, previous: previous)
            GioLog.record(
                .info,
                "focus window requested id=\(id.pid):\(id.elementID) workspace=\(plan.index) switched=\(plan.switchesWorkspace)"
            )
            reflowAll()
        }
        return true
    }

    /// Same effect as the IPC `reload` verb, driven by the app.
    func reloadConfig() {
        configCoordinator.reloadFromApp()
    }

    /// Main thread. Re-creates the tap with the current mouse-move setting.
    private func restartTapForMouseSetting() {
        guard let tap = hotkeyTap else {
            return
        }
        hoverLock.lock()
        let wanted = hoverEnabled
        hoverLock.unlock()
        guard tapNeedsRestart(observingMouseMoved: tap.observesMouseMoved, wanted: wanted) else {
            return
        }
        tap.stop()
        hotkeyTap = nil
        startTap()
        GioLog.record(.info, "hotkey tap restarted mouse-moved=\(wanted)")
    }

    /// Read-only state for the main window. Never waits on the session
    /// queue: returns the last published snapshot and asks the queue for a
    /// fresh one (visible on the next call; the UI polls every 2-3 s).
    func snapshot() -> SessionSnapshot {
        queue.async { [weak self] in
            self?.publishSnapshot()
        }
        return snapshotCell.read()
    }

    /// Last published menu bar state; never waits on the session queue.
    func barState() -> BarSessionState? {
        barPublisher.read()
    }

    /// Ask the session for one initial publication (after the hook is set).
    func requestBarState() {
        queue.async { [weak self] in
            self?.barPublisher.publish()
        }
    }

    /// Must run on `queue`.
    private func publishSnapshot() {
        snapshotCell.publish(
            SessionSnapshot(
                keybindings: session.config.keybindings, facts: factsBuilder.facts(), config: session.config
            )
        )
    }

    /// Patch config.toml from the app, then reload it exactly like the IPC
    /// `reload` verb. Nothing is reloaded when the edit is rejected.
    func applyConfigEdits(_ edits: [ConfigEdit]) -> Result<PatchedConfig, ConfigErrors> {
        configCoordinator.applyConfigEdits(edits)
    }

    /// Post the focus ring (and refresh the dim) for the focused window of
    /// the current workspace. Session queue; cheap enough for every frame.
    private func publishFocusRing() {
        focusDim.update()
        focusRing.publish()
    }

    // MARK: - Sync

    private func mainHeight() -> CGFloat {
        probe.mainScreenHeight
    }

    private func initialSync() {
        if actuator == nil {
            actuator = AXWindowActuator(displayHeight: mainHeight())
        }
        actuator?.countsCalls = GioLog.minimumLevel <= .debug
        enumerateAndPlace()
        syncDisplays()
        // The first layout is instant (`instantPlacement` starts armed for
        // `.startup`): windows land on their tiles instead of flying there.
        // Leftovers of a crashed session: windows that will not be tiled
        // (floating, excluded) may still sit parked off-screen. Tiled ones
        // are re-placed by the first reflow.
        _ = tileableModes()
        restoreOffscreenWindows(
            session.registry.managedWindows()
                .filter { $0.mode != .tiled && !$0.isMinimized }
                .map(\.id)
        )
        reflowAll()
    }

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
    private func enumerateAndPlace(onlyPID: pid_t? = nil) {
        guard let found = try? discoverSystemWindows(onlyPID: onlyPID) else {
            return
        }
        let flip = AXVerticalFlip(displayHeight: mainHeight())
        var liveIDs = Set<WindowID>()
        var focusCandidates: [FocusCandidate] = []
        // Minimized windows are candidates too: they stay registered (and
        // keep their column) but sit out of the layout.
        for candidate in found.windows + found.floating {
            if let known = actuator?.id(
                matching: candidate.element, pid: candidate.window.pid
            ) {
                liveIDs.insert(known)
                if var record = session.registry.find(known) {
                    if !candidate.window.isMinimized {
                        record.frame = flip.toCocoa(candidate.window.frame)
                    }
                    if let title = candidate.window.title, !title.isEmpty {
                        record.title = title
                    }
                    try? session.registry.update(record)
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
            liveIDs.insert(registerNew(candidate))
        }
        // Clicks change macOS focus behind our back: adopt the observed
        // focus instead of fighting it on the next reflow. Every app reports
        // a focused window; only the frontmost app's is the user's.
        // A click in flight is the focus events' business (they validate
        // it against the click point), never the rescan's.
        if currentClick() == nil,
           let focusedID = adoptableFocus(
               among: focusCandidates,
               frontmostPID: probe.frontmostPID
           )
        {
            adoptFocus(focusedID, source: .rescan)
        }
        if onlyPID == nil {
            reapDeadPids(live: liveIDs)
        }
        // Fallback for destroyed events whose element match failed: windows
        // of a fully-read pid that the scan no longer lists are gone.
        purge(vanishedWindowIDs(
            registered: session.registry.managedWindows(),
            scannedPIDs: found.completePIDs,
            present: liveIDs
        ))
    }

    private func applyMinimized(_ minimized: Bool, to id: WindowID) {
        trustedFrames.invalidate(id)
        if minimized {
            minimizeWindow(id, registry: session.registry, manager: &session.manager)
        } else {
            restoreWindow(id, registry: session.registry, manager: &session.manager)
        }
    }

    /// Config reload: rule-owned floats follow the new rules. Workspace
    /// assignment is not re-applied (rules place windows at arrival only).
    private func reapplyRules() {
        for change in reevaluateRules(session.config.rules, windows: session.registry.managedWindows()) {
            switch change {
            case .float(let id):
                try? session.registry.setFloating(.rule, for: id)
            case .tile(let id):
                try? session.registry.setMode(.tiled, for: id)
                tileability.invalidate(id)
            }
        }
    }

    /// Register a genuinely new window: fresh ID, retained AX handles,
    /// rules and admission decide mode and workspace, a new column on the
    /// target workspace, and a per-window observer subscription.
    @discardableResult
    private func registerNew(_ candidate: DiscoveredSystemWindow) -> WindowID {
        nextElementID += 1
        let id = WindowID(pid: candidate.window.pid, elementID: nextElementID)
        actuator?.register(
            elementID: id.elementID, pid: id.pid,
            element: candidate.element, appElement: candidate.appElement
        )
        var window = ManagedWindow(
            id: id, pid: candidate.window.pid,
            application: candidate.window.appName,
            title: candidate.window.title ?? "",
            frame: AXVerticalFlip(displayHeight: mainHeight()).toCocoa(candidate.window.frame),
            mode: .tiled,
            isMinimized: candidate.window.isMinimized
        )
        let outcome = evaluateRules(session.config.rules, app: window.application)
        window.mode = outcome.mode ?? .tiled
        if outcome.mode == .floating {
            window.floatReason = .rule
        } else if let admitted = candidate.floatReason {
            // Discovery floated it (dialog, panel, fixed size): managed
            // and visible, never moved by the layout.
            window.mode = .floating
            window.floatReason = admitted
        }
        tileability.invalidate(id)
        minimumSizes.forget(id)
        trustedFrames.invalidate(id)
        try? session.registry.register(window)
        if let wanted = outcome.workspace,
           let destID = session.manager.ruleTarget(wanted),
           destID != session.manager.currentID
        {
            var dest = session.manager.workspace(id: destID)!
            var column = Column(
                id: ColumnID((dest.columns.map(\.id.rawValue).max() ?? 0) + 1),
                width: 0, windows: [id]
            )
            column.focusedWindowIndex = 0
            dest.columns.append(column)
            if !window.isMinimized {
                dest.focusedColumn = dest.columns.count - 1
                dest.focusedWindow = id
            }
            session.manager.update(dest)
        } else {
            var current = session.manager.currentWorkspace()
            var column = Column(
                id: ColumnID((current.columns.map(\.id.rawValue).max() ?? 0) + 1),
                width: 0, windows: [id]
            )
            column.focusedWindowIndex = 0
            current.columns.append(column)
            if !window.isMinimized {
                current.focusedColumn = current.columns.count - 1
                current.focusedWindow = id
            }
            session.manager.update(current)
        }
        eventObserver?.watch(window: candidate.element, pid: candidate.window.pid)
        return id
    }

    /// Remove records whose process is gone (proof, not absence) from the
    /// registry and every workspace. Present-but-unlisted windows survive:
    /// enumeration gaps must never read as deaths.
    private func reapDeadPids(live: Set<WindowID>) {
        let livePIDs = Set(live.map(\.pid))
        let dead = session.registry.managedWindows()
            .map(\.id)
            .filter { !livePIDs.contains($0.pid) && !probe.isRunning($0.pid) }
        guard !dead.isEmpty else {
            return
        }
        purge(dead)
    }

    /// Forget windows everywhere: registry, every workspace, tileability
    /// cache, fullscreen records and the actuator's AX handles.
    private func purge(_ ids: [WindowID]) {
        guard !ids.isEmpty else {
            return
        }
        let idSet = Set(ids)
        for id in ids.sorted() {
            session.registry.remove(id)
            tileability.invalidate(id)
            minimumSizes.forget(id)
            echoGate.forget(id)
            trustedFrames.invalidate(id)
            renderVerifier.forget([id])
            physicalFrames.removeValue(forKey: id)
            nativeZoom.forget(id)
            nativeZoomTimers.removeValue(forKey: id)?.cancel()
            dropZoomVerification(id)
            resizeProbeGate.forget(id)
            snapshotCache.evict([id])
            fullscreen.forget(id)
            actuator?.forget(elementID: id.elementID)
        }
        for candidate in session.manager.allWorkspaces {
            var workspace = candidate
            let before = workspace
            workspace.stripWindows(idSet)
            if workspace != before {
                session.manager.update(workspace)
            }
        }
    }

    private func syncDisplays() {
        let snapshot = snapshotDisplayList()
        let seen = Set(snapshot.map(\.id))
        // Each display owns a workspace stack: register them first so a
        // vanished display's windows merge into a survivor before anything
        // is laid out.
        session.manager.syncDisplays(snapshot.map(\.id))
        for display in snapshot {
            visibleFrames[display.id] = display.visibleFrame
            displays.connect(
                display.id, frame: display.frame,
                workspace: session.manager.activeID(on: display.id) ?? session.manager.currentID
            )
        }
        for known in displays.allDisplays().map(\.id) where !seen.contains(known) {
            displays.disconnect(known)
            visibleFrames.removeValue(forKey: known)
        }
        if let main = probe.mainScreenFrame {
            actuator?.updateDisplayHeight(main.height)
        }
        // A topology change can move windows behind our back and changes
        // every parking target: nothing placed before it is trusted.
        trustedFrames.removeAll()
        inactiveParking.invalidate()
        focusRing.resetGate()
    }

    // MARK: - Reflow

    private func engine() -> ScrollableLayoutEngine {
        // Rebuilt per pass so config reloads apply instantly.
        ScrollableLayoutEngine(
            config: session.config.makeLayoutConfig(
                viewportWidth: probe.mainScreenVisibleFrame?.width ?? 1800
            ),
            minimumSizes: minimumSizes.sizes
        )
    }

    /// FI-02: a write that landed larger than asked teaches the layout that
    /// window's minimum; relayout once so neighbours make room instead of
    /// being overlapped. Bounded: only a strictly larger minimum triggers it.
    private func learnMinimumSizes(from report: ReconcileReport) {
        let changed = minimumSizes.learn(from: report)
        guard !changed.isEmpty else {
            return
        }
        for id in changed.keys.sorted() {
            noteResizeClamp(pid: id.pid)
            let size = changed[id]!
            GioLog.record(
                .info,
                "min size learned id=\(id.pid):\(id.elementID) "
                    + "app=\(session.registry.find(id)?.application ?? "pid\(id.pid)") "
                    + "w=\(Int(size.width.rounded())) h=\(Int(size.height.rounded()))"
            )
        }
        scheduleReflow(full: false)
    }

    private func resizeKey(_ pid: pid_t) -> String {
        probe.applicationLabel(pid)
    }

    private func logResizeCapability(_ key: String) {
        let metrics = resizeCapability.metrics(key)
        GioLog.record(
            .debug,
            "resize capability app=\(key) animate=\(resizeCapability.canAnimateSize(key)) "
                + "cost=\(String(format: "%.1f", metrics?.costMilliseconds ?? 0))ms "
                + "drops=\(String(format: "%.0f", (metrics?.dropRate ?? 0) * 100))%"
        )
    }

    private func noteResizeClamp(pid: pid_t) {
        let key = resizeKey(pid)
        if resizeCapability.noteClamp(key) {
            logResizeCapability(key)
        }
    }

    /// Feed a finished motion's per-app write stats into the capability book.
    private func learnResizeCapability(from summary: MotionSummary) {
        for pid in summary.appStats.keys.sorted() {
            let key = resizeKey(pid)
            if resizeCapability.record(key, stats: summary.appStats[pid]!) {
                logResizeCapability(key)
            }
        }
    }

    private func tileableModes() -> [WindowID: WindowMode] {
        // Verdicts are cached per window; a failed probe makes the window
        // floating(notResizable) in the registry instead of dropping it.
        reconcileTileability(registry: session.registry, cache: &tileability) { [actuator] id in
            guard let element = actuator?.element(for: id) else {
                return false
            }
            return axIsTileable(element)
        }
    }

    /// Adopt `id` as the session focus (current workspace), logging what it
    /// did to the viewport. True when the focus changed. Callers that adopt
    /// outside a reflow follow up with `reflowAll` when `scrolls` is set.
    @discardableResult
    private func adoptFocus(_ id: WindowID, source: FocusSource) -> Bool {
        let current = session.manager.currentWorkspace()
        let column = current.columns.firstIndex { $0.windows.contains(id) }
        let visibility = isVisibleInViewport(id)
        guard let adopted = adoptingFocus(id, in: current), adopted != current else {
            logAdoption(source, id, column, visibility, changed: false)
            return false
        }
        session.manager.update(adopted)
        logAdoption(source, id, column, visibility, changed: true)
        publishFocusRing()
        return true
    }

    private func logAdoption(
        _ source: FocusSource, _ id: WindowID, _ column: Int?, _ visible: Bool?, changed: Bool
    ) {
        let scroll = pendingScroll().map { "\(Int($0.from))->\(Int($0.to))" } ?? "no scroll"
        let placement = visible.map { $0 ? "visible" : "parked" } ?? "unplaced"
        GioLog.record(
            .debug,
            "focus adopt source=\(source.rawValue) id=\(id.pid):\(id.elementID) "
                + "column=\(column.map(String.init) ?? "none") \(placement) "
                + "changed=\(changed) scroll=\(scroll)"
        )
    }

    /// Would `id` be inside its display's viewport under the current offset?
    private func isVisibleInViewport(_ id: WindowID) -> Bool? {
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(id: display.workspace),
                  workspace.columns.contains(where: { $0.windows.contains(id) })
            else {
                continue
            }
            let viewport = visibleFrames[display.id] ?? display.frame
            guard let layout = try? engine().calculate(
                workspace: tilingWorkspace(from: workspace, modes: modes), viewport: viewport
            ), let frame = layout.frames[id]
            else {
                return nil
            }
            return frame.intersects(viewport)
        }
        return nil
    }

    /// The viewport move laying out the current workspaces would make
    /// (focused column hidden, or offset out of bounds), if any. Decides
    /// whether a click on an already-visible column needs any reflow.
    private func pendingScroll() -> (from: CGFloat, to: CGFloat)? {
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(id: display.workspace),
                  let planned = try? planDisplayLayout(
                      workspace: workspace, modes: modes, engine: engine(),
                      viewport: visibleFrames[display.id] ?? display.frame,
                      display: display.frame, otherDisplays: []
                  )
            else {
                continue
            }
            if planned.workspace.viewportOffset != workspace.viewportOffset {
                return (workspace.viewportOffset, planned.workspace.viewportOffset)
            }
        }
        return nil
    }

    /// Every write funnels through here. While a mouse button is down the
    /// reflow waits (polling every 50 ms, coalesced) so nothing moves under
    /// the cursor; a user's manual drag is therefore not fought, and the
    /// window snaps back to its column after release.
    private func reflowAll() {
        guard !isShuttingDown else {
            return
        }
        switch reflowDeferral.request(mouseDown: probe.isMouseDown) {
        case .apply:
            // FI-06: during a motion the retargeting reflow waits for the next
            // tick, so a burst of keys costs one reflow, not one per key.
            let flying = flightGate.isActive
            if reflowCoalescer.request(motionActive: player?.isActive == true || flying) == .runNow {
                performReflow()
            } else if flying {
                // An overlay flight has no tick: one merged retarget shortly after the burst.
                scheduleFlightReflow()
            }
        case .poll(let delay):
            scheduleDeferredReflow(after: delay)
        case .alreadyPolling:
            break
        }
    }

    private func scheduleDeferredReflow(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isShuttingDown else {
                return
            }
            switch self.reflowDeferral.poll(mouseDown: probe.isMouseDown) {
            case .apply:
                self.performReflow()
            case .poll(let next):
                self.scheduleDeferredReflow(after: next)
            case .alreadyPolling:
                break
            }
        }
    }

    private func performReflow(animate: Bool = true) {
        guard let actuator else {
            return
        }
        // The snap-back reflow after a drag releases the dim hold.
        focusDim.releaseDragHold()
        // Every exit (animation started or instant pass) refreshes the ring.
        defer {
            publishFocusRing()
            barPublisher.publish()
        }
        // A new pass invalidates any pending render check (FI-05).
        renderVerifier.cancel()
        // One reconciler for the session: it remembers apps whose write lane
        // is still stuck so a hung app is never written twice at once.
        let reconciler = self.reconciler ?? WindowReconciler(
            actuator: actuator,
            appName: { [probe] in probe.applicationName($0) }
        )
        self.reconciler = reconciler
        let settings = session.config.animations
        let placement = instantPlacement.decide(requested: animate && settings.isActive)
        if case .instant(let reason?) = placement {
            GioLog.record(reason == .mouse ? .debug : .info, instantPlacementLogLine(reason))
        }
        let animating = placement == .animate
        // Focusing away from a fullscreen window brings its column back.
        fullscreen.release(
            keeping: Set(displays.allDisplays().compactMap {
                session.manager.workspace(id: $0.workspace)?.focusedWindow
            }),
            registry: session.registry
        )
        syncShownWorkspace()
        let modes = tileableModes()
        var plans: [ParkingPlan] = []
        var animations: [WindowAnimation] = []
        var prepositions: [WindowID: CGRect] = [:]
        let centering = centerRequest ?? .none
        centerRequest = nil
        let sizingTarget = sizingFocus
        sizingFocus = nil
        var hovered: [WindowID: CGRect] = [:]
        let inactive = planInactiveWorkspaces()
        // Native zoom: windows whose zoom ended since the last pass get their
        // verdict against this pass's layout target.
        var unjudgedZooms = nativeZoom.takeResolved()
        for (index, display) in displays.allDisplays().enumerated() {
            guard let workspace = session.manager.workspace(id: display.workspace) else {
                continue
            }
            let visible = visibleFrames[display.id] ?? display.frame
            guard let planned = try? planDisplayLayout(
                workspace: workspace, modes: modes, engine: engine(),
                viewport: visible, display: display.frame,
                otherDisplays: displays.allDisplays().filter { $0.id != display.id }.map(\.frame),
                centering: display.workspace == session.manager.currentID ? centering : .none
            ) else {
                continue
            }
            var displayPlan = planned.plan
            judgeNativeZooms(&unjudgedZooms, plan: displayPlan, viewport: visible)
            displayPlan.visible = nativeZoom.applyAccepted(
                to: displayPlan.visible, parked: Set(displayPlan.parked.keys).union(inactive.parked.keys)
            )
            plans.append(displayPlan)
            hovered.merge(displayPlan.visible) { first, _ in first }
            if animating {
                // NC-07: the first display also carries the workspace switch:
                // hidden windows drop below its bottom edge, revealed ones rise.
                let carriesSwitch = index == 0
                let motionFrames = carriesSwitch
                    ? displayPlan.visible.merging(inactive.visible) { first, _ in first }
                    : displayPlan.visible
                learnPhysicalFrames(of: motionFrames.keys)
                let motion = planWorkspaceSwitchMotion(
                    current: physicalFrames, visible: motionFrames,
                    parked: displayPlan.parked, hidden: carriesSwitch ? inactive.parked : [:],
                    viewport: visible, display: display.frame, duration: settings.duration
                )
                animations += motion.animations
                prepositions.merge(motion.prepositions) { _, new in new }
            }
            // Logical state moves at once; only the physical writes animate.
            session.manager.update(planned.workspace)
            displays.updateViewport(
                Viewport(offset: planned.layout.viewportOffset, width: visible.width), for: display.id
            )
        }
        plans.append(inactive)
        hoverFrames = hovered
        dropUnjudgedZooms(unjudgedZooms)
        if settings.curve == .spring {
            animations = animations.map { $0.springing(settings.spring) }
        }
        // Native zoom: a maximize that grows a single-window column presses the
        // app's own zoom instead of writing a size. The zooming window leaves
        // this pass's motion and writes; the zoom starts after the neighbours'
        // motion is under way.
        let zoomJob = planNativeZoom(animations: animations, animating: animating, reconciler: reconciler)
        if nativeZoom.hasInFlight {
            animations = animations.filter { !nativeZoom.isInFlight($0.id) }
            plans = plans.map { plan in
                var kept = plan
                kept.visible = nativeZoom.withoutInFlight(plan.visible)
                kept.parked = plan.parked.filter { !nativeZoom.isInFlight($0.key) }
                return kept
            }
        }
        // PA-06: growing windows may follow the flight when their app keeps up.
        let capablePids = Set(animations.map(\.id.pid).filter { resizeCapability.canAnimateSize(resizeKey($0)) })
        // Focused-grow: the window the keyboard is about to raise (FI-06) that
        // grows gets its final size in the first frame. The raise (`focusNow`)
        // runs below, before the session queue serves the first motion tick,
        // so the one size write lands on an already frontmost window. Without
        // a focus intent (passive reflow) the target is nil: FI-03 applies.
        animations = planSizeSchedules(
            animations, mode: settings.resize, capablePids: capablePids,
            focused: focusIntent.pendingTarget(parked: Set(plans.flatMap { $0.parked.keys })) ?? sizingTarget,
            focusedGrow: settings.focusedGrow
        )
        // SM-04: with the snapshot renderer the real windows get one write to
        // their final frames (the instant pass below) under an opaque overlay
        // that flies their images on the GPU; the AX motion is the fallback.
        var snapshotFlight = false
        if animating, snapshotRendererUsable() {
            if !animations.isEmpty {
                snapshotFlight = driveSnapshotFlight(animations: animations, plans: plans, spring: settings.spring)
            } else {
                snapshotFlight = flightGate.isActive
            }
        }
        if !snapshotFlight {
            endSnapshotFlight(fadeOut: false)
        }
        if !animations.isEmpty && !snapshotFlight {
            applyPrepositions(prepositions, reconciler: reconciler)
            startMotion(animations, reconciler: reconciler)
            // FI-06: the keyboard follows the logical focus right away instead
            // of after the animation; the final pass only re-asserts a drift.
            let now = ProcessInfo.processInfo.systemUptime
            if let target = focusIntent.takeImmediate(
                parked: Set(plans.flatMap { $0.parked.keys }), now: now
            ) {
                let result = reconciler.focusNow(target)
                GioLog.record(
                    .debug,
                    "focus now id=\(target.pid):\(target.elementID) failed=\(result == .failed)"
                )
                if warpAfterFocus {
                    warpCursorToFocus(target, plans: plans)
                }
            }
            warpAfterFocus = false
            if let zoomJob {
                startNativeZoom(zoomJob, reconciler: reconciler)
            }
            scheduleZoomVerifications(failed: [])
            return
        }
        stopMotion()
        // Only a keyboard/IPC intent focuses anything (HD-01); passive reflows
        // pass nil so they never steal focus. The intent reaches the last
        // plan only, so focus lands after every frame of the pass.
        var focusTarget = focusIntent.take(
            motionStarting: false,
            parked: Set(plans.flatMap { $0.parked.keys }),
            now: ProcessInfo.processInfo.systemUptime
        )
        if focusTarget == nil,
           let reassert = focusIntent.takeReassert(
            logicalFocus: session.manager.currentWorkspace().focusedWindow,
            frontmostPID: probe.frontmostPID,
            frontmostFocusedWindow: { [actuator] in
                // Never reads Gio's own pid: a target is never Gio's.
                guard let pid = probe.frontmostPID,
                      pid != ProcessInfo.processInfo.processIdentifier,
                      let element = focusedWindowElement(pid: pid) else {
                    return nil
                }
                return actuator.id(matching: element, pid: pid)
            }
           ) {
            GioLog.record(
                .debug,
                "focus reassert id=\(reassert.id.pid):\(reassert.id.elementID) reason=\(reassert.reason.rawValue)"
            )
            focusTarget = reassert.id
        }
        let warp = warpAfterFocus
        warpAfterFocus = false
        defer {
            if warp, let focusTarget {
                warpCursorToFocus(focusTarget, plans: plans)
            }
        }
        var zoomWriteFailures: Set<WindowID> = []
        for (planIndex, plan) in plans.enumerated() {
            let report = reconciler.reconcile(
                frames: plan.visible, parked: plan.parked,
                focused: planIndex == plans.count - 1 ? focusTarget : nil, currentlyFocused: nil,
                trusted: trustedFrames
            )
            if let focusTarget, report.focusChanged || report.focusFailed {
                GioLog.record(
                    .debug,
                    "focus intent id=\(focusTarget.pid):\(focusTarget.elementID) changed=\(report.focusChanged) failed=\(report.focusFailed)"
                )
            }
            learnMinimumSizes(from: report)
            zoomWriteFailures.formUnion(report.failed)
            GioLog.record(
                .debug,
                "reflow applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) failed=\(report.failed.count)"
            )
            // Our writes echo back as moved/resized events: remember them
            // (parked ones too, so they never retrigger a reflow).
            // In place, once per settle: no merged copies of the dictionaries.
            let now = ProcessInfo.processInfo.systemUptime
            for (id, frame) in plan.visible where plan.parked[id] == nil {
                echoGate.recordApplied(id, frame: frame, at: now)
                physicalFrames[id] = frame
            }
            for (id, target) in plan.parked {
                echoGate.recordApplied(id, frame: target.frame, at: now)
                physicalFrames[id] = target.frame
            }
            for id in report.failed + report.vanished {
                physicalFrames.removeValue(forKey: id)
            }
            trustedFrames.recordSettle(report: report, visible: plan.visible, parked: plan.parked)
            // Only visible windows written here are worth a render check;
            // a settle that wrote parked/hidden windows alone checks nothing.
            for id in report.applied where plan.visible[id] != nil && plan.parked[id] == nil {
                renderVerifier.insertCandidate(id)
            }
            renderVerifier.recordSettled(from: report.settledFrames)
            GioLog.record(.debug, "settle skippedReads=\(report.skippedReads)")
        }
        if let zoomJob {
            startNativeZoom(zoomJob, reconciler: reconciler)
        }
        scheduleZoomVerifications(failed: zoomWriteFailures)
        if snapshotFlight {
            // The final exact pass is done; the flight settles once its layers land too.
            if flightGate.passSettled(flightGate.currentToken) {
                settleSnapshotFlight()
            }
        } else {
            if renderVerifier.hasCandidates {
                renderVerifier.schedule()
            }
            scheduleSnapshotRefresh()
        }
    }

    // MARK: - Snapshot renderer (SM-04)

    /// Snapshot rendering is in force: configured, permission granted,
    /// macOS 14+. Otherwise the cache is dropped (its memory is released and
    /// an overlay is never shown without fresh images). Session queue.
    private func snapshotRendererUsable() -> Bool {
        let settings = session.config.animations
        let usable = SnapshotCapturer.isSupported
            && effectiveRenderer(config: settings, permission: hasScreenRecordingPermission()) == .snapshot
        if !usable, snapshotCache.count > 0 {
            snapshotCache.removeAll()
            GioLog.record(.debug, "snapshot cache cleared renderer=ax")
        }
        return usable
    }

    private func scheduleFlightReflow() {
        guard !flightReflowScheduled else {
            return
        }
        flightReflowScheduled = true
        queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else {
                return
            }
            self.flightReflowScheduled = false
            if !self.isShuttingDown, self.reflowCoalescer.takeAtTick() {
                self.performReflow()
            }
        }
    }

    private func makeFlights(_ items: [SnapshotFlightItem]) -> [SnapshotDisplayFlight] {
        let frames = displays.allDisplays().map(\.frame)
        var byDisplay: [Int: [SnapshotOverlayItem]] = [:]
        for item in items {
            guard let entry = snapshotCache.entry(item.id), frames.indices.contains(item.displayIndex) else {
                continue
            }
            byDisplay[item.displayIndex, default: []].append(
                SnapshotOverlayItem(id: item.id, image: entry.image, from: item.from, to: item.to)
            )
        }
        return byDisplay.keys.sorted().map { SnapshotDisplayFlight(displayFrame: frames[$0], items: byDisplay[$0]!) }
    }

    /// Decide snapshot vs AX for this motion and start (or retarget) the
    /// overlay flight. True when the overlay carries the motion. The caller
    /// then runs the ordinary instant pass, which is the real windows' one
    /// write. Session queue.
    private func driveSnapshotFlight(
        animations: [WindowAnimation], plans: [ParkingPlan], spring: SpringParameters
    ) -> Bool {
        let screens = displays.allDisplays().map(\.frame)
        var targets: [WindowID: CGRect] = [:]
        for plan in plans {
            for (id, frame) in plan.visible where plan.parked[id] == nil {
                targets[id] = frame
            }
            for (id, parked) in plan.parked {
                targets[id] = parked.frame
            }
        }
        var starts = physicalFrames.filter { targets[$0.key] != nil }
        for animation in animations {
            starts[animation.id] = animation.from
        }
        let now = ProcessInfo.processInfo.systemUptime
        let usable: (WindowID) -> Bool = { [snapshotCache] id in
            guard let entry = snapshotCache.entry(id) else {
                return false
            }
            return snapshotEntryUsable(entry, currentFrame: starts[id] ?? targets[id] ?? entry.frame, now: now)
        }
        if flightGate.isActive {
            let plan = planSnapshotRetarget(
                active: flightIDs, starts: starts, targets: targets, displays: screens,
                activeDisplays: flightDisplays, hasImage: usable
            )
            let token = flightGate.retarget()
            overlayRetarget?(token, plan.retargets, makeFlights(plan.adds))
            flightIDs.formUnion(plan.adds.map(\.id))
            flightWindows.formUnion(plan.adds.map(\.id))
            snapshotCache.touch(plan.adds.map(\.id), at: now)
            if !plan.uncovered.isEmpty {
                // No image: written once under the overlay, revealed when it ends.
                GioLog.record(.debug, "snapshot retarget uncovered ids=\(plan.uncovered.count)")
                scheduleSnapshotRefresh(delay: 0.05)
            }
            return true
        }
        let wallpapers = overlayWallpapers
        let decision = planSnapshotFlight(
            starts: starts, targets: targets, displays: screens, hasImage: usable,
            backdropReady: { wallpapers?.hasImage(for: screens[$0]) ?? false }
        )
        switch decision {
        case .fallback(let reason, let missing):
            GioLog.record(.info, snapshotFallbackLine(reason: reason, count: missing.count))
            // Next time the images are there.
            scheduleSnapshotRefresh(delay: 0.05)
            return false
        case .snapshot(let items):
            let flights = makeFlights(items)
            guard !flights.isEmpty else {
                return false
            }
            let ids = Set(items.map(\.id))
            let token = flightGate.begin()
            flightIDs = ids
            flightWindows = ids
            flightDisplays = Set(items.map(\.displayIndex))
            flightStartedAt = now
            flightCacheAgeMilliseconds = snapshotCache.maxAgeMilliseconds(of: ids, now: now)
            snapshotCache.touch(ids, at: now)
            overlayBegin?(token, spring, flights)
            return true
        }
    }

    /// Overlay layers of flight `token` landed (called from the main thread).
    func snapshotLayersFinished(_ token: Int) {
        queue.async { [weak self] in
            guard let self, !self.isShuttingDown else {
                return
            }
            if self.flightGate.layersFinished(token) {
                self.settleSnapshotFlight()
            }
        }
    }

    /// The overlay came down on its own (watchdog, mouse down): treat it as a
    /// settle without the fade. Called from the main thread.
    func snapshotFlightAborted(_ reason: SnapshotAbortReason) {
        queue.async { [weak self] in
            guard let self, !self.isShuttingDown, self.flightGate.isActive else {
                return
            }
            GioLog.record(reason.logLevel, snapshotAbortLine(reason: reason))
            self.flightGate.abort()
            self.flightIDs = []
            self.flightDisplays = []
            self.flightWindows = []
            self.publishFocusRing()
            if self.renderVerifier.hasCandidates {
                self.renderVerifier.schedule()
            }
            self.scheduleSnapshotRefresh()
        }
    }

    /// Layers landed and the real windows settled: remove the overlay, show
    /// the ring, verify the render and refresh the image cache in the
    /// background.
    private func settleSnapshotFlight() {
        let duration = ProcessInfo.processInfo.systemUptime - flightStartedAt
        overlayEnd?(true)
        GioLog.record(
            .info,
            MotionSummary(
                windows: flightWindows.count, frames: 0, dropped: 0, duration: duration, slowest: nil,
                curve: "spring", renderer: "snapshot"
            ).logLine
        )
        GioLog.record(
            .info,
            snapshotFlightLine(
                layers: flightIDs.count, cacheAgeMilliseconds: flightCacheAgeMilliseconds, duration: duration
            )
        )
        flightIDs = []
        flightDisplays = []
        flightWindows = []
        publishFocusRing()
        if renderVerifier.hasCandidates {
            renderVerifier.schedule()
        }
        scheduleSnapshotRefresh()
    }

    /// Abandon a flight without the normal settle (fallback to AX, shutdown).
    private func endSnapshotFlight(fadeOut: Bool) {
        guard flightGate.isActive else {
            return
        }
        flightGate.abort()
        flightIDs = []
        flightDisplays = []
        flightWindows = []
        overlayEnd?(fadeOut)
        publishFocusRing()
    }

    // MARK: Pre-captured cache

    /// One-shot, debounced: ~300 ms after a settle, capture the visible
    /// windows and their neighbours in the background. No periodic timer.
    private func scheduleSnapshotRefresh(delay: TimeInterval = 0.3) {
        guard !isShuttingDown, snapshotRendererUsable() else {
            return
        }
        cacheRefreshToken += 1
        let token = cacheRefreshToken
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runSnapshotRefresh(token: token)
        }
    }

    /// Windows to keep cached and where they are now: visible ones, the
    /// columns next to the viewport, and the focused window of the adjacent
    /// workspaces of each display (at most 12).
    private func snapshotRefreshSet() -> [(id: WindowID, frame: CGRect)] {
        var ordered: [WindowID] = []
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(id: display.workspace) else {
                continue
            }
            let columns = workspace.columns.map(\.windows)
            let visible = Set(columns.joined().filter { id in
                physicalFrames[id].map { overlayDisplayIndex(from: $0, to: $0, displays: [display.frame]) != nil } ?? false
            })
            var extras: [WindowID] = []
            let stack = session.manager.stack(on: display.id)
            if let index = stack.firstIndex(where: { $0.id == display.workspace }) {
                for neighbour in [index - 1, index + 1] where stack.indices.contains(neighbour) {
                    if let focused = stack[neighbour].focusedWindow {
                        extras.append(focused)
                    }
                }
            }
            ordered += snapshotCaptureSet(columns: columns, visible: visible, extras: extras)
        }
        var seen: Set<WindowID> = []
        var result: [(id: WindowID, frame: CGRect)] = []
        for id in ordered where seen.insert(id).inserted {
            guard let window = session.registry.find(id), !window.isMinimized, let frame = physicalFrames[id] else {
                continue
            }
            result.append((id, frame))
            if result.count == 12 {
                break
            }
        }
        return result
    }

    private func runSnapshotRefresh(token: Int) {
        guard token == cacheRefreshToken, !isShuttingDown, !flightGate.isActive, player?.isActive != true,
              snapshotRendererUsable()
        else {
            return
        }
        guard !cacheRefreshBusy else {
            cacheRefreshAgain = true
            return
        }
        let wanted = snapshotRefreshSet()
        guard !wanted.isEmpty else {
            return
        }
        let (screens, primary) = refreshLock.withLock { (captureScreens, capturePrimaryHeight) }
        let request = SnapshotCaptureRequest(
            windows: Dictionary(uniqueKeysWithValues: wanted.map { ($0.id, $0.frame) }),
            displays: screens, primaryDisplayHeight: primary, includeBackdrop: false,
            budgetMilliseconds: 1500, logLevel: .debug
        )
        cacheRefreshBusy = true
        Task.detached { [snapshotCapturer, weak self] in
            let result = await snapshotCapturer.capture(request)
            self?.queue.async { self?.finishSnapshotRefresh(result) }
        }
    }

    private func finishSnapshotRefresh(_ result: SnapshotCaptureResult) {
        cacheRefreshBusy = false
        guard !isShuttingDown, snapshotRendererUsable() else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, snapshot) in result.snapshots {
            snapshotCache.store(
                id, image: snapshot.image, frame: snapshot.frame,
                pixels: snapshot.image.width * snapshot.image.height, at: now
            )
        }
        // Gone or minimized windows lose their image; the rest stays under the cap.
        let live = Set(session.registry.managedWindows().filter { !$0.isMinimized }.map(\.id))
        snapshotCache.retain(only: live)
        let displayPixels = captureScreens.map {
            Int($0.frame.width * $0.scale) * Int($0.frame.height * $0.scale)
        }.max() ?? 0
        let evicted = snapshotCache.enforce(capPixels: snapshotCacheCapPixels(displayPixels: displayPixels))
        GioLog.record(
            .debug,
            "snapshot cache entries=\(snapshotCache.count) pixels=\(snapshotCache.totalPixels) evicted=\(evicted.count)"
        )
        if cacheRefreshAgain {
            cacheRefreshAgain = false
            scheduleSnapshotRefresh(delay: 0.05)
        }
    }

    private func appName(_ pid: pid_t) -> String {
        probe.applicationLabel(pid)
    }

    // MARK: - Workspace visibility (NC-06)

    /// Point a display at the current workspace when none shows it yet: the
    /// display that showed the previous one switches over.
    private func syncShownWorkspace() {
        for display in displays.allDisplays() {
            if let active = session.manager.activeID(on: display.id), active != display.workspace {
                displays.assign(display.id, workspace: active)
            }
        }
    }

    /// Windows of workspaces no display shows hang off a corner of the first
    /// display (size kept); floating windows of shown workspaces that were
    /// hidden return to the frame they had. Minimized windows are untouched.
    private func planInactiveWorkspaces() -> ParkingPlan {
        let all = displays.allDisplays()
        var plan = ParkingPlan(visible: [:], parked: [:])
        guard let hiddenDisplay = all.first else {
            return plan
        }
        let shown = Set(all.map(\.workspace))
        let windows = Dictionary(
            uniqueKeysWithValues: session.registry.managedWindows().map { ($0.id, $0) }
        )
        let hidden = session.manager.windows(outside: shown).filter {
            windows[$0].map { !$0.isMinimized } ?? false
        }
        learnPhysicalFrames(of: hidden)
        var frames: [WindowID: CGRect] = [:]
        for id in hidden {
            guard let frame = physicalFrames[id] else {
                continue
            }
            frames[id] = frame
            if windows[id]?.mode == .floating {
                hiddenBook.hide(id, from: frame)
            }
        }
        let others = all.filter { $0.id != hiddenDisplay.id }.map(\.frame)
        plan.parked = inactiveParking.value(
            for: InactiveParkKey(frames: frames, display: hiddenDisplay.frame, others: others)
        ) {
            planHiddenWindows(frames: frames, display: hiddenDisplay.frame, otherDisplays: others)
        }
        let active = shown.flatMap { id in
            (session.manager.workspace(id: id)?.columns ?? []).flatMap(\.windows)
        }
        // Keep the memory until the window really sits at its frame: a
        // retarget mid-flight (or an abandoned animation) must find it again.
        let floating = active.filter { windows[$0]?.mode == .floating }
        plan.visible = hiddenBook.frames(of: floating)
        for (id, frame) in plan.visible {
            if let physical = physicalFrames[id],
               abs(physical.minX - frame.minX) <= 1, abs(physical.minY - frame.minY) <= 1
            {
                _ = hiddenBook.reveal([id])
            }
        }
        return plan
    }

    // MARK: - Motion (MO-04)

    /// Windows about to be seen but never placed by us (new ones) have no
    /// known physical frame; one read each lets them slide in.
    private func learnPhysicalFrames(of ids: some Sequence<WindowID>) {
        for id in ids where physicalFrames[id] == nil {
            if let frame = try? actuator?.frame(of: id) {
                physicalFrames[id] = frame
            }
        }
    }

    /// Place hidden incoming windows directly below their target before the
    /// player starts (off-screen, so the jump is invisible).
    private func applyPrepositions(_ frames: [WindowID: CGRect], reconciler: WindowReconciler<AXWindowActuator>) {
        let written = reconciler.preposition(frames: frames, from: physicalFrames)
        for id in written {
            guard let frame = frames[id] else {
                continue
            }
            physicalFrames[id] = frame
            trustedFrames.invalidate(id)
            echoGate.recordApplied(id, frame: frame, at: ProcessInfo.processInfo.systemUptime)
        }
    }

    private func startMotion(_ animations: [WindowAnimation], reconciler: WindowReconciler<AXWindowActuator>) {
        let player = self.player ?? MotionPlayer(
            sink: reconciler,
            appName: { [probe] in probe.applicationName($0) }
        )
        self.player = player
        player.start(animations)
        lastMotionAnimations = animations
        probeResizes(of: animations.filter { $0.sizeSchedule == .atStart }, frames: { $0.from })
        // Motion frames are unverified: the final pass must read these windows,
        // and the render check looks at them afterwards.
        for animation in animations {
            trustedFrames.invalidate(animation.id)
            renderVerifier.insertCandidate(animation.id)
            animatingPids.insert(animation.id.pid)
        }
        guard motionTimer == nil else {
            return
        }
        // A display-rate timer on the session queue: a tick only samples and
        // hands frames to per-app lanes (never an AX call here), so it costs
        // microseconds, and sampling by elapsed time keeps late ticks honest.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        // PA-03: paced to the display holding the moving windows (60 Hz ->
        // 16.7 ms, 120 Hz -> 8.3 ms), fixed for this motion.
        let refreshes = refreshLock.withLock { displayRefreshes }
        let fps = motionRefreshRate(animations: animations, displays: refreshes)
        let interval = frameInterval(for: fps)
        timer.schedule(
            deadline: .now(), repeating: .nanoseconds(Int(interval * 1e9)), leeway: .microseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.motionTick()
        }
        motionTimer = timer
        timer.resume()
    }

    /// Diagnostics: for each growing animation, poll the WindowServer bounds of
    /// that window only until they match the requested size or 1.5 s pass, and
    /// log `resize latency`. The window is found by pid + frame (FI-05 rule);
    /// unresolvable or ambiguous windows are skipped. The probe ends itself.
    private func probeResizes(of animations: [WindowAnimation], frames: (WindowAnimation) -> CGRect) {
        let growing = animations.filter {
            $0.duration > 0
                && ($0.to.width - $0.from.width > ResizeProbeLimits.tolerance
                    || $0.to.height - $0.from.height > ResizeProbeLimits.tolerance)
        }
        guard !growing.isEmpty else {
            return
        }
        let managed = Dictionary(growing.map { ($0.id, frames($0)) }, uniquingKeysWith: { $1 })
        let candidates = windowServerSnapshotCandidates(
            pids: Set(managed.keys.map(\.pid)), displayHeight: mainHeight()
        )
        let matches = matchSnapshotCandidates(managed: managed, candidates: candidates)
        for animation in growing {
            guard case .matched(let windowID)? = matches[animation.id] else {
                continue
            }
            if let live = resizeProbes[animation.id], live.size == animation.to.size {
                continue
            }
            // Only windows that can be resized and are not already that size:
            // anything else could only log a `wsMs=timeout` that says nothing.
            let current = windowServerSize(windowID: windowID)
            let settable = actuator?.element(for: animation.id).map(axIsSizeSettable) ?? false
            guard resizeProbeGate.shouldStart(
                animation.id, current: current, requested: animation.to.size, sizeSettable: settable
            ) else {
                continue
            }
            startResizeProbe(id: animation.id, requested: animation.to.size, windowID: windowID, started: current)
        }
    }

    private func startResizeProbe(id: WindowID, requested: CGSize, windowID: UInt32, started: CGSize?) {
        resizeProbes[id]?.timer.cancel()
        let began = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isShuttingDown else {
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let decision = resizeProbeDecision(
                requested: requested, observed: windowServerSize(windowID: windowID), elapsed: elapsed
            )
            guard decision != .pending else {
                return
            }
            self.resizeProbes[id]?.timer.cancel()
            self.resizeProbes[id] = nil
            // A window that never left its size is not slow to repaint, it
            // does not resize: remember that and stay quiet.
            if decision == .timeout,
               self.resizeProbeGate.recordTimeout(id, started: started, observed: windowServerSize(windowID: windowID))
            {
                return
            }
            let first = self.resizeHistory.recordIsFirst(id, size: requested)
            GioLog.record(
                .info,
                resizeLatencyLine(id: id, app: self.appName(id.pid), size: requested, result: decision, first: first)
            )
        }
        resizeProbes[id] = (requested, started, timer)
        timer.resume()
    }

    // MARK: - Native zoom

    private struct NativeZoomJob {
        let id: WindowID
        let action: NativeZoomAction
        let windowID: UInt32
        let start: CGRect
    }

    private func logNativeZoom(
        _ id: WindowID, action: NativeZoomAction, outcome: NativeZoomOutcome, milliseconds: Int,
        errorCode: Int32? = nil, settleMilliseconds: Int? = nil, verified: Bool? = nil
    ) {
        GioLog.record(
            .info,
            nativeZoomLogLine(
                id: id, app: appName(id.pid), action: action, outcome: outcome, milliseconds: milliseconds,
                errorCode: errorCode, settleMilliseconds: settleMilliseconds, verified: verified
            )
        )
    }

    /// A zoom that ended with a write: its verdict is logged once the window
    /// has been checked again (`verified=`), with at most one reassert.
    private struct ZoomVerification {
        let action: NativeZoomAction
        let outcome: NativeZoomOutcome
        let settle: NativeZoomSettle
        let target: CGRect
        var verifier: NativeZoomVerifier
        var writeFailed: Bool
        var scheduled = false
        var generation = 0
    }

    /// Judge the zooms that ended against the layout target of `plan`. An
    /// accepted zoom keeps the app's own frame (physical, trusted and echo
    /// gate updated, no correcting write); the others leave the window at the
    /// frame it reached so this pass's ordinary write brings it to the target,
    /// and are verified again shortly after (`scheduleZoomVerifications`).
    private func judgeNativeZooms(_ pending: inout [NativeZoomResolution], plan: ParkingPlan, viewport: CGRect) {
        var rest: [NativeZoomResolution] = []
        let now = ProcessInfo.processInfo.systemUptime
        for resolution in pending {
            let id = resolution.id
            guard let target = plan.visible[id], plan.parked[id] == nil else {
                rest.append(resolution)
                continue
            }
            let outcome = nativeZoomOutcome(settle: resolution.settle, target: target, visible: viewport)
            let settleMs = resolution.settle.settleMilliseconds
            trustedFrames.invalidate(id)
            var actualFrame: CGRect?
            if case .settled(let actual, _, _) = resolution.settle {
                actualFrame = actual
                physicalFrames[id] = actual
                // Late frame events of the zoom are echoes of where it landed.
                echoGate.recordApplied(id, frame: actual, at: now)
            } else {
                // Unknown frame: the pass reads it from the window itself.
                physicalFrames.removeValue(forKey: id)
            }
            if outcome == .exact, let actualFrame {
                logNativeZoom(
                    id, action: resolution.action, outcome: outcome, milliseconds: resolution.settle.milliseconds,
                    errorCode: resolution.settle.errorCode, settleMilliseconds: settleMs, verified: true
                )
                nativeZoom.accept(id, target: target, actual: actualFrame)
                trustedFrames.trust(id, frame: actualFrame)
                zoomWindowServerIDs.removeValue(forKey: id)
            } else if outcome == .fallback(.pressFailed) {
                logNativeZoom(
                    id, action: resolution.action, outcome: outcome, milliseconds: resolution.settle.milliseconds,
                    errorCode: resolution.settle.errorCode, settleMilliseconds: settleMs
                )
                zoomWindowServerIDs.removeValue(forKey: id)
            } else {
                // The ordinary pass writes the target; the app's zoom may
                // still overwrite it. Keep the window's events suppressed and
                // check the WindowServer bounds again.
                nativeZoom.beginVerifying(id)
                var entry = ZoomVerification(
                    action: resolution.action, outcome: outcome, settle: resolution.settle, target: target,
                    verifier: NativeZoomVerifier(target: target, before: actualFrame ?? .zero), writeFailed: false
                )
                entry.generation = (zoomVerifications[id]?.generation ?? 0) + 1
                zoomVerifications[id] = entry
            }
        }
        pending = rest
    }

    /// Start the verification clock of the zooms judged in this pass, once
    /// the pass has written them. `failed` are the windows whose write failed
    /// or timed out (an app that is busy).
    private func scheduleZoomVerifications(failed: Set<WindowID>) {
        for id in zoomVerifications.keys.sorted() where zoomVerifications[id]?.scheduled == false {
            zoomVerifications[id]?.scheduled = true
            zoomVerifications[id]?.writeFailed = failed.contains(id)
            scheduleZoomVerify(id, after: NativeZoomLimits.verifyDelay)
        }
    }

    private func scheduleZoomVerify(_ id: WindowID, after delay: TimeInterval) {
        guard let generation = zoomVerifications[id]?.generation else {
            return
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isShuttingDown, self.zoomVerifications[id]?.generation == generation else {
                return
            }
            self.verifyNativeZoom(id)
        }
    }

    private func verifyNativeZoom(_ id: WindowID) {
        guard var entry = zoomVerifications[id] else {
            return
        }
        // Gio moved the window elsewhere since (a newer layout): not ours to judge.
        if let physical = physicalFrames[id], !entry.writeFailed,
           abs(physical.minX - entry.target.minX) > NativeZoomLimits.acceptTolerance
            || abs(physical.maxX - entry.target.maxX) > NativeZoomLimits.acceptTolerance
            || abs(physical.minY - entry.target.minY) > NativeZoomLimits.acceptTolerance
            || abs(physical.maxY - entry.target.maxY) > NativeZoomLimits.acceptTolerance {
            finishZoomVerification(id, entry, verified: false)
            return
        }
        let bounds = zoomWindowServerIDs[id].flatMap { windowServerBounds(windowID: $0, displayHeight: mainHeight()) }
        switch entry.verifier.observe(bounds, writeFailed: entry.writeFailed) {
        case .verified:
            finishZoomVerification(id, entry, verified: true)
        case .unverified:
            finishZoomVerification(id, entry, verified: false)
        case .recheck:
            zoomVerifications[id] = entry
            scheduleZoomVerify(id, after: NativeZoomLimits.quietPeriod)
        case .reassert(let reason):
            GioLog.record(.info, nativeZoomReassertLogLine(id: id, app: appName(id.pid), reason: reason))
            guard let reconciler else {
                finishZoomVerification(id, entry, verified: false)
                return
            }
            trustedFrames.invalidate(id)
            let report = reconciler.reconcile(
                frames: [id: entry.target], parked: [:], focused: nil, currentlyFocused: nil, trusted: trustedFrames
            )
            let now = ProcessInfo.processInfo.systemUptime
            echoGate.recordApplied(id, frame: entry.target, at: now)
            physicalFrames[id] = entry.target
            entry.writeFailed = report.failed.contains(id)
            zoomVerifications[id] = entry
            scheduleZoomVerify(id, after: NativeZoomLimits.verifyDelay)
        }
    }

    private func finishZoomVerification(_ id: WindowID, _ entry: ZoomVerification, verified: Bool) {
        dropZoomVerification(id)
        trustedFrames.invalidate(id)
        logNativeZoom(
            id, action: entry.action, outcome: entry.outcome, milliseconds: entry.settle.milliseconds,
            errorCode: entry.settle.errorCode, settleMilliseconds: entry.settle.settleMilliseconds, verified: verified
        )
    }

    private func dropZoomVerification(_ id: WindowID) {
        zoomVerifications.removeValue(forKey: id)
        zoomWindowServerIDs.removeValue(forKey: id)
        nativeZoom.endVerifying(id)
        // The last verification lifts the zoom hold on the dim.
        focusDim.update()
    }

    /// Zooms whose window is no longer laid out on a display: nothing to judge.
    private func dropUnjudgedZooms(_ pending: [NativeZoomResolution]) {
        for resolution in pending {
            logNativeZoom(
                resolution.id, action: resolution.action, outcome: .fallback(.notVisible),
                milliseconds: resolution.settle.milliseconds
            )
            trustedFrames.invalidate(resolution.id)
            physicalFrames.removeValue(forKey: resolution.id)
        }
    }

    /// Decide whether this maximize toggle uses the app's own zoom and, when
    /// it does, take the window out of Gio's writes. Cheap rules first; one AX
    /// round trip for the zoom button; one WindowServer lookup for the window
    /// to watch. Anything short of a certain zoom leaves the ordinary path.
    private func planNativeZoom(
        animations: [WindowAnimation], animating: Bool, reconciler: WindowReconciler<AXWindowActuator>
    ) -> NativeZoomJob? {
        guard let request = pendingZoomRequest else {
            return nil
        }
        pendingZoomRequest = nil
        guard !nativeZoom.isBusy(request.id) else {
            return nil
        }
        let animation = animations.first { $0.id == request.id }
        let grows = animation.map { $0.duration > 0 && nativeZoomGrows(from: $0.from, to: $0.to) } ?? false
        let enabled = session.config.animations.nativeZoom
        func skipped(_ reason: NativeZoomSkipReason) -> NativeZoomJob? {
            GioLog.record(
                .debug, "native zoom skipped id=\(request.id.pid):\(request.id.elementID) reason=\(reason.rawValue)"
            )
            return nil
        }
        // The zoom needs the AX motion of the neighbours (a snapshot overlay
        // would fly an image of the window over its own zoom).
        if enabled, request.columnWindowCount == 1, !animating || snapshotRendererUsable() {
            return skipped(.noAxMotion)
        }
        if case .ineligible(let reason) = nativeZoomEligibility(
            request, enabled: enabled, grows: grows, zoomAvailable: true
        ) {
            return skipped(reason)
        }
        if case .unavailable(let why) = reconciler.zoomAvailability(of: request.id) {
            GioLog.record(.debug, "native zoom unavailable id=\(request.id.pid):\(request.id.elementID) why=\(why)")
            logNativeZoom(request.id, action: request.action, outcome: .fallback(.unavailable), milliseconds: 0)
            return nil
        }
        guard let from = physicalFrames[request.id] ?? animation?.from else {
            return skipped(.noWindowServer)
        }
        let candidates = windowServerSnapshotCandidates(pids: [request.id.pid], displayHeight: mainHeight())
        guard case .matched(let windowID)? = matchSnapshotCandidates(
            managed: [request.id: from], candidates: candidates
        )[request.id] else {
            logNativeZoom(request.id, action: request.action, outcome: .fallback(.noWindowServer), milliseconds: 0)
            return nil
        }
        let start = windowServerBounds(windowID: windowID, displayHeight: mainHeight()) ?? from
        nativeZoom.begin(request.id, action: request.action)
        trustedFrames.invalidate(request.id)
        return NativeZoomJob(id: request.id, action: request.action, windowID: windowID, start: start)
    }

    /// Press the zoom (on the app's lane, through the reconciler) and watch
    /// the WindowServer bounds until they settle or the settle timeout passes.
    private func startNativeZoom(_ job: NativeZoomJob, reconciler: WindowReconciler<AXWindowActuator>) {
        let pressed = reconciler.pressZoom(job.id)
        switch nativeZoomPressDisposition(pressed) {
        case .fallbackNow(let settle):
            GioLog.record(
                .debug, "native zoom press failed id=\(job.id.pid):\(job.id.elementID) result=\(pressed)"
            )
            finishNativeZoom(job.id, settle: settle)
            return
        case .watch:
            // A timeout-class error means the app is busy zooming: keep the
            // window out of Gio's writes and let the settle detection decide.
            if case .pending(let code) = pressed {
                GioLog.record(
                    .debug,
                    "native zoom press pending id=\(job.id.pid):\(job.id.elementID) axerror=\(code.map(String.init) ?? "laneTimeout")"
                )
            }
        }
        zoomWindowServerIDs[job.id] = job.windowID
        let began = ProcessInfo.processInfo.systemUptime
        var tracker = NativeZoomSettleTracker(start: job.start)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(
            deadline: .now() + NativeZoomLimits.pollInterval, repeating: NativeZoomLimits.pollInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self, !self.isShuttingDown, self.nativeZoom.isInFlight(job.id) else {
                self?.nativeZoomTimers.removeValue(forKey: job.id)?.cancel()
                return
            }
            let bounds = windowServerBounds(windowID: job.windowID, displayHeight: self.mainHeight())
            if let settle = tracker.observe(bounds, elapsed: ProcessInfo.processInfo.systemUptime - began) {
                self.finishNativeZoom(job.id, settle: settle)
            }
        }
        nativeZoomTimers[job.id]?.cancel()
        nativeZoomTimers[job.id] = timer
        timer.resume()
    }

    /// The zoom ended (settled, timed out or could not be pressed). While a
    /// motion runs its final pass judges it; otherwise one instant pass does.
    private func finishNativeZoom(_ id: WindowID, settle: NativeZoomSettle) {
        nativeZoomTimers.removeValue(forKey: id)?.cancel()
        nativeZoom.finish(id, settle: settle)
        guard player?.isActive != true, !flightGate.isActive else {
            return
        }
        queue.async { [weak self] in
            guard let self, !self.isShuttingDown, self.nativeZoom.hasResolved, self.player?.isActive != true else {
                return
            }
            self.performReflow(animate: false)
        }
    }

    private func stopMotion() {
        animatingPids = []
        reflowCoalescer.reset()
        motionTimer?.cancel()
        motionTimer = nil
        player?.cancel()
    }

    private func motionTick() {
        guard let player, player.isActive, !isShuttingDown else {
            stopMotion()
            return
        }
        if probe.isMouseDown {
            // Nothing moves under the cursor: abandon the flight, and let
            // the deferred reflow finish instantly after release.
            stopMotion()
            instantPlacement.arm(.mouse)
            reflowAll()
            return
        }
        if reflowCoalescer.takeAtTick() {
            // One merged retarget for every action since the last tick.
            performReflow()
            return
        }
        let tick = player.tick()
        // In place, only the windows written this tick; frame writes raise
        // moved events like any other write of ours.
        let now = ProcessInfo.processInfo.systemUptime
        for (id, frame) in tick.sampled {
            physicalFrames[id] = frame
            echoGate.recordApplied(id, frame: frame, at: now)
        }
        // The ring follows the focused window's sampled frame, and only
        // when that window moved this tick.
        if let focused = session.manager.currentWorkspace().focusedWindow, tick.sampled[focused] != nil {
            publishFocusRing()
        }
        if let summary = tick.summary {
            stopMotion()
            GioLog.record(.info, summary.logLine)
            learnResizeCapability(from: summary)
            // FI-03 grows land in the final pass: measure them for comparison.
            probeResizes(
                of: lastMotionAnimations.filter { $0.sizeSchedule == .none },
                frames: { physicalFrames[$0.id] ?? $0.from }
            )
            lastMotionAnimations = []
            performReflow(animate: false)
        }
    }

    /// Debounced reflow. `full` also re-enumerates windows (resync); a
    /// light one only re-lays out what is registered. A pending full
    /// request is never downgraded by a later light one.
    private func scheduleReflow(full: Bool = true) {
        pendingFull = pendingFull || full
        pendingReflow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let wantsFull = self.pendingFull
            self.pendingFull = false
            if wantsFull {
                self.resyncAndReflow()
            } else {
                self.reflowAll()
            }
        }
        pendingReflow = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func resyncAndReflow() {
        if let main = probe.mainScreenFrame {
            actuator?.updateDisplayHeight(main.height)
        }
        // The tap starts once at launch; if permission arrived later it
        // stayed deaf — retry here so granting + any window event heals it
        // without relaunching.
        if hotkeyTap == nil {
            startTap()
            if hotkeyTap != nil {
                // Permission regained: observers built without it are dead,
                // and every verdict is stale. The one full rebuild, placed
                // without motion like a fresh start.
                instantPlacement.arm(.permission)
                tileability.invalidateAll()
                rebuildEventObservation()
            }
        }
        // Tileability verdicts are invalidated per window by resize events
        // and on registration, not on every resync.
        enumerateAndPlace()
        syncObservers()
        reflowAll()
    }

    // MARK: - Observers

    /// Full rebuild: only for startup and permission regain. Everyday app
    /// churn goes through the incremental attach/detach below.
    private func rebuildEventObservation() {
        eventObserver?.stop()
        observationBook = ObservationBook()
        eventObserver = SystemWindowObserver { [weak self] event in
            // Delivered on the main thread; session state lives on `queue`.
            guard let self else {
                return
            }
            self.queue.async {
                self.handle(event)
            }
        }
        syncObservers()
    }

    /// Reconcile observers with the running set: attach new apps, detach
    /// vanished ones, leave everything else alone. Safety net for missed
    /// launch/terminate notifications; refused apps wait for activation.
    private func syncObservers() {
        guard let observer = eventObserver else {
            return
        }
        let plan = observationBook.reconcile(running: probe.runningRegularPIDs())
        for pid in plan.detach {
            observer.detach(pid: pid)
            observationBook.didDetach(pid)
        }
        var refused: [pid_t] = []
        for pid in plan.attach {
            if observer.attach(pid: pid) {
                observationBook.didAttach(pid)
            } else {
                observationBook.didRefuse(pid)
                refused.append(pid)
            }
        }
        if !refused.isEmpty {
            print("[gio] observation refused: pid \(refused.map(String.init).joined(separator: ", "))")
            GioLog.record(.warn, "observation refused for \(refused.count) app(s)")
        }
    }

    private func handle(_ event: SystemWindowEvent) {
        switch event.kind {
        case .appLaunched:
            attachLaunchedApp(event.pid, attempt: 0)
        case .appTerminated:
            handleTerminated(event.pid)
        case .appActivated:
            // A previously refused (or missed) app gets another chance now.
            if observationBook.needsAttach(event.pid), let observer = eventObserver,
               observer.attach(pid: event.pid)
            {
                observationBook.didAttach(event.pid)
            }
            if hotkeyTap == nil {
                // Permission may have arrived late: the one activation-time
                // full resync (it retries the tap and rebuilds observers).
                scheduleReflow()
            }
            requestFocusAdoption(.activation, pid: event.pid, element: nil)
            // Another app's windows may now be in front of dimmed ones.
            focusDim.update()
        case .window(let kind):
            handleWindowEvent(kind, pid: event.pid, element: event.element)
        }
    }

    private func handleWindowEvent(_ kind: WindowEventKind, pid: pid_t, element: AXUIElement?) {
        // Our own animation writes: dropped before the handle lookup.
        if dropsAsMotionEcho(kind, pid: pid, animating: animatingPids) {
            return
        }
        let known = element.flatMap { actuator?.id(matching: $0, pid: pid) }
        // Native zoom: the app animating its own window raises a burst of frame
        // and focus events; they are expected until the zoom was judged.
        if let known, nativeZoomDropsEvent(kind, inFlight: nativeZoom.isBusy(known)) {
            return
        }
        switch windowEventAction(for: kind, isKnownWindow: known != nil) {
        case .register:
            if let element {
                registerAppearedWindow(element, pid: pid, attempt: 0)
            }
        case .remove:
            // Exactly this window: no rescan, no debounce.
            if let known {
                purge([known])
                reflowAll()
            }
        case .frameChanged(let invalidate):
            guard let known else {
                return
            }
            // Animation frames raise a burst of events: skip the AX read.
            if echoGate.isSuppressed(known, at: ProcessInfo.processInfo.systemUptime) {
                return
            }
            if let observed = try? actuator?.frame(of: known),
               echoGate.isEcho(known, observed: observed, at: ProcessInfo.processInfo.systemUptime)
            {
                return
            }
            // Not our echo: the window moved on its own (drag, app resize).
            // The dim comes down and returns after the snap-back reflow.
            focusDim.holdForDrag()
            trustedFrames.invalidate(known)
            nativeZoom.forget(known)
            if invalidate {
                tileability.invalidate(known)
            }
            scheduleReflow(full: false)
        case .reflow:
            scheduleReflow(full: false)
        case .minimize:
            if let known {
                trustedFrames.invalidate(known)
                minimizeWindow(known, registry: session.registry, manager: &session.manager)
                reflowAll()
            }
        case .restore:
            if let known {
                trustedFrames.invalidate(known)
                restoreWindow(known, registry: session.registry, manager: &session.manager)
                reflowAll()
            }
        case .updateTitle:
            if let known, let element, let title = axTitle(of: element), !title.isEmpty,
               var record = session.registry.find(known)
            {
                record.title = title
                try? session.registry.update(record)
            }
        case .adoptFocus:
            requestFocusAdoption(.focusChanged, pid: pid, element: element)
        case .resync:
            scheduleReflow()
        case .ignore:
            break
        }
    }

    /// The click explaining a focus event right now, if any: a button is
    /// down or one went down moments ago, at a point inside a window area.
    private func currentClick() -> MouseClick? {
        clickLock.lock()
        let tapped = tappedClick
        clickLock.unlock()
        let click = recentClick(
            pressed: probe.isMouseDown,
            currentLocation: probe.mouseLocation,
            now: ProcessInfo.processInfo.systemUptime,
            lastTapped: tapped
        )
        return windowAreaClick(
            click, visibleAreas: displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame }
        )
    }

    /// Light path for a click or app switch: no rescan. Keyboard-driven
    /// events adopt at once; mouse-driven ones coalesce, settle and are
    /// validated against the click (`FocusSettle`). The activation and the
    /// focused-window event of one click therefore adopt once.
    private func requestFocusAdoption(_ source: FocusSource, pid: pid_t, element: AXUIElement?) {
        // Gio's own window (main window, launcher) is never a tiling focus.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        // A background app changing its own key window is not the user's focus.
        if source == .focusChanged,
           pid != probe.frontmostPID
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

    private func scheduleFocusPoll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isShuttingDown else {
                return
            }
            let poll = self.focusSettle.poll(
                mouseDown: probe.isMouseDown,
                now: ProcessInfo.processInfo.systemUptime
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
        return focusedWindowElement(pid: event.pid)
    }

    private func validateClickFocus(_ event: FocusEvent, click: MouseClick, fresh: Bool) {
        let element = probe.frontmostPID == event.pid
            ? focusedElement(for: event, fresh: fresh) : nil
        let known = element.flatMap { actuator?.id(matching: $0, pid: event.pid) }
        var matches = false
        var frame: CGRect?
        if let known {
            frame = try? actuator?.frame(of: known)
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
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isShuttingDown,
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
            GioLog.record(
                .debug,
                "focus dropped source=\(event.source.rawValue) id=\(id) frame=\(box) "
                    + "click=\(Int(click.location.x)),\(Int(click.location.y)) "
                    + "reason=focused window not under click"
            )
        }
    }

    /// The frontmost app's window becomes the session focus; an unknown
    /// window goes through single-window admission; a reflow follows only
    /// when the viewport has to scroll to show the focused column.
    private func adoptResolved(_ element: AXUIElement, event: FocusEvent) {
        guard event.pid == probe.frontmostPID else {
            return
        }
        guard let id = actuator?.id(matching: element, pid: event.pid) else {
            // Registration focuses the new window and reflows.
            registerAppearedWindow(element, pid: event.pid, attempt: 0)
            return
        }
        if session.registry.find(id)?.isMinimized == true {
            return
        }
        // Trailing activation events of a focus Gio just moved must not undo it.
        if focusIntent.shouldIgnoreAdoption(of: id, now: ProcessInfo.processInfo.systemUptime) {
            GioLog.record(.debug, "focus adopt ignored (superseded by keyboard intent) id=\(id.pid):\(id.elementID)")
            return
        }
        adoptFocus(id, source: event.source)
        if pendingScroll() != nil {
            reflowAll()
        }
    }

    /// A window appeared after startup (created or deminiaturized): classify
    /// it with the admission rules, register it, reflow at once. Attributes
    /// of a brand-new window are often unreadable for a moment, so an
    /// unclassifiable element is retried a few times. Minimized windows
    /// register too (out of the layout until deminimized).
    private func registerAppearedWindow(_ element: AXUIElement, pid: pid_t, attempt: Int) {
        if actuator?.id(matching: element, pid: pid) != nil {
            return
        }
        if let candidate = discoverSystemWindow(element: element, pid: pid) {
            registerNew(candidate)
            reflowAll()
        } else if let delay = WindowRegistrationRetry.delay(afterFailedAttempt: attempt) {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.registerAppearedWindow(element, pid: pid, attempt: attempt + 1)
            }
        }
    }

    /// Attach one launched app's observer, retrying with backoff while AX
    /// is not ready, then register its windows and reflow. Windows that
    /// appear later arrive through the app-level window-created event.
    private func attachLaunchedApp(_ pid: pid_t, attempt: Int) {
        guard let observer = eventObserver,
              probe.isRegularApplication(pid),
              observationBook.needsAttach(pid)
        else {
            return
        }
        if observer.attach(pid: pid) {
            observationBook.didAttach(pid)
            enumerateAndPlace(onlyPID: pid)
            reflowAll()
        } else if let delay = ObservationRetry.delay(afterFailedAttempt: attempt) {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attachLaunchedApp(pid, attempt: attempt + 1)
            }
        } else {
            observationBook.didRefuse(pid)
            print("[gio] observation refused: pid \(pid)")
            GioLog.record(.warn, "observation refused for launched pid \(pid)")
        }
    }

    /// Terminate is proof of death: drop the observer, reap the windows,
    /// reflow now.
    private func handleTerminated(_ pid: pid_t) {
        eventObserver?.detach(pid: pid)
        observationBook.didDetach(pid)
        let ids = session.registry.managedWindows().map(\.id).filter { $0.pid == pid }
        // PA-05: tear down the app's persistent write lane and cached name.
        reconciler?.forgetApp(pid: pid)
        purge(ids)
        reflowAll()
    }

    /// Read the screens' refresh rates on main and hand them to the session.
    private func publishDisplayRefreshes() {
        if Thread.isMainThread {
            storeDisplayRefreshes()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.storeDisplayRefreshes()
            }
        }
    }

    private func storeDisplayRefreshes() {
        let snapshot = snapshotDisplayRefreshes()
        let screens = NSScreen.screens.compactMap { screen -> SnapshotDisplay? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return SnapshotDisplay(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }
        let primary = NSScreen.screens.first?.frame.height ?? 1169
        refreshLock.withLock {
            displayRefreshes = snapshot
            captureScreens = screens
            capturePrimaryHeight = primary
        }
    }

    private func watchDisplays() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.publishDisplayRefreshes()
            self.queue.async {
                if self.flightGate.isActive {
                    // Screens changed under the flight: come down, then relayout.
                    GioLog.record(.info, snapshotAbortLine(reason: .displayChange))
                    self.endSnapshotFlight(fadeOut: false)
                }
                self.syncDisplays()
                self.reflowAll()
            }
        }
    }

    /// `mouse-follows-focus`: after a keyboard focus change landed, put the
    /// cursor in the middle of the focused window (unless already inside).
    private func warpCursorToFocus(_ id: WindowID, plans: [ParkingPlan]) {
        guard let frame = plans.lazy.compactMap({ $0.visible[id] }).first,
              let target = mouseFollowsFocusTarget(
                  enabled: session.config.behavior.mouseFollowsFocus, frame: frame,
                  pointer: probe.mouseLocation
              )
        else {
            return
        }
        hoverFocus.noteWarp(now: ProcessInfo.processInfo.systemUptime)
        warpCursor(toCocoa: target)
        GioLog.record(.debug, "cursor warped to focus id=\(id.pid):\(id.elementID)")
    }

    // MARK: - Focus follows mouse (HD-04)

    /// Main thread (tap). Hands the latest pointer location to the session
    /// queue, coalesced to one look per 30 ms.
    private func handlePointerMoved(_ location: CGPoint) {
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
        queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.processPointer()
        }
    }

    private func processPointer() {
        hoverLock.lock()
        let location = hoverLocation
        hoverScheduled = false
        hoverLock.unlock()
        guard let location, !isShuttingDown else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let target = hoveredWindow(at: location)
        if let delay = hoverFocus.pointerMoved(over: target, now: now) {
            queue.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
                self?.fireHoverFocus()
            }
        }
    }

    private func hoveredWindow(at location: CGPoint) -> WindowID? {
        // Cheap geometry first; the window-server lookup only near a managed window.
        guard hoverFrames.values.contains(where: { $0.contains(location) }) else {
            return nil
        }
        return hoverTarget(
            at: location, frames: hoverFrames, topWindowPID: topWindowOwnerPID(atCocoa: location),
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    private func fireHoverFocus() {
        guard !isShuttingDown else {
            return
        }
        let frontPID = probe.frontmostPID
        let logical = session.manager.currentWorkspace().focusedWindow
        let focused = logical.flatMap { $0.pid == frontPID ? $0 : nil }
        guard let id = hoverFocus.due(
            now: ProcessInfo.processInfo.systemUptime,
            buttonDown: probe.isMouseDown, focused: focused
        ), hoveredWindow(at: probe.mouseLocation) == id else {
            return
        }
        adoptFocus(id, source: .hover)
        focusIntent.request(id, now: ProcessInfo.processInfo.systemUptime)
        reflowAll()
    }

    private func recordClick(at location: CGPoint) {
        // Clicks must hit real windows: an overlay in the air comes down now.
        _ = overlayAbortForMouseDown?()
        clickLock.lock()
        tappedClick = MouseClick(location: location, time: ProcessInfo.processInfo.systemUptime)
        clickLock.unlock()
        // A click is the user choosing the focus: drop any pending keyboard intent.
        queue.async { [weak self] in
            self?.focusIntent.cancel()
        }
    }

    private func startTap() {
        hoverLock.lock()
        let observeMouseMoved = hoverEnabled
        hoverLock.unlock()
        // Only subscribed while focus-follows-mouse is on: otherwise every
        // mouse move would cost a main-thread callback.
        var moveHandler: (@Sendable (CGPoint) -> Void)?
        if observeMouseMoved {
            moveHandler = { [weak self] location in
                self?.handlePointerMoved(location)
            }
        }
        let tap = HotkeyTap(
            onMouseDown: { [weak self] location in
                self?.recordClick(at: location)
            },
            onMouseMoved: moveHandler,
            onCombo: { [weak self] combo in
                self?.handleCombo(combo) ?? false
            }
        )
        if tap.start() {
            hotkeyTap = tap
        } else {
            print("[gio] hotkey tap refused (grant Accessibility, then relaunch)")
            GioLog.record(.warn, "hotkey tap refused; running without global hotkeys")
        }
    }

    // MARK: - Actions (main thread in, session queue for work)

    private func handleCombo(_ combo: HotkeyCombo) -> Bool {
        if combo == HotkeyCombo(modifiers: [.alt], key: "Space") {
            DispatchQueue.main.async { [weak self] in
                self?.onSummonLauncher?()
            }
            return true
        }
        guard let action = configCoordinator.currentDispatcher().action(for: combo) else {
            return false
        }
        queue.async { [weak self] in
            self?.apply(action)
        }
        return true
    }

    private func apply(_ action: HotkeyAction) {
        GioLog.record(.debug, "hotkey \(action)")
        var workspace = session.manager.currentWorkspace()
        let previousFocus = workspace.focusedWindow
        switch action {
        case .focusLeft:
            let next = moveFocus(in: workspace, direction: .left)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .focusRight:
            let next = moveFocus(in: workspace, direction: .right)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .focusUp:
            let next = moveFocus(in: workspace, direction: .up)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .focusDown:
            let next = moveFocus(in: workspace, direction: .down)
            if next != workspace {
                workspace = next
                session.manager.update(workspace)
            }
        case .moveLeft:
            narrowMove(in: &workspace, direction: .left)
        case .moveRight:
            narrowMove(in: &workspace, direction: .right)
        case .moveColumnLeft:
            commit(moveColumn(in: workspace, direction: .left), over: workspace)
        case .moveColumnRight:
            commit(moveColumn(in: workspace, direction: .right), over: workspace)
        case .moveUp:
            narrowMove(in: &workspace, direction: .up)
        case .moveDown:
            narrowMove(in: &workspace, direction: .down)
        case .workspace(let number):
            session.manager.switchTo(number)
            syncShownWorkspace()
        case .moveToWorkspace(let number):
            if let id = workspace.focusedWindow {
                session.manager.moveWindow(id, to: number)
            }
        case .focusWorkspaceDown:
            session.manager.focusDown()
            syncShownWorkspace()
        case .focusWorkspaceUp:
            session.manager.focusUp()
            syncShownWorkspace()
        case .moveWindowToWorkspaceDown:
            if let id = workspace.focusedWindow {
                session.manager.moveWindowDown(id)
                syncShownWorkspace()
            }
        case .moveWindowToWorkspaceUp:
            if let id = workspace.focusedWindow {
                session.manager.moveWindowUp(id)
                syncShownWorkspace()
            }
        case .toggleFloating:
            if let id = workspace.focusedWindow {
                _ = try? session.registry.toggleFloating(for: id)
            }
        case .fullscreen:
            toggleFullscreen()
        case .switchPresetColumnWidth:
            let sizing = focusedSizing()
            let next = switchPresetColumnWidth(
                in: workspace, presets: session.config.layout.presetColumnWidths,
                config: sizing.config, viewportWidth: sizing.viewportWidth
            )
            commit(next, over: workspace)
        case .shrinkColumnWidth, .growColumnWidth:
            let sizing = focusedSizing()
            let next = stepFocusedColumnWidth(
                in: workspace, by: action == .growColumnWidth ? 0.1 : -0.1,
                config: sizing.config, viewportWidth: sizing.viewportWidth
            )
            commit(next, over: workspace)
        case .maximizeColumn:
            pendingZoomRequest = nativeZoomRequest(in: workspace) { [nativeZoom] in nativeZoom.isNativeMaximized($0) }
            commit(toggleMaximizeFocusedColumn(in: workspace), over: workspace)
        case .consumeOrExpelLeft:
            commit(consumeOrExpelWindow(in: workspace, direction: .left), over: workspace)
        case .consumeOrExpelRight:
            commit(consumeOrExpelWindow(in: workspace, direction: .right), over: workspace)
        case .centerColumn:
            let viewport = focusedViewport()
            commit(
                centerFocusedColumn(in: workspace, modes: tileableModes(), engine: engine(), viewport: viewport),
                over: workspace
            )
        }
        requestFocusIntent(if: action.carriesFocusIntent, previous: previousFocus)
        if action.growsFocusedWindow {
            sizingFocus = session.manager.currentWorkspace().focusedWindow
        }
        reflowAll()
    }

    /// Ask the next reflow to focus and raise the current workspace's focused
    /// window (after its frame lands; at the end of an animation).
    private func requestFocusIntent(if carries: Bool, previous: WindowID?) {
        guard carries else {
            return
        }
        // Keyboard/IPC focus changes may center the column and warp the
        // cursor (HD-04); passive and hover focus never do.
        centerRequest = CenterRequest(mode: session.config.layout.centerFocusedColumn, previouslyFocused: previous)
        warpAfterFocus = true
        focusIntent.request(
            session.manager.currentWorkspace().focusedWindow,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Store `next` when an action changed anything.
    private func commit(_ next: Workspace, over current: Workspace) {
        if next != current {
            session.manager.update(next)
        }
    }

    /// Usable frame of the display showing the current workspace.
    private func focusedViewport() -> CGRect {
        let current = session.manager.currentID
        let display = displays.allDisplays().first { $0.workspace == current }
            ?? displays.allDisplays().first
        return display.map { visibleFrames[$0.id] ?? $0.frame }
            ?? probe.mainScreenVisibleFrame ?? CGRect(x: 0, y: 0, width: 1800, height: 1000)
    }

    /// Layout config plus the viewport width of the display showing the
    /// current workspace: what width actions resolve proportions against.
    private func focusedSizing() -> (config: LayoutConfig, viewportWidth: CGFloat) {
        (engine().config, focusedViewport().width)
    }

    private func narrowMove(in workspace: inout Workspace, direction: FocusDirection) {
        let next = moveWindow(in: workspace, direction: direction)
        if next != workspace {
            workspace = next
            session.manager.update(workspace)
        }
    }

    /// Fullscreen is a layout mode: flip it in the registry and let the
    /// reflow place the window (see `planDisplayLayout`). Never native Spaces.
    private func toggleFullscreen() {
        let workspace = session.manager.currentWorkspace()
        guard let id = workspace.focusedWindow else {
            return
        }
        let current = session.manager.currentID
        guard let display = displays.allDisplays().first(where: { $0.workspace == current })
            ?? displays.allDisplays().first
        else {
            return
        }
        let frame = fullscreenFrame(
            display: display.frame, usable: visibleFrames[display.id] ?? display.frame,
            gap: session.config.layout.resolvedFullscreenGap
        )
        try? fullscreen.toggle(id, registry: session.registry, frame: frame)
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

/// The menu bar's dedupe gate drives the bar publisher.
extension BarStateGate: PublicationGate {}
