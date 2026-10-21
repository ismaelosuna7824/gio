import AppKit
import GioCore
import SwiftUI

// FX-06: a short on-screen notice for an action Gio refused (today: a switch
// to dwindle with more windows than `[dwindle] max-windows`), so a key that
// changes nothing is not mistaken for a dead shortcut. Main thread only. One
// small click-through, non-activating panel, made on first use and reused;
// it fades in, stays `holdSeconds`, fades out and leaves the screen. Nothing
// runs while no notice is up.

/// What the notice says.
public struct GioNotice: Equatable, Sendable {
    public var symbol: String
    public var title: String
    public var detail: String

    public init(symbol: String, title: String, detail: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

/// The notice for a refused switch to dwindle.
public func dwindleRefusalNotice(_ refusal: DwindleRefusal) -> GioNotice {
    GioNotice(
        symbol: "rectangle.split.2x2",
        title: "Too many windows for dwindle",
        detail: "This workspace has \(refusal.windows); dwindle holds up to \(refusal.maximum). "
            + "Change it in Settings > Layout."
    )
}

/// Where the notice sits: centred, 14% up the display's visible frame (like
/// the system volume HUD), never outside it.
public func noticeFrame(size: CGSize, in visible: CGRect) -> CGRect {
    let width = min(size.width, visible.width)
    let height = min(size.height, visible.height)
    let y = min(visible.minY + visible.height * 0.14, visible.maxY - height)
    return CGRect(x: visible.midX - width / 2, y: y, width: width, height: height)
}

private final class NoticeWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct NoticeView: View {
    let notice: GioNotice

    var body: some View {
        HStack(spacing: GioSpacing.m) {
            Image(systemName: notice.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(GioFont.headline)
                Text(notice.detail).font(GioFont.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, GioSpacing.l)
        .padding(.vertical, GioSpacing.m)
        .frame(width: NoticePanelController.width, alignment: .leading)
        .background(
            VisualEffectBackground(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous))
        )
        .environment(\.colorScheme, .dark)
    }
}

@MainActor
public final class NoticePanelController {
    static let width: CGFloat = 400
    private static let holdSeconds: TimeInterval = 2.2
    private var panel: NoticeWindow?
    /// Bumped by every `show`: a fade or hide from an older notice never
    /// takes a newer one down.
    private var generation = 0

    public init() {}

    /// Shows `notice` on the display whose visible frame (Cocoa global
    /// coordinates) is `visible`; a notice already up is replaced.
    public func show(_ notice: GioNotice, on visible: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        generation += 1
        let shown = generation
        let host = NSHostingView(rootView: NoticeView(notice: notice))
        panel.contentView = host
        panel.setFrame(noticeFrame(size: host.fittingSize, in: visible), display: false)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds) { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeOut(shown)
            }
        }
    }

    private func fadeOut(_ shown: Int) {
        guard let panel, shown == generation else {
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, shown == self.generation else {
                    return
                }
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    private func makePanel() -> NoticeWindow {
        let panel = NoticeWindow(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        return panel
    }
}
