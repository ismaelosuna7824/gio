import CoreGraphics
import Foundation
import GioCore

/// DD-03 pure presentation logic behind the settings sections: preview
/// geometry, motion sampling, draft state and row models. Views only draw.

// MARK: - Draft / apply bar

/// A section's editable value against the value the session runs with.
/// Edits stay local until Apply; a config refresh only replaces them while
/// there are none.
public struct SettingsDraft<Value: Equatable>: Equatable {
    public private(set) var saved: Value
    public var current: Value

    public init(saved: Value) {
        self.saved = saved
        current = saved
    }

    public var isDirty: Bool { current != saved }

    public mutating func revert() {
        current = saved
    }

    /// The session's value changed (reload, another section's Apply).
    public mutating func adopt(saved newSaved: Value) {
        if !isDirty {
            current = newSaved
        }
        saved = newSaved
    }

    /// Apply succeeded: what is on screen is what runs.
    public mutating func commit() {
        saved = current
    }

    /// "Reset section": the defaults become an unsaved edit to review.
    public mutating func reset(to defaults: Value) {
        current = defaults
    }

    public func isAtDefaults(_ defaults: Value) -> Bool {
        current == defaults
    }
}

public enum ApplyBarState: Equatable, Sendable {
    case hidden
    case visible(canApply: Bool, problemCount: Int)
}

/// The Apply bar appears only with unsaved edits; problems block Apply.
public func applyBarState(isDirty: Bool, problems: [String]) -> ApplyBarState {
    guard isDirty else {
        return .hidden
    }
    return .visible(canApply: problems.isEmpty, problemCount: problems.count)
}

/// Short-lived confirmation after an Apply.
public struct ApplyToast: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case success, warning, failure
    }

    public let kind: Kind
    public let title: String
    public let details: [String]

    public init(kind: Kind, title: String, details: [String]) {
        self.kind = kind
        self.title = title
        self.details = details
    }

    public init(feedback: ApplyFeedback) {
        switch feedback {
        case .applied(let warnings) where warnings.isEmpty:
            self.init(kind: .success, title: "Applied", details: [])
        case .applied(let warnings):
            self.init(kind: .warning, title: "Applied with warnings", details: warnings)
        case .rejected(let messages):
            self.init(kind: .failure, title: "Not applied — config.toml unchanged", details: messages)
        }
    }
}

// MARK: - Layout preview

public enum LayoutPreviewMode: String, CaseIterable, Sendable {
    case columns, maximized, fullscreen

    public var title: String {
        switch self {
        case .columns: return "Columns"
        case .maximized: return "Maximized"
        case .fullscreen: return "Fullscreen"
        }
    }
}

/// Three columns on a display, in display points (top-left origin). The
/// focused column is in the middle; its neighbors may extend off screen,
/// exactly as the strip scrolls.
public struct LayoutPreviewGeometry: Equatable, Sendable {
    public let display: CGSize
    public let columns: [CGRect]
    public let focusedIndex: Int
    /// Padding at the screen edges (sanitized), where a column starts.
    public let padding: CGFloat
    /// Widths the preset list cycles through on this display, in order.
    public let presetWidths: [CGFloat]
    /// How each preset reads: "50%" for fractions, "800 pt" for points.
    public let presetLabels: [String]
}

/// Display the previews draw at: a 14" MacBook Pro's default resolution.
public let layoutPreviewDisplay = CGSize(width: 1512, height: 945)

private func sane(_ value: Double, max upper: Double) -> CGFloat {
    guard value.isFinite else {
        return 0
    }
    return CGFloat(min(max(value, 0), upper))
}

public func layoutPreviewGeometry(
    _ form: LayoutSettingsForm, display: CGSize = layoutPreviewDisplay, mode: LayoutPreviewMode
) -> LayoutPreviewGeometry {
    let limit = Double(min(display.width, display.height)) / 4
    let gap = sane(form.gaps, max: limit)
    let padding = sane(form.padding, max: limit)
    let usable = display.width - padding * 2
    let height = display.height - padding * 2

    func resolve(_ value: Double) -> CGFloat {
        if value <= 1 {
            let fraction = CGFloat(min(max(value, 0.05), 1))
            return proportionalColumnWidth(fraction, viewportWidth: display.width, padding: padding, gap: gap)
        }
        return min(CGFloat(value), usable)
    }

    let rawWidth = form.widthValue.isFinite ? form.widthValue : 0.5
    let width: CGFloat
    switch form.widthKind {
    case .fraction: width = resolve(min(max(rawWidth, 0.05), 1))
    case .points: width = min(max(CGFloat(rawWidth), 40), usable)
    }

    let focused: CGRect
    switch mode {
    case .columns:
        focused = CGRect(x: (display.width - width) / 2, y: padding, width: width, height: height)
    case .maximized:
        focused = CGRect(x: padding, y: padding, width: usable, height: height)
    case .fullscreen:
        let raw = form.fullscreenGapFollowsGaps ? Double(gap) : form.fullscreenGap
        let inset = sane(raw, max: limit)
        focused = CGRect(x: 0, y: 0, width: display.width, height: display.height).insetBy(dx: inset, dy: inset)
    }
    let left = CGRect(x: focused.minX - gap - width, y: padding, width: width, height: height)
    let right = CGRect(x: focused.maxX + gap, y: padding, width: width, height: height)

    let specs = parsePresetList(form.presetsText) ?? []
    return LayoutPreviewGeometry(
        display: display, columns: [left, focused, right], focusedIndex: 1, padding: padding,
        presetWidths: specs.map(resolve),
        presetLabels: specs.map(presetWidthLabel)
    )
}

