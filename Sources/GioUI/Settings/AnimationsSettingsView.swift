import GioCore
import SwiftUI

/// DD-03 Animations: motion curve with a playable preview, per-animation
/// overrides (NA-04), resizing behavior and the renderer choice.
struct AnimationsSettingsView: View {
    @ObservedObject var model: DesktopModel
    @State private var draft: SettingsDraft<AnimationsForm>
    @State private var toast: ApplyToast?
    /// NA-04: per-animation rows showing their details.
    @State private var expandedKinds: Set<AnimationKind>
    private let previewTime: TimeInterval?
    private let drafts: SettingsDraftStore

    /// `editing` / `previewTime` seed the view for snapshot tests.
    init(
        model: DesktopModel, drafts: SettingsDraftStore = SettingsDraftStore(),
        editing: AnimationsForm? = nil, previewTime: TimeInterval? = nil,
        expandedKinds: Set<AnimationKind> = []
    ) {
        _expandedKinds = State(initialValue: expandedKinds)
        self.model = model
        self.previewTime = previewTime
        self.drafts = drafts
        var draft = drafts.restore(for: .animations, saved: AnimationsForm(config: model.snapshot.config.animations))
        if let editing {
            draft.current = editing
        }
        _draft = State(initialValue: draft)
    }

    private var form: Binding<AnimationsForm> { $draft.current }
    private var defaults: AnimationsForm { AnimationsForm(config: AnimationsSectionConfig()) }

    var body: some View {
        SettingsScaffold(
            "Animations", subtitle: "How columns move when you scroll, focus and resize.",
            barState: applyBarState(isDirty: draft.isDirty, problems: []),
            toast: $toast, onApply: apply, onRevert: { draft.revert() }
        ) {
            ResetSectionButton(isDisabled: draft.isAtDefaults(defaults)) { draft.reset(to: defaults) }
        } content: {
            motionCard
            PerAnimationSettingsCard(form: form, expanded: $expandedKinds, previewTime: previewTime)
            resizingCard
            rendererCard
        }
        .onReceive(model.$snapshot) { snapshot in
            draft.adopt(saved: AnimationsForm(config: snapshot.config.animations))
        }
        .onChange(of: draft) { drafts.store($0, for: .animations) }
    }

    private var motionFooter: String {
        guard draft.current.enabled else {
            return "Every move is instant."
        }
        switch draft.current.curve {
        case .spring:
            return "Damping 1 never overshoots; lower bounces. Higher stiffness is faster. A spring keeps the speed of a move it interrupts, so rapid key presses flow."
        case .easeOut:
            return "A fixed-length glide that slows into place. 0 ms makes every move instant."
        }
    }

    private var motionCard: some View {
        SectionCard("Motion", footer: motionFooter) {
            MotionPreviewView(parameters: draft.current.preview, frozenTime: previewTime)
                .padding(GioSpacing.s)
            Divider().padding(.leading, GioSpacing.m - 2)
            CardRow {
                ToggleRow("Animate scrolling and focus changes", isOn: form.enabled)
            }
            CardRow {
                SegmentedRow("Curve", selection: form.curve, options: [(.spring, "Spring"), (.easeOut, "Ease Out")], width: 180)
                    .disabled(!draft.current.enabled)
            }
            switch draft.current.curve {
            case .spring:
                CardRow {
                    SliderRow(
                        "Damping", value: form.dampingRatio, in: SpringParameters.dampingRatioRange, step: 0.05,
                        format: { String(format: "%.2f", $0) }
                    )
                }
                .disabled(!draft.current.enabled)
                CardRow(divider: false) {
                    SliderRow(
                        "Stiffness", value: form.stiffness, in: SpringParameters.stiffnessRange, step: 50,
                        format: { "\(Int($0))" }
                    )
                }
                .disabled(!draft.current.enabled)
            case .easeOut:
                CardRow(divider: false) {
                    SliderRow(
                        "Duration", value: form.durationMilliseconds,
                        in: Double(AnimationsSectionConfig.durationRange.lowerBound)...Double(AnimationsSectionConfig.durationRange.upperBound),
                        step: 10, format: { "\(Int($0)) ms" }
                    )
                }
                .disabled(!draft.current.enabled)
            }
        }
    }

