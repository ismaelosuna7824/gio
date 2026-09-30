import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// Sidebar sections of the unified Gio window.
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case overview, shortcuts, layout, animations, rules, logs, diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .shortcuts: return "Shortcuts"
        case .layout: return "Layout"
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
    private let model: DesktopModel

    public init(model: DesktopModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            detail(for: selection ?? .overview)
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    @ViewBuilder
    private func detail(for section: MainSection) -> some View {
        switch section {
        case .overview: OverviewView(model: model)
        case .shortcuts: ShortcutsView(model: model)
        case .layout: LayoutSettingsView(model: model)
        case .animations: AnimationsSettingsView(model: model)
        case .rules: RulesSettingsView(model: model)
        case .logs: LogsView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
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
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Gio"
            window.contentView = NSHostingView(rootView: GioMainView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
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
