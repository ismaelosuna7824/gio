import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// DD-05 first-run onboarding, presented as a sheet on the main window: a
/// welcome, Accessibility (required, with live status from the existing
/// permission polling), Screen Recording (recommended; macOS 14 and later
/// only), and the keys to know with the Open at Login switch (DA-06).

/// Remembers that onboarding was finished. Injected so tests never write
/// the user's defaults.
public struct OnboardingStore {
    private let defaults: UserDefaults
    static let key = "GioOnboardingCompleted"
    static let resumeKey = "GioOnboardingResumeStep"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompleted: Bool { defaults.bool(forKey: Self.key) }

    public func markCompleted() {
        defaults.set(true, forKey: Self.key)
    }

    public func markResume(_ step: OnboardingStep) {
        defaults.set(step.rawValue, forKey: Self.resumeKey)
    }

    public func clearResume() {
        defaults.removeObject(forKey: Self.resumeKey)
    }

    public func consumeResumeStep() -> OnboardingStep? {
        let stored = defaults.object(forKey: Self.resumeKey) as? Int
        clearResume()
        return stored.flatMap(OnboardingStep.init(rawValue:))
    }
}

/// Main-window state for the onboarding sheet: decided once per launch,
/// on the first session facts; the Overview can reopen it any time.
@MainActor
public final class OnboardingPresenter: ObservableObject {
    @Published public var isPresented = false
    public private(set) var startStep = OnboardingStep.welcome
    private var store: OnboardingStore
    private var evaluated = false

    public init(store: OnboardingStore = OnboardingStore()) {
        self.store = store
    }

    func evaluate(_ facts: SessionFacts?) {
        guard !evaluated, let facts else {
            return
        }
        evaluated = true
        let resumeStep = store.consumeResumeStep()
        let shouldShow = shouldShowOnboarding(
            hasCompleted: store.hasCompleted, accessibilityGranted: facts.accessibilityGranted, resumeStep: resumeStep
        )
        if shouldShow {
            startStep = resumeStep ?? .welcome
            isPresented = true
        }
    }

    public func present() {
        startStep = .welcome
        isPresented = true
    }

    func prepareRelaunch(at step: OnboardingStep) {
        store.markResume(step)
    }

    func finish() {
        store.markCompleted()
        store.clearResume()
        isPresented = false
    }

    func later() {
        store.clearResume()
        isPresented = false
    }
}

private struct OnboardingPresenterKey: EnvironmentKey {
    static let defaultValue: OnboardingPresenter? = nil
}

extension EnvironmentValues {
    var onboardingPresenter: OnboardingPresenter? {
        get { self[OnboardingPresenterKey.self] }
        set { self[OnboardingPresenterKey.self] = newValue }
    }
}

/// The live sheet: polls permissions through the model while on screen.
struct OnboardingSheet: View {
    @ObservedObject var model: DesktopModel
    @StateObject private var loginItem = LoginItemModel(service: SystemLoginItem())
    let startStep: OnboardingStep
    let onFinish: () -> Void
    let onLater: () -> Void
    let onPrepareRelaunch: () -> Void

    var body: some View {
        OnboardingContent(
            accessibilityGranted: model.snapshot.facts?.accessibilityGranted ?? false,
            screenRecordingGranted: model.snapshot.facts?.screenRecordingGranted ?? false,
            screenRecordingRequested: model.screenRecordingRequested,
            screenRecordingAvailable: screenRecordingAvailableOnThisMac,
            step: startStep,
            loginItem: loginItem.presentation,
            onFinish: onFinish, onLater: onLater,
            requestAccessibility: {
                _ = requestAXPermission()
                openPrivacyPane("Privacy_Accessibility")
                model.refresh()
            },
            requestScreenRecording: {
                _ = requestScreenRecordingPermission()
                model.markScreenRecordingRequested()
                model.refresh()
            },
            relaunch: {
                onPrepareRelaunch()
                model.relaunch()
            },
            setLoginItem: { loginItem.set($0) },
            openLoginItems: { loginItem.openSystemSettings() }
        )
        .onAppear {
            model.refresh()
            loginItem.refresh()
        }
        .pollWhileVisible(model, every: 1) {
            model.refresh()
            loginItem.refresh()
        }
    }
}

