import AppKit
import XCTest
@testable import GioUI

/// Crash 2026-10-07: the launcher's slide-in called the `setFrame` override
/// through the animator proxy, so the override ran with the proxy as `self`
/// and read `anchoredTop` from foreign memory (frame y = 3e59, AppKit
/// assertion, Gio stopped tiling and every hotkey died).
@MainActor
final class LauncherPanelAnimationTests: XCTestCase {
    func testTheSlideInLandsOnTheRequestedFrame() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 120),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.anchoredTop = nil
        let target = NSRect(x: 300, y: 400, width: 640, height: 469)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            panel.animateFrame(to: target)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(panel.frame, target)
    }
}
