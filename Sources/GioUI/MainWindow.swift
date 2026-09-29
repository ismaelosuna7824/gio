import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// Sidebar sections of the unified Gio window. Sections without a
/// dedicated view yet render a short placeholder.
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case overview, shortcuts, layout, animations, rules, logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return "Overview"
        case .shortcuts: return "Shortcuts"
        case .layout: return "Layout"
        case .animations: return "Animations"
        case .rules: return "Rules"
        case .logs: return "Logs"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: return "rectangle.3.group"
        case .shortcuts: return "keyboard"
        case .layout: return "rectangle.split.3x1"
        case .animations: return "wand.and.stars"
        case .rules: return "list.bullet.rectangle"
        case .logs: return "text.alignleft"
        }
    }

    /// False while the section only shows a placeholder.
    public var isImplemented: Bool {
        switch self {
        case .overview, .shortcuts, .logs: return true
        case .layout, .animations, .rules: return false
        }
    }
}

/// The Dock icon and Cmd+Tab entry exist only while the main window is
/// visible; hidden, Gio is a pure menu-bar agent again.
public func desiredActivationPolicy(windowVisible: Bool) -> NSApplication.ActivationPolicy {
    windowVisible ? .regular : .accessory
}

public struct GioMainView: View {
    @State private var selection: MainSection? = .overview

    public init() {}

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
        case .overview: OverviewPlaceholderView()
        case .logs: LogsView()
        default: PlaceholderView(section: section)
        }
    }
}

struct PlaceholderView: View {
    let section: MainSection

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: section.symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(section.title).font(.title2)
            Text("Coming soon. Until then, edit ~/.config/gio/config.toml.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Interim Overview: Accessibility state and the Request Access button
/// that used to live in the debug console.
struct OverviewPlaceholderView: View {
    @State private var trusted = hasAXPermission()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview").font(.title2)
            HStack {
                Text("Accessibility: \(trusted ? "granted" : "missing")").font(.headline)
                Spacer()
                Button("Request Access") { trusted = requestAXPermission() }
                Button("Refresh") { trusted = hasAXPermission() }
            }
            if !trusted {
                Text("Gio needs Accessibility access to move windows and hear shortcuts.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct LogsView: View {
    @State private var text = ""
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logs").font(.title2)
                Spacer()
                Button("Refresh") { reload() }
            }
            ScrollView {
                Text(text.isEmpty ? "(log empty)" : text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .border(Color.secondary.opacity(0.3))
        }
        .padding()
        .onAppear { reload() }
        .onReceive(ticker) { _ in reload() }
    }

    private func reload() {
        text = GioLog.entries().suffix(200).map { $0.line() }.joined(separator: "\n")
    }
}

/// Owns the single "Gio" window. Closing (red button, Cmd+W) hides it and
/// drops the app back to accessory policy; Gio keeps tiling from the
/// menu bar. `show()` restores the Dock icon and brings it forward.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    public override init() {
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
            window.contentView = NSHostingView(rootView: GioMainView())
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
    }

    public func hide() {
        window?.orderOut(nil)
        NSApplication.shared.setActivationPolicy(desiredActivationPolicy(windowVisible: false))
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
