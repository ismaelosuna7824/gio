import GioCore
import SwiftUI

/// NA-04: settings copy for each Niri animation.
extension AnimationKind {
    var settingsTitle: String {
        switch self {
        case .horizontalViewMovement: return "View movement"
        case .windowMovement: return "Window movement"
        case .workspaceSwitch: return "Workspace switch"
        case .windowOpen: return "Window open"
        case .windowClose: return "Window close"
        case .windowResize: return "Window resize"
        }
    }

    var settingsDetail: String {
        switch self {
        case .horizontalViewMovement: return "Scrolling to the focused column."
        case .windowMovement: return "Moving columns and windows, consume and expel."
        case .workspaceSwitch: return "Windows leaving and entering through the bottom edge."
        case .windowOpen: return "A new window rises into its column."
        case .windowClose: return "The neighbours close the gap."
        case .windowResize: return "Maximize, fullscreen and width changes. Off by default: the window takes its new size at once."
        }
    }
}

/// One line describing a curve: "Spring · damping 1.00 · stiffness 800".
func motionSummary(curve: MotionCurveKind, dampingRatio: Double, stiffness: Double, durationMilliseconds: Double) -> String {
    switch curve {
    case .spring:
        return "Spring · damping \(String(format: "%.2f", dampingRatio)) · stiffness \(Int(stiffness))"
    case .easeOut:
        return "Ease Out · \(Int(durationMilliseconds.rounded())) ms"
    }
}

/// NA-04: a row per animation with its switch and a "Custom" disclosure
/// that reveals its own curve, parameters and preview. Rows that are not
/// custom say they inherit the Motion card.
struct PerAnimationSettingsCard: View {
    @Binding var form: AnimationsForm
    @Binding var expanded: Set<AnimationKind>
    var previewTime: TimeInterval?

    var body: some View {
        SectionCard(
            "Per-animation",
            footer: "A move uses the animation of the action that started it. New windows always use Window open and windows crossing the bottom edge use Workspace switch."
        ) {
            ForEach(Array(AnimationKind.allCases.enumerated()), id: \.element) { index, kind in
                row(kind, isLast: index == AnimationKind.allCases.count - 1)
            }
        }
        .disabled(!form.enabled)
    }

    private func binding(_ kind: AnimationKind) -> Binding<AnimationKindForm> {
        Binding(
            get: { form.kinds[kind] ?? AnimationKindForm(kind: kind, config: AnimationsSectionConfig()) },
            set: { form.kinds[kind] = $0 }
        )
    }

    private func summary(_ kind: AnimationKind) -> String {
        let row = binding(kind).wrappedValue
        guard row.enabled else {
            return "Off: instant"
        }
        guard row.custom else {
            return "Inherits global"
        }
        return motionSummary(
            curve: row.curve, dampingRatio: row.dampingRatio, stiffness: row.stiffness,
            durationMilliseconds: row.durationMilliseconds
        )
    }

    @ViewBuilder
    private func row(_ kind: AnimationKind, isLast: Bool) -> some View {
        let isOpen = expanded.contains(kind)
        CardRow(divider: !isLast || isOpen) {
            HStack(alignment: .center, spacing: GioSpacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: GioSpacing.xs) {
                        Text(kind.settingsTitle).font(GioFont.body)
                        Text(kind.rawValue)
                            .font(GioFont.caption.monospaced())
                            .foregroundStyle(GioColor.secondaryText)
                    }
                    Text(summary(kind))
                        .font(GioFont.caption)
                        .foregroundStyle(binding(kind).wrappedValue.custom ? GioColor.primaryText : GioColor.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DisclosureChip(title: "Custom", isOpen: isOpen, isActive: binding(kind).wrappedValue.custom) {
                    if isOpen {
                        expanded.remove(kind)
                    } else {
                        expanded.insert(kind)
                    }
                }
                GioSwitch(title: "\(kind.settingsTitle) enabled", isOn: binding(kind).enabled)
            }
        }
        if isOpen {
            detail(kind)
                .padding(.leading, GioSpacing.m)
                .background(GioColor.secondaryText.opacity(0.04))
            if !isLast {
                Divider().padding(.leading, GioSpacing.m - 2)
            }
        }
    }

    @ViewBuilder
    private func detail(_ kind: AnimationKind) -> some View {
        let row = binding(kind)
        VStack(alignment: .leading, spacing: 0) {
            CardRow {
                ToggleRow(
                    "Custom curve",
                    caption: row.wrappedValue.custom
                        ? "This animation uses its own curve."
                        : "Inherits global: \(motionSummary(curve: form.curve, dampingRatio: form.dampingRatio, stiffness: form.stiffness, durationMilliseconds: form.durationMilliseconds)).",
                    isOn: Binding(get: { row.wrappedValue.custom }, set: { form.setCustom(kind, $0) })
                )
            }
            if row.wrappedValue.custom {
                CardRow {
                    SegmentedRow("Curve", selection: row.curve, options: [(.spring, "Spring"), (.easeOut, "Ease Out")], width: 180)
                }
                switch row.wrappedValue.curve {
                case .spring:
                    CardRow {
                        SliderRow(
                            "Damping", value: row.dampingRatio, in: SpringParameters.dampingRatioRange, step: 0.05,
                            format: { String(format: "%.2f", $0) }
                        )
                    }
                    CardRow {
                        SliderRow(
                            "Stiffness", value: row.stiffness, in: SpringParameters.stiffnessRange, step: 50,
                            format: { "\(Int($0))" }
                        )
                    }
                case .easeOut:
                    CardRow {
                        SliderRow(
                            "Duration", value: row.durationMilliseconds,
                            in: Double(AnimationsSectionConfig.durationRange.lowerBound)...Double(AnimationsSectionConfig.durationRange.upperBound),
                            step: 10, format: { "\(Int($0)) ms" }
                        )
                    }
                }
                MotionPreviewView(parameters: form.preview(for: kind), frozenTime: previewTime)
                    .padding(GioSpacing.s)
                    .disabled(!row.wrappedValue.enabled)
            }
            if kind == .windowOpen {
                CardRow(divider: false) {
                    SliderRow(
                        "Rise from", caption: "Points below its tile a new window starts; 0 places it without a flight.",
                        value: $form.openOffset, in: 0...96, step: 2, format: { "\(Int($0)) pt" }
                    )
                }
            }
            if kind == .windowClose {
                CardRow(divider: false) {
                    ToggleRow(
                        "Close ghost",
                        caption: "Fades out an image of the closed window. Needs Screen Recording; without it only the neighbours move.",
                        isOn: $form.closeGhost
                    )
                }
            }
        }
    }
}

/// "Custom ›" pill that opens a row's details; tinted while the row is custom.
private struct DisclosureChip: View {
    let title: String
    let isOpen: Bool
    let isActive: Bool
    let toggle: () -> Void
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(title).font(GioFont.caption.weight(.medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .foregroundStyle(isActive ? palette.ink : GioColor.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isActive ? palette.fill.opacity(0.14) : GioColor.secondaryText.opacity(0.08))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) settings")
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
    }
}
