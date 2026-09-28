import CoreGraphics

/// A pure, conservative correlation heuristic, not an authoritative AX-to-CG identity join.
/// Callers must supply complete AX enumeration and a simultaneous on-screen CG snapshot in
/// the same Space generation. Never move a window solely because this heuristic matches it.
public enum SpaceWindowEligibility {
    public struct AXCandidate {
        public let windowID: Int
        public let pid: Int
        public let title: String?
        public let frame: CGRect?
        public let displayBounds: CGRect?

        public init(windowID: Int, pid: Int, title: String?, frame: CGRect?, displayBounds: CGRect?) {
            self.windowID = windowID
            self.pid = pid
            self.title = title
            self.frame = frame
            self.displayBounds = displayBounds
        }
    }

    public struct CGWindow {
        public let pid: Int
        public let title: String?
        public let frame: CGRect?

        public init(pid: Int, title: String?, frame: CGRect?) {
            self.pid = pid
            self.title = title
            self.frame = frame
        }
    }

    public enum SkipReason: Hashable {
        case staleGeneration
        case missingMetadata
        case invalidFrame
        case outOfDisplay
        case ambiguousAX
        case missingOnScreenMatch
        case ambiguousCG
    }

    public struct Result {
        /// IDs retain the input AX order; no frames are modified by this evaluator.
        public let eligibleWindowIDs: [Int]
        public let skipped: [(windowID: Int, reason: SkipReason)]

        public func count(_ reason: SkipReason) -> Int {
            skipped.filter { $0.reason == reason }.count
        }
    }

    /// Epochs are supplied by the snapshot owner and must change on every Space notification.
    /// A stale or non-simultaneous snapshot fails closed for every candidate.
    public static func evaluate(ax: [AXCandidate], axGeneration: UInt64,
                                onScreen: [CGWindow], cgGeneration: UInt64,
                                currentGeneration: UInt64) -> Result {
        guard axGeneration == currentGeneration, cgGeneration == currentGeneration else {
            return Result(eligibleWindowIDs: [],
                          skipped: ax.map { ($0.windowID, .staleGeneration) })
        }

        var eligible: [Int] = []
        var skipped: [(windowID: Int, reason: SkipReason)] = []
        for candidate in ax {
            let reason: SkipReason?
            if candidate.pid <= 0 || candidate.title?.isEmpty != false ||
                candidate.frame == nil || candidate.displayBounds == nil {
                reason = .missingMetadata
            } else if !valid(candidate.frame!) || !valid(candidate.displayBounds!) {
                reason = .invalidFrame
            } else if !candidate.displayBounds!.contains(candidate.frame!) {
                reason = .outOfDisplay
            } else {
                // Count across the FULL AX enumeration, including other Spaces and displays.
                let axMatches = ax.filter {
                    $0.pid == candidate.pid && $0.title == candidate.title && $0.frame == candidate.frame
                }.count
                if axMatches != 1 {
                    reason = .ambiguousAX
                } else {
                    let cgMatches = onScreen.filter {
                        $0.pid == candidate.pid && $0.title == candidate.title &&
                        $0.title?.isEmpty == false && $0.frame == candidate.frame &&
                        $0.frame.map(valid) == true
                    }.count
                    reason = cgMatches == 1 ? nil : (cgMatches == 0 ? .missingOnScreenMatch : .ambiguousCG)
                }
            }
            if let reason {
                skipped.append((candidate.windowID, reason))
            } else {
                eligible.append(candidate.windowID)
            }
        }
        return Result(eligibleWindowIDs: eligible, skipped: skipped)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}
