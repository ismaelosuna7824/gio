import AppKit
import GioCore
import SwiftUI

// MARK: - View

/// WO-01: every workspace of the display as a row; each row is the strip
/// to scale (the screen's viewport framed), windows as live thumbnails once
/// captured, app icons until then. Hover selects, click goes there.
struct WorkspaceOverviewView: View {
    @ObservedObject var model: WorkspaceOverviewModel
    let accent: ThemeColor
    /// Menu bar and Dock: the panel covers the whole screen, the content
    /// stays inside the usable area.
    let insets: EdgeInsets

    private static let rowSpacing: CGFloat = 18
    private static let labelWidth: CGFloat = 150
    private static let headerHeight: CGFloat = 44

    var body: some View {
        let palette = AccentPalette(accent: accent, colorScheme: .dark)
        ZStack {
            VisualEffectBackground(material: .fullScreenUI)
                .overlay(Color.black.opacity(0.3))
                .contentShape(Rectangle())
                .onTapGesture { model.dismiss?(.background) }
            GeometryReader { proxy in
                let rowHeight = overviewRowHeight(
                    rows: model.rows.count,
                    available: proxy.size.height - Self.headerHeight - GioSpacing.m,
                    spacing: Self.rowSpacing, minimum: 110, maximum: proxy.size.height * 0.42
                )
                let canvasWidth = proxy.size.width - Self.labelWidth - GioSpacing.xl
                VStack(alignment: .leading, spacing: GioSpacing.m) {
                    header.frame(height: Self.headerHeight)
                    ScrollViewReader { scroller in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                                ForEach(model.rows) { row in
                                    OverviewRowView(
                                        row: row, model: model, palette: palette,
                                        height: rowHeight, maxCanvasWidth: canvasWidth, labelWidth: Self.labelWidth
                                    )
                                    .id(row.index)
                                }
                            }
                        }
                        .onAppear { scroller.scrollTo(model.selection.workspace, anchor: .center) }
                        .onChange(of: model.selection.workspace) { workspace in
                            withAnimation(.easeOut(duration: 0.18)) { scroller.scrollTo(workspace) }
                        }
                    }
                }
            }
            .padding(insets)
            .padding(.horizontal, 56)
            .padding(.vertical, GioSpacing.xxl)
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Workspaces")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Text("←→↑↓ select   ⏎ go   1–9 workspace   esc close")
                .font(GioFont.callout)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// One workspace: its label, then the strip with the viewport framed.
private struct OverviewRowView: View {
    let row: WorkspaceOverviewRow
    @ObservedObject var model: WorkspaceOverviewModel
    let palette: AccentPalette
    let height: CGFloat
    let maxCanvasWidth: CGFloat
    let labelWidth: CGFloat

