import Foundation
import GioCore

/// DD-05 pure presentation logic for onboarding, the menu bar and the
/// launcher's keyboard selection.

// MARK: - Onboarding

/// First run, or any launch while Accessibility is missing. Unknown
/// permission (no facts yet) only counts on first run.
public func shouldShowOnboarding(hasCompleted: Bool, accessibilityGranted: Bool?) -> Bool {
    !hasCompleted || accessibilityGranted == false
}

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome, accessibility, screenRecording, keys
}

public struct OnboardingProgress: Equatable, Sendable {
    public let index: Int
    public let count: Int
}

public struct OnboardingState: Equatable, Sendable {
    public private(set) var step: OnboardingStep = .welcome
    public private(set) var accessibilityGranted: Bool
    public private(set) var screenRecordingGranted: Bool

    public init(accessibilityGranted: Bool, screenRecordingGranted: Bool, step: OnboardingStep = .welcome) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.step = step
    }

    /// Live permission polling while the window is visible.
    public mutating func update(accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
    }

    /// Accessibility is required; everything else can be passed.
    public var canAdvance: Bool {
        step != .accessibility || accessibilityGranted
    }

    public var canGoBack: Bool { step != .welcome }
    public var isLastStep: Bool { step == OnboardingStep.allCases.last }

    public var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .accessibility: return "Continue"
        case .screenRecording: return screenRecordingGranted ? "Continue" : "Skip"
        case .keys: return "Done"
        }
    }

    public var progress: OnboardingProgress {
        OnboardingProgress(index: step.rawValue, count: OnboardingStep.allCases.count)
    }

    public mutating func advance() {
        guard canAdvance, let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            return
        }
        step = next
    }

    public mutating func back() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) {
            step = previous
        }
    }
}

/// One line of the "Keys to know" card. `families` names the catalog
/// action of each combo (empty for app-level keys like the launcher).
public struct OnboardingKey: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let combos: [HotkeyCombo]
    public let families: [String]
}

public let onboardingKeys: [OnboardingKey] = [
    OnboardingKey(
        title: "Focus left / right", detail: "Move between columns",
        combos: [HotkeyCombo(modifiers: [.alt], key: "H"), HotkeyCombo(modifiers: [.alt], key: "L")],
        families: ["focus-left", "focus-right"]
    ),
    OnboardingKey(
        title: "Maximize column", detail: "Fill the display, again to restore",
        combos: [HotkeyCombo(modifiers: [.alt], key: "F")], families: ["maximize-column"]
    ),
    OnboardingKey(
        title: "Workspace down / up", detail: "Switch workspaces on this display",
        combos: [HotkeyCombo(modifiers: [.alt], key: "U"), HotkeyCombo(modifiers: [.alt], key: "I")],
        families: ["focus-workspace-down", "focus-workspace-up"]
    ),
    OnboardingKey(
        title: "Open launcher", detail: "Search apps and windows",
        combos: [HotkeyCombo(modifiers: [.alt], key: "Space")], families: []
    ),
]

// MARK: - Menu bar

/// The number drawn on the status item: the active workspace.
public func barBadgeText(_ state: BarSessionState?) -> String? {
    state.map { "\($0.workspace)" }
}

public struct BarMenuRow: Equatable, Sendable {
    public let index: Int
    public let title: String
    public let detail: String
    public let isChecked: Bool
    public let isEnabled: Bool
    /// NW-04: a named workspace's SF Symbol and hex color.
    public var symbol: String? = nil
    public var color: String? = nil
}

public struct BarMenuSection: Equatable, Sendable {
    public let title: String
    public let rows: [BarMenuRow]
}

public struct BarMenuModel: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public let sections: [BarMenuSection]
}

private func windowCount(_ count: Int) -> String {
    count == 1 ? "1 window" : "\(count) windows"
}

public func barMenuModel(_ state: BarSessionState?) -> BarMenuModel {
    guard let state else {
        return BarMenuModel(title: "Gio", subtitle: "Starting…", sections: [])
    }
    let focusedStack = state.stacks.first(where: \.focused)?.workspaces ?? []
    let position: String
    if let active = focusedStack.first(where: { $0.index == state.workspace }), let name = active.name {
        position = "\(name) (\(state.workspace) of \(focusedStack.count))"
    } else {
        position = focusedStack.isEmpty ? "Workspace \(state.workspace)" : "Workspace \(state.workspace) of \(focusedStack.count)"
    }
    let named = state.stacks.contains { $0.workspaces.contains { $0.name != nil } }
    // Only the focused display's rows switch; other stacks are information.
    let sections = state.stacks.enumerated().map { position, stack in
        BarMenuSection(
            title: state.stacks.count > 1 ? "Display \(position + 1)" : "Workspaces",
            rows: stack.workspaces.map { entry -> BarMenuRow in
                let count = entry.windows == 0 ? "Empty" : windowCount(entry.windows)
                // With named workspaces the title is the name, so the
                // detail carries the index (its Alt shortcut).
                return BarMenuRow(
                    index: entry.index, title: workspaceShortName(entry),
                    detail: named && entry.index <= 9 ? "⌥\(entry.index) · \(count)" : count,
                    isChecked: entry.isActive, isEnabled: stack.focused,
                    symbol: entry.icon, color: entry.color
                )
            }
        )
    }
    return BarMenuModel(title: "Gio", subtitle: "\(position) · \(windowCount(state.windows))", sections: sections)
}

// MARK: - Launcher selection

/// Keyboard selection over the launcher results: ↑/↓ clamp, ⌘1–9 pick.
public struct LauncherSelection: Equatable, Sendable {
    public private(set) var index = 0
    public private(set) var count: Int

    public init(count: Int) {
        self.count = max(count, 0)
    }

    public var current: Int? { count > 0 ? index : nil }

    public mutating func moveDown() {
        index = min(index + 1, max(count - 1, 0))
    }

    public mutating func moveUp() {
        index = max(index - 1, 0)
    }

    /// New results: back to the top.
    public mutating func reset(count: Int) {
        self.count = max(count, 0)
        index = 0
    }

    public mutating func select(_ row: Int) {
        if row >= 0, row < count {
            index = row
        }
    }

    public func index(forDigit digit: Int) -> Int? {
        guard digit >= 1, digit <= 9, digit <= count else {
            return nil
        }
        return digit - 1
    }
}
