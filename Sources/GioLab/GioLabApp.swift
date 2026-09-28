import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// GioLab: minimal validation harness for the 0.1-alpha pipeline. NOT the
/// RW-20 menu bar app — a throwaway-window tool so live retests run from
/// Xcode with buttons instead of CLI permission dances. Thin by design:
/// all logic lives in GioMacOS/GioCore; this file only renders state.
@main
struct GioLabApp: App {
    var body: some Scene {
        WindowGroup {
            GioLabView()
        }
    }
}

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
    guard let display = NSScreen.main?.visibleFrame,
          display.width > 0, display.height > 0
    else {
        return "tile failed: no usable main display"
    }
    do {
        return try runTileReflow(display: display).describe()
    } catch {
        return "tile failed: \(error)"
    }
}

struct GioLabView: View {
    @State private var trusted = hasAXPermission()
    @State private var log = "Ready. Grant access, then List or Tile.\n"
    @State private var running = false

    var body: some View {
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
