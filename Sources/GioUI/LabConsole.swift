import AppKit
import GioCore
import GioMacOS
import SwiftUI

func labListWindows() -> String {
    do {
        let result = try discoverSystemWindows()
        var lines = ["windows=\(result.windows.count) skipped=\(result.skipped)"]
        lines += result.windows.map { $0.window.describe() }
        return lines.joined(separator: "\n")
    } catch {
        return "list failed: \(error)"
    }
}

func labTileMainDisplay() -> String {
    guard let screen = NSScreen.main,
          screen.visibleFrame.width > 0, screen.visibleFrame.height > 0
    else {
        return "tile failed: no usable main display"
    }
    do {
        return try runTileReflow(
            display: screen.visibleFrame, displayHeight: screen.frame.height
        ).describe()
    } catch {
        return "tile failed: \(error)"
    }
}

public struct GioLabView: View {
    public init() {}
    @State private var trusted = hasAXPermission()
    @State private var log = "Ready. Grant access, then List or Tile.\n"
    @State private var running = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Accessibility: \(trusted ? "granted" : "missing")")
                    .font(.headline)
                Spacer()
                Button("Request Access") {
                    trusted = requestAXPermission()
                    append(trusted ? "access granted" : "still missing — approve in System Settings, then press Refresh")
                }
                Button("Refresh") {
                    trusted = hasAXPermission()
                    append("permission: \(trusted ? "granted" : "missing")")
                }
            }
            HStack {
                Button("List Windows") {
                    run(labListWindows)
                }
                Button("Tile Main Display") {
                    run(labTileMainDisplay)
                }
                Button("Show Log") {
                    let lines = GioLog.entries().suffix(30).map { $0.line() }
                    append(lines.isEmpty ? "(log empty)" : lines.joined(separator: "\n"))
                }
                Button("Clear Log") {
                    log = ""
                }
            }
            .disabled(running)
            ScrollView {
                Text(log)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .border(Color.secondary.opacity(0.3))
        }
        .padding()
        .frame(minWidth: 600, minHeight: 440)
    }

    private func append(_ line: String) {
        log += line + "\n"
    }

    private func run(_ work: @escaping @Sendable () -> String) {
        running = true
        DispatchQueue.global(qos: .userInitiated).async {
            let output = work()
            DispatchQueue.main.async {
                self.log += output + "\n"
                self.trusted = hasAXPermission()
                self.running = false
            }
        }
    }
}
