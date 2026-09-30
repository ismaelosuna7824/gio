import AppKit
import Foundation
import GioCore
import SwiftUI

/// Plan §26 launcher shell: spotlight-style window (type to filter, Enter
/// runs, Esc quits). Executes apps via NSWorkspace, windows through the
/// session (`focusWindow`), Gio verbs over IPC, and `!` shell lines via zsh —
/// never touching Core state directly. Thin and live-only; matching and
/// routing are tested in LauncherModel.
func runLauncherEntry(_ entry: LauncherEntry, focusWindow: (String) -> Bool = { _ in false }) -> String {
    switch entry {
    case .window(let id, let application, _, _):
        return focusWindow(id) ? "focused \(application)" : "that window is gone"
    case .app(let name, let bundleID, let path):
        let url: URL?
        if let bundleID,
           let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        {
            url = found
        } else {
            url = URL(fileURLWithPath: path)
        }
        let opened = url.map { NSWorkspace.shared.open($0) } ?? false
        return opened ? "opened \(name)" : "could not open \(name)"
    case .gioCommand(let argv, _):
        do {
            let response = try sendIPCRequest(argv, socketPath: defaultSocketPath())
            if response.ok {
                return response.output ?? "ok"
            }
            return "gio failed: \(response.error ?? "unknown")"
        } catch {
            return "no running Gio session"
        }
    case .shellCommand(let command):
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        do {
            try task.run()
            return "launched: \(command)"
        } catch {
            return "shell failed: \(error)"
        }
    }
}

/// Keys the launcher panel handles before the text field sees them.
public enum LauncherKey: Equatable, Sendable {
    case up, down, enter, escape
    case digit(Int)
}

/// DD-05 launcher state: query, ranked results and keyboard selection.
/// Search, ranking and routing stay in `LauncherModel` (pure, tested).
@MainActor
public final class LauncherViewModel: ObservableObject {
    @Published public var text = "" {
        didSet { refreshResults() }
    }
    @Published public private(set) var results: [LauncherEntry] = []
    @Published public private(set) var selection = LauncherSelection(count: 0)
    @Published public private(set) var status: String?
    private let entries: [LauncherEntry]
    private let focusWindow: (String) -> Bool
    var dismiss: () -> Void = {}

    public init(
        windows: [WindowFact] = [], apps: [LauncherEntry] = [], focusWindow: @escaping (String) -> Bool = { _ in false }
    ) {
        entries = launcherWindowEntries(from: windows) + apps
        self.focusWindow = focusWindow
        refreshResults()
    }

    /// `> …` and `! …` are commands: no list, Enter routes them.
    public var commandHint: String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            return "Run a Gio command, like \u{201C}> workspace 2\u{201D} or \u{201C}> reload\u{201D}"
        }
        if trimmed.hasPrefix("!") {
            return "Run a shell command with zsh"
        }
        return nil
    }

    private func refreshResults() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = Array(entries.prefix(8))
        } else if trimmed.hasPrefix(">") || trimmed.hasPrefix("!") {
            results = []
        } else {
            results = Array(searchLauncherEntries(trimmed, in: entries).prefix(8))
        }
        selection.reset(count: results.count)
        status = nil
    }

    public func select(_ index: Int) {
        selection.select(index)
    }

    /// True when the key was used (the panel then swallows it).
    @discardableResult
    public func handle(_ key: LauncherKey) -> Bool {
        switch key {
        case .up:
            selection.moveUp()
        case .down:
            selection.moveDown()
        case .enter:
            commit()
        case .escape:
            if text.isEmpty {
                dismiss()
            } else {
                text = ""
            }
        case .digit(let digit):
            guard let index = selection.index(forDigit: digit) else {
                return false
            }
            run(results[index])
        }
        return true
    }

    func commit() {
        if let index = selection.current, results.indices.contains(index) {
            run(results[index])
            return
        }
        switch routeLauncherInput(text, apps: entries) {
        case .empty: dismiss()
        case .runEntry(let entry): run(entry)
        case .noMatch: status = "No app or window matches."
        case .invalid(let message): status = message
        }
    }

    func run(_ entry: LauncherEntry) {
        let outcome = runLauncherEntry(entry, focusWindow: focusWindow)
        switch entry {
        case .app, .window:
            dismiss()
        default:
            status = outcome
        }
    }
}