/// "Reset section" for Layout: every layout default except the centering
/// mode, which the Focus section owns.
public func layoutDefaults(preserving form: LayoutSettingsForm) -> LayoutSettingsForm {
    var defaults = LayoutSettingsForm(config: LayoutSectionConfig())
    defaults.centerFocusedColumn = form.centerFocusedColumn
    return defaults
}

// MARK: - Motion preview

public struct MotionPreviewParameters: Equatable, Sendable {
    public var enabled: Bool
    public var curve: MotionCurveKind
    public var dampingRatio: Double
    public var stiffness: Double
    public var durationMilliseconds: Int

    public init(enabled: Bool, curve: MotionCurveKind, dampingRatio: Double, stiffness: Double, durationMilliseconds: Int) {
        self.enabled = enabled
        self.curve = curve
        self.dampingRatio = dampingRatio
        self.stiffness = stiffness
        self.durationMilliseconds = durationMilliseconds
    }

    var spring: SpringParameters {
        SpringParameters(dampingRatio: dampingRatio, stiffness: stiffness, epsilon: SpringParameters.niri.epsilon)
    }

    var isInstant: Bool {
        !enabled || durationMilliseconds <= 0
    }
}

/// Travel the preview's settle time is measured over (points): a typical
/// column scroll.
let motionPreviewTravel = 400.0

/// Seconds one move takes with these parameters; 0 when instant.
public func motionDuration(_ parameters: MotionPreviewParameters) -> TimeInterval {
    guard !parameters.isInstant else {
        return 0
    }
    switch parameters.curve {
    case .spring:
        return parameters.spring.settleTime(axes: [(displacement: motionPreviewTravel, velocity: 0)])
    case .easeOut:
        return Double(parameters.durationMilliseconds) / 1000
    }
}

/// Progress from 0 (start) to 1 (target) `t` seconds into a move, from the
/// same spring / easing math the session animates with. Springs may
/// overshoot past 1.
public func motionProgress(_ parameters: MotionPreviewParameters, at t: TimeInterval) -> Double {
    guard !parameters.isInstant else {
        return 1
    }
    switch parameters.curve {
    case .spring:
        return 1 + parameters.spring.state(displacement: -1, velocity: 0, at: t).displacement
    case .easeOut:
        let duration = Double(parameters.durationMilliseconds) / 1000
        return eased(t / duration, easing: .easeOut)
    }
}

public struct MotionSample: Equatable, Sendable {
    public let time: TimeInterval
    public let progress: Double
}

public struct MotionCurve: Equatable, Sendable {
    public let duration: TimeInterval
    public let samples: [MotionSample]

    public var maxProgress: Double {
        samples.map(\.progress).max() ?? 1
    }

    public var minProgress: Double {
        samples.map(\.progress).min() ?? 0
    }
}

/// `sampleCount` evenly spaced samples from 0 to the duration.
public func motionCurve(_ parameters: MotionPreviewParameters, sampleCount: Int) -> MotionCurve {
    let duration = motionDuration(parameters)
    let count = max(sampleCount, 2)
    let samples = (0..<count).map { index -> MotionSample in
        let t = duration * Double(index) / Double(count - 1)
        return MotionSample(time: t, progress: motionProgress(parameters, at: t))
    }
    return MotionCurve(duration: duration, samples: samples)
}

/// Every Animations setting, edited as one value.
public struct AnimationsForm: Equatable, Sendable {
    public var enabled: Bool
    public var durationMilliseconds: Double
    public var curve: MotionCurveKind
    public var dampingRatio: Double
    public var stiffness: Double
    public var resize: ResizeMode
    public var renderer: RendererKind
    public var focusedGrow: FocusedGrowMode
    public var nativeZoom: Bool

    public init(config: AnimationsSectionConfig) {
        enabled = config.enabled
        durationMilliseconds = Double(config.durationMilliseconds)
        curve = config.curve
        dampingRatio = config.springDampingRatio
        stiffness = config.springStiffness
        resize = config.resize
        renderer = config.renderer
        focusedGrow = config.focusedGrow
        nativeZoom = config.nativeZoom
    }

    public var preview: MotionPreviewParameters {
        MotionPreviewParameters(
            enabled: enabled, curve: curve, dampingRatio: dampingRatio, stiffness: stiffness,
            durationMilliseconds: Int(durationMilliseconds.rounded())
        )
    }

