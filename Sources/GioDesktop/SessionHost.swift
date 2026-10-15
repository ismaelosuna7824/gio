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
    /// SM-12: real-window writes dispatched under the snapshot overlay,
    /// folded when the flight ends (`collectDispatchedWrites`).
    private var dispatchedWrites: [(
        pass: WindowReconciler<AXWindowActuator>.DispatchedPass, visible: [WindowID: CGRect],
        parked: [WindowID: ParkedTarget], focusTarget: WindowID?
    )] = []
    private var server: IPCServer?
    private let instanceLock = SingleInstanceLock()
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
    /// SM-09: last time a typing hop reached the session; written on main
    /// in the tap callback, guarded by `typingLock`.
    private var lastTypingHop: TimeInterval?
    private let typingLock = NSLock()
    /// DA-07: set while the app records a shortcut; the tap callback (main)
    /// then passes every combo through. `HotkeyGate` carries its own lock.
    private let hotkeyGate = HotkeyGate()
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
    private var desktopPictureObservers: [NSObjectProtocol] = []
    /// SM-20: system memory pressure trims the snapshot cache (set once at
    /// start, events on the session queue, cancelled at shutdown).
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var spaceMonitor: ManagedSpaceMonitor?
    private var space: SpaceCoordinator!
    private var pendingReflow: DispatchWorkItem?
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
    /// frame). On `queue`.
    private var physicalFrames: [WindowID: CGRect] = [:]
    /// The AX motion: player, display-rate timer, animating pids.
    private var motion: MotionDriver!
    /// Diagnostics: resize-latency probes (owned with the motion).
    private var resizeProbes: ResizeProbeRunner!
    /// Native zoom: presses, settle pollers, verdicts and verifications.
    private var nativeZoom: NativeZoomController!
    /// The next pass is written without motion: armed for the session's
    /// first layout (launch, `gio restart`), Accessibility regained, and a
    /// mouse-abandoned motion (session queue only).
    private var instantPlacement = InstantPlacementGate()
    /// NA-02: windows registered since the last pass (they enter from below).
    private var openingWindows = WindowOpenBook()
    /// PF-02: per-window open timings, one log line when each settles.
    private var openTimeline = WindowOpenTimeline()
    /// NA-04: what triggered the next pass (picks its animation settings).
    private var motionCauses = MotionCauseLatch()
    /// FI-05: render verification: candidates, settled frames, nudges.
    private var renderVerifier: RenderVerifier!
    /// PF-A: one more final pass for windows a busy app made the last one defer.
    private var deferredSettle: DeferredSettle!
    /// PA-04: frames Gio placed and verified; the final pass skips their AX
    /// read. Invalidated by non-echo frame events, minimize/restore, purge,
    /// failures, motions and display changes (session queue only).
    private var trustedFrames = TrustedFrames()
    /// TG-03: trackpad gestures: recognition and the interactive scroll
    /// (session queue), fed by the mailbox (its own lock) from
    /// MultitouchSupport's callback thread, which never touches session state.
    private var gestures: GestureController!
    private var touchMailbox: TouchFrameMailbox!
    /// TG-03: the release of a trackpad scroll, consumed by the next pass.
    private var pendingGestureRelease: GestureRelease?
    /// TG-03, session queue: the symbols MultitouchSupport lacks (nil until
    /// loaded) and how many devices report frames.
    private var multitouchMissing: [String]?
    private var multitouchDevices = 0
    /// TG-03, main thread only: the touch source, its device watcher,
    /// whether it runs and the debounce generation of re-registrations.
    private var multitouch: MultitouchSource?
    private var multitouchWatcher: MultitouchDeviceWatcher?
    private var multitouchRunning = false
    private var multitouchGeneration = 0
    private var multitouchShutDown = false
    /// TG-04, session queue: macOS's own swipe settings, read again at most
    /// every 10 s when the facts are built, and on every config apply.
    private var trackpadPreferences = TrackpadSystemPreferences()
    private var trackpadPreferencesRead: TimeInterval?
    /// SM-02: caches ScreenCaptureKit content between debug captures.
    private let snapshotCapturer = SnapshotCapturer()
    /// PF-X: the Screen Recording check is an IPC to tccd (~8 ms); hot
    /// paths answer from this cache, the polled facts refresh it.
    private let screenRecording = ScreenRecordingPermissionCache()
    /// SM-04: pre-captured window images (refreshed once after each settle,
    /// no periodic timer) and the running overlay flight.
    private var snapshotRefresher: SnapshotCacheRefresher!
    private var overlayFlight: SnapshotFlightController!
    /// SM-04/SM-08 overlay hooks, set once by the app before `start()`. They
    /// are invoked on the session queue and hop to the main thread themselves.
    /// `overlayBegin` primes the overlay and reports back through
    /// `snapshotPrimed`; `overlayFly` starts the tracks after the real writes.
    /// SM-16: the `[CGRect]` are the holes cut in the backdrops (targets of
    /// the windows that fly without a layer). SM-27: the retarget's
    /// `[WindowID: SnapshotFace<CGImage>]` are the images of the new sizes.
    var overlayBegin: ((Int, SpringParameters, [SnapshotDisplayFlight], [CGRect], OverlayDecorations) -> Void)?
    var overlayFly: ((Int) -> Void)?
    var overlayRetarget: ((
        Int, [WindowID: CGRect], [WindowID: SnapshotFace<CGImage>], [SnapshotDisplayFlight], [CGRect], OverlayDecorations
    ) -> Void)?
    var overlayEnd: (() -> Void)?
    /// SM-30: a resized layer's fresh image of its landing size (token,
    /// faces), and the hand-off that fades the resized layers out (ids,
    /// duration) instead of `overlayEnd`.
    var overlayFreshen: ((Int, [WindowID: SnapshotFace<CGImage>]) -> Void)?
    var overlayFade: ((Set<WindowID>, TimeInterval) -> Void)?
    /// Main thread: removes a running flight at once (mouse down); true when one ran.
    var overlayAbortForMouseDown: (() -> Bool)?
    /// NA-03 close ghost hooks, set once by the app before `start()`; invoked
    /// on the session queue, they hop to the main thread themselves.
    var ghostShow: ((Int, CGImage, CGRect, TimeInterval, CGFloat) -> Void)?
    var ghostRemove: ((Int) -> Void)?
    private var closeGhost: CloseGhostController!
    /// The planning half of a reflow pass; owns the hidden-window book and
    /// the inactive parking memo (NC-06, PA-04).
    private var reflowPlanner: ReflowPlanner!
    /// PA-03 / SM-04: refresh rates and capture screens, read on main
    /// (AppKit), read by the session queue behind their lock.
    private let displayParameters = DisplayParameters()
    /// Discovery, registration, purge and display sync; the observers and
    /// event routing on top of it.
    private var discovery: DiscoveryService!
    private var events: WindowEventRouter!
    /// Focus adoption, keyboard intent, centering, cursor warp and
    /// focus-follows-mouse (clicks and pointer handed over under their locks).
    private var focus: FocusCoordinator!
    /// FI-06: rapid actions during a motion merge into one reflow per tick.
    private var reflowCoalescer = ReflowCoalescer()
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
    /// Argument: when the hotkey fired (uptime seconds), for `summon→shown`.
    var onSummonLauncher: ((TimeInterval) -> Void)?
    /// `gio restart` (HD-05): invoked on the main thread shortly after the
    /// IPC reply left; the app shuts the session down and relaunches itself.
    var onRestart: (() -> Void)?
    /// WO-01: Alt+O or `gio overview`; invoked on the main thread. The app
    /// opens or closes the workspace overview panel.
    var onToggleOverview: (() -> Void)?
    /// UP-06: `gio update [--install]`, answered by the app's updater on the
    /// IPC thread (it may block for the network, so never on `queue`). Set
    /// once before `start()`; read-only afterwards.
    var onUpdateRequest: (@Sendable (UpdateCLIRequest) -> String)?

    func requestRestart() {
        onRestart?()
    }

    /// Builds the components. Their contexts read host state on the session
    /// queue; `unowned` is safe because the host owns them and lives as long
    /// as the app.
    init() {
        space = SpaceCoordinator(context: .init(
            reflowAll: { [unowned self] in reflowAll() },
            discardPendingAdoptions: { [unowned self] in focus.discardPendingAdoptions() },
            rescan: { [unowned self] in
                discovery.enumerateAndPlace()
                events.syncObservers()
            },
            adoptFrontmostFocus: { [unowned self] in
                guard let pid = probe.frontmostPID else {
                    return
                }
                focus.requestAdoption(.activation, pid: pid, element: nil)
            },
            log: { GioLog.record($0, $1) }
        ))
        reflowPlanner = ReflowPlanner(context: .init(
            physicalFrames: { [unowned self] in physicalFrames },
            readFrame: { [unowned self] in try? actuator?.frame(of: $0) },
            storePhysicalFrame: { [unowned self] in physicalFrames[$0] = $1 }
        ))
        focusRing = FocusRingPublisher(context: .init(
            session: { [unowned self] in session },
            physicalFrame: { [unowned self] in physicalFrames[$0] },
            displayFrames: { [unowned self] in displays.allDisplays().map(\.frame) },
            isFlightActive: { [unowned self] in overlayFlight.isActive },
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
                isMotionActive: { [unowned self] in motion.isActive || gestures.isTracking },
                isFlightActive: { [unowned self] in overlayFlight.isActive },
                isNativeZoomActive: { [unowned self] in nativeZoom.isActive },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                isShuttingDown: { [unowned self] in isShuttingDown },
                frontToBack: { [unowned self] in probe.windowServerWindows(displayHeight: primaryHeight()) },
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
            screenRecordingGranted: { [unowned self] in screenRecording.refresh() },
            accessibilityGranted: { hasAXPermission() },
            configFileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: { FileManager.default.homeDirectoryForCurrentUser.path },
            prefetchSnapshotContent: { [unowned self] in snapshotRefresher.prefetchIfNeeded(permissionGranted: $0) },
            gestureStatus: { [unowned self] in
                gestureSourceStatus(
                    enabled: session.config.gestures.anyEnabled, missingSymbols: multitouchMissing,
                    devices: multitouchDevices
                )
            },
            gestureConflicts: { [unowned self] in gestureConflicts() },
            log: { GioLog.record($0, $1) }
        ))
        renderVerifier = RenderVerifier(
            context: .init(
                isShuttingDown: { [unowned self] in isShuttingDown },
                isMotionActive: { [unowned self] in motion.isActive || gestures.isTracking },
                isFlightActive: { [unowned self] in overlayFlight.isActive },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                isReady: { [unowned self] in reconciler != nil },
                visibleTargets: { [unowned self] in focus.hoverFrames },
                viewports: { [unowned self] in displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame } },
                serverWindows: { [unowned self] in probe.windowServerWindows(displayHeight: primaryHeight()) },
                nudge: { [unowned self] in reconciler?.nudge(steps: $0) ?? [] },
                recordEcho: { [unowned self] in echoGate.recordApplied($0, frame: $1, at: $2) },
                appName: { [unowned self] in appName($0) },
                log: { GioLog.record($0, $1) },
                serverWindowStates: { [unowned self] in windowServerWindowStates(pid: $0, displayHeight: primaryHeight()) }
            ),
            scheduler: scheduler
        )
        snapshotRefresher = SnapshotCacheRefresher(
            context: .init(
                session: { [unowned self] in session },
                displays: { [unowned self] in displays.allDisplays() },
                physicalFrame: { [unowned self] in physicalFrames[$0] },
                isShuttingDown: { [unowned self] in isShuttingDown },
                isFlightActive: { [unowned self] in overlayFlight.isActive },
                isMotionActive: { [unowned self] in motion.isActive || gestures.isTracking },
                rendererAvailable: { [unowned self] in
                    SnapshotCapturer.isSupported
                        && effectiveRenderer(
                            config: session.config.animations, permission: screenRecording.granted()
                        ) == .snapshot
                },
                ghostCacheWanted: { [unowned self] in
                    SnapshotCapturer.isSupported && closeGhostEnabled() && screenRecording.granted()
                },
                captureScreens: { [unowned self] in displayParameters.captureScreens },
                capture: { [snapshotCapturer] request, done in
                    Task.detached {
                        let result = await snapshotCapturer.capture(request)
                        done(SnapshotCaptureOutcome(
                            images: result.snapshots.mapValues {
                                CapturedImage(image: $0.image, frame: $0.frame, fill: $0.fill)
                            },
                            backdrops: result.backdrops.values.map {
                                CapturedBackdropImage(image: $0.image, displayFrame: $0.frame)
                            },
                            misses: result.summary.misses
                        ))
                    }
                },
                prefetch: { [snapshotCapturer] managed, done in
                    Task.detached {
                        await snapshotCapturer.prefetch(managed: managed)
                        done()
                    }
                },
                serverWindows: { [unowned self] in probe.windowServerWindows(displayHeight: primaryHeight()) },
                ownPid: getpid(),
                log: { GioLog.record($0, $1) },
                appName: { [unowned self] in appName($0) },
                physicalMemory: ProcessInfo.processInfo.physicalMemory
            ),
            scheduler: scheduler
        )
        closeGhost = CloseGhostController(
            context: .init(
                isEnabled: { [unowned self] in closeGhostEnabled() },
                isMinimized: { [unowned self] in session.registry.find($0)?.isMinimized ?? true },
                physicalFrame: { [unowned self] in physicalFrames[$0] },
                viewports: { [unowned self] in displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame } },
                cachedImage: { [unowned self] id in
                    snapshotRefresher.cache.entry(id).map { ($0.image, $0.frame, $0.capturedAt) }
                },
                log: { GioLog.record($0, $1) }
            ),
            port: HostGhostPort(host: self), scheduler: scheduler
        )
        overlayFlight = SnapshotFlightController(
            context: .init(
                displayFrames: { [unowned self] in displays.allDisplays().map(\.frame) },
                usableFrames: { [unowned self] in displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame } },
                physicalFrames: { [unowned self] in physicalFrames },
                isShuttingDown: { [unowned self] in isShuttingDown },
                takeCoalescedReflow: { [unowned self] in reflowCoalescer.takeAtTick() },
                requestReflow: { [unowned self] in _ = reflowCoalescer.request(motionActive: true) },
                performReflow: { [unowned self] in performReflow() },
                decorations: { [unowned self] in focusRing.flightDecorations(targets: $0) },
                // SM-08: the dim is computed now (not 50 ms later) so the live
                // ring and dim are up in the frame the overlay leaves.
                publishIndicators: { [unowned self] in
                    focusDim.publishNow()
                    focusRing.publish()
                },
                collectWrites: { [unowned self] in collectDispatchedWrites() },
                scheduleRenderCheck: { [unowned self] in
                    if renderVerifier.hasCandidates {
                        renderVerifier.schedule()
                    }
                },
                // SM-14: tiny captures off the session queue; the answer hops back.
                // SM-29: probes carry a resized window's start size and background.
                checkPaint: { [unowned self, snapshotCapturer] probes, answer in
                    let (screens, primary) = displayParameters.captureScreens
                    Task.detached {
                        answer(await snapshotCapturer.paintCheck(
                            windows: probes, displays: screens, primaryDisplayHeight: primary
                        ))
                    }
                },
                // SM-30: a resized window captured again at its target size mid-flight.
                captureFresh: { [unowned self, snapshotCapturer] id, probe, answer in
                    let (screens, primary) = displayParameters.captureScreens
                    Task.detached {
                        answer(await snapshotCapturer.freshCapture(
                            id, probe: probe, displays: screens, primaryDisplayHeight: primary
                        ))
                    }
                },
                log: { GioLog.record($0, $1) }
            ),
            cache: snapshotRefresher, overlay: HostOverlayPort(host: self), scheduler: scheduler
        )
        nativeZoom = NativeZoomController(
            context: .init(
                isShuttingDown: { [unowned self] in isShuttingDown },
                isMotionActive: { [unowned self] in motion.isActive },
                isFlightActive: { [unowned self] in overlayFlight.isActive },
                isEnabled: { [unowned self] in session.config.animations.nativeZoom },
                snapshotRendererUsable: { [unowned self] in snapshotRefresher.rendererUsable() },
                physicalFrame: { [unowned self] in physicalFrames[$0] },
                setPhysicalFrame: { [unowned self] in physicalFrames[$0] = $1 },
                invalidateTrust: { [unowned self] in trustedFrames.invalidate($0) },
                trust: { [unowned self] in trustedFrames.trust($0, frame: $1) },
                recordEcho: { [unowned self] in echoGate.recordApplied($0, frame: $1, at: $2) },
                windowServerID: { [unowned self] id, frame in
                    let candidates = windowServerSnapshotCandidates(pids: [id.pid], displayHeight: primaryHeight())
                    guard case .matched(let windowID)? = matchSnapshotCandidates(
                        managed: [id: frame], candidates: candidates
                    )[id] else {
                        return nil
                    }
                    return windowID
                },
                windowServerBounds: { [unowned self] in windowServerBounds(windowID: $0, displayHeight: primaryHeight()) },
                zoomAvailability: { [unowned self] in
                    reconciler?.zoomAvailability(of: $0) ?? .unavailable("no reconciler")
                },
                pressZoom: { [unowned self] in reconciler?.pressZoom($0) ?? .unavailable("no reconciler") },
                reassert: { [unowned self] id, target in
                    guard let reconciler else {
                        return nil
                    }
                    trustedFrames.invalidate(id)
                    let report = reconciler.reconcile(
                        frames: [id: target], parked: [:], focused: nil, currentlyFocused: nil, trusted: trustedFrames
                    )
                    return report.failed.contains(id)
                },
                updateDim: { [unowned self] in focusDim.update() },
                instantReflow: { [unowned self] in performReflow(animate: false) },
                appName: { [unowned self] in appName($0) },
                log: { GioLog.record($0, $1) }
            ),
            scheduler: scheduler
        )
        resizeProbes = ResizeProbeRunner(
            context: .init(
                isShuttingDown: { [unowned self] in isShuttingDown },
                matchWindows: { [unowned self] managed in
                    let candidates = windowServerSnapshotCandidates(
                        pids: Set(managed.keys.map(\.pid)), displayHeight: primaryHeight()
                    )
                    return matchSnapshotCandidates(managed: managed, candidates: candidates)
                },
                windowServerSize: { windowServerSize(windowID: $0) },
                isSizeSettable: { [unowned self] in actuator?.element(for: $0).map(axIsSizeSettable) ?? false },
                appName: { [unowned self] in appName($0) },
                log: { GioLog.record($0, $1) }
            ),
            scheduler: scheduler
        )
        motion = MotionDriver(
            context: .init(
                isShuttingDown: { [unowned self] in isShuttingDown },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                armInstantPlacementForMouse: { [unowned self] in instantPlacement.arm(.mouse) },
                reflowAll: { [unowned self] in reflowAll() },
                takeCoalescedReflow: { [unowned self] in reflowCoalescer.takeAtTick() },
                resetCoalescer: { [unowned self] in reflowCoalescer.reset() },
                performReflow: { [unowned self] in performReflow() },
                finalPass: { [unowned self] in performReflow(animate: false) },
                recordSampled: { [unowned self] id, frame, now in
                    physicalFrames[id] = frame
                    echoGate.recordApplied(id, frame: frame, at: now)
                },
                recordPreposition: { [unowned self] id, frame, now in
                    physicalFrames[id] = frame
                    trustedFrames.invalidate(id)
                    echoGate.recordApplied(id, frame: frame, at: now)
                },
                markUnverified: { [unowned self] id in
                    trustedFrames.invalidate(id)
                    renderVerifier.insertCandidate(id)
                },
                focusedWindow: { [unowned self] in session.manager.currentWorkspace().focusedWindow },
                publishFocusRing: { [unowned self] in publishFocusRing() },
                learnResizeCapability: { [unowned self] in learnResizeCapability(from: $0) },
                physicalFrame: { [unowned self] in physicalFrames[$0] },
                displayRefreshes: { [unowned self] in displayParameters.displayRefreshes },
                playerAppName: { [probe] in probe.applicationName($0) },
                log: { GioLog.record($0, $1) }
            ),
            resizeProbes: resizeProbes, scheduler: scheduler
        )
        deferredSettle = DeferredSettle(
            context: .init(
                isBusy: { [unowned self] in reconciler?.isMotionBusy(pids: $0) ?? false },
                isMotionActive: { [unowned self] in motion.isActive },
                finalPass: { [unowned self] in performReflow(animate: false) },
                log: { GioLog.record($0, $1) }
            ),
            scheduler: scheduler
        )
        discovery = DiscoveryService(
            context: .init(
                registry: { [unowned self] in session.registry },
                manager: { [unowned self] in session.manager },
                updateManager: { [unowned self] body in body(&session.manager) },
                rules: { [unowned self] in session.config.rules },
                discoverAll: { try? discoverSystemWindows(onlyPID: $0) },
                discoverOne: { discoverSystemWindow(element: $0, pid: $1) },
                knownWindow: { [unowned self] in actuator?.id(matching: $0, pid: $1) },
                registerHandles: { [unowned self] id, candidate in
                    actuator?.register(
                        elementID: id.elementID, pid: id.pid,
                        element: candidate.element, appElement: candidate.appElement
                    )
                },
                watchWindow: { [unowned self] in events.watch(window: $0, pid: $1) },
                displayHeight: { [unowned self] in primaryHeight() },
                isRunning: { [unowned self] in probe.isRunning($0) },
                frontmostPID: { [unowned self] in probe.frontmostPID },
                currentClick: { [unowned self] in focus.currentClick() },
                adoptFocus: { [unowned self] in focus.adoptFocus($0, source: $1) },
                invalidateTrust: { [unowned self] in trustedFrames.invalidate($0) },
                resetWindowState: { [unowned self] id in
                    tileability.invalidate(id)
                    minimumSizes.forget(id)
                    trustedFrames.invalidate(id)
                    events.forgetSnapBacks(id)
                },
                forgetWindow: { [unowned self] id in
                    tileability.invalidate(id)
                    minimumSizes.forget(id)
                    echoGate.forget(id)
                    trustedFrames.invalidate(id)
                    events.forgetSnapBacks(id)
                    renderVerifier.forget([id])
                    physicalFrames.removeValue(forKey: id)
                    nativeZoom.purge(id)
                    resizeProbes.forget(id)
                    snapshotRefresher.evict([id])
                    fullscreen.forget(id)
                    openingWindows.forget(id)
                    openTimeline.forget(id)
                    actuator?.forget(elementID: id.elementID)
                },
                forgetApp: { [unowned self] in reconciler?.forgetApp(pid: $0) },
                reflowAll: { [unowned self] in reflowAll() },
                displaySnapshots: { snapshotDisplayList() },
                knownDisplayIDs: { [unowned self] in displays.allDisplays().map(\.id) },
                connectDisplay: { [unowned self] display, workspace in
                    visibleFrames[display.id] = display.visibleFrame
                    displays.connect(display.id, frame: display.frame, workspace: workspace)
                },
                disconnectDisplay: { [unowned self] id in
                    displays.disconnect(id)
                    visibleFrames.removeValue(forKey: id)
                },
                displayFrames: { [unowned self] in
                    displays.allDisplays().reduce(into: [:]) { $0[$1.id] = visibleFrames[$1.id] ?? $1.frame }
                },
                updateDisplayHeight: { [unowned self] in actuator?.updateDisplayHeight($0) },
                displaysChanged: { [unowned self] in
                    trustedFrames.removeAll()
                    // MM-04: macOS may have moved windows: land, never fly
                    // from a stale frame (startup is already instant).
                    instantPlacement.arm(.displays)
                    reflowPlanner.invalidateParking()
                    focusRing.resetGate()
                    snapshotRefresher.markBackdropDirty()
                },
                windowOpened: { [unowned self] in
                    openingWindows.mark($0)
                    motionCauses.note(.windowOpen)
                },
                windowsClosing: { [unowned self] in
                    motionCauses.note(.windowClose)
                    closeGhost.windowsClosing($0)
                },
                followArrival: { [unowned self] previous in
                    // NW-02: the config asked to follow this arrival to its
                    // named workspace; the following reflow focuses it.
                    // PF-02: that reflow is the switch (no separate entry).
                    syncShownWorkspace()
                    motionCauses.note(.workspaceSwitch)
                    focus.requestIntent(if: true, previous: previous)
                },
                discoverAttempt: { discoverSystemWindowAttempt(element: $0, pid: $1) },
                windowRegistered: { [unowned self] timing in
                    openTimeline.registered(timing)
                    snapshotRefresher.noteRegistered(timing.id)
                },
                log: { GioLog.record($0, $1) },
                allowsWindowWork: { [unowned self] in space.allowsWindowWork },
                listedWindows: { axWindowElements(pid: $0) },
                windowFrame: { [unowned self] in try? actuator?.frame(of: $0) }
            ),
            scheduler: scheduler
        )
        events = WindowEventRouter(
            context: .init(
                makePort: { SystemWindowObserver(onEvent: $0) },
                runningRegularPIDs: { [unowned self] in probe.runningRegularPIDs() },
                isRegularApplication: { [unowned self] in probe.isRegularApplication($0) },
                isTapMissing: { [unowned self] in hotkeyTap == nil },
                scheduleReflow: { [unowned self] in scheduleReflow(full: $0) },
                reflowAll: { [unowned self] in reflowAll() },
                requestFocusAdoption: { [unowned self] in focus.requestAdoption($0, pid: $1, element: $2) },
                updateDim: { [unowned self] in focusDim.update() },
                holdDimForDrag: { [unowned self] in focusDim.holdForDrag() },
                animatingPids: { [unowned self] in
                    gestures.isTracking ? motion.animatingPids.union(gestures.animatingPids) : motion.animatingPids
                },
                knownWindow: { [unowned self] in actuator?.id(matching: $0, pid: $1) },
                isZoomBusy: { [unowned self] in nativeZoom.isBusy($0) },
                forgetZoom: { [unowned self] in nativeZoom.forget($0) },
                isEchoSuppressed: { [unowned self] in echoGate.isSuppressed($0, at: $1) },
                frame: { [unowned self] in try? actuator?.frame(of: $0) },
                isEcho: { [unowned self] in echoGate.isEcho($0, observed: $1, at: $2) },
                invalidateTrust: { [unowned self] in trustedFrames.invalidate($0) },
                invalidateTileability: { [unowned self] in tileability.invalidate($0) },
                title: { axTitle(of: $0) },
                registry: { [unowned self] in session.registry },
                console: { print($0) },
                log: { GioLog.record($0, $1) },
                lastWrite: { [unowned self] in echoGate.lastWrite(of: $0) },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                writtenFrame: { [unowned self] in echoGate.writtenFrame(of: $0) },
                learnLateClamp: { [unowned self] in learnLateClamp($0, written: $1, observed: $2) }
            ),
            discovery: discovery, scheduler: scheduler
        )
        focus = FocusCoordinator(
            context: .init(
                isShuttingDown: { [unowned self] in isShuttingDown },
                isMouseDown: { [unowned self] in probe.isMouseDown },
                mouseLocation: { [unowned self] in probe.mouseLocation },
                frontmostPID: { [unowned self] in probe.frontmostPID },
                windowAreas: { [unowned self] in displays.allDisplays().map { visibleFrames[$0.id] ?? $0.frame } },
                currentWorkspace: { [unowned self] in session.manager.currentWorkspace() },
                updateWorkspace: { [unowned self] in session.manager.update($0) },
                isMinimized: { [unowned self] in session.registry.find($0)?.isMinimized == true },
                knownWindow: { [unowned self] in actuator?.id(matching: $0, pid: $1) },
                focusedWindowElement: { focusedWindowElement(pid: $0) },
                frame: { [unowned self] in try? actuator?.frame(of: $0) },
                registerAppeared: { [unowned self] in discovery.registerAppeared($0, pid: $1) },
                pendingScroll: { [unowned self] in pendingScroll() },
                isVisibleInViewport: { [unowned self] in isVisibleInViewport($0) },
                topWindowOwnerPID: { topWindowOwnerPID(atCocoa: $0) },
                warpCursor: { warpCursor(toCocoa: $0) },
                mouseFollowsFocus: { [unowned self] in session.config.behavior.mouseFollowsFocus },
                centerMode: { [unowned self] in session.config.layout.centerFocusedColumn },
                publishFocusRing: { [unowned self] in publishFocusRing() },
                reflowAll: { [unowned self] in reflowAll() },
                workspaceFocusPlan: { [unowned self] in planFocusWindow($0, in: session.manager) },
                showWorkspace: { [unowned self] workspace, cause in
                    _ = session.manager.focus(workspace)
                    syncShownWorkspace()
                    motionCauses.note(cause)
                },
                log: { GioLog.record($0, $1) },
                allowsWindowWork: { [unowned self] in space.allowsWindowWork },
                bringTabToFront: { [unowned self] in discovery.bringTabToFront($0) }
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
                    reflowPlanner.invalidateParking()
                    focusRing.resetGate()
                    applyGestureConfig()
                },
                setFocusFollowsMouse: { [unowned self] in focus.focusFollowsMouse = $0 },
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
            dispatch: { [unowned self] argv in
                // MM-06: `gio move left/right` may cross to a neighbouring display.
                session.displayFrames = Dictionary(
                    displays.allDisplays().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first }
                )
                // DW-02: `gio focus` / `gio move` measure dwindle tiles in the usable frames.
                session.visibleFrames = Dictionary(
                    displays.allDisplays().map { ($0.id, visibleFrames[$0.id] ?? $0.frame) },
                    uniquingKeysWith: { first, _ in first }
                )
                return dispatchIPC(argv, session: &session, restartAvailable: true)
            },
            applyReloadedConfig: { [unowned self] in configCoordinator.applyReloadedConfig() },
            requestFocusIntent: { [unowned self] in focus.requestIntent(if: $0, previous: $1) },
            reflow: { [unowned self] in reflowAll() },
            publishBar: { [unowned self] in barPublisher.publish() },
            mainAfter: { delay, block in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block) },
            restart: { [weak self] in self?.onRestart?() },
            toggleOverview: { [weak self] in
                DispatchQueue.main.async { self?.onToggleOverview?() }
            },
            log: { GioLog.record($0, $1) }
        ))
        gestures = GestureController(context: .init(
            settings: { [unowned self] in session.config.gestures },
            isMouseDown: { [unowned self] in probe.isMouseDown },
            surface: { [unowned self] in gestureSurface() },
            physicalFrames: { [unowned self] in physicalFrames },
            sink: { [unowned self] in reconciler },
            updateManager: { [unowned self] body in body(&session.manager) },
            beginTracking: { [unowned self] in
                // The fingers take the strip from wherever a motion left it;
                // passes wait for the release (`performReflow`).
                motion.stop()
                overlayFlight.end()
                renderVerifier.cancel()
                focusDim.update()
            },
            recordSampled: { [unowned self] id, frame, now in
                physicalFrames[id] = frame
                echoGate.recordApplied(id, frame: frame, at: now)
            },
            markUnverified: { [unowned self] id in
                trustedFrames.invalidate(id)
                renderVerifier.insertCandidate(id)
            },
            focusedWindow: { [unowned self] in session.manager.currentWorkspace().focusedWindow },
            publishFocusRing: { [unowned self] in publishFocusRing() },
            settle: { [unowned self] release in
                if release.focusChanged {
                    focus.requestGestureIntent()
                }
                pendingGestureRelease = release
                motionCauses.note(.viewScroll)
                performReflow()
            },
            abandon: { [unowned self] reason in
                // A mouse-abandoned gesture lands like a mouse-abandoned
                // flight: instantly, once the button is up.
                if reason == .mouse {
                    instantPlacement.arm(.mouse)
                }
                reflowAll()
            },
            perform: { [unowned self] in apply($0) },
            toggleOverview: { [weak self] in
                DispatchQueue.main.async { self?.onToggleOverview?() }
            },
            log: { GioLog.record($0, $1) }
        ))
        touchMailbox = TouchFrameMailbox(scheduler: scheduler) { [unowned self] in gestures.deliver($0) }
    }

    // MARK: - Lifecycle

    /// Starts everything. Returns an error message instead of starting when
    /// another instance holds the lock or the socket cannot bind.
    private var guardian: GuardianHandle?

    /// UP-05: the guardian's pid (main thread; set by `start()`), so the
    /// update helper waits for it to exit too.
    var guardianPID: Int32? {
        guardian?.processIdentifier
    }

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
            if let request = parseUpdateRequest(argv), let answer = self.onUpdateRequest {
                return IPCResponse(ok: true, output: answer(request))
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
        GioLog.record(.info, "spaces separate=\(displaysHaveSeparateSpaces())")
        guardian = spawnGuardian()
        queue.sync {
            self.initialSync()
        }
        watchDisplays()
        watchDesktopPicture()
        watchMemoryPressure()
        watchManagedSpace()
        queue.sync {
            self.events.rebuild()
            self.publishSnapshot()
        }
        startTap()
        startMultitouch(gestures: config.gestures)
        return nil
    }

    /// Gio is exiting (Quit, SIGTERM/SIGINT/SIGHUP): stop laying out, bring
    /// every parked or off-screen window back on screen through the
    /// reconciler, release the socket and lock. Idempotent and synchronous,
    /// so it is safe to call from both the terminate hook and a signal.
    func shutdown() {
        // TG-03: no touch frame arrives after this (main thread). The source
        // itself stays alive: a callback already running holds its refcon.
        multitouchWatcher = nil
        multitouch?.stop()
        multitouchRunning = false
        multitouchShutDown = true
        queue.sync {
            guard !isShuttingDown else {
                return
            }
            isShuttingDown = true
            pendingReflow?.cancel()
            motion.stop()
            overlayFlight.end()
            memoryPressure?.cancel()
            snapshotRefresher.removeAll()
            closeGhost.removeAll()
            reconciler?.waitForMotionIdle(timeout: 0.3)
            // PF-K: no app is left with `AXEnhancedUserInterface` off (VoiceOver).
            reconciler?.restoreEnhancedUI(waiting: true)
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
        // WC-11: a background tab is never written (macOS moves it with its front tab).
        let ids = ids.filter { !discovery.isBackgroundTab($0) }
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
            motion.stop()
            overlayFlight.end()
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

    /// SM-02 debug action (Diagnostics): captures the visible managed windows
    /// and a backdrop once, logs the summary and hands it back on the main
    /// queue. Never runs from a motion; images are released on return. The
    /// session queue only reads bookkeeping, the capture runs in a task.
    func testSnapshotCapture(completion: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            guard screenRecording.refresh() else {
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
                    primaryDisplayHeight: primaryScreen()?.frame.height ?? 1169,
                    measure: true, reason: .measure
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
            focus.requestIntent(if: true, previous: previous)
            GioLog.record(
                .info,
                "focus window requested id=\(id.pid):\(id.elementID) workspace=\(plan.index) switched=\(plan.switchesWorkspace)"
            )
            reflowAll()
        }
        return true
    }

    /// WO-01: the focused display's stack for the overview, built on the
    /// session queue and handed back on the main thread (nil without a
    /// focused display).
    func workspaceOverview(completion: @escaping @Sendable (WorkspaceOverviewFacts?) -> Void) {
        queue.async { [weak self] in
            self?.focusOverviewDisplay()
            let facts = self?.factsBuilder.workspaceOverview()
            DispatchQueue.main.async { completion(facts) }
        }
    }

    /// MM-04: the overview opens on the display the user is on: the one
    /// holding the focused window (the frontmost app's front window, as the
    /// WindowServer lists it, so focus Gio did not adopt counts too), else
    /// the display under the cursor, else the focused display.
    private func focusOverviewDisplay() {
        let own = ProcessInfo.processInfo.processIdentifier
        let frontmost = probe.frontmostPID.flatMap { $0 == own ? nil : $0 }
        let focusedFrame = frontmost.flatMap { pid in
            probe.windowServerWindows(displayHeight: primaryHeight()).first { $0.pid == pid }?.bounds
        }
        var manager = session.manager
        guard let choice = ActionApplier.focusOverviewDisplay(
            manager: &manager, focusedWindowFrame: focusedFrame, cursor: probe.mouseLocation,
            displays: displays.allDisplays()
        ) else {
            return
        }
        session.manager = manager
        GioLog.record(.info, "overview display id=\(choice.display.rawValue) reason=\(choice.reason.rawValue)")
    }

    /// WO-01: one capture of the given windows (`WindowFact.id`s) at their
    /// current physical frames, parked ones included, without a backdrop and
    /// at most `overviewThumbnailScale`. Empty without Screen Recording or
    /// before macOS 14; the panel then keeps the app icons. Main-thread
    /// completion; the capture logs its own summary (counts only).
    func captureOverviewThumbnails(
        _ ids: [String], completion: @escaping @Sendable ([String: OverviewThumbnail]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, SnapshotCapturer.isSupported, screenRecording.granted() else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            var frames: [WindowID: CGRect] = [:]
            for text in ids {
                if let id = WindowID(text: text), session.registry.find(id)?.isMinimized == false,
                   let frame = physicalFrames[id] {
                    frames[id] = frame
                }
            }
            guard !frames.isEmpty else {
                DispatchQueue.main.async { completion([:]) }
                return
            }
            let (screens, primaryHeight) = displayParameters.captureScreens
            let request = SnapshotCaptureRequest(
                windows: frames,
                displays: screens.map {
                    SnapshotDisplay(id: $0.id, frame: $0.frame, scale: min($0.scale, overviewThumbnailScale))
                },
                primaryDisplayHeight: primaryHeight, includeBackdrop: false, budgetMilliseconds: 1500, reason: .overview
            )
            Task.detached { [snapshotCapturer] in
                let result = await snapshotCapturer.capture(request)
                var thumbnails: [String: OverviewThumbnail] = [:]
                for (id, snapshot) in result.snapshots {
                    thumbnails[windowFactID(id)] = OverviewThumbnail(image: snapshot.image)
                }
                DispatchQueue.main.async { completion(thumbnails) }
            }
        }
    }

    /// WO-01: the overview picked a workspace row with no window; same path
    /// as `workspace N` (past the end lands on the empty one at the bottom).
    func focusWorkspace(_ index: Int) {
        queue.async { [weak self] in
            self?.apply(.workspace(index))
        }
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
        let wanted = focus.focusFollowsMouse
        guard tapNeedsRestart(observingMouseMoved: tap.observesMouseMoved, wanted: wanted) else {
            return
        }
        tap.stop()
        hotkeyTap = nil
        startTap()
        GioLog.record(.info, "hotkey tap restarted mouse-moved=\(wanted)")
    }

    // MARK: - Trackpad gestures (TG-03)

    /// Main thread, once at start: load MultitouchSupport (a missing symbol
    /// leaves gestures off and Gio otherwise unchanged), register the devices
    /// when a gesture is on, and watch for devices coming and going.
    private func startMultitouch(gestures: GesturesSectionConfig) {
        let mailbox = touchMailbox!
        let loaded = MultitouchSource.load { mailbox.post($0) }
        multitouch = loaded.source
        let devices = gestures.anyEnabled ? (loaded.source?.start() ?? 0) : 0
        multitouchRunning = gestures.anyEnabled && loaded.source != nil
        if loaded.source != nil {
            multitouchWatcher = MultitouchDeviceWatcher { [weak self] in
                self?.multitouchTopologyChanged()
            }
        }
        queue.async { [weak self] in
            guard let self else {
                return
            }
            multitouchMissing = loaded.missing
            multitouchDevices = devices
            applyGestureConfig()
            publishSnapshot()
        }
    }

    /// Session queue, at start and on every config change: the mailbox lets
    /// through only what the enabled gestures can use, and the devices run
    /// only while a gesture is on.
    private func applyGestureConfig() {
        let gestures = session.config.gestures
        touchMailbox.setMinimumFingers(gestures.recognizerSettings.minimumFingers)
        // TG-04: a reload re-reads macOS's swipe settings for the facts.
        trackpadPreferencesRead = nil
        DispatchQueue.main.async { [weak self] in
            self?.setMultitouchRunning(gestures.anyEnabled)
        }
    }

    /// Main thread.
    private func setMultitouchRunning(_ running: Bool) {
        guard let multitouch, running != multitouchRunning, !multitouchShutDown else {
            return
        }
        multitouchRunning = running
        let devices = running ? multitouch.start() : 0
        if !running {
            multitouch.stop()
        }
        GioLog.record(.info, "gestures devices running=\(running) count=\(devices)")
        queue.async { [weak self] in
            self?.multitouchDevices = devices
            self?.publishSnapshot()
        }
    }

    /// Main thread: a multitouch device appeared or vanished, or the Mac
    /// woke up. Registers again once things settle (a burst re-registers once).
    private func multitouchTopologyChanged() {
        multitouchGeneration += 1
        let generation = multitouchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, generation == multitouchGeneration, multitouchRunning, let multitouch else {
                return
            }
            let devices = multitouch.start()
            GioLog.record(.info, "gestures devices re-registered count=\(devices)")
            queue.async { [weak self] in
                self?.multitouchDevices = devices
                self?.publishSnapshot()
            }
        }
    }

    /// Session queue (facts): Gio's gestures that macOS performs too. The
    /// preferences are re-read at most every 10 s (a few `cfprefsd` round
    /// trips, only while the facts are built: UI polling, config changes);
    /// no gesture can run without MultitouchSupport, so nothing collides then.
    private func gestureConflicts() -> [GestureConflict] {
        let now = ProcessInfo.processInfo.systemUptime
        if trackpadPreferencesRead.map({ now - $0 >= 10 }) ?? true {
            trackpadPreferences = readTrackpadSystemPreferences()
            trackpadPreferencesRead = now
        }
        guard multitouchMissing?.isEmpty == true else {
            return []
        }
        return detectGestureConflicts(session.config.gestures, preferences: trackpadPreferences)
    }

    /// Session queue: the strip a scroll moves (the display under the
    /// pointer, else the focused one), with what laying it out needs.
    private func gestureSurface() -> GestureSurface? {
        let all = displays.allDisplays()
        guard let display = gestureDisplay(at: probe.mouseLocation, displays: all, focused: session.manager.focusedDisplay),
              let workspace = session.manager.workspace(id: display.workspace)
        else {
            return nil
        }
        return GestureSurface(
            display: display.id, workspace: workspace, modes: tileableModes(), engine: engine(),
            viewport: visibleFrames[display.id] ?? display.frame, displayFrame: display.frame,
            otherDisplays: all.filter { $0.id != display.id }.map(\.frame),
            centering: session.config.layout.centerFocusedColumn == .always
        )
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
            SessionSnapshot(facts: factsBuilder.facts(), config: session.config)
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
        // SM-09: a focus move repaints both windows; their images follow.
        snapshotRefresher.noteFocus(session.manager.currentWorkspace().focusedWindow)
    }

    // MARK: - Sync

    /// MM-01: the global AX/WindowServer flip height is the primary
    /// display's, whichever screen holds the key window.
    private func primaryHeight() -> CGFloat {
        probe.primaryScreenHeight
    }

    private func initialSync() {
        if actuator == nil {
            let created = AXWindowActuator(displayHeight: primaryHeight())
            actuator = created
            // SM-17: the snapshot title tie-break reads the AX title of a
            // registered element on the capture task (the actuator's handle
            // table is behind its lock); titles never leave the capturer.
            nonisolated(unsafe) let handles = created
            snapshotCapturer.setWindowTitleReader { id in
                handles.element(for: id).flatMap(axTitle(of:))
            }
            // SM-20: equal or missing titles fall back to the app's AX
            // window order, mapped to registered ids (no titles), read on
            // the capture task as well.
            snapshotCapturer.setWindowOrderReader { pid in
                axWindowOrder(pid: pid) { handles.id(matching: $0, pid: pid) }
            }
        }
        actuator?.countsCalls = GioLog.minimumLevel <= .debug
        // MM-01: displays first, so every startup window lands in the stack
        // of the display it sits on (not all in the first one).
        discovery.syncDisplays()
        discovery.enumerateAndPlace()
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

    /// Config reload: rule-owned floats and rule width limits follow the new
    /// rules. Workspace assignment, width, maximized, display and focus are
    /// not re-applied (rules place windows at arrival only);
    /// named workspaces were already re-applied when `session.config` was
    /// assigned (`CommandSession.config` didSet, NW-02).
    private func reapplyRules() {
        for change in reevaluateRules(session.config.rules, windows: session.registry.managedWindows()) {
            switch change {
            case .float(let id):
                try? session.registry.setFloating(.rule, for: id)
            case .tile(let id):
                try? session.registry.setMode(.tiled, for: id)
                tileability.invalidate(id)
            case .widthLimits(let id, let limits):
                if var record = session.registry.find(id) {
                    record.widthLimits = limits
                    try? session.registry.update(record)
                }
            }
        }
    }

    // MARK: - Reflow

    private func engine() -> ScrollableLayoutEngine {
        // Rebuilt per pass so config reloads apply instantly. Display
        // independent (MM-01): default widths resolve per display viewport.
        ScrollableLayoutEngine(
            config: session.config.makeLayoutConfig(),
            minimumSizes: minimumSizes.sizes,
            widthLimits: ruleWidthLimits()
        )
    }

    /// WR-05: rule width limits of the registered windows. Empty, without a
    /// pass over the registry, when no rule sets any (a reload clears the
    /// windows' limits through `reapplyRules`).
    private func ruleWidthLimits() -> [WindowID: ColumnWidthLimits] {
        guard session.config.rules.contains(where: { $0.minWidth != nil || $0.maxWidth != nil }) else {
            return [:]
        }
        var limits: [WindowID: ColumnWidthLimits] = [:]
        for window in session.registry.managedWindows() {
            if let windowLimits = window.widthLimits {
                limits[window.id] = windowLimits
            }
        }
        return limits
    }

    /// FI-02: a write that landed larger than asked teaches the layout that
    /// window's minimum; relayout once so neighbours make room instead of
    /// being overlapped. Bounded: only a strictly larger minimum triggers it.
    private func learnMinimumSizes(from report: ReconcileReport, placement: InstantPlacementDecision) {
        let changed = minimumSizes.learn(from: report, placement: placement)
        guard !changed.isEmpty else {
            return
        }
        for id in changed.keys.sorted() {
            logLearnedMinimum(id, size: changed[id]!, late: false)
        }
        scheduleReflow(full: false)
    }

    /// FI-11: a clamp the app applied after the write's read-back, found by
    /// the router's late re-check (`observed`) against Gio's last write.
    private func learnLateClamp(_ id: WindowID, written: CGRect, observed: CGRect) -> Bool {
        guard let size = minimumSizes.learnLate(id, requested: written, actual: observed) else {
            return false
        }
        physicalFrames[id] = observed
        trustedFrames.invalidate(id)
        logLearnedMinimum(id, size: size, late: true)
        scheduleReflow(full: false)
        return true
    }

    private func logLearnedMinimum(_ id: WindowID, size: CGSize, late: Bool) {
        noteResizeClamp(pid: id.pid)
        GioLog.record(
            .info,
            "min size learned id=\(id.pid):\(id.elementID) "
                + "app=\(session.registry.find(id)?.application ?? "pid\(id.pid)") "
                + "w=\(Int(size.width.rounded())) h=\(Int(size.height.rounded()))"
                + (late ? " late=true" : "")
        )
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

    /// Would `id` be inside its display's viewport under the current offset?
    /// DW-01: a shown dwindle workspace has every window on screen.
    private func isVisibleInViewport(_ id: WindowID) -> Bool? {
        let modes = tileableModes()
        for display in displays.allDisplays() {
            guard let workspace = session.manager.workspace(id: display.workspace),
                  workspace.columns.contains(where: { $0.windows.contains(id) })
            else {
                continue
            }
            if workspace.layout == .dwindle {
                return true
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
        guard !isShuttingDown, space.allowsWindowWork else {
            return
        }
        switch reflowDeferral.request(mouseDown: probe.isMouseDown) {
        case .apply:
            // FI-06: during a motion the retargeting reflow waits for the next
            // tick, so a burst of keys costs one reflow, not one per key.
            let flying = overlayFlight.isActive
            if reflowCoalescer.request(motionActive: motion.isActive || flying) == .runNow {
                performReflow()
            } else if flying {
                // An overlay flight has no tick: one merged retarget on the next queue turn.
                overlayFlight.scheduleReflow()
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

    /// NA-03: the close ghost is configured and animations run.
    private func closeGhostEnabled() -> Bool {
        let settings = session.config.animations
        return settings.closeGhost && settings.resolved(.windowClose).isActive
    }

    private func performReflow(animate: Bool = true) {
        guard let actuator, space.allowsWindowWork else {
            return
        }
        // TG-03: while the fingers move a strip, every pass waits; the
        // release (or the abandon) runs one that covers them all.
        guard !gestures.isTracking else {
            return
        }
        let gestureRelease = pendingGestureRelease
        pendingGestureRelease = nil
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
        // PF-K: it switches `AXEnhancedUserInterface` off around each app's
        // write batch (never Gio's own pid) and back on at the batch's end.
        let reconciler = self.reconciler ?? WindowReconciler(
            actuator: actuator,
            appName: { [probe] in probe.applicationName($0) },
            enhancedUI: AXEnhancedUserInterfaceSwitch()
        )
        self.reconciler = reconciler
        let settings = session.config.animations
        // NA-04: the triggering action picks the pass's animation; a kind
        // that is off makes its pass instant.
        let cause = motionCauses.take()
        let passAnimation = settings.resolved(cause.kind)
        let placement = instantPlacement.decide(requested: animate && passAnimation.isActive)
        if case .instant(let reason?) = placement {
            GioLog.record(reason == .mouse ? .debug : .info, instantPlacementLogLine(reason))
        }
        let animating = placement == .animate
        // NA-02: an instant pass (startup, permission, mouse) just places them.
        let opening = openingWindows.take(animating: animating)
        fullscreen.prune(registry: session.registry)
        syncShownWorkspace()
        let modes = tileableModes()
        let centering = focus.takeCenterRequest()
        let sizingTarget = focus.takeSizingFocus()
        let inactive = reflowPlanner.planInactiveWorkspaces(
            displays: displays.allDisplays(), visibleFrames: visibleFrames,
            manager: session.manager, registry: session.registry
        )
        // Native zoom: windows whose zoom ended since the last pass get their
        // verdict against this pass's layout target.
        var unjudgedZooms = nativeZoom.takeResolved()
        let pass = reflowPlanner.plan(
            .init(
                displays: displays.allDisplays(), visibleFrames: visibleFrames, manager: session.manager,
                modes: modes, engine: { [unowned self] in engine() }, centering: centering,
                animating: animating, duration: passAnimation.duration,
                opening: opening,
                openOffset: settings.resolved(.windowOpen).isActive ? CGFloat(settings.openOffset) : 0,
                cause: cause
            ),
            inactive: inactive
        ) { displayPlan, visible in
            nativeZoom.judge(&unjudgedZooms, plan: displayPlan, viewport: visible)
            return nativeZoom.applyAccepted(
                to: displayPlan.visible, parked: Set(displayPlan.parked.keys).union(inactive.parked.keys)
            )
        }
        // Logical state moves at once; only the physical writes animate.
        for outcome in pass.displays {
            session.manager.update(outcome.workspace)
            displays.updateViewport(outcome.viewport, for: outcome.display)
        }
        var plans = pass.plans
        var animations = pass.animations
        let prepositions = pass.prepositions
        focus.setHoverFrames(pass.hovered)
        nativeZoom.dropUnjudged(unjudgedZooms)
        animations = ReflowPlanner.applyingAnimationSettings(
            animations, settings: settings, kinds: pass.kinds, fallback: cause.kind
        )
        // TG-03: the strip keeps the velocity the fingers left it with.
        if let gestureRelease {
            animations = handingOffGestureVelocity(
                animations, windows: gestureRelease.windows, velocity: gestureRelease.velocity
            )
        }
        // Native zoom: a maximize that grows a single-window column presses the
        // app's own zoom instead of writing a size. The zooming window leaves
        // this pass's motion and writes; the zoom starts after the neighbours'
        // motion is under way.
        let zoomJob = nativeZoom.plan(animations: animations, animating: animating)
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
        // Focused-grow: the window the keyboard is about to raise (FI-06) that
        // grows gets its final size in the first frame. The raise (`focusNow`)
        // runs below, before the session queue serves the first motion tick,
        // so the one size write lands on an already frontmost window. Without
        // a focus intent (passive reflow) the target is nil: FI-03 applies.
        animations = ReflowPlanner.sizeSchedules(
            animations, settings: settings,
            canAnimateSize: { resizeCapability.canAnimateSize(resizeKey($0)) },
            focused: focus.pendingIntentTarget(parked: Set(plans.flatMap { $0.parked.keys })) ?? sizingTarget
        )
        // SM-04/SM-08: with the snapshot renderer the real windows get one
        // write to their final frames (the instant pass) under an overlay
        // that draws an opaque picture and flies their images on the GPU. The overlay must be on
        // screen before that write: `.priming` hands the pass to the flight
        // controller, which runs it once main reports the prime (or the AX
        // motion instead when the overlay never made it). The AX motion is
        // the fallback. TG-03: a gesture's settle stays on the motion player,
        // which carries the release velocity (the overlay starts from rest).
        var snapshotFlight = false
        if animating, gestureRelease == nil, snapshotRefresher.rendererUsable(),
           !animations.isEmpty || overlayFlight.isActive
        {
            switch overlayFlight.drive(
                animations: animations, plans: plans, spring: passAnimation.spring, jumps: pass.jumps
            ) {
            case .ax:
                break
            case .flying:
                snapshotFlight = true
            case .priming:
                // A running AX motion (a fallback's) stops here, not in the
                // deferred instant pass: its ticks would keep moving the real
                // windows while main primes, and its end would run the final
                // pass, which ends the new flight. The AX fallback restarts
                // its own motion.
                motion.stop()
                overlayFlight.deferPass(
                    writes: { [unowned self] in
                        instantPass(plans: plans, zoomJob: zoomJob, snapshotFlight: true, placement: placement, reconciler: reconciler)
                    },
                    fallback: { [unowned self] in
                        axMotionPass(
                            animations: animations, plans: plans, prepositions: prepositions, entries: pass.entries,
                            zoomJob: zoomJob, reconciler: reconciler
                        )
                    }
                )
                return
            }
        }
        if !snapshotFlight {
            overlayFlight.end()
        }
        if !animations.isEmpty && !snapshotFlight {
            axMotionPass(
                animations: animations, plans: plans, prepositions: prepositions, entries: pass.entries,
                zoomJob: zoomJob, reconciler: reconciler
            )
            return
        }
        instantPass(plans: plans, zoomJob: zoomJob, snapshotFlight: snapshotFlight, placement: placement, reconciler: reconciler)
    }

    /// The AX renderer: pre-positions, then the motion driver writes every
    /// frame of the animation through the reconciler.
    private func axMotionPass(
        animations: [WindowAnimation], plans: [ParkingPlan], prepositions: [WindowID: CGRect], entries: Set<WindowID>,
        zoomJob: NativeZoomController.Job?, reconciler: WindowReconciler<AXWindowActuator>
    ) {
        // PF-02: entries (new windows) are written at once and merge into
        // a running motion; only switch pre-positions wait for its lanes.
        let writes = planPrepositionWrites(
            prepositions, entries: entries, motionInFlight: reconciler.hasMotionWritesInFlight
        )
        motion.applyPrepositions(writes.immediate) {
            reconciler.preposition(frames: $0, from: physicalFrames, waitForMotion: false)
        }
        var waitedForMotion: TimeInterval = 0
        if writes.waitsForMotion {
            let waitStarted = ProcessInfo.processInfo.systemUptime
            reconciler.waitForMotionIdle(timeout: 0.3)
            waitedForMotion = ProcessInfo.processInfo.systemUptime - waitStarted
            motion.applyPrepositions(writes.afterMotionIdle) {
                reconciler.preposition(frames: $0, from: physicalFrames, waitForMotion: false)
            }
        }
        motion.start(animations, sink: reconciler)
        openTimeline.wrote(at: ProcessInfo.processInfo.systemUptime, waitedForMotion: waitedForMotion)
        // FI-06: the keyboard follows the logical focus right away instead
        // of after the animation; the final pass only re-asserts a drift.
        // PF-Q: off the session queue, so the first tick is not held.
        focus.focusAtMotionStart(parked: Set(plans.flatMap { $0.parked.keys }), plans: plans) {
            reconciler.focusSoon($0)
        }
        if let zoomJob {
            nativeZoom.start(zoomJob)
        }
        nativeZoom.scheduleVerifications(failed: [])
    }

    /// The instant pass: one reconciler write per window to its final frame
    /// (a still reflow, the final exact pass, or the real windows' single
    /// write under a snapshot overlay).
    private func instantPass(
        plans: [ParkingPlan], zoomJob: NativeZoomController.Job?, snapshotFlight: Bool,
        placement: InstantPlacementDecision, reconciler: WindowReconciler<AXWindowActuator>
    ) {
        motion.stop()
        // Only a keyboard/IPC intent focuses anything (HD-01); passive reflows
        // pass nil so they never steal focus. The intent reaches the last
        // plan only, so focus lands after every frame of the pass.
        let settleFocus = focus.takeSettleFocus(parked: Set(plans.flatMap { $0.parked.keys }))
        let focusTarget = settleFocus.target
        defer {
            if settleFocus.warp, let focusTarget {
                focus.warpCursorToFocus(focusTarget, plans: plans)
            }
        }
        openTimeline.wrote(at: ProcessInfo.processInfo.systemUptime, waitedForMotion: 0)
        if snapshotFlight {
            dispatchUnderOverlay(plans: plans, focusTarget: focusTarget, reconciler: reconciler)
            if let zoomJob {
                nativeZoom.start(zoomJob)
            }
            // The writes are on their lanes; the flight settles once its
            // layers land too, and folds their outcome then.
            overlayFlight.passSettled()
            return
        }
        var zoomWriteFailures: Set<WindowID> = []
        var deferred: [WindowID] = []
        for (planIndex, plan) in plans.enumerated() {
            let planFocus = planIndex == plans.count - 1 ? focusTarget : nil
            let report = reconciler.reconcile(
                frames: plan.visible, parked: plan.parked,
                focused: planFocus, currentlyFocused: nil,
                trusted: trustedFrames
            )
            foldSettle(report, visible: plan.visible, parked: plan.parked, focusTarget: planFocus, placement: placement)
            zoomWriteFailures.formUnion(report.failed)
            deferred += report.deferred
        }
        if let zoomJob {
            nativeZoom.start(zoomJob)
        }
        finishSettle(deferred: deferred, zoomWriteFailures: zoomWriteFailures)
        if renderVerifier.hasCandidates {
            renderVerifier.schedule()
        }
        snapshotRefresher.schedule()
    }

    /// SM-12: the real windows' one write under a snapshot overlay. All
    /// plans go out as one pass on the per-app lanes and the session queue
    /// does not wait for them (the overlay hides the windows; a slow app no
    /// longer holds the next key). Echoes and physical frames are recorded
    /// now (the writes land during the flight and a retarget starts from
    /// them); the windows written lose their trust until the flight's
    /// settle folds the outcome (`collectDispatchedWrites`). Echoes cover
    /// the latest landing of each write and restart when the pass is folded.
    private func dispatchUnderOverlay(
        plans: [ParkingPlan], focusTarget: WindowID?, reconciler: WindowReconciler<AXWindowActuator>
    ) {
        var visible: [WindowID: CGRect] = [:]
        var parked: [WindowID: ParkedTarget] = [:]
        for plan in plans {
            visible.merge(plan.visible) { _, new in new }
            parked.merge(plan.parked) { _, new in new }
        }
        let pass = reconciler.dispatch(
            frames: visible, parked: parked, focused: focusTarget, currentlyFocused: nil, trusted: trustedFrames
        )
        let now = ProcessInfo.processInfo.systemUptime
        // SM-13: a write lands on its lane up to `landingBounds` after now
        // (claim wait, the app's earlier writes): its echo is covered until then.
        for (id, frame) in visible where parked[id] == nil {
            echoGate.recordDispatched(id, frame: frame, at: now, landingWithin: pass.landingBounds[id] ?? 0)
            physicalFrames[id] = frame
            if !trustedFrames.canSkipRead(id, desired: frame) {
                trustedFrames.invalidate(id)
            }
        }
        for (id, target) in parked {
            echoGate.recordDispatched(id, frame: target.frame, at: now, landingWithin: pass.landingBounds[id] ?? 0)
            physicalFrames[id] = target.frame
            if !trustedFrames.canSkipRead(id, desired: target.frame) {
                trustedFrames.invalidate(id)
            }
        }
        dispatchedWrites.append((pass, visible, parked, focusTarget))
    }

    /// SM-12: fold every pass dispatched under the overlay, oldest first
    /// (the newest outcome wins). Bounded: a lane with no progress for the
    /// stall timeout fails its windows with "timeout", as in `reconcile`.
    private func collectDispatchedWrites() {
        guard !dispatchedWrites.isEmpty, let reconciler else {
            dispatchedWrites = []
            return
        }
        let passes = dispatchedWrites
        dispatchedWrites = []
        var failures: Set<WindowID> = []
        var deferred: [WindowID] = []
        for entry in passes {
            let report = reconciler.collect(entry.pass)
            // Passes dispatched under an overlay belong to an animated pass.
            foldSettle(
                report, visible: entry.visible, parked: entry.parked, focusTarget: entry.focusTarget, placement: .animate
            )
            failures.formUnion(report.failed)
            deferred += report.deferred
        }
        finishSettle(deferred: deferred, zoomWriteFailures: failures)
    }

    /// One settled report into the session's memory: minimum sizes, physical
    /// frames (failed, vanished and deferred windows are forgotten), trust,
    /// render-check candidates. SM-31: vanished windows lose their snapshot
    /// images and get one proof scan of their pid.
    private func foldSettle(
        _ report: ReconcileReport, visible: [WindowID: CGRect], parked: [WindowID: ParkedTarget],
        focusTarget: WindowID?, placement: InstantPlacementDecision
    ) {
        // PF-I: a refused focus is logged by the reconciler, with its reason,
        // once per window per minute (one fails per key press onto it).
        if let focusTarget, report.focusChanged {
            GioLog.record(.debug, "focus intent id=\(focusTarget.pid):\(focusTarget.elementID) changed=true")
        }
        learnMinimumSizes(from: report, placement: placement)
        // FI-11: a display-change pass's writes teach the late re-check nothing.
        minimumSizes.notePlaced(visible.keys, placement: placement)
        GioLog.record(
            .debug,
            "reflow applied=\(report.applied.count) parked=\(report.parked.count) already=\(report.alreadyCorrect.count) failed=\(report.failed.count)"
        )
        // Our writes echo back as moved/resized events: remember them
        // (parked ones too, so they never retrigger a reflow). A dispatched
        // pass is folded after its lanes returned, so `now` is at or after
        // every landing (SM-13): the echo window restarts from it.
        // In place, once per settle: no merged copies of the dictionaries.
        let now = ProcessInfo.processInfo.systemUptime
        for (id, frame) in visible where parked[id] == nil {
            echoGate.recordApplied(id, frame: frame, at: now)
            physicalFrames[id] = frame
        }
        for (id, target) in parked {
            echoGate.recordApplied(id, frame: target.frame, at: now)
            physicalFrames[id] = target.frame
        }
        for id in report.failed + report.vanished + report.deferred {
            physicalFrames.removeValue(forKey: id)
        }
        snapshotRefresher.noteVanished(report.vanished)
        discovery.noteSettled(vanished: report.vanished, alive: report.applied + report.alreadyCorrect + report.parked)
        trustedFrames.recordSettle(report: report, visible: visible, parked: parked)
        // FI-09: a floating restore this settle attempted is not repeated.
        reflowPlanner.restoreSettled(visible: visible, deferred: report.deferred)
        // Only visible windows written here are worth a render check;
        // a settle that wrote parked/hidden windows alone checks nothing.
        for id in report.applied where visible[id] != nil && parked[id] == nil {
            renderVerifier.insertCandidate(id)
        }
        renderVerifier.recordSettled(from: report.settledFrames)
        GioLog.record(.debug, "settle skippedReads=\(report.skippedReads)")
    }

    /// Every window of the pass is on its final frame (or failed). A zoom
    /// started by the pass is already running, so its verification is
    /// scheduled here too.
    private func finishSettle(deferred: [WindowID], zoomWriteFailures: Set<WindowID>) {
        // PF-02: one line per opened window.
        for line in openTimeline.settled(at: ProcessInfo.processInfo.systemUptime) {
            GioLog.record(.info, line)
        }
        deferredSettle.defer(deferred)
        // PF-K: a hung app may have missed its restore; retry on its lane.
        reconciler?.restoreEnhancedUI()
        nativeZoom.scheduleVerifications(failed: zoomWriteFailures)
    }

    // MARK: - Snapshot renderer (SM-04/SM-08)

    /// The overlay of flight `token` is on screen with every layer at its
    /// start frame (`ok`), or could not be shown. Called from the main
    /// thread; the controller hops on and only then writes the real windows.
    func snapshotPrimed(_ token: Int, ok: Bool) {
        overlayFlight.primed(token, ok: ok)
    }

    /// SM-19: the overlay armed flight `token` to land at `deadline`
    /// (`systemUptime`); the paint check starts before it. Called from main.
    func snapshotDeadlineArmed(_ token: Int, at deadline: TimeInterval) {
        overlayFlight.deadlineArmed(token, at: deadline)
    }

    /// Overlay layers of flight `token` landed with the frames the display
    /// presented meanwhile (called from the main thread).
    func snapshotLayersFinished(_ token: Int, frames: FlightFrameStats?) {
        overlayFlight.layersFinished(token, frames: frames)
    }

    /// The overlay came down on its own (watchdog, mouse down): treat it as a
    /// settle. Called from the main thread.
    func snapshotFlightAborted(_ reason: SnapshotAbortReason) {
        overlayFlight.aborted(reason)
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

    /// Debounced reflow. `full` also re-enumerates windows (resync); a
    /// light one only re-lays out what is registered. A pending full
    /// request is never downgraded by a later light one.
    private func scheduleReflow(full: Bool = true) {
        guard space.allowsWindowWork else {
            return
        }
        pendingFull = pendingFull || full
        pendingReflow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let wantsFull = self.pendingFull
            self.pendingFull = false
            guard self.space.allowsWindowWork else {
                return
            }
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
        if let primary = probe.primaryScreenFrame {
            actuator?.updateDisplayHeight(primary.height)
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
                events.rebuild()
            }
        }
        // Tileability verdicts are invalidated per window by resize events
        // and on registration, not on every resync.
        discovery.enumerateAndPlace()
        events.syncObservers()
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
        let primary = primaryScreen()?.frame.height ?? 1169
        displayParameters.store(refreshes: snapshot, captureScreens: screens, primaryHeight: primary)
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
                // Screens changed under the flight: come down at once; the
                // sync and the relayout wait for the end of the burst (MM-04).
                self.overlayFlight.abortForDisplayChange()
                self.discovery.noteDisplayChange()
            }
        }
    }

    /// SM-10: the captured backdrop shows the desktop picture; a wallpaper
    /// change (`com.apple.desktop`, also a rotating one advancing) or a
    /// Space switch makes it stale. Mark it dirty and refresh; no timer.
    private func watchDesktopPicture() {
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.queue.async {
                guard let self, !self.isShuttingDown else {
                    return
                }
                self.snapshotRefresher.markBackdropDirty()
                self.snapshotRefresher.schedule()
            }
        }
        desktopPictureObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.desktop"), object: nil, queue: .main, using: handler
            ),
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: handler
            ),
        ]
    }

    /// SM-20: warning and critical memory pressure drop snapshot images
    /// (`SnapshotCacheRefresher.noteMemoryPressure`); SM-21: normal after
    /// them re-captures what the shown strips lack. Event-driven: a
    /// dispatch source on the session queue, no timer.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.isShuttingDown, let event = self.memoryPressure?.data else {
                return
            }
            self.snapshotRefresher.noteMemoryPressure(event)
        }
        memoryPressure = source
        source.resume()
    }

    private func watchManagedSpace() {
        spaceMonitor = ManagedSpaceMonitor { [weak self] managedActive in
            self?.queue.async {
                self?.space.managedSpaceActivityChanged(managedActive)
            }
        }
    }

    private func recordClick(at location: CGPoint) {
        // Clicks must hit real windows: an overlay in the air comes down now.
        _ = overlayAbortForMouseDown?()
        // A click is the user choosing the focus: drop any pending keyboard intent.
        focus.recordClick(at: location)
    }

    private func startTap() {
        let observeMouseMoved = focus.focusFollowsMouse
        // Only subscribed while focus-follows-mouse is on: otherwise every
        // mouse move would cost a main-thread callback.
        var moveHandler: (@Sendable (CGPoint) -> Void)?
        if observeMouseMoved {
            moveHandler = { [weak self] location in
                self?.focus.pointerMoved(location)
            }
        }
        let tap = HotkeyTap(
            onMouseDown: { [weak self] location in
                self?.recordClick(at: location)
            },
            onMouseMoved: moveHandler,
            onKeyDown: { [weak self] in
                self?.noteTyping()
            },
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

    /// SM-09: typing changes the focused window's image. Runs in the tap
    /// callback on main for every key; only the first key per half second
    /// hops to the session queue (`typingLock` guards the timestamp).
    private func noteTyping() {
        let now = ProcessInfo.processInfo.systemUptime
        typingLock.lock()
        let due = snapshotTypingHopDue(now: now, lastHop: lastTypingHop, interval: snapshotTypingHopInterval)
        if due {
            lastTypingHop = now
        }
        typingLock.unlock()
        guard due else {
            return
        }
        queue.async { [weak self] in
            self?.snapshotRefresher.noteTyping()
        }
    }

    // MARK: - Actions (main thread in, session queue for work)

    /// DA-07: pause or resume hotkey dispatch (the recorder; main thread).
    /// The tap stays installed, so resuming needs no restart.
    func setHotkeysSuspended(_ suspended: Bool) {
        hotkeyGate.setSuspended(suspended)
        GioLog.record(.info, "hotkeys \(suspended ? "suspended" : "resumed") for shortcut recording")
    }

    private func handleCombo(_ combo: HotkeyCombo) -> Bool {
        let route = routeHotkey(
            combo, dispatcher: configCoordinator.currentDispatcher(), suspended: hotkeyGate.isSuspended
        )
        switch route {
        case .passThrough:
            return false
        case .launcher:
            let firedAt = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                self?.onSummonLauncher?(firedAt)
            }
        case .overview:
            DispatchQueue.main.async { [weak self] in
                self?.onToggleOverview?()
            }
        case .action(let action):
            queue.async { [weak self] in
                self?.apply(action)
            }
        }
        return true
    }

    private func apply(_ action: HotkeyAction) {
        GioLog.record(.debug, "hotkey \(action)")
        // A copy: the lazy reads below touch `session` while the action runs.
        var manager = session.manager
        let effect = ActionApplier.apply(action, manager: &manager, context: .init(
            registry: session.registry, displays: displays.allDisplays(), visibleFrames: visibleFrames,
            layout: session.config.layout, behavior: session.config.behavior, engine: { [unowned self] in engine() },
            modes: { [unowned self] in tileableModes() },
            fallbackViewport: { [probe] in probe.primaryScreenVisibleFrame }
        ))
        session.manager = manager
        if effect.syncsShownWorkspace {
            syncShownWorkspace()
        }
        if let workspace = effect.zoomRequest {
            nativeZoom.requestToggle(in: workspace)
        }
        if let toggle = effect.fullscreenToggle {
            _ = try? fullscreen.toggle(toggle.id, registry: session.registry, frame: toggle.frame)
        }
        motionCauses.note(motionCause(for: action))
        focus.requestIntent(if: effect.carriesFocusIntent, previous: effect.previousFocus)
        if effect.growsFocusedWindow {
            focus.noteSizingFocus(session.manager.currentWorkspace().focusedWindow)
        }
        if let frame = effect.warpsToDisplay {
            focus.warpCursor(toDisplay: frame)
        }
        reflowAll()
    }
}

