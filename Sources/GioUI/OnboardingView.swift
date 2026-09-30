import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// DD-05 first-run onboarding, presented as a sheet on the main window: a
/// welcome, Accessibility (required, with live status from the existing
/// permission polling), optional Screen Recording, and the keys to know.

/// Remembers that onboarding was finished. Injected so tests never write
/// the user's defaults.
public struct OnboardingStore {
    private let defaults: UserDefaults
    static let key = "GioOnboardingCompleted"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompleted: Bool { defaults.bool(forKey: Self.key) }

    public func markCompleted() {
        defaults.set(true, forKey: Self.key)
    }
}

/// Main-window state for the onboarding sheet: decided once per launch,
/// on the first session facts; the Overview can reopen it any time.
@MainActor
public final class OnboardingPresenter: ObservableObject {
    @Published public var isPresented = false
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
        if shouldShowOnboarding(hasCompleted: store.hasCompleted, accessibilityGranted: facts.accessibilityGranted) {
            isPresented = true
        }
    }

    public func present() {
        isPresented = true
    }

    func finish() {
        store.markCompleted()
        isPresented = false
    }

    func later() {
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
    let onFinish: () -> Void
    let onLater: () -> Void

    var body: some View {
        OnboardingContent(
            accessibilityGranted: model.snapshot.facts?.accessibilityGranted ?? false,
            screenRecordingGranted: model.snapshot.facts?.screenRecordingGranted ?? false,
            onFinish: onFinish, onLater: onLater,
            requestAccessibility: {
                _ = requestAXPermission()
                openPrivacyPane("Privacy_Accessibility")
                model.refresh()
            },
            requestScreenRecording: {
                _ = requestScreenRecordingPermission()
                model.refresh()
            }
        )
        .onAppear { model.refresh() }
        .pollWhileVisible(model, every: 1) { model.refresh() }
    }
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
    var onFinish: () -> Void = {}
    var onLater: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var requestScreenRecording: () -> Void = {}
    @State private var state: OnboardingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        accessibilityGranted: Bool, screenRecordingGranted: Bool, step: OnboardingStep = .welcome,
        onFinish: @escaping () -> Void = {}, onLater: @escaping () -> Void = {},
        requestAccessibility: @escaping () -> Void = {}, requestScreenRecording: @escaping () -> Void = {}
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.onFinish = onFinish
        self.onLater = onLater
        self.requestAccessibility = requestAccessibility
        self.requestScreenRecording = requestScreenRecording
        _state = State(initialValue: OnboardingState(
            accessibilityGranted: accessibilityGranted, screenRecordingGranted: screenRecordingGranted, step: step
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(progress: state.progress)
                .padding(.top, GioSpacing.l)
            Group {
                switch state.step {
                case .welcome: welcome
                case .accessibility: accessibility
                case .screenRecording: screenRecording
                case .keys: keys
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, GioSpacing.xxl + 8)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(state.step)
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .background(GioColor.page)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9), value: state.step)
        .onChange(of: accessibilityGranted) { _ in sync() }
        .onChange(of: screenRecordingGranted) { _ in sync() }
    }

    private func sync() {
        state.update(accessibilityGranted: accessibilityGranted, screenRecordingGranted: screenRecordingGranted)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: GioSpacing.m) {
            Spacer(minLength: 0)
            GioAppMark(size: 96)
            Text("Welcome to Gio").font(.system(size: 26, weight: .bold))
            Text("Scrollable tiling for macOS. Windows open as columns on an endless strip, and your keyboard glides you along it.")
                .font(.system(size: 14))
                .foregroundStyle(GioColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            HStack(spacing: GioSpacing.l) {
                valuePoint("rectangle.split.3x1.fill", "Columns, not piles")
                valuePoint("keyboard", "Keyboard first")
                valuePoint("sparkles", "Smooth motion")
            }
            .padding(.top, GioSpacing.s)
            Spacer(minLength: 0)
        }
    }

    private func valuePoint(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: GioSpacing.xs - 2) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(GioColor.secondaryText)
                .frame(height: 22)
            Text(title).font(GioFont.caption.weight(.medium)).foregroundStyle(GioColor.secondaryText)
        }
        .frame(width: 120)
    }

    private var accessibility: some View {
        permissionStep(
            icon: SectionIcon(symbol: "hand.raised.fill", tint: .blue, size: 64),
            title: "Allow Accessibility",
            why: "Gio arranges your windows and listens for its shortcuts through Accessibility. Without it nothing can tile. Gio never reads window contents, and its logs never contain window titles.",
            granted: accessibilityGranted,
            waiting: "Waiting for permission… turn Gio on in the list, then come back.",
            grantedText: "Accessibility is on. You're ready to tile.",
            button: "Open System Settings", action: requestAccessibility
        )
    }

    private var screenRecording: some View {
        permissionStep(
            icon: SectionIcon(symbol: "record.circle", tint: .pink, size: 64),
            title: "Screen Recording (Optional)",
            why: "Only the experimental snapshot renderer needs it: it animates captured images of your windows, then places them once. Gio records nothing and saves nothing. Skip this unless you want to try it.",
            granted: screenRecordingGranted,
            waiting: "Not granted. macOS applies it after you relaunch Gio.",
            grantedText: "Screen Recording is on.",
            button: "Open System Settings", action: requestScreenRecording
        )
    }

    private func permissionStep(
        icon: SectionIcon, title: String, why: String, granted: Bool, waiting: String, grantedText: String,
        button: String, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: GioSpacing.m) {
            Spacer(minLength: 0)
            icon
            Text(title).font(.system(size: 22, weight: .bold))
            Text(why)
                .font(GioFont.body)
                .foregroundStyle(GioColor.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            HStack(spacing: GioSpacing.s - 2) {
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(GioColor.ok)
                        .transition(.scale.combined(with: .opacity))
                    Text(grantedText).font(GioFont.callout.weight(.medium))
                } else {
                    ProgressView().controlSize(.small).opacity(isStatic ? 0 : 1)
                    Text(waiting).font(GioFont.callout).foregroundStyle(GioColor.secondaryText)
                }
                Spacer(minLength: 0)
                if !granted {
                    GioButton(title: button, systemImage: "arrow.up.forward.app", action: action)
                }
            }
            .padding(GioSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                    .fill(granted ? GioColor.ok.opacity(0.10) : GioColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                    .strokeBorder(granted ? GioColor.ok.opacity(0.3) : GioColor.hairline.opacity(0.6), lineWidth: 0.5)
            )
            .accessibilityElement(children: .combine)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: granted)
            Spacer(minLength: 0)
        }
    }

    @Environment(\.gioStaticPage) private var isStatic

    private var keys: some View {
        VStack(spacing: GioSpacing.m) {
            Spacer(minLength: 0)
            Text("Keys to Know").font(.system(size: 22, weight: .bold))
            Text("A few shortcuts go a long way. Every other one is under Shortcuts.")
                .font(GioFont.body)
                .foregroundStyle(GioColor.secondaryText)
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
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: GioSpacing.s) {
            if state.canGoBack {
                GioButton(title: "Back", role: .borderless) { state.back() }
            }
            Spacer(minLength: 0)
            if state.step == .accessibility, !state.canAdvance {
                GioButton(title: "Set Up Later", action: onLater)
                    .help("Close for now; this guide opens again on the next launch")
            }
            GioButton(title: state.primaryTitle, role: .prominent, shortcut: .defaultAction) {
                if state.isLastStep {
                    onFinish()
                } else {
                    state.advance()
                }
            }
            .disabled(!state.canAdvance)
        }
        .padding(.horizontal, GioSpacing.l)
        .padding(.vertical, GioSpacing.s + 2)
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

/// The app icon when running as the app, else the Gio mark tile.
struct GioAppMark: View {
    let size: CGFloat
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.gioStaticPage) private var isStatic

    var body: some View {
        if !isStatic, Bundle.main.bundleURL.pathExtension == "app", let icon = NSApp?.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(palette.gradient)
                .overlay(
                    Image(systemName: "rectangle.split.3x1.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(palette.onGradient)
                )
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: size * 0.06, y: size * 0.03)
                .accessibilityHidden(true)
        }
    }
}
