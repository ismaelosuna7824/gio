import AppKit
import GioCore
import QuartzCore

/// A running display link; `invalidate` takes it off its run loop.
protocol FrameLinkHandle: AnyObject {
    func invalidate()
}

@available(macOS 14.0, *)
extension CADisplayLink: FrameLinkHandle {}

/// The display link's target: forwards each callback's frame timestamp.
/// The link retains it; `owner` is weak so the cycle ends at `invalidate`.
@MainActor
final class FlightFrameLinkTarget: NSObject {
    weak var owner: FlightFrameLink?

    @available(macOS 14.0, *)
    @objc func step(_ link: CADisplayLink) {
        owner?.frame(at: link.timestamp)
    }
}

/// SM-12: counts the frames the overlay's screen presents while a flight is
/// on screen (`FlightFrameMeter`). One display-synchronised callback per
/// screen refresh on main (`NSView.displayLink`, macOS 14+; nothing on 13),
/// created when the layers fly and invalidated on every exit, so there is no
/// link at rest. Per frame: one increment and one timestamp comparison.
@MainActor
final class FlightFrameLink {
    typealias Factory = @MainActor (_ view: NSView, _ target: FlightFrameLinkTarget) -> FrameLinkHandle?

    private let makeLink: Factory
    private var link: FrameLinkHandle?
    private var meter = FlightFrameMeter()

    nonisolated init(makeLink: @escaping Factory = FlightFrameLink.systemLink) {
        self.makeLink = makeLink
    }

    var isRunning: Bool {
        link != nil
    }

    /// The layers fly at `now` (CA media time) on `view`'s screen. A
    /// running link keeps counting.
    func start(on view: NSView, refreshRate: Double, at now: TimeInterval) {
        guard link == nil else {
            return
        }
        let target = FlightFrameLinkTarget()
        target.owner = self
        guard let made = makeLink(view, target) else {
            return
        }
        link = made
        meter.start(at: now, refreshRate: refreshRate)
    }

    /// SM-13: a flying flight was retargeted. A running link keeps counting
    /// (same flight); when the deadline of the previous token already
    /// finished it, the retargeted flight is measured from here instead of
    /// landing with no stats.
    func retargeted(on view: NSView, refreshRate: Double, at now: TimeInterval) {
        start(on: view, refreshRate: refreshRate, at: now)
    }

    func frame(at timestamp: TimeInterval) {
        meter.frame(at: timestamp)
    }

    /// The flight landed: the link goes and the counts are returned.
    func finish(at now: TimeInterval) -> FlightFrameStats? {
        guard let running = link else {
            return nil
        }
        running.invalidate()
        link = nil
        return meter.finish(at: now)
    }

    /// The flight ended any other way: the link goes, nothing is reported.
    func cancel() {
        link?.invalidate()
        link = nil
        meter.cancel()
    }

    static func systemLink(view: NSView, target: FlightFrameLinkTarget) -> FrameLinkHandle? {
        guard #available(macOS 14.0, *) else {
            return nil
        }
        let link = view.displayLink(target: target, selector: #selector(FlightFrameLinkTarget.step(_:)))
        let rate = Float(view.window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        return link
    }
}
