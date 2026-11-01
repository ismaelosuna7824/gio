import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import GioCore
import IOSurface
@preconcurrency import ScreenCaptureKit

enum LiveFrameDelivery: Equatable {
    case drop
    case deliver(firstFrameMilliseconds: Int?)
}

struct LiveStreamBook {
    private struct Entry {
        let startedAt: UInt64
        var frames = 0
    }

    private(set) var generation = 0
    private var entries: [WindowID: Entry] = [:]
    private var delivered = 0

    var streaming: Set<WindowID> {
        Set(entries.keys)
    }

    mutating func admit(
        _ windows: [WindowID: CGRect], ownPid: pid_t, now: UInt64, limit: Int = liveLayerMaxStreams
    ) -> [WindowID] {
        let open = max(0, limit - entries.count)
        let admitted = windows.keys
            .filter { $0.pid != ownPid && entries[$0] == nil }
            .sorted()
            .prefix(open)
        for id in admitted {
            entries[id] = Entry(startedAt: now)
        }
        return Array(admitted)
    }

    func owns(_ id: WindowID, generation: Int) -> Bool {
        generation == self.generation && entries[id] != nil
    }

    mutating func deliver(_ id: WindowID, generation: Int, now: UInt64) -> LiveFrameDelivery {
        guard owns(id, generation: generation), var entry = entries[id] else {
            return .drop
        }
        let firstFrame = entry.frames == 0 ? liveStreamMilliseconds(from: entry.startedAt, to: now) : nil
        entry.frames += 1
        entries[id] = entry
        delivered += 1
        return .deliver(firstFrameMilliseconds: firstFrame)
    }

    mutating func drop(_ id: WindowID, generation: Int) {
        guard generation == self.generation else {
            return
        }
        entries[id] = nil
    }

    mutating func stopAll() -> (count: Int, frames: Int) {
        let stopped = (count: entries.count, frames: delivered)
        generation += 1
        entries = [:]
        delivered = 0
        return stopped
    }
}

func liveStreamMilliseconds(from start: UInt64, to now: UInt64) -> Int {
    guard now > start else {
        return 0
    }
    return Int((Double(now - start) / 1_000_000).rounded())
}

func liveFrameIsComplete(statusRawValue: Int?) -> Bool {
    statusRawValue.flatMap(SCFrameStatus.init(rawValue:)) == .complete
}

func liveFramePointSize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> CGSize {
    let divisor = scale > 0 ? scale : 1
    return CGSize(width: CGFloat(pixelWidth) / divisor, height: CGFloat(pixelHeight) / divisor)
}

public final class LiveWindowStreamer: @unchecked Sendable {
    private struct Running {
        let stream: SCStream
        let output: LiveStreamOutput
    }

    private let capturer: SnapshotCapturer
    private var frames: @Sendable (WindowID, IOSurface, CGSize) -> Void
    private let log: @Sendable (LogLevel, String) -> Void
    private let sampleQueue = DispatchQueue(label: "gio.live-layers")
    private let lock = NSLock()
    private var book = LiveStreamBook()
    private var running: [WindowID: Running] = [:]

    public init(
        capturer: SnapshotCapturer,
        frames: @escaping @Sendable (WindowID, IOSurface, CGSize) -> Void = { _, _, _ in },
        log: @escaping @Sendable (LogLevel, String) -> Void = { GioLog.record($0, $1) }
    ) {
        self.capturer = capturer
        self.frames = frames
        self.log = log
    }

    public func deliverFrames(to frames: @escaping @Sendable (WindowID, IOSurface, CGSize) -> Void) {
        lock.withLock { self.frames = frames }
    }

