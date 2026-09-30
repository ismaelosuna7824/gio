import AppKit
import Foundation
import GioCore

/// Plan §25 menu bar, DD-05 design: a template status glyph carrying the
/// active workspace number, and a tidy menu (session header, workspaces
/// with checkmarks, actions, Quit). Actions go through IPC, so the bar never
/// touches windows directly. State is event-driven (PA-02): the session
/// pushes a `BarSessionState` whenever a reflow or command changed it
/// (`apply`), the glyph follows, and the menu is rebuilt from the latest
/// state only when it opens (`menuNeedsUpdate`). No timer, no polling, no
/// IPC round trip for reads.
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var latest: BarSessionState?
    private var shownBadge: String??
    /// Host-provided: the last published state; must never wait on the session queue.
    public var stateProvider: (() -> BarSessionState?)?
    /// Host-provided: summon the launcher window / the main Gio window.
    public var onOpenLauncher: (() -> Void)?
    public var onOpenMain: (() -> Void)?

    public override init() {
        super.init()
    }

    /// Build the status item. Call once from the host (this controller is no
    /// longer an app delegate — nothing calls it back automatically).
    public func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        statusItem.menu = menu
        apply(stateProvider?())
    }

    /// Pushed by the session when its state changed. Cheap: the glyph is
    /// redrawn only when the workspace number changes.
    public func apply(_ state: BarSessionState?) {
        latest = state
        let badge = barBadgeText(state)
        guard let button = statusItem?.button, shownBadge != .some(badge) else {
            return
        }
        shownBadge = .some(badge)
        button.image = statusItemImage(badge: badge)
        button.title = ""
        button.setAccessibilityLabel(badge.map { "Gio, workspace \($0)" } ?? "Gio")
        button.toolTip = barMenuModel(state).subtitle
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        if let fresh = stateProvider?() {
            latest = fresh
        }
        menu.removeAllItems()
        populate(menu, model: barMenuModel(latest), connected: latest != nil)
    }

    private func populate(_ menu: NSMenu, model: BarMenuModel, connected: Bool) {
        menu.addItem(headerItem(model))
        for section in model.sections {
            menu.addItem(.separator())
            menu.addItem(sectionHeader(section.title))
            for row in section.rows {
                let item = NSMenuItem(title: row.title, action: #selector(switchWorkspace(_:)), keyEquivalent: "")
                item.attributedTitle = rowTitle(row)
                item.tag = row.index
                item.target = self
                item.state = row.isChecked ? .on : .off
                item.isEnabled = row.isEnabled
                if row.symbol != nil || row.color != nil {
                    item.image = workspaceMenuImage(symbol: row.symbol, color: row.color, index: row.index)
                }
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Open Gio", symbol: "macwindow", key: ",", modifiers: .command, action: #selector(openMain)))
        menu.addItem(actionItem("Launcher", symbol: "magnifyingglass", key: " ", modifiers: .option, action: #selector(openLauncher)))
        let reload = actionItem("Reload Config", symbol: "arrow.clockwise", key: "r", modifiers: .command, action: #selector(reloadConfig))
        reload.isEnabled = connected
        menu.addItem(reload)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Gio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = menuSymbol("power")
        menu.addItem(quit)
    }

    private func headerItem(_ model: BarMenuModel) -> NSMenuItem {
        let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
        let text = NSMutableAttributedString(
            string: model.title,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)]
        )
        text.append(NSAttributedString(
            string: "\n" + model.subtitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        item.attributedTitle = text
        item.image = statusItemImage(badge: nil)
        item.isEnabled = false
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func rowTitle(_ row: BarMenuRow) -> NSAttributedString {
        let text = NSMutableAttributedString(string: row.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        text.append(NSAttributedString(
            string: "   " + row.detail,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return text
    }

    private func actionItem(
        _ title: String, symbol: String, key: String, modifiers: NSEvent.ModifierFlags, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.image = menuSymbol(symbol)
        return item
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    @objc private func switchWorkspace(_ sender: NSMenuItem) {
        sendAsync(["workspace", "\(sender.tag)"])
    }

    @objc private func reloadConfig() {
        sendAsync(["reload"])
    }

    /// Fire an IPC verb off-main. The session pushes the resulting state.
    private func sendAsync(_ argv: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? sendIPCRequest(argv, socketPath: defaultSocketPath())
        }
    }

    @objc private func openLauncher() {
        onOpenLauncher?()
    }

    @objc private func openMain() {
        onOpenMain?()
    }
}

/// The status glyph: three columns with the focused middle one filled, and
/// the workspace number in a rounded badge beside it. A template image, so
/// the menu bar tints it for light, dark and highlighted states.
public func statusItemImage(badge: String?) -> NSImage {
    let columnsWidth: CGFloat = 19
    let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
    let badgeText = badge.map { NSAttributedString(string: $0, attributes: [.font: badgeFont]) }
    let badgeWidth = badgeText.map { max(ceil($0.size().width) + 7, 13) } ?? 0
    let size = NSSize(width: columnsWidth + (badge == nil ? 0 : 3 + badgeWidth), height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        // Columns: narrow, wide (focused, filled), narrow.
        let top: CGFloat = 13, bottom: CGFloat = 3
        let widths: [CGFloat] = [3.5, 7, 3.5]
        var x: CGFloat = 0.75
        for (index, width) in widths.enumerated() {
            let rect = NSRect(x: x, y: bottom, width: width, height: top - bottom)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2)
            if index == 1 {
                path.fill()
            } else {
                path.lineWidth = 1.2
                path.stroke()
            }
            x += width + 1.5
        }
        if let badgeText {
            let rect = NSRect(x: columnsWidth + 3, y: 2, width: badgeWidth, height: 12)
            NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
            // Knock the number out of the badge.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let textSize = badgeText.size()
            badgeText.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = badge.map { "Gio, workspace \($0)" } ?? "Gio"
    return image
}

/// NW-04: a named workspace's mark for menus: its symbol on a rounded
/// tile of its color (gray without one), like the app's workspace glyph.
public func workspaceMenuImage(symbol: String?, color: String?, index: Int) -> NSImage {
    let theme = color.flatMap(ThemeColor.init(hex:)) ?? ThemeColor(red: 0.56, green: 0.56, blue: 0.58)
    let fill = NSColor(srgbRed: theme.red, green: theme.green, blue: theme.blue, alpha: 1)
    let ink = workspaceGlyphForeground(theme)
    let inkColor = NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: 1)
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { rect in
        fill.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [inkColor]))
        if let symbol, let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let glyphSize = glyph.size
            glyph.draw(in: NSRect(
                x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2,
                width: glyphSize.width, height: glyphSize.height
            ))
        } else {
            let text = NSAttributedString(string: "\(index)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold), .foregroundColor: inkColor,
            ])
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        }
        return true
    }
    image.isTemplate = false
    return image
}

/// Open `~/.config/gio/config.toml` in the default editor, writing the
/// commented template first when it does not exist yet.
public func openConfigFileInEditor() {
    let path = FileManager.default.homeDirectoryForCurrentUser.path + "/.config/gio/config.toml"
    if !FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? defaultConfigTemplate().write(toFile: path, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}