    private var resizingCard: some View {
        SectionCard("Resizing", footer: "Adaptive and Always keep their own timing when they already grow the window during the motion.") {
            CardRow {
                SegmentedRow(
                    "Resize during motion",
                    caption: "Never grows windows once at the end. Adaptive grows them during the motion when the app keeps up.",
                    selection: form.resize,
                    options: [(.never, "Never"), (.adaptive, "Adaptive"), (.always, "Always")], width: 220
                )
            }
            CardRow {
                SegmentedRow(
                    "Focused window growth",
                    caption: "At start gives it the final size in the first frame, so it is not cut while others slide away.",
                    selection: form.focusedGrow,
                    options: [(.start, "At Start"), (.end, "At End")], width: 160
                )
            }
            CardRow(divider: false) {
                ToggleRow(
                    "Use the app's own zoom to maximize",
                    caption: "Alt+F on a single-window column presses the app's zoom button; falls back to a normal resize when it lands off the layout.",
                    isOn: form.nativeZoom
                )
            }
        }
        .disabled(!draft.current.enabled)
    }

    private var rendererCard: some View {
        SectionCard("Renderer") {
            RendererOption(
                title: "Accessibility", badge: StatusBadge(.ok, "Default"),
                detail: "Moves the real windows every frame, so you always see live content.",
                isSelected: draft.current.renderer == .ax
            ) { draft.current.renderer = .ax }
            Divider().padding(.leading, 44)
            RendererOption(
                title: "Snapshot", badge: StatusBadge(.warning, "Experimental", symbol: "flask.fill"),
                detail: "Animates window images in an overlay: smoother on slow apps, but it can flicker and needs Screen Recording.",
                isSelected: draft.current.renderer == .snapshot
            ) { draft.current.renderer = .snapshot }
        }
        .disabled(!draft.current.enabled)
    }

    private func apply() {
        guard draft.isDirty else {
            return
        }
        let feedback = model.apply(draft.current.edits)
        if case .applied = feedback {
            draft.commit()
        }
        toast = ApplyToast(feedback: feedback)
    }
}

/// A radio-style choice with a title, badge and explanation.
private struct RendererOption: View {
    let title: String
    let badge: StatusBadge
    let detail: String
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        Button(action: select) {
            HStack(alignment: .top, spacing: GioSpacing.s) {
                ZStack {
                    Circle().strokeBorder(isSelected ? palette.fill : GioColor.secondaryText.opacity(0.5), lineWidth: 1.5)
                    Circle().fill(isSelected ? palette.fill : .clear).padding(4)
                }
                .frame(width: 16, height: 16)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: GioSpacing.xs) {
                        Text(title).font(GioFont.body.weight(.medium))
                        badge
                    }
                    Text(detail)
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, GioSpacing.m - 2)
            .padding(.vertical, GioSpacing.s - 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A sample tile gliding with the configured curve, plus the curve itself
/// (position over time). Plays on demand and whenever a parameter changes;
/// with Reduce Motion it shows only the static curve.
struct MotionPreviewView: View {
    let parameters: MotionPreviewParameters
    /// Snapshot tests: draw the tile at this time instead of at rest.
    var frozenTime: TimeInterval?
    /// Snapshot tests: force the Reduce Motion rendering.
    var reduceMotionOverride: Bool?
    @State private var playStart: Date?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let curve = motionCurve(parameters, sampleCount: 90)
        PreviewCanvas(height: 150) {
            HStack(spacing: GioSpacing.m) {
                VStack(alignment: .leading, spacing: GioSpacing.xs) {
                    if reduceMotion {
                        track(progress: 1)
                        Label("Reduce Motion is on: the curve is shown instead of played.", systemImage: "figure.walk")
                            .font(GioFont.caption)
                            .foregroundStyle(GioColor.secondaryText)
                    } else if let frozenTime {
                        track(progress: motionProgress(parameters, at: frozenTime))
                        playRow(curve)
                    } else {
                        TimelineView(.animation(minimumInterval: nil, paused: playStart == nil)) { context in
                            track(progress: progress(at: context.date, curve: curve))
                        }
                        playRow(curve)
                    }
                }
                MotionCurvePlot(curve: curve, marker: frozenTime)
                    .frame(width: 190)
            }
            .padding(GioSpacing.m)
        }
        .onChange(of: parameters) { _ in play(curve: motionCurve(parameters, sampleCount: 2)) }
        .accessibilityElement(children: .contain)
    }

    private func progress(at date: Date, curve: MotionCurve) -> Double {
        guard let playStart else {
            return 1
        }
        return motionProgress(parameters, at: min(date.timeIntervalSince(playStart), curve.duration))
    }

    private func play(curve: MotionCurve) {
        guard !reduceMotion, frozenTime == nil else {
            return
        }
        let start = Date()
        playStart = start
        let hold = curve.duration + 0.5
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            if playStart == start {
                playStart = nil
            }
        }
    }

