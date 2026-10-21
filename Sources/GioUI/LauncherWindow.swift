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
    case .gioCommand, .workspace:
        return runLauncherIPC(entry)
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

/// A Gio command or workspace entry over IPC. PA-17c: blocks until the
/// session answers (its queue may be busy), so never on the main thread.
public func runLauncherIPC(_ entry: LauncherEntry) -> String {
    guard let argv = launcherIPCArguments(entry) else {
        return "nothing to run"
    }
    do {
        let response = try sendIPCRequest(argv, socketPath: defaultSocketPath())
        if response.ok {
            if case .workspace(_, let name, _, _) = entry {
                return "switched to \(name)"
            }
            return response.output ?? "ok"
        }
        return "gio failed: \(response.error ?? "unknown")"
    } catch {
        return "no running Gio session"
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
    private var entries: [LauncherEntry]
    private let leading: [LauncherEntry]
    private let focusWindow: (String) -> Bool
    /// PA-17c: answers a Gio command or workspace entry; runs off main.
    private let requestIPC: @Sendable (LauncherEntry) -> String
    var dismiss: (LauncherDismissReason) -> Void = { _ in }

    public init(
        windows: [WindowFact] = [], workspaces: [LauncherEntry] = [], apps: [LauncherEntry] = [],
        focusWindow: @escaping (String) -> Bool = { _ in false },
        requestIPC: @escaping @Sendable (LauncherEntry) -> String = { runLauncherIPC($0) }
    ) {
        leading = launcherWindowEntries(from: windows) + workspaces
        entries = leading + apps
        self.focusWindow = focusWindow
        self.requestIPC = requestIPC
        refreshResults()
    }

    /// PF-01: the background app scan landed while the panel is up. Keeps
    /// the query; the selection resets only when the results change.
    public func updateApps(_ apps: [LauncherEntry]) {
        let updated = leading + apps
        guard updated != entries else {
            return
        }
        entries = updated
        refreshResults(keepingStatus: true)
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

    private func refreshResults(keepingStatus: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = Array(entries.prefix(8))
        } else if trimmed.hasPrefix(">") || trimmed.hasPrefix("!") {
            results = []
        } else {
            results = Array(searchLauncherEntries(trimmed, in: entries).prefix(8))
        }
        selection.reset(count: results.count)
        if !keepingStatus {
            status = nil
        }
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
                dismiss(.escape)
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
        case .empty: dismiss(.escape)
        case .runEntry(let entry): run(entry)
        case .noMatch: status = "No app, window or workspace matches."
        case .invalid(let message): status = message
        }
    }

    func run(_ entry: LauncherEntry) {
        switch entry {
        case .gioCommand, .workspace:
            // PA-17c: the reply waits on the session queue; main never does.
            let request = requestIPC
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = request(entry)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finish(entry, outcome: outcome) }
                }
            }
        default:
            finish(entry, outcome: runLauncherEntry(entry, focusWindow: focusWindow))
        }
    }

    private func finish(_ entry: LauncherEntry, outcome: String) {
        switch entry {
        case .app, .window:
            dismiss(.action)
        case .workspace:
            if outcome.hasPrefix("switched") {
                dismiss(.action)
            } else {
                status = outcome
            }
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
                    Text(model.text.isEmpty ? "Search apps, windows and workspaces" : model.text)
                        .foregroundStyle(model.text.isEmpty ? GioColor.tertiaryText : GioColor.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Search apps, windows and workspaces", text: $model.text)
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
                if case .workspace(let number, _, let symbol, let color) = entry {
                    WorkspaceGlyph(icon: symbol, color: color, size: 28, fallback: "\(number)")
                } else if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    SectionIcon(symbol: fallbackSymbol, tint: fallbackTint, size: 28)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(primary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? GioColor.onAccent : GioColor.primaryText)
                    .lineLimit(1)
                if let secondary {
                    Text(secondary)
                        .font(GioFont.caption)
                        .foregroundStyle(isSelected ? GioColor.onAccent.opacity(0.8) : GioColor.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: GioSpacing.s)
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? GioColor.onAccent : GioColor.secondaryText)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(isSelected ? GioColor.onAccent.opacity(0.16) : Color.primary.opacity(0.07)))
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(GioFont.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? GioColor.onAccent.opacity(0.85) : GioColor.tertiaryText)
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, GioSpacing.s - 2)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? GioColor.accent : Color.clear)
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
        case .workspace(let number, _, _, _): return number <= 9 ? "Workspace \(number) · ⌥\(number)" : "Workspace \(number)"
        default: return nil
        }
    }

    private var badge: String {
        switch entry {
        case .app: return "App"
        case .window(_, _, _, let workspace): return workspace.map { "Window · WS \($0)" } ?? "Window"
        case .gioCommand: return "Gio"
        case .shellCommand: return "Shell"
        case .workspace: return "Workspace"
        }
    }

    private var fallbackSymbol: String {
        switch entry {
        case .app: return "app.fill"
        case .window: return "macwindow"
        case .gioCommand: return "command"
        case .shellCommand: return "terminal.fill"
        case .workspace: return "square.stack.3d.up.fill"
        }
    }

    private var fallbackTint: SectionTint {
        switch entry {
        case .app: return .blue
        case .window: return .indigo
        case .gioCommand: return .gray
        case .shellCommand: return .gray
        case .workspace: return .cyan
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
    case .gioCommand, .shellCommand, .workspace:
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

    /// Slides to `frame` inside the current animation group. The animator
    /// proxy is reached as a plain `NSWindow` so the call goes through
    /// Objective-C dispatch: called on the Swift subclass, the `setFrame`
    /// override above runs with the proxy as `self` and reads `anchoredTop`
    /// from foreign memory (2026-10-07: frame y = 3e59, AppKit assertion).
    func animateFrame(to frame: NSRect) {
        let window: NSWindow = animator()
        window.setFrame(frame, display: true)
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
///
/// FI-09 presentation: Gio is usually an inactive `.accessory` app when the
/// hotkey fires, so the panel is ordered in with `orderFrontRegardless()`
/// and then made key (a non-activating panel takes key without activating
/// Gio) and the search field is made first responder explicitly. A
/// resign-key within `LauncherLifecycle.resignGrace` of showing reclaims key
/// instead of dismissing; the appear end state (alpha 1, anchored frame) is
/// applied by the animation completion and again by a safety deadline; and
/// generation tokens keep a stale fade-out from ordering out a new show.
/// The toggle reads the real panel (`isVisible`), not a flag alone.
@MainActor
public final class LauncherPanelController: NSObject, NSWindowDelegate {
    private var panel: LauncherPanel?
    private let focusWindow: (String) -> Bool
    private let now: () -> TimeInterval
    private var lifecycle = LauncherLifecycle()
    /// PF-01: cached apps and icons, scanned in the background.
    private let catalog: LauncherAppCatalog?
    private weak var model: LauncherViewModel?

    public init(
        focusWindow: @escaping (String) -> Bool,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        catalog: LauncherAppCatalog? = nil
    ) {
        self.focusWindow = focusWindow
        self.now = now
        self.catalog = catalog
        super.init()
        catalog?.onChange = { [weak self] in self?.appsChanged() }
    }

    /// A scan landed while the panel is up: the list updates in place.
    private func appsChanged() {
        guard let catalog, let model, lifecycle.isPresented else {
            return
        }
        model.updateApps(catalog.apps)
    }

    /// What a summon does now: derived from the panel and the lifecycle.
    public var summonAction: LauncherToggle {
        lifecycle.toggle(panelVisible: panel?.isVisible ?? false)
    }

    public var isVisible: Bool { summonAction == .dismiss }

    /// Show when hidden (or fading out), dismiss when presented.
    /// `requestedAt` is when the hotkey fired (uptime seconds); the log's
    /// `summon→shown` spans from it to the panel ordered front and key.
    public func summon(
        source: LauncherSummonSource, requestedAt: TimeInterval? = nil, windows: () -> [WindowFact],
        workspaces: () -> [LauncherEntry] = { [] }, apps: () -> [LauncherEntry]
    ) {
        let requested = requestedAt ?? now()
        GioLog.record(.info, "launcher summon source=\(source.rawValue)")
        switch summonAction {
        case .dismiss:
            dismiss(reason: .toggle)
        case .show:
            show(windows: windows(), workspaces: workspaces(), apps: apps())
            GioLog.record(
                .info,
                "launcher summon→shown ms=\(Int(((now() - requested) * 1000).rounded())) source=\(source.rawValue)"
                    + " apps=\(apps().count) cached=\(catalog != nil)"
            )
            catalog?.refreshIfStale()
        }
    }

    /// A fresh model per summon: the window list is current, the query empty.
    public func show(windows: [WindowFact], workspaces: [LauncherEntry] = [], apps: [LauncherEntry]) {
        let model = LauncherViewModel(windows: windows, workspaces: workspaces, apps: apps, focusWindow: focusWindow)
        model.dismiss = { [weak self] reason in self?.dismiss(reason: reason) }
        self.model = model
        // PF-01: icons come from the catalog's cache; never a bundle icon
        // lookup per row render.
        let view: GioLauncherView
        if let catalog {
            view = GioLauncherView(model: model, icon: { catalog.icon(for: $0) })
        } else {
            view = GioLauncherView(model: model)
        }
        let hosting = NSHostingController(rootView: view)
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
        let final = NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let plan = LauncherLifecycle.appearPlan(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let token = lifecycle.beginShow(at: now())
        // Unanchored while it slides; the end state re-anchors the top edge.
        panel.alphaValue = 0
        panel.setFrame(final.offsetBy(dx: 0, dy: plan.offset), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        focusSearchField(in: panel)
        GioLog.record(
            .info,
            "launcher shown frame=\(Int(final.minX)),\(Int(final.minY)),\(Int(final.width))x\(Int(final.height))"
                + " key=\(panel.isKeyWindow) active=\(NSApplication.shared.isActive) level=\(panel.level.rawValue)"
        )
        NSAnimationContext.runAnimationGroup { context in
            context.duration = plan.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            if plan.offset != 0 {
                panel.animateFrame(to: final)
            }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.settleAppear(token, top: top) }
        }
        // The completion may never run (interrupted, window hidden): the end
        // state is applied again once the animation must be over.
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.safetyDeadline) { [weak self] in
            MainActor.assumeIsolated { self?.settleAppear(token, top: top) }
        }
    }

    public func dismiss(reason: LauncherDismissReason) {
        guard let panel, panel.isVisible, let token = lifecycle.beginDismiss() else {
            return
        }
        GioLog.record(.info, "launcher dismissed reason=\(reason.rawValue)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.completeDismiss(token) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.completeDismiss(token) }
        }
    }

    public func windowDidResignKey(_ notification: Notification) {
        switch lifecycle.resignDecision(now: now()) {
        case .ignore:
            return
        case .dismiss:
            dismiss(reason: .resignKey)
        case .reclaimKey:
            GioLog.record(.info, "launcher resignKey within grace; reclaiming key")
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, self.lifecycle.isPresented,
                          panel.isVisible, !panel.isKeyWindow
                    else {
                        return
                    }
                    panel.makeKey()
                    self.focusSearchField(in: panel)
                    GioLog.record(.info, "launcher reclaimed key=\(panel.isKeyWindow)")
                }
            }
        }
    }

    /// Alpha 1 and the final, top-anchored frame for the current show only.
    private func settleAppear(_ token: Int, top: CGFloat) {
        guard let panel, lifecycle.finishAppear(token) else {
            return
        }
        if panel.alphaValue < 1 {
            panel.alphaValue = 1
        }
        if panel.anchoredTop != top {
            panel.anchoredTop = top
            panel.setFrame(panel.frame, display: true)
        }
    }

    private func completeDismiss(_ token: Int) {
        guard let panel, lifecycle.finishDismiss(token) else {
            return
        }
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    /// SwiftUI's `@FocusState` only lands when the window is already key;
    /// make the field first responder directly after taking key.
    private func focusSearchField(in panel: NSPanel) {
        guard let root = panel.contentView, let field = firstTextField(in: root) else {
            return
        }
        panel.makeFirstResponder(field)
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) {
                return field
            }
        }
        return nil
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
        // Above app windows, the overlays (.normal + 1) and the focus ring
        // (.floating); below menus, so the status menu still opens over it.
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        return panel
    }
}