/// NA-03: forwards the close ghost to the app's hooks (set before `start()`).
private final class HostGhostPort: CloseGhostPort, @unchecked Sendable {
    private unowned let host: SessionHost

    init(host: SessionHost) {
        self.host = host
    }

    func showGhost(token: Int, image: CGImage, frame: CGRect, duration: TimeInterval, shrink: CGFloat) {
        host.ghostShow?(token, image, frame, duration, shrink)
    }

    func removeGhost(token: Int) {
        host.ghostRemove?(token)
    }
}

/// SM-04/SM-08: forwards the overlay flight to the app's hooks (set before `start()`).
private final class HostOverlayPort: OverlayPort {
    private unowned let host: SessionHost

    init(host: SessionHost) {
        self.host = host
    }

    func beginFlight(
        token: Int, spring: SpringParameters, flights: [OverlayFlight], holes: [WindowID: CGRect],
        decorations: OverlayDecorations
    ) {
        host.overlayBegin?(token, spring, flights.map(SnapshotDisplayFlight.init), Array(holes.values), decorations)
    }

    func flyFlight(token: Int) {
        host.overlayFly?(token)
    }

    func retargetFlight(
        token: Int, targets: [WindowID: CGRect], images: [WindowID: SnapshotFace<CGImage>], adds: [OverlayFlight],
        holes: [WindowID: CGRect], decorations: OverlayDecorations
    ) {
        host.overlayRetarget?(
            token, targets, images, adds.map(SnapshotDisplayFlight.init), Array(holes.values), decorations
        )
    }

    func endFlight() {
        host.overlayEnd?()
    }

    func freshenFlight(token: Int, faces: [WindowID: SnapshotFace<CGImage>]) {
        host.overlayFreshen?(token, faces)
    }

    func fadeOutFlight(windows: Set<WindowID>, duration: TimeInterval) {
        host.overlayFade?(windows, duration)
    }
}

private extension SnapshotDisplayFlight {
    init(_ flight: OverlayFlight) {
        self.init(
            displayFrame: flight.displayFrame, usableFrame: flight.usableFrame, backdrop: flight.backdrop,
            items: flight.items.map {
                SnapshotOverlayItem(id: $0.id, image: $0.image, target: $0.target, from: $0.from, to: $0.to)
            }
        )
    }
}

/// The menu bar's dedupe gate drives the bar publisher.
extension BarStateGate: PublicationGate {}