    private func playRow(_ curve: MotionCurve) -> some View {
        HStack(spacing: GioSpacing.xs) {
            GioButton(title: "Play", systemImage: "play.fill") { play(curve: curve) }
                .accessibilityHint("Plays a sample move with these settings")
            Text(curve.duration == 0 ? "Instant" : "\(Int((curve.duration * 1000).rounded())) ms to settle")
                .font(GioFont.caption.monospacedDigit())
                .foregroundStyle(GioColor.secondaryText)
        }
    }

    /// The tile travels from the left slot to the dashed target slot.
    private func track(progress: Double) -> some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        return GeometryReader { proxy in
            let tile = CGSize(width: 64, height: proxy.size.height)
            let travel = proxy.size.width - tile.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(GioColor.secondaryText.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: travel)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(GioColor.secondaryText.opacity(0.08))
                    .frame(width: tile.width, height: tile.height)
                MiniWindow(tint: .blue, cornerRadius: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(palette.fill, lineWidth: 1.5)
                    )
                    .frame(width: tile.width, height: tile.height)
                    .offset(x: travel * CGFloat(progress))
            }
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }
}

/// Position over time: the target line at 1, the curve, overshoot visible.
struct MotionCurvePlot: View {
    let curve: MotionCurve
    var marker: TimeInterval?
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        let low = min(0, curve.minProgress)
        let high = max(1, curve.maxProgress)
        GeometryReader { proxy in
            let size = proxy.size
            let y = { (value: Double) -> CGFloat in
                size.height - CGFloat((value - low) / (high - low)) * size.height
            }
            let x = { (time: TimeInterval) -> CGFloat in
                curve.duration > 0 ? CGFloat(time / curve.duration) * size.width : 0
            }
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(1)))
                    path.addLine(to: CGPoint(x: size.width, y: y(1)))
                }
                .stroke(GioColor.secondaryText.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(0)))
                    path.addLine(to: CGPoint(x: size.width, y: y(0)))
                }
                .stroke(GioColor.hairline, lineWidth: 1)
                if curve.duration == 0 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y(0)))
                        path.addLine(to: CGPoint(x: 0, y: y(1)))
                        path.addLine(to: CGPoint(x: size.width, y: y(1)))
                    }
                    .stroke(palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                } else {
                    Path { path in
                        for (index, sample) in curve.samples.enumerated() {
                            let point = CGPoint(x: x(sample.time), y: y(sample.progress))
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(palette.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let marker, curve.duration > 0 {
                    let time = min(marker, curve.duration)
                    let progress = curve.samples.min { abs($0.time - time) < abs($1.time - time) }?.progress ?? 1
                    Circle()
                        .fill(palette.fill)
                        .overlay(Circle().strokeBorder(GioColor.page, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .offset(x: x(time) - 4.5, y: y(progress) - 4.5)
                }
                Text("target")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(GioColor.secondaryText)
                    .offset(x: size.width - 32, y: y(1) - 13)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(curve.maxProgress > 1.001 ? "Motion curve, overshoots then settles" : "Motion curve, settles without overshoot")
    }
}
