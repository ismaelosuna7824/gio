import Foundation

/// SB-01 `[hooks]`: shell commands Gio runs (with `/bin/sh -c`, off the
/// session queue, output discarded, killed after 5 s) when the bar state
/// changes; consumed by `BarHookNotifier` (GioSession). Nil is off; an empty
/// string in the file is off too.
public struct HooksSectionConfig: Equatable, Sendable {
    /// The focused display, its shown workspace or another display's shown
    /// workspace changed (and once after startup).
    public var onWorkspaceChange: String?
    /// A workspace's window count or apps changed (coalesced ~100 ms).
    public var onWindowsChange: String?

    public init(onWorkspaceChange: String? = nil, onWindowsChange: String? = nil) {
        self.onWorkspaceChange = onWorkspaceChange
        self.onWindowsChange = onWindowsChange
    }

    /// No hook is set: the session builds no bar state at all.
    public var isEmpty: Bool {
        onWorkspaceChange == nil && onWindowsChange == nil
    }
}

func applyHooksKey(
    _ key: String, value: ConfigValue, line: Int,
    errors: inout [String], warnings: inout [String], config: inout GioConfig
) {
    guard key == "on-workspace-change" || key == "on-windows-change" else {
        warnings.append("line \(line): unknown hooks key '\(key)', ignored")
        return
    }
    guard case .string(let text) = value else {
        errors.append("line \(line): hooks.\(key) expects a shell command in quotes")
        return
    }
    let command = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
    if key == "on-workspace-change" {
        config.hooks.onWorkspaceChange = command
    } else {
        config.hooks.onWindowsChange = command
    }
}
