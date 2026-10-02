import AppKit
import Foundation

public final class ManagedSpaceMonitor {
    private let marker: NSWindow
    private var token: NSObjectProtocol?

    public init(onChange: @escaping (Bool) -> Void) {
        marker = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        marker.isOpaque = false
        marker.backgroundColor = .clear
        marker.hasShadow = false
        marker.ignoresMouseEvents = true
        marker.isReleasedWhenClosed = false
        marker.level = .floating
        marker.collectionBehavior = [.ignoresCycle]
        marker.orderFrontRegardless()
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            onChange(self.isManagedActive)
        }
    }

    deinit {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        marker.close()
    }

    public var isManagedActive: Bool {
        marker.isOnActiveSpace
    }
}