    public var edits: [ConfigEdit] {
        animationEdits(
            enabled: enabled, durationMilliseconds: Int(durationMilliseconds.rounded()),
            curve: curve, springDampingRatio: dampingRatio, springStiffness: stiffness,
            resize: resize, renderer: renderer, focusedGrow: focusedGrow, nativeZoom: nativeZoom
        )
    }
}

// MARK: - Focus section

/// Focus indicator, ring, centering and pointer behavior, edited as one.
public struct FocusSectionDraft: Equatable, Sendable {
    public var indicator: FocusSettingsForm
    public var ring: FocusRingSettingsForm
    public var centerFocusedColumn: CenterFocusedColumnMode
    public var focusFollowsMouse: Bool
    public var mouseFollowsFocus: Bool

    public init(config: GioConfig) {
        indicator = FocusSettingsForm(config: config.focus)
        ring = FocusRingSettingsForm(config: config.focusRing)
        centerFocusedColumn = config.layout.centerFocusedColumn
        focusFollowsMouse = config.behavior.focusFollowsMouse
        mouseFollowsFocus = config.behavior.mouseFollowsFocus
    }

    /// Ring problems only count while the ring is the indicator: its
    /// settings are hidden otherwise and must not block Apply.
    public var problems: [String] {
        indicator.problems + (indicator.indicator == .ring ? ring.problems : [])
    }

    public var edits: [ConfigEdit] {
        [.set(table: "layout", key: "center-focused-column", value: .string(centerFocusedColumn.rawValue))]
            + behaviorEdits(focusFollowsMouse: focusFollowsMouse, mouseFollowsFocus: mouseFollowsFocus)
            + ring.edits + indicator.edits
    }
}

/// How the three sample windows of the focus preview are drawn.
public struct FocusPreviewStyle: Equatable, Sendable {
    /// Black overlay opacity on the unfocused windows.
    public let unfocusedDim: Double
    /// Ring stroke around the focused window; 0 draws none.
    public let ringWidth: Double
    public let ringColor: ThemeColor?
}

public func focusPreviewStyle(_ draft: FocusSectionDraft) -> FocusPreviewStyle {
    switch draft.indicator.indicator {
    case .dim:
        let strength = draft.indicator.dimStrength.isFinite ? draft.indicator.dimStrength : 0
        return FocusPreviewStyle(unfocusedDim: strength, ringWidth: 0, ringColor: nil)
    case .ring:
        guard draft.ring.enabled else {
            return FocusPreviewStyle(unfocusedDim: 0, ringWidth: 0, ringColor: draft.ring.color)
        }
        let width = draft.ring.width.isFinite ? min(max(draft.ring.width, 0), 20) : 0
        return FocusPreviewStyle(unfocusedDim: 0, ringWidth: width, ringColor: draft.ring.color)
    case .none:
        return FocusPreviewStyle(unfocusedDim: 0, ringWidth: 0, ringColor: nil)
    }
}

// MARK: - Rules

public struct RuleBadge: Equatable, Sendable {
    public let label: String
    public let symbol: String
    public let kind: StatusKind
}

/// One row of the rules list.
public struct RuleRowPresentation: Equatable, Sendable {
    public let title: String
    public let initials: String
    public let modeBadge: RuleBadge?
    public let workspaceBadge: RuleBadge?
    public let accessibilityLabel: String

    public init(rule: WindowRule) {
        title = rule.app
        initials = appInitials(rule.app)
        switch rule.mode {
        case .floating?: modeBadge = RuleBadge(label: "Floating", symbol: "macwindow.on.rectangle", kind: .info)
        case .tiled?: modeBadge = RuleBadge(label: "Tiled", symbol: "rectangle.split.3x1", kind: .neutral)
        case .fullscreen?: modeBadge = RuleBadge(label: "Fullscreen", symbol: "arrow.up.left.and.arrow.down.right", kind: .neutral)
        case nil: modeBadge = nil
        }
        workspaceBadge = rule.workspace.map {
            RuleBadge(label: "Workspace \($0)", symbol: "square.stack.3d.up", kind: .neutral)
        }
        var parts: [String] = []
        if let mode = rule.mode { parts.append(mode.rawValue) }
        if let workspace = rule.workspace { parts.append("workspace \(workspace)") }
        accessibilityLabel = "\(rule.app): " + (parts.isEmpty ? "no action" : parts.joined(separator: ", "))
    }
}

/// Where an app named `name` may be installed, most likely first. Names
/// with path separators are refused so a rule can never point elsewhere.
public func appBundleCandidates(named name: String, home: String) -> [String] {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else {
        return []
    }
    let bundle = "\(trimmed).app"
    return [
        "/Applications/\(bundle)",
        "/System/Applications/\(bundle)",
        "/System/Applications/Utilities/\(bundle)",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/\(bundle)",
        "/Applications/Utilities/\(bundle)",
        "\(home)/Applications/\(bundle)",
    ]
}
