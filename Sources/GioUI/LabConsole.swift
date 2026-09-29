import GioMacOS

/// One-shot AX scan for diagnostics (no session state involved).
func labListWindows() -> String {
    do {
        let result = try discoverSystemWindows()
        var lines = ["windows=\(result.windows.count) skipped=\(result.skipped)"]
        lines += result.windows.map { $0.window.describe() }
        return lines.joined(separator: "\n")
    } catch {
        return "list failed: \(error)"
    }
}