    var body: some View {
        // A strip wider than the screen shrinks to fit instead of scrolling.
        let aspect = max(row.miniature.aspectRatio, 0.1)
        let canvasHeight = min(height, maxCanvasWidth / aspect)
        let canvas = CGSize(width: canvasHeight * aspect, height: canvasHeight)
        let rowSelected = model.selection.workspace == row.index
        HStack(alignment: .center, spacing: GioSpacing.xl) {
            label(selected: rowSelected)
                .frame(width: labelWidth, alignment: .leading)
            ZStack(alignment: .topLeading) {
                viewport(in: canvas, selected: rowSelected && model.selection.windowID == nil)
                ForEach(row.miniature.tiles) { tile in
                    OverviewTileView(
                        tile: tile, rect: scaled(tile.rect, canvas).insetBy(dx: 3, dy: 3),
                        title: model.title(of: tile.id), thumbnail: model.thumbnails[tile.id],
                        isSelected: model.selection == OverviewSelection(workspace: row.index, windowID: tile.id),
                        palette: palette
                    )
                    .onHover { inside in
                        if inside {
                            model.hover(OverviewSelection(workspace: row.index, windowID: tile.id))
                        }
                    }
                    .onTapGesture { model.pick(OverviewSelection(workspace: row.index, windowID: tile.id)) }
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .frame(height: height)
    }

    private func label(selected: Bool) -> some View {
        let count = row.miniature.tiles.count
        return VStack(alignment: .leading, spacing: GioSpacing.xxs) {
            HStack(spacing: GioSpacing.xs) {
                WorkspaceGlyph(icon: row.icon, color: row.color, size: 26, fallback: "\(row.index)")
                Text(row.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.85))
                    .lineLimit(2)
            }
            Text(count == 0 ? "Empty" : count == 1 ? "1 window" : "\(count) windows")
                .font(GioFont.caption)
                .foregroundStyle(.white.opacity(0.55))
            if row.isActive {
                Text("Current")
                    .font(GioFont.captionEmphasis)
                    .foregroundStyle(palette.fill)
            }
        }
    }

    /// The screen: what this workspace shows when it is the display's.
    /// Clicking it (outside any window) goes to the workspace.
    private func viewport(in canvas: CGSize, selected: Bool) -> some View {
        let rect = scaled(row.miniature.viewport, canvas)
        let shape = RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
        return shape
            .fill(Color.white.opacity(0.06))
            .overlay(
                shape.strokeBorder(
                    selected || row.isActive ? palette.fill : Color.white.opacity(0.22),
                    lineWidth: selected ? 3 : 1.25
                )
            )
            .frame(width: rect.width, height: rect.height)
            .contentShape(shape)
            .onHover { inside in
                if inside, row.miniature.tiles.isEmpty {
                    model.hover(OverviewSelection(workspace: row.index, windowID: nil))
                }
            }
            .onTapGesture { model.pick(OverviewSelection(workspace: row.index, windowID: nil)) }
            .offset(x: rect.minX, y: rect.minY)
    }

    private func scaled(_ unit: CGRect, _ size: CGSize) -> CGRect {
        CGRect(
            x: unit.minX * size.width, y: unit.minY * size.height,
            width: unit.width * size.width, height: unit.height * size.height
        )
    }
}

/// A window: its thumbnail (or app icon on the app's tint), a caption with
/// the app icon and title when there is room, the accent when selected.
private struct OverviewTileView: View {
    let tile: MiniatureTile
    let rect: CGRect
    let title: String?
    let thumbnail: OverviewThumbnail?
    let isSelected: Bool
    let palette: AccentPalette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GioRadius.small, style: .continuous)
        let size = CGSize(width: max(rect.width, 1), height: max(rect.height, 1))
        content(size)
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(alignment: .bottomLeading) { caption(size) }
            .overlay(
                shape.strokeBorder(
                    isSelected ? palette.fill : Color.white.opacity(0.14), lineWidth: isSelected ? 3 : 1
                )
            )
            .shadow(color: .black.opacity(0.4), radius: isSelected ? 12 : 4, y: 2)
            .opacity(tile.isParked && !isSelected ? 0.7 : 1)
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title.map { "\(tile.application), \($0)" } ?? tile.application)
            .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        if let thumbnail {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
        } else {
            ZStack {
                GioColor.tint(appTint(tile.application)).opacity(0.25)
                AppIconView(
                    windowID: tile.id, application: tile.application,
                    size: max(12, min(56, size.width * 0.35, size.height * 0.35))
                )
            }
        }
    }

    @ViewBuilder
    private func caption(_ size: CGSize) -> some View {
        if size.width >= 90, size.height >= 56 {
            HStack(spacing: 6) {
                AppIconView(windowID: tile.id, application: tile.application, size: 16)
                Text(title ?? tile.application)
                    .font(GioFont.captionEmphasis)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(6)
            .frame(maxWidth: size.width, alignment: .leading)
        }
    }
}

// MARK: - Panel

/// Full-screen borderless panel that takes key without activating Gio and
/// routes the overview's keys to the model (everything else passes on).
final class WorkspaceOverviewPanel: NSPanel {
    var keyHandler: ((OverviewKey) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let key = overviewKey(event), keyHandler?(key) == true {
            return
        }
        super.sendEvent(event)
    }

    /// Arrows or H/J/K/L step, Return picks, Escape closes, 1-9 go to that
    /// workspace. Combos with Command, Option or Control are not ours.
    private func overviewKey(_ event: NSEvent) -> OverviewKey? {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }
        switch event.keyCode {
        case 123, 4: return .step(.left)
        case 124, 37: return .step(.right)
        case 126, 40: return .step(.up)
        case 125, 38: return .step(.down)
        case 36, 76: return .enter
        case 53: return .escape
        default:
            if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                return .digit(digit)
            }
            return nil
        }
    }
}

/// Owns the overview panel. A toggle loads the display's stack from the
/// session (queue hop), shows the panel on that display, then asks for the
/// thumbnails; they land in the model while it is up. Presentation follows
/// the launcher's lifecycle (generation tokens, resign-key grace).
@MainActor
public final class WorkspaceOverviewController: NSObject, NSWindowDelegate {
    public typealias Load = (@escaping @Sendable (WorkspaceOverviewFacts?) -> Void) -> Void
    public typealias Capture = ([String], @escaping @Sendable ([String: OverviewThumbnail]) -> Void) -> Void