/// Spotlight-like launcher content: large search field, result rows with
/// icons, kind badges and ⌘1–9 hints, over a vibrant rounded panel.
public struct GioLauncherView: View {
    @ObservedObject var model: LauncherViewModel
    let icon: (LauncherEntry) -> NSImage?
    @FocusState private var searchFocused: Bool
    @Environment(\.gioStaticPage) private var isStatic

    public init(model: LauncherViewModel, icon: @escaping @MainActor (LauncherEntry) -> NSImage? = launcherIcon) {
        self.model = model
        self.icon = icon
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchRow
            if !model.results.isEmpty || model.commandHint != nil || model.status != nil {
                Divider().opacity(0.6)
            }
            if !model.results.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.listID) { index, entry in
                        LauncherRow(
                            entry: entry, icon: icon(entry), index: index,
                            isSelected: index == model.selection.current
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { model.run(entry) }
                        .onHover { inside in
                            if inside { model.select(index) }
                        }
                    }
                }
                .padding(GioSpacing.xs - 2)
            }
            if let hint = model.commandHint, model.status == nil {
                messageRow(symbol: "command", text: hint)
            }
            if let status = model.status {
                messageRow(symbol: "info.circle", text: status)
            }
            footer
        }
        .frame(width: 640)
        .background(LauncherBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear { searchFocused = true }
    }

    private var searchRow: some View {
        HStack(spacing: GioSpacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(GioColor.secondaryText)
            Group {
                if isStatic {
                    Text(model.text.isEmpty ? "Search apps and windows" : model.text)
                        .foregroundStyle(model.text.isEmpty ? GioColor.tertiaryText : GioColor.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Search apps and windows", text: $model.text)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { model.commit() }
                }
            }
            .font(.system(size: 22, weight: .light))
            if !model.text.isEmpty {
                InlineTag(text: "esc to clear")
            }
        }
        .padding(.horizontal, GioSpacing.l)
        .frame(height: 60)
    }

    private func messageRow(symbol: String, text: String) -> some View {
        HStack(spacing: GioSpacing.xs) {
            Image(systemName: symbol).foregroundStyle(GioColor.secondaryText)
            Text(text).font(GioFont.callout).foregroundStyle(GioColor.secondaryText).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GioSpacing.l)
        .padding(.vertical, GioSpacing.s)
    }

    private var footer: some View {
        HStack(spacing: GioSpacing.m) {
            footerHint("↑↓", "select")
            footerHint("return", "open")
            footerHint("⌘1–9", "jump")
            footerHint("esc", "close")
            Spacer(minLength: 0)
            Text("> Gio command  ·  ! shell")
                .font(GioFont.caption)
                .foregroundStyle(GioColor.tertiaryText)
        }
        .padding(.horizontal, GioSpacing.l)
        .frame(height: 30)
        .background(Color.primary.opacity(0.035))
    }

    private func footerHint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).font(GioFont.caption.weight(.semibold)).foregroundStyle(GioColor.secondaryText)
            Text(label).font(GioFont.caption).foregroundStyle(GioColor.tertiaryText)
        }
    }
}