    public func start(_ windows: [WindowID: CGRect], displays: [SnapshotDisplay], primaryDisplayHeight: CGFloat) {
        guard #available(macOS 14.0, *) else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let (admitted, generation) = lock.withLock {
            (book.admit(windows, ownPid: capturer.ownPid, now: now), book.generation)
        }
        guard !admitted.isEmpty else {
            return
        }
        log(.debug, liveLayerStartLine(count: admitted.count))
        let requested = windows.filter { admitted.contains($0.key) }
        Task {
            await launch(requested, generation: generation, displays: displays, primaryDisplayHeight: primaryDisplayHeight)
        }
    }

    public func stop(_ ids: Set<WindowID>) {
        let streams = lock.withLock {
            for id in ids {
                book.drop(id, generation: book.generation)
            }
            let stopped = ids.compactMap { running.removeValue(forKey: $0)?.stream }
            return stopped
        }
        for stream in streams {
            halt(stream)
        }
    }

    public func stopAll() {
        let (stopped, streams) = lock.withLock {
            let stopped = book.stopAll()
            let streams = running.values.map(\.stream)
            running = [:]
            return (stopped, streams)
        }
        if stopped.count > 0 {
            log(.debug, liveLayerStopLine(count: stopped.count, frames: stopped.frames))
        }
        for stream in streams {
            halt(stream)
        }
    }

    @available(macOS 14.0, *)
    private func launch(
        _ windows: [WindowID: CGRect], generation: Int, displays: [SnapshotDisplay], primaryDisplayHeight: CGFloat
    ) async {
        let resolved = await capturer.liveWindows(windows, primaryDisplayHeight: primaryDisplayHeight)
        for (id, frame) in windows.sorted(by: { $0.key < $1.key }) {
            guard let window = resolved[id] else {
                fail(id, generation: generation, reason: "unmatched")
                continue
            }
            let scale = backingScale(for: frame, displays: displays)
            await open(id, window: window, frame: frame, scale: scale, generation: generation)
        }
    }

    @available(macOS 14.0, *)
    private func open(_ id: WindowID, window: SCWindow, frame: CGRect, scale: CGFloat, generation: Int) async {
        guard lock.withLock({ book.owns(id, generation: generation) }) else {
            return
        }
        let configuration = SnapshotCapturer.windowCaptureConfiguration(
            pixels: snapshotPixelSize(points: frame.size, scale: scale)
        )
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(liveLayerFrameRate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        let output = LiveStreamOutput(
            id: id, generation: generation, scale: scale,
            onSample: { [weak self] id, generation, sample, scale in
                self?.receive(id, generation: generation, sample: sample, scale: scale)
            },
            onStop: { [weak self] id, generation, error in
                self?.streamStopped(id, generation: generation, error: error)
            }
        )
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            fail(id, generation: generation, reason: "code=\((error as NSError).code)")
            return
        }
        let kept = lock.withLock {
            guard book.owns(id, generation: generation) else {
                return false
            }
            running[id] = Running(stream: stream, output: output)
            return true
        }
        if !kept {
            halt(stream)
        }
    }

    private func receive(_ id: WindowID, generation: Int, sample: CMSampleBuffer, scale: CGFloat) {
        guard let surface = completeSurface(of: sample) else {
            return
        }
        let size = liveFramePointSize(
            pixelWidth: IOSurfaceGetWidth(surface), pixelHeight: IOSurfaceGetHeight(surface), scale: scale
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let delivery = lock.withLock {
            let delivery = book.deliver(id, generation: generation, now: now)
            if delivery != .drop {
                frames(id, surface, size)
            }
            return delivery
        }
        if case .deliver(let firstFrame?) = delivery {
            log(.debug, liveLayerFirstFrameLine(id, milliseconds: firstFrame))
        }
    }

    private func completeSurface(of sample: CMSampleBuffer) -> IOSurface? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary]
        let status = attachments?.first?[SCStreamFrameInfo.status.rawValue] as? NSNumber
        guard liveFrameIsComplete(statusRawValue: status?.intValue), let pixels = sample.imageBuffer else {
            return nil
        }
        return CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue()
    }

    private func streamStopped(_ id: WindowID, generation: Int, error: Error) {
        let stream = lock.withLock {
            guard book.owns(id, generation: generation) else {
                return Optional<SCStream>.none
            }
            book.drop(id, generation: generation)
            return running.removeValue(forKey: id)?.stream
        }
        log(.debug, "live layer stream stopped id=\(id.pid):\(id.elementID) code=\((error as NSError).code)")
        if let stream {
            halt(stream)
        }
    }

    private func fail(_ id: WindowID, generation: Int, reason: String) {
        let owned = lock.withLock {
            let owned = book.owns(id, generation: generation)
            book.drop(id, generation: generation)
            return owned
        }
        if owned {
            log(.debug, "live layer stream failed id=\(id.pid):\(id.elementID) \(reason)")
        }
    }

    private func halt(_ stream: SCStream) {
        let log = log
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                log(.debug, "live layer stream stop failed code=\((error as NSError).code)")
            }
        }
    }
}

private final class LiveStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let id: WindowID
    let generation: Int
    let scale: CGFloat
    let onSample: @Sendable (WindowID, Int, CMSampleBuffer, CGFloat) -> Void
    let onStop: @Sendable (WindowID, Int, Error) -> Void

    init(
        id: WindowID, generation: Int, scale: CGFloat,
        onSample: @escaping @Sendable (WindowID, Int, CMSampleBuffer, CGFloat) -> Void,
        onStop: @escaping @Sendable (WindowID, Int, Error) -> Void
    ) {
        self.id = id
        self.generation = generation
        self.scale = scale
        self.onSample = onSample
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else {
            return
        }
        onSample(id, generation, sampleBuffer, scale)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(id, generation, error)
    }
}
