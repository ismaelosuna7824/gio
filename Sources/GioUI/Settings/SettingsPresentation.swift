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

    /// DA-07: a one-off edit names its change ("Added ⌥⇧X to …") instead of
    /// a bare "Applied"; warnings and rejections read as usual.
    public init(feedback: ApplyFeedback, successTitle: String) {
        if case .applied(let warnings) = feedback, warnings.isEmpty {
            self.init(kind: .success, title: successTitle, details: [])
        } else {
            self.init(feedback: feedback)
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
    /// NA-04: one row per Niri animation.
    public var kinds: [AnimationKind: AnimationKindForm]
    /// NA-04: `[animations.window-open] offset`.
    public var openOffset: Double
    /// NA-03: `[animations.window-close] ghost`.
    public var closeGhost: Bool

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
        kinds = Dictionary(uniqueKeysWithValues: AnimationKind.allCases.map {
            ($0, AnimationKindForm(kind: $0, config: config))
        })
        openOffset = config.openOffset
        closeGhost = config.closeGhost
    }

    /// Custom on: the kind starts from the global values shown above it;
    /// custom off: it inherits again (its keys are removed on Apply).
    public mutating func setCustom(_ kind: AnimationKind, _ custom: Bool) {
        guard var row = kinds[kind] else {
            return
        }
        if custom, !row.custom {
            row.curve = curve
            row.dampingRatio = dampingRatio
            row.stiffness = stiffness
            row.durationMilliseconds = durationMilliseconds
        }
        row.custom = custom
        kinds[kind] = row
    }

    /// The motion a kind would play: its own when custom, else the global one.
    public func preview(for kind: AnimationKind) -> MotionPreviewParameters {
        guard let row = kinds[kind], row.custom else {
            var inherited = preview
            inherited.enabled = enabled && (kinds[kind]?.enabled ?? kind.enabledByDefault)
            return inherited
        }
        return MotionPreviewParameters(
            enabled: enabled && row.enabled, curve: row.curve, dampingRatio: row.dampingRatio,
            stiffness: row.stiffness, durationMilliseconds: Int(row.durationMilliseconds.rounded())
        )
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
        ) + perAnimationEdits
    }

    /// NA-04: every kind's table, then the window-open offset and the
    /// window-close ghost (written only when they differ from the default).
    private var perAnimationEdits: [ConfigEdit] {
        var edits: [ConfigEdit] = []
        for kind in AnimationKind.allCases {
            edits += animationOverrideEdits(kind, override: kinds[kind]?.override ?? AnimationOverride())
        }
        let open = AnimationKind.windowOpen.tableName
        let defaults = AnimationsSectionConfig()
        edits.append(
            openOffset == defaults.openOffset
                ? .remove(table: open, key: "offset")
                : .set(table: open, key: "offset", value: .number(openOffset.rounded()))
        )
        let close = AnimationKind.windowClose.tableName
        edits.append(closeGhost ? .set(table: close, key: "ghost", value: .bool(true)) : .remove(table: close, key: "ghost"))
        return edits
    }
}

/// NA-04: one animation's row: on/off, and its own curve when custom.
public struct AnimationKindForm: Equatable, Sendable {
    public let kind: AnimationKind
    public var enabled: Bool
    public var custom: Bool
    public var curve: MotionCurveKind
    public var dampingRatio: Double
    public var stiffness: Double
    public var durationMilliseconds: Double

    public init(kind: AnimationKind, config: AnimationsSectionConfig) {
        self.kind = kind
        let own = config.overrides[kind] ?? AnimationOverride()
        let resolved = config.resolved(kind)
        enabled = own.enabled ?? kind.enabledByDefault
        custom = own.hasCustomTiming
        curve = resolved.curve
        dampingRatio = resolved.spring.dampingRatio
        stiffness = resolved.spring.stiffness
        durationMilliseconds = Double(resolved.durationMilliseconds)
    }

