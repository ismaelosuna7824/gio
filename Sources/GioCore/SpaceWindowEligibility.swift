import CoreGraphics

/// A pure, conservative correlation heuristic, not an authoritative AX-to-CG identity join.
/// Callers must supply complete AX enumeration and a simultaneous on-screen CG snapshot in
/// the same Space generation. Never move a window solely because this heuristic matches it.
public enum SpaceWindowEligibility {
    public struct AXCandidate {
        public let windowID: LegacyWindowID
        public let pid: Int
        public let title: String?
        public let frame: CGRect?
        public let displayBounds: CGRect?

        public init(windowID: LegacyWindowID, pid: Int, title: String?, frame: CGRect?, displayBounds: CGRect?) {
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
        public let eligibleWindowIDs: [LegacyWindowID]
        public let skipped: [(windowID: LegacyWindowID, reason: SkipReason)]

        public func count(_ reason: SkipReason) -> Int {
            skipped.filter { $0.reason == reason }.count
        }
    }

    /// Approximate on-screen AX candidate handles for menu reporting, not write authority.
    /// A straddling window belongs to the display containing its center; offscreen
    /// AX handles and PID/title-only similarities are deliberately excluded.
    public static func onScreenCandidates(ax: [AXCandidate], onScreen: [CGWindow],
                                          display: CGRect) -> Set<LegacyWindowID> {
        guard valid(display) else { return [] }
        return Set(ax.compactMap { candidate -> LegacyWindowID? in
            guard candidate.pid > 0, let frame = candidate.frame, valid(frame),
                  display.contains(CGPoint(x: frame.midX, y: frame.midY)),
                  onScreen.contains(where: { $0.pid == candidate.pid && $0.frame == frame &&
                      $0.frame.map(valid) == true && compatible(candidate.title, $0.title) }) else { return nil }
            return candidate.windowID
        })
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

        var eligible: [LegacyWindowID] = []
        var skipped: [(windowID: LegacyWindowID, reason: SkipReason)] = []
        for candidate in ax {
            let reason: SkipReason?
            if candidate.pid <= 0 || candidate.frame == nil || candidate.displayBounds == nil {
                reason = .missingMetadata
            } else if !valid(candidate.frame!) || !valid(candidate.displayBounds!) {
                reason = .invalidFrame
            } else if !candidate.displayBounds!.contains(candidate.frame!) {
                reason = .outOfDisplay
            } else {
                // Count across the FULL AX enumeration, including other Spaces and displays.
                let axMatches = ax.filter {
                    $0.pid == candidate.pid && $0.frame == candidate.frame
                }.count
                if axMatches != 1 {
                    reason = .ambiguousAX
                } else {
                    let cgMatches = onScreen.filter {
                        $0.pid == candidate.pid && $0.frame == candidate.frame &&
                        $0.frame.map(valid) == true
                    }
                    reason = cgMatches.count != 1 ? (cgMatches.isEmpty ? .missingOnScreenMatch : .ambiguousCG)
                        : (compatible(candidate.title, cgMatches[0].title) ? nil : .missingOnScreenMatch)
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

    private static func compatible(_ ax: String?, _ cg: String?) -> Bool {
        guard let ax, !ax.isEmpty, let cg, !cg.isEmpty else { return true }
        return ax == cg
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}
