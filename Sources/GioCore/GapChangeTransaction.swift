/// Applies a gap to enabled displays, reversing completed reflows if any display fails.
/// The caller persists the new gap only for `applied`; a failed rollback requires recovery.
public enum GapChangeTransaction {
    public enum Outcome<ID: Equatable>: Equatable {
        case applied
        case reverted
        case divergent(rollbackFailures: [ID])
    }

    public static func run<ID: Equatable>(displays: [ID], newGap: Int, oldGap: Int,
                                          reflow: (ID, Int) -> Bool) -> Outcome<ID> {
        var changed: [ID] = []
        for display in displays {
            guard reflow(display, newGap) else {
                var failures: [ID] = []
                for previous in changed.reversed() where !reflow(previous, oldGap) {
                    failures.append(previous)
                }
                return failures.isEmpty ? .reverted : .divergent(rollbackFailures: failures)
            }
            changed.append(display)
        }
        return .applied
    }
}
