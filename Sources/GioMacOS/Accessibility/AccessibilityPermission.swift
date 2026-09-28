import ApplicationServices
import Foundation

/// Read-only permission check. Never prompts.
public func hasAXPermission() -> Bool {
    AXIsProcessTrusted()
}

/// Permission check that asks macOS to show the accessibility dialog when
/// missing. Unlike a bare `AXIsProcessTrusted`, this actually brings the
/// prompt: command-line tools never get it otherwise. Returns the post-call
/// trust state — the user may still need to approve and retry.
@discardableResult
public func requestAXPermission() -> Bool {
    if AXIsProcessTrusted() {
        return true
    }
    // Literal key instead of kAXTrustedCheckOptionPrompt: the CF global is a
    // shared mutable var, which Swift 6 rejects. Documented value below.
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}