private struct LauncherRow: View {
    let entry: LauncherEntry
    let icon: NSImage?
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: GioSpacing.s) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    SectionIcon(symbol: fallbackSymbol, tint: fallbackTint, size: 28)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(primary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : GioColor.primaryText)
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(GioFont.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : GioColor.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: GioSpacing.s)
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : GioColor.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.07)))
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(GioFont.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : GioColor.tertiaryText)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, GioSpacing.s - 2)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? Color(nsColor: .controlAccentColor) : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var primary: String {
        switch entry {
        case .window(_, let application, let title, _): return title.isEmpty ? application : title
        default: return entry.title
        }
    }

    private var secondary: String? {
        switch entry {
        case .window(_, let application, let title, _): return title.isEmpty ? nil : application
        default: return nil
        }
    }

    private var badge: String {
        switch entry {
        case .app: return "App"
        case .window(_, _, _, let workspace): return workspace.map { "Window · WS \($0)" } ?? "Window"
        case .gioCommand: return "Gio"
        case .shellCommand: return "Shell"
        }
    }

    private var fallbackSymbol: String {
        switch entry {
        case .app: return "app.fill"
        case .window: return "macwindow"
        case .gioCommand: return "command"
        case .shellCommand: return "terminal.fill"
        }
    }

    private var fallbackTint: SectionTint {
        switch entry {
        case .app: return .blue
        case .window: return .indigo
        case .gioCommand: return .gray
        case .shellCommand: return .gray
        }
    }
}

/// Behind-window vibrancy; a plain material stand-in on a static page.
private struct LauncherBackdrop: View {
    @Environment(\.gioStaticPage) private var isStatic
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if isStatic {
            (colorScheme == .dark ? Color(white: 0.17).opacity(0.97) : Color(white: 0.97).opacity(0.97))
        } else {
            VisualEffectBackground(material: .popover)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// App icon for an app entry, the running app's icon for a window entry.
@MainActor
public func launcherIcon(_ entry: LauncherEntry) -> NSImage? {
    switch entry {
    case .app(_, _, let path):
        return NSWorkspace.shared.icon(forFile: path)
    case .window(_, let application, _, _):
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == application }?.icon
    case .gioCommand, .shellCommand:
        return nil
    }
}

// MARK: - Panel

/// Borderless panel that takes key without activating Gio (so summoning it
/// never raises the main window), keeps its top edge fixed while its height
/// follows the results, and routes navigation keys to the model.
final class LauncherPanel: NSPanel {
    var keyHandler: ((LauncherKey) -> Bool)?
    var anchoredTop: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var frame = frameRect
        if let top = anchoredTop {
            frame.origin.y = top - frame.height
        }
        super.setFrame(frame, display: flag)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let key = launcherKey(event), keyHandler?(key) == true {
            return
        }
        super.sendEvent(event)
    }

    private func launcherKey(_ event: NSEvent) -> LauncherKey? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), let char = event.charactersIgnoringModifiers, let digit = Int(char), (1...9).contains(digit) {
            return .digit(digit)
        }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .enter
        case 53: return .escape
        default: return nil
        }
    }
}

/// Owns the launcher panel: shows it centered near the top of the screen
/// with the pointer, animates it in (a fade only with Reduce Motion) and
/// dismisses it when it loses focus.
@MainActor
public final class LauncherPanelController: NSObject, NSWindowDelegate {
    private var panel: LauncherPanel?
    private let focusWindow: (String) -> Bool
    private var dismissing = false

    public init(focusWindow: @escaping (String) -> Bool) {
        self.focusWindow = focusWindow
        super.init()
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// A fresh model per summon: the window list is current, the query empty.
    public func show(windows: [WindowFact], apps: [LauncherEntry]) {
        let model = LauncherViewModel(windows: windows, apps: apps, focusWindow: focusWindow)
        model.dismiss = { [weak self] in self?.dismiss() }
        let hosting = NSHostingController(rootView: GioLauncherView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.keyHandler = { [weak model] key in model?.handle(key) ?? false }
        panel.anchoredTop = nil
        panel.contentViewController = hosting
        panel.layoutIfNeeded()
        let size = hosting.view.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = visible.maxY - visible.height * 0.18
        panel.anchoredTop = top
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height), display: false)
        dismissing = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        let final = panel.frame
        if !reduceMotion {
            panel.anchoredTop = top + 8
            panel.setFrame(final.offsetBy(dx: 0, dy: 8), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if !reduceMotion {
                panel.animator().setFrame(final, display: true)
            }
        } completionHandler: {
            MainActor.assumeIsolated { panel.anchoredTop = top }
        }
    }

    public func dismiss() {
        guard let panel, panel.isVisible, !dismissing else {
            return
        }
        dismissing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.contentViewController = nil
            }
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func makePanel() -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }
}
