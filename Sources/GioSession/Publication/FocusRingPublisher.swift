import CoreGraphics
import GioCore

/// NF-01: posts the focus ring for the focused window of the current
/// workspace. Uses only session bookkeeping (registry, physical frames,
/// display frames): no AX call, cheap enough for every motion frame.
/// Session queue only; `deliver` runs on the main thread.
public final class FocusRingPublisher: @unchecked Sendable {
    public struct Context {
        public var session: () -> CommandSession
        public var physicalFrame: (WindowID) -> CGRect?
        public var displayFrames: () -> [CGRect]
        public var isFlightActive: () -> Bool
        public var isZoomBusy: (WindowID) -> Bool
        public var isFullscreen: (WindowID) -> Bool
        public var mainHop: MainHop
        public var deliver: (FocusRingState) -> Void

        public init(
            session: @escaping () -> CommandSession, physicalFrame: @escaping (WindowID) -> CGRect?,
            displayFrames: @escaping () -> [CGRect], isFlightActive: @escaping () -> Bool,
            isZoomBusy: @escaping (WindowID) -> Bool, isFullscreen: @escaping (WindowID) -> Bool,
            mainHop: @escaping MainHop, deliver: @escaping (FocusRingState) -> Void
        ) {
            self.session = session
            self.physicalFrame = physicalFrame
            self.displayFrames = displayFrames
            self.isFlightActive = isFlightActive
            self.isZoomBusy = isZoomBusy
            self.isFullscreen = isFullscreen
            self.mainHop = mainHop
            self.deliver = deliver
        }
    }

    private let context: Context
    /// PA-04: publishes only when the ring's drawing changed.
    private var gate = FocusRingPublishGate()
    /// Keeps only the newest value and at most one main-queue block pending,
    /// so motion frames never back up main.
    private let mailbox = LatestValueMailbox<FocusRingState>()

    public init(context: Context) {
        self.context = context
    }

    public func publish() {
        let state = snapshot()
        guard gate.shouldPublish(state), mailbox.post(state) else {
            return
        }
        context.mainHop { [weak self] in
            guard let self, let next = self.mailbox.take() else {
                return
            }
            self.context.deliver(next)
        }
    }

    /// Display topology or config changed: the next state publishes.
    public func resetGate() {
        gate.reset()
    }

    public func snapshot() -> FocusRingState {
        let session = context.session()
        let config = session.config.focusRing
        // SM-04: the ring stays hidden while an overlay flight is in the air
        // (the real window is already at its final frame, the image is not)
        // and returns at the settle, so it never sits apart from its window.
        // Native zoom: hidden while the app animates its own window (it follows
        // physical frames), shown again once the zoom settled and was judged.
        guard config.enabled, session.config.focus.showsRing, !context.isFlightActive(),
              let id = session.manager.currentWorkspace().focusedWindow,
              !context.isZoomBusy(id), let window = session.registry.find(id)
        else {
            return .hidden
        }
        return focusRingState(
            config: config,
            focused: FocusRingWindow(
                frame: context.physicalFrame(id), isMinimized: window.isMinimized,
                isFullscreen: window.mode == .fullscreen || context.isFullscreen(id),
                isMaximized: session.manager.currentWorkspace().focusedColumnRef?.savedWidthSpec != nil
            ),
            displays: context.displayFrames(),
            fullscreenGap: session.config.layout.resolvedFullscreenGap
        )
    }
}