    private let load: Load
    private let snapshot: () -> SessionSnapshot
    private let capture: Capture
    private let focusWindow: (String) -> Bool
    private let focusWorkspace: (Int) -> Void
    private let now: () -> TimeInterval
    private var panel: WorkspaceOverviewPanel?
    private var lifecycle = LauncherLifecycle()
    private var loading = false
    private weak var model: WorkspaceOverviewModel?

    /// `load` and `capture` complete on the main thread.
    public init(
        load: @escaping Load, snapshot: @escaping () -> SessionSnapshot, capture: @escaping Capture,
        focusWindow: @escaping (String) -> Bool, focusWorkspace: @escaping (Int) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.load = load
        self.snapshot = snapshot
        self.capture = capture
        self.focusWindow = focusWindow
        self.focusWorkspace = focusWorkspace
        self.now = now
        super.init()
    }

    public var isVisible: Bool {
        lifecycle.toggle(panelVisible: panel?.isVisible ?? false) == .dismiss
    }

    /// Show when hidden, dismiss when presented; a toggle while the stack
    /// is still loading is dropped.
    public func toggle() {
        if isVisible {
            dismiss(reason: .toggle)
            return
        }
        guard !loading else {
            return
        }
        loading = true
        let requested = now()
        load { [weak self] facts in
            MainActor.assumeIsolated {
                self?.loaded(facts, requestedAt: requested)
            }
        }
    }

    private func loaded(_ facts: WorkspaceOverviewFacts?, requestedAt: TimeInterval) {
        loading = false
        guard let facts else {
            GioLog.record(.info, "overview unavailable: no focused display")
            return
        }
        let session = snapshot()
        let stack = session.facts?.displays.first { $0.id == facts.displayID }?.stack ?? []
        let titles = Dictionary(
            (session.facts?.windows ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }
        )
        let model = WorkspaceOverviewModel(
            facts: facts, stack: stack, titles: titles, focusWindow: focusWindow, focusWorkspace: focusWorkspace
        )
        model.dismiss = { [weak self] reason in self?.dismiss(reason: reason) }
        self.model = model
        show(model, accent: session.config.focusRing.resolvedColor(), displayID: facts.displayID)
        let ids = model.windowIDs
        GioLog.record(
            .info,
            "overview shown workspaces=\(facts.strips.count) windows=\(ids.count)"
                + " ms=\(Int(((now() - requestedAt) * 1000).rounded()))"
        )
        guard !ids.isEmpty else {
            return
        }
        capture(ids) { [weak model] thumbnails in
            MainActor.assumeIsolated {
                model?.setThumbnails(thumbnails)
            }
        }
    }

    private func show(_ model: WorkspaceOverviewModel, accent: ThemeColor, displayID: UInt32) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = screen?.visibleFrame ?? frame
        let insets = EdgeInsets(
            top: frame.maxY - visible.maxY, leading: visible.minX - frame.minX,
            bottom: visible.minY - frame.minY, trailing: frame.maxX - visible.maxX
        )
        let hosting = NSHostingController(rootView: WorkspaceOverviewView(model: model, accent: accent, insets: insets))
        // The panel keeps the screen's frame; the view never resizes it.
        hosting.sizingOptions = []
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.keyHandler = { [weak model] key in model?.handle(key) ?? false }
        panel.contentViewController = hosting
        panel.setFrame(frame, display: false)
        let token = lifecycle.beginShow(at: now())
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.settleAppear(token) }
        }
        // The completion may never run (interrupted, window hidden).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.settleAppear(token) }
        }
    }

    public func dismiss(reason: OverviewDismissReason) {
        guard let panel, panel.isVisible, let token = lifecycle.beginDismiss() else {
            return
        }
        GioLog.record(.info, "overview dismissed reason=\(reason.rawValue)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
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
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, self.lifecycle.isPresented,
                          panel.isVisible, !panel.isKeyWindow
                    else {
                        return
                    }
                    panel.makeKey()
                }
            }
        }
    }

    private func settleAppear(_ token: Int) {
        guard let panel, lifecycle.finishAppear(token), panel.alphaValue < 1 else {
            return
        }
        panel.alphaValue = 1
    }

    private func completeDismiss(_ token: Int) {
        guard let panel, lifecycle.finishDismiss(token) else {
            return
        }
        panel.orderOut(nil)
        panel.contentViewController = nil
    }

    private func makePanel() -> WorkspaceOverviewPanel {
        let panel = WorkspaceOverviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Same level as the launcher: above app windows, the overlays and the
        // focus ring; below menus.
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        return panel
    }
}
