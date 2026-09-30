import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// Sidebar sections of the unified Gio window.
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case overview, shortcuts, layout, focus, animations, rules, logs, diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .shortcuts: return "Shortcuts"
        case .layout: return "Layout"
        case .focus: return "Focus"
        case .animations: return "Animations"
        case .rules: return "Rules"
        case .logs: return "Logs"
        case .diagnostics: return "Diagnostics"
        }
    }

    /// Sidebar tile symbol; see `sectionStyle` for the tint.
    public var symbol: String {
        sectionStyle(self).symbol
    }
}

/// The Dock icon and Cmd+Tab entry exist only while the main window is
/// visible; hidden, Gio is a pure menu-bar agent again.
public func desiredActivationPolicy(windowVisible: Bool) -> NSApplication.ActivationPolicy {
    windowVisible ? .regular : .accessory
}

public struct GioMainView: View {
    @State private var selection: MainSection? = .overview
    @ObservedObject private var model: DesktopModel
    /// Unsaved settings edits per section, kept across section switches
    /// and window closes (the hosting view lives as long as the app).
    @StateObject private var drafts = SettingsDraftStore()
    @StateObject private var onboarding = OnboardingPresenter()
    private let onSectionChange: (MainSection) -> Void

    public init(model: DesktopModel, onSectionChange: @escaping (MainSection) -> Void = { _ in }) {
        self.model = model
        self.onSectionChange = onSectionChange
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(sidebarGroups) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            SidebarRow(section: section, hasUnsavedEdits: drafts.dirtySections.contains(section))
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top, spacing: 0) {
                SidebarHeader(status: sessionStatus(model.snapshot.facts), version: appVersionLabel())
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail(for: selection ?? .overview)
                .navigationTitle((selection ?? .overview).title)
        }
        .environment(\.gioAccent, model.snapshot.config.focusRing.resolvedColor())
        .environment(\.onboardingPresenter, onboarding)
        .sheet(isPresented: $onboarding.isPresented) {
            OnboardingSheet(model: model, onFinish: { onboarding.finish() }, onLater: { onboarding.later() })
                .environment(\.gioAccent, model.snapshot.config.focusRing.resolvedColor())
        }
        .onReceive(model.$snapshot) { onboarding.evaluate($0.facts) }
        .frame(minWidth: mainWindowMinSize.width, minHeight: mainWindowMinSize.height)
        .onAppear { onSectionChange(selection ?? .overview) }
        .onChange(of: selection) { section in
            onSectionChange(section ?? .overview)
        }
    }

    @ViewBuilder
    private func detail(for section: MainSection) -> some View {
        switch section {
        case .overview: OverviewView(model: model)
        case .shortcuts: ShortcutsView(model: model)
        case .layout: LayoutSettingsView(model: model, drafts: drafts)
        case .focus: FocusSettingsView(model: model, drafts: drafts)
        case .animations: AnimationsSettingsView(model: model, drafts: drafts)
        case .rules: RulesSettingsView(model: model)
        case .logs: LogsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        }
    }
}

/// Smallest and first-launch sizes of the main window's content.
public let mainWindowMinSize = CGSize(width: 860, height: 580)
public let mainWindowDefaultSize = CGSize(width: 1040, height: 700)

/// `0.1.0` from the bundle, else the built-in version string.
func appVersionLabel() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? gioVersion
}

/// One sidebar row: colored symbol tile and title, System Settings style,
/// with a dot while the section holds unsaved edits.
struct SidebarRow: View {
    let section: MainSection
    var hasUnsavedEdits = false
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label {
            HStack(spacing: GioSpacing.xs) {
                Text(section.title)
                Spacer(minLength: 0)
                if hasUnsavedEdits {
                    Circle()
                        .fill(AccentPalette(accent: accent, colorScheme: colorScheme).ink)
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes")
                        .transition(.scale.combined(with: .opacity))
                }
            }
        } icon: {
            SectionIcon(section, size: 20)
        }
        .padding(.vertical, 1)
        .accessibilityValue(hasUnsavedEdits ? "Unsaved changes" : "")
    }
}

/// Top of the sidebar: Gio mark, name, version and the session status dot.
struct SidebarHeader: View {
    let status: SessionStatus
    let version: String
    @Environment(\.gioAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: colorScheme)
        HStack(spacing: GioSpacing.s - 2) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.gradient)
                .overlay(
                    Image(systemName: "rectangle.split.3x1.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.onGradient)
                )
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: GioSpacing.xxs + 1) {
                    Text("Gio").font(.system(size: 15, weight: .semibold))
                    Text(version)
                        .font(GioFont.caption.monospacedDigit())
                        .foregroundStyle(GioColor.tertiaryText)
                        .lineLimit(1)
                }
                HStack(spacing: GioSpacing.xxs + 1) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(status.label)
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GioSpacing.m)
        .padding(.top, GioSpacing.xs)
        .padding(.bottom, GioSpacing.s)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch status.kind {
        case .ok: return GioColor.ok
        case .warning: return GioColor.warning
        case .error: return GioColor.error
        case .info: return GioColor.info
        case .neutral: return GioColor.tertiaryText
        }
    }
}

/// Owns the single "Gio" window. Closing (red button, Cmd+W) hides it and
/// drops the app back to accessory policy; Gio keeps tiling from the
/// menu bar. `show()` restores the Dock icon and brings it forward.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: DesktopModel

    public init(model: DesktopModel) {
        self.model = model
        super.init()
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func show() {
        if window == nil {
            window = makeWindow()
        }
        NSApplication.shared.setActivationPolicy(desiredActivationPolicy(windowVisible: true))
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        model.setWindowVisible(true)
    }

    private static let autosaveName = "GioMainWindow"

    /// Unified toolbar window with a full-height sidebar; the title follows
    /// the selected section and the frame is restored across launches.
    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: GioMainView(model: model) { [weak self] section in
            self?.window?.title = section.title
        })
        hosting.sizingOptions = []
        if #available(macOS 14.0, *) {
            hosting.sceneBridgingOptions = [.title, .toolbars]
        }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = MainSection.overview.title
        window.toolbar = NSToolbar(identifier: "GioMainToolbar")
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: mainWindowMinSize.width, height: mainWindowMinSize.height)
        window.setContentSize(NSSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height))
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        return window
    }

    public func hide() {
        window?.orderOut(nil)
        model.setWindowVisible(false)
        NSApplication.shared.setActivationPolicy(desiredActivationPolicy(windowVisible: false))
    }

    /// Minimized or fully covered windows need no live updates either.
    public func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else {
            return
        }
        model.setWindowVisible(window.isVisible && window.occlusionState.contains(.visible))
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Minimal main menu so Cmd+W hides the window and Cmd+Q quits through
    /// the normal terminate path (which restores parked windows).
    public func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "Quit Gio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let close = NSMenuItem(title: "Close", action: #selector(closeFromMenu), keyEquivalent: "w")
        close.target = self
        windowMenu.addItem(close)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    @objc private func closeFromMenu() {
        hide()
    }
}