    /// Only what this row changes: `enabled` when it differs from the kind's
    /// default, and when custom the curve with the parameters it uses
    /// (spring: damping and stiffness; ease-out: duration).
    public var override: AnimationOverride {
        var result = AnimationOverride(enabled: enabled == kind.enabledByDefault ? nil : enabled)
        guard custom else {
            return result
        }
        result.curve = curve
        switch curve {
        case .spring:
            result.springDampingRatio = dampingRatio
            result.springStiffness = stiffness
        case .easeOut:
            result.durationMilliseconds = Int(durationMilliseconds.rounded())
        }
        return result
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
    /// MM-06 `[behavior] move-crosses-monitor-at-edge`.
    public var moveCrossesMonitorAtEdge: Bool
    /// TG-02 `[gestures]`.
    public var gestures: GesturesSettingsForm

    public init(config: GioConfig) {
        indicator = FocusSettingsForm(config: config.focus)
        ring = FocusRingSettingsForm(config: config.focusRing)
        centerFocusedColumn = config.layout.centerFocusedColumn
        focusFollowsMouse = config.behavior.focusFollowsMouse
        mouseFollowsFocus = config.behavior.mouseFollowsFocus
        moveCrossesMonitorAtEdge = config.behavior.moveCrossesMonitorAtEdge
        gestures = GesturesSettingsForm(config: config.gestures)
    }

    /// Ring problems only count while the ring is the indicator: its
    /// settings are hidden otherwise and must not block Apply.
    public var problems: [String] {
        indicator.problems + (indicator.indicator == .ring ? ring.problems : []) + gestures.problems
    }

    public var edits: [ConfigEdit] {
        [.set(table: "layout", key: "center-focused-column", value: .string(centerFocusedColumn.rawValue))]
            + behaviorEdits(
                focusFollowsMouse: focusFollowsMouse, mouseFollowsFocus: mouseFollowsFocus,
                moveCrossesMonitorAtEdge: moveCrossesMonitorAtEdge
            )
            + ring.edits + indicator.edits + gestures.edits
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
    /// The app name, else the bundle id, else "Any app" (a title-only rule).
    public let title: String
    /// "Title matches <pattern>" for a rule with a title matcher.
    public let subtitle: String?
    public let initials: String
    public let modeBadge: RuleBadge?
    public let workspaceBadge: RuleBadge?
    /// WR-06: width, maximized, display, focus and width limits, in that order.
    public let optionBadges: [RuleBadge]
    public let accessibilityLabel: String

    public init(rule: WindowRule) {
        title = !rule.app.isEmpty ? rule.app : rule.bundleID ?? "Any app"
        subtitle = rule.title.map { "Title matches \($0.pattern)" }
        initials = appInitials(rule.app)
        switch rule.mode {
        case .floating?: modeBadge = RuleBadge(label: "Floating", symbol: "macwindow.on.rectangle", kind: .info)
        case .tiled?: modeBadge = RuleBadge(label: "Tiled", symbol: "rectangle.split.3x1", kind: .neutral)
        case .fullscreen?: modeBadge = RuleBadge(label: "Fullscreen", symbol: "arrow.up.left.and.arrow.down.right", kind: .neutral)
        case nil: modeBadge = nil
        }
        if let named = rule.openOnWorkspace {
            workspaceBadge = RuleBadge(label: named, symbol: "square.stack.3d.up.fill", kind: .info)
        } else {
            workspaceBadge = rule.workspace.map {
                RuleBadge(label: "Workspace \($0)", symbol: "square.stack.3d.up", kind: .neutral)
            }
        }
        let options = ruleOptionBadges(rule)
        optionBadges = options
        var parts: [String] = []
        if let mode = rule.mode { parts.append(mode.rawValue) }
        if let named = rule.openOnWorkspace {
            parts.append("workspace \(named)")
        } else if let workspace = rule.workspace {
            parts.append("workspace \(workspace)")
        }
        parts += options.map { $0.label.prefix(1).lowercased() + $0.label.dropFirst() }
        let name = title
        let subject = subtitle.map { "\(name), \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? name
        accessibilityLabel = "\(subject): " + (parts.isEmpty ? "no action" : parts.joined(separator: ", "))
    }

    /// No opinion at all: the row says "No action".
    public var isEmpty: Bool {
        modeBadge == nil && workspaceBadge == nil && optionBadges.isEmpty
    }
}

private func ruleOptionBadges(_ rule: WindowRule) -> [RuleBadge] {
    var badges: [RuleBadge] = []
    switch rule.columnWidth {
    case .proportion(let value)?:
        badges.append(RuleBadge(label: "Width \(ruleNumber(value))", symbol: "arrow.left.and.right", kind: .neutral))
    case .points(let value)?:
        badges.append(RuleBadge(label: "Width \(ruleNumber(value)) pt", symbol: "arrow.left.and.right", kind: .neutral))
    case .standard?, nil:
        break
    }
    if rule.openMaximized {
        badges.append(RuleBadge(label: "Maximized", symbol: "arrow.left.and.right.square", kind: .neutral))
    }
    if let display = rule.openOnDisplay {
        badges.append(RuleBadge(label: "Display \(display)", symbol: "display", kind: .neutral))
    }
    if !rule.openFocused {
        badges.append(RuleBadge(label: "Opens unfocused", symbol: "eye.slash", kind: .neutral))
    }
    switch (rule.minWidth, rule.maxWidth) {
    case let (low?, high?):
        badges.append(RuleBadge(label: "\(ruleNumber(low))–\(ruleNumber(high)) pt", symbol: "ruler", kind: .neutral))
    case let (low?, nil):
        badges.append(RuleBadge(label: "Min \(ruleNumber(low)) pt", symbol: "ruler", kind: .neutral))
    case let (nil, high?):
        badges.append(RuleBadge(label: "Max \(ruleNumber(high)) pt", symbol: "ruler", kind: .neutral))
    case (nil, nil):
        break
    }
    return badges
}

/// "900", "0.5", "0.33333": whole numbers without a decimal part.
private func ruleNumber(_ value: CGFloat) -> String {
    let number = Double(value)
    return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : "\(number)"
}

/// WR-06: a min/max width field's text: empty is "no limit" (nil); text
/// that is not a number becomes NaN so the form reports it.
public func ruleWidthLimitValue(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
        return nil
    }
    return Double(trimmed) ?? .nan
}

/// The field text for a saved limit ("" for none).
public func ruleWidthLimitText(_ value: Double?) -> String {
    value.map { ruleNumber(CGFloat($0)) } ?? ""
}

/// WR-06: the rule editor shows its display picker with more than one
/// display, or when the rule already names a display.
public func ruleShowsDisplayPicker(displayCount: Int, current: Int?) -> Bool {
    displayCount > 1 || current != nil
}

/// Display picker options: the focused display (no key), then each
/// connected display by number; a saved display that is not connected
/// stays listed.
public func ruleDisplayOptions(displayCount: Int, current: Int?) -> [(Int?, String)] {
    var options: [(Int?, String)] = [(nil, "Focused display")]
    options += (1...max(displayCount, 1)).map { (Int?.some($0), "Display \($0)") }
    if let current, current > max(displayCount, 1) {
        options.append((current, "Display \(current)"))
    }
    return options
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