/// S5: Screen Recording features use ScreenCaptureKit (macOS 14 and later).
var screenRecordingAvailableOnThisMac: Bool {
    if #available(macOS 14.0, *) {
        return true
    }
    return false
}

/// Opens System Settings › Privacy & Security at `anchor`.
func openPrivacyPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
        NSWorkspace.shared.open(url)
    }
}

/// Presentational onboarding; `step` seeds snapshot tests.
struct OnboardingContent: View {
    let accessibilityGranted: Bool
    let screenRecordingGranted: Bool
    let screenRecordingRequested: Bool
    /// DA-06: the Open at Login row on the last step; nil hides it.
    let loginItem: LoginItemPresentation?
    var onFinish: () -> Void = {}
    var onLater: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var requestScreenRecording: () -> Void = {}
    var relaunch: () -> Void = {}
    var setLoginItem: (Bool) -> Void = { _ in }
    var openLoginItems: () -> Void = {}
    @State private var state: OnboardingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        accessibilityGranted: Bool, screenRecordingGranted: Bool, screenRecordingRequested: Bool = false,
        screenRecordingAvailable: Bool, step: OnboardingStep = .welcome, loginItem: LoginItemPresentation? = nil,
        onFinish: @escaping () -> Void = {}, onLater: @escaping () -> Void = {},
        requestAccessibility: @escaping () -> Void = {}, requestScreenRecording: @escaping () -> Void = {},
        relaunch: @escaping () -> Void = {},
        setLoginItem: @escaping (Bool) -> Void = { _ in }, openLoginItems: @escaping () -> Void = {}
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.screenRecordingRequested = screenRecordingRequested
        self.loginItem = loginItem
        self.relaunch = relaunch
        self.onFinish = onFinish
        self.onLater = onLater
        self.requestAccessibility = requestAccessibility
        self.requestScreenRecording = requestScreenRecording
        self.setLoginItem = setLoginItem
        self.openLoginItems = openLoginItems
        _state = State(initialValue: OnboardingState(
            accessibilityGranted: accessibilityGranted, screenRecordingGranted: screenRecordingGranted,
            screenRecordingAvailable: screenRecordingAvailable, step: step
        ))
    }

    var body: some View {
        ZStack {
            SetupBackdrop()
            VStack(spacing: 0) {
                Group {
                    switch state.step {
                    case .welcome: welcome
                    case .accessibility: accessibility
                    case .screenRecording: screenRecording
                    case .keys: keys
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 56)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(state.step)
                footer
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .tint(GioColor.accent)
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: state.step)
    }

    private var current: OnboardingState {
        state.updating(accessibilityGranted: accessibilityGranted, screenRecordingGranted: screenRecordingGranted)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            GioMascot(size: 190)
                .padding(.bottom, 6)
            HStack(spacing: 0) {
                Text("Hi, I'm ")
                Text("Gio").foregroundStyle(GioColor.tint(.green)).squiggleUnderline(GioColor.tint(.green))
                Text(".")
            }
            .font(.system(size: 52, weight: .bold, design: .rounded))
            .foregroundStyle(GioColor.primaryText)
            Text("Scrollable tiling for macOS. Windows open as columns on an endless strip, and your keyboard glides you along it.")
                .font(.system(size: 18))
                .foregroundStyle(GioColor.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 500)
            HStack(spacing: 28) {
                valuePoint("rectangle.split.3x1.fill", "Columns, not piles", tint: .green)
                valuePoint("keyboard", "Keyboard first", tint: .orange)
                valuePoint("sparkles", "Smooth motion", tint: .pink)
            }
            .padding(.top, 18)
            Spacer(minLength: 0)
        }
    }

    private func valuePoint(_ symbol: String, _ title: String, tint: SectionTint) -> some View {
        VStack(spacing: 10) {
            SectionIcon(symbol: symbol, tint: tint, size: 40)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(GioColor.secondaryText)
        }
        .frame(width: 150)
    }

    private var accessibility: some View {
        permissionStep(
            icon: SectionIcon(symbol: "hand.raised.fill", tint: .blue, size: 80),
            title: "Allow Accessibility",
            why: "Gio arranges your windows and listens for its shortcuts through Accessibility. Without it nothing can tile. Gio never stores or uploads window contents, and its logs never contain window titles.",
            phase: accessibilityGranted ? .granted : .notRequested,
            idleText: "Waiting for permission… turn Gio on in the list, then come back.",
            showsProgress: true,
            grantedText: "Accessibility is on. You're ready to tile.",
            button: "Open System Settings", action: requestAccessibility
        )
    }

    private var screenRecording: some View {
        permissionStep(
            icon: SectionIcon(symbol: "record.circle", tint: .pink, size: 80),
            title: "Screen Recording (Recommended)",
            why: "Gio's smooth motion needs it: Gio slides captured images of your windows, so every app moves at the same speed, even slow ones, and the overview shows live thumbnails. Without it windows still tile, but they stutter as they move. The images stay in memory; nothing is recorded or saved. macOS applies this permission only after Gio relaunches.",
            phase: screenRecordingStepPhase(granted: screenRecordingGranted, requested: screenRecordingRequested),
            idleText: "Not granted. Turn Gio on in System Settings, then relaunch Gio.",
            showsProgress: false,
            grantedText: "Screen Recording is on.",
            button: "Open System Settings", action: requestScreenRecording
        )
    }

    @ViewBuilder
    private func permissionStep(
        icon: SectionIcon, title: String, why: String, phase: PermissionStepPhase, idleText: String,
        showsProgress: Bool, grantedText: String, button: String, action: @escaping () -> Void
    ) -> some View {
        let granted = phase == .granted
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            icon
            Text(title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(GioColor.primaryText)
                .multilineTextAlignment(.center)
            Text(why)
                .font(.system(size: 16))
                .foregroundStyle(GioColor.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 540)
            HStack(spacing: GioSpacing.s) {
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(GioColor.ok)
                        .transition(.scale.combined(with: .opacity))
                    Text(grantedText).font(.system(size: 15, weight: .medium))
                } else if phase == .awaitingRelaunch {
                    Text("Granted it? macOS applies Screen Recording after Gio relaunches.")
                        .font(.system(size: 14))
                        .foregroundStyle(GioColor.secondaryText)
                } else {
                    if showsProgress {
                        ProgressView().controlSize(.small).opacity(isStatic ? 0 : 1)
                    }
                    Text(idleText).font(.system(size: 14)).foregroundStyle(GioColor.secondaryText)
                }
                Spacer(minLength: 0)
                if phase == .awaitingRelaunch {
                    Button("Relaunch Gio", action: relaunch).buttonStyle(SetupButtonStyle(prominent: true))
                } else if !granted {
                    Button(button, action: action).buttonStyle(SetupButtonStyle(prominent: false))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 580)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(granted ? GioColor.ok.opacity(0.10) : GioColor.card.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(granted ? GioColor.ok.opacity(0.3) : GioColor.hairline.opacity(0.6), lineWidth: 0.5)
            )
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: granted)
            Spacer(minLength: 0)
        }
    }

    @Environment(\.gioStaticPage) private var isStatic

    private var keys: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            SectionIcon(symbol: "keyboard", tint: .orange, size: 72)
            Text("Keys to Know")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(GioColor.primaryText)
            Text("A few shortcuts go a long way. Every other one is under Shortcuts.")
                .font(.system(size: 16))
                .foregroundStyle(GioColor.secondaryText)
                .multilineTextAlignment(.center)
            SectionCard {
                ForEach(Array(onboardingKeys.enumerated()), id: \.offset) { index, key in
                    CardRow(divider: index < onboardingKeys.count - 1) {
                        HStack(spacing: GioSpacing.m) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(key.title).font(GioFont.body.weight(.medium))
                                Text(key.detail).font(GioFont.caption).foregroundStyle(GioColor.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: GioSpacing.xs) {
                                ForEach(Array(key.combos.enumerated()), id: \.offset) { position, combo in
                                    if position > 0 {
                                        Text("/").font(GioFont.caption).foregroundStyle(GioColor.tertiaryText)
                                    }
                                    KeyCombo(combo)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 580)
            .padding(.top, 8)
            Label(onboardingKeyboardNote, systemImage: "globe")
                .font(GioFont.caption)
                .foregroundStyle(GioColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 580, alignment: .leading)
            if let loginItem {
                SectionCard {
                    CardRow(divider: false) {
                        LoginItemRow(item: loginItem, setEnabled: setLoginItem, openLoginItems: openLoginItems)
                    }
                }
                .frame(maxWidth: 580)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            ProgressDots(progress: state.progress)
            HStack(spacing: GioSpacing.m) {
                if state.canGoBack {
                    Button("Back") { state.back() }
                        .buttonStyle(SetupButtonStyle(prominent: false, plain: true))
                }
                Spacer(minLength: 0)
                if current.step == .accessibility, !current.canAdvance {
                    Button("Set Up Later", action: onLater)
                        .buttonStyle(SetupButtonStyle(prominent: false, plain: true))
                        .help("Close for now; this guide opens again on the next launch")
                }
                Button(current.primaryTitle) {
                    if current.isLastStep {
                        onFinish()
                    } else {
                        var next = current
                        next.advance()
                        state = next
                    }
                }
                .buttonStyle(SetupButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!current.canAdvance)
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, GioSpacing.m)
        .padding(.bottom, 44)
    }
}

/// The setup's background: Gio's page color with a soft mint glow from the
/// top and a faint pink one from the bottom corner.
private struct SetupBackdrop: View {
    var body: some View {
        GioColor.page
            .overlay(
                RadialGradient(
                    colors: [GioColor.accent.opacity(0.20), .clear],
                    center: UnitPoint(x: 0.5, y: -0.15), startRadius: 0, endRadius: 760
                )
            )
            .overlay(
                RadialGradient(
                    colors: [GioColor.tint(.pink).opacity(0.08), .clear],
                    center: UnitPoint(x: 1.0, y: 1.1), startRadius: 0, endRadius: 620
                )
            )
            .ignoresSafeArea()
    }
}

/// Large capsule buttons of the setup: mint for the primary action, a
/// quiet surface for the secondary one, text only for Back and Later.
private struct SetupButtonStyle: ButtonStyle {
    let prominent: Bool
    var plain = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? GioColor.onAccent : (plain ? GioColor.secondaryText : GioColor.primaryText))
            .padding(.horizontal, plain ? 8 : 24)
            .frame(minWidth: prominent ? 140 : nil, minHeight: 40)
            .background {
                if prominent {
                    Capsule().fill(GioColor.accent)
                } else if !plain {
                    Capsule().fill(Color.primary.opacity(0.08))
                        .overlay(Capsule().strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

private struct ProgressDots: View {
    let progress: OnboardingProgress
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<progress.count, id: \.self) { index in
                Capsule()
                    .fill(index == progress.index
                        ? AccentPalette(accent: accent, colorScheme: colorScheme).ink
                        : GioColor.secondaryText.opacity(0.25))
                    .frame(width: index == progress.index ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(progress.index + 1) of \(progress.count)")
    }
}
