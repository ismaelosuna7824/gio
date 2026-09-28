import AppKit
import Foundation
import GioCore
import SwiftUI

/// Plan §26 launcher shell: spotlight-style window (type to filter, Enter
/// runs, Esc quits). Executes apps via NSWorkspace, Gio verbs over IPC, and
/// `!` shell lines via zsh — never touching Core state directly. Thin and
/// live-only; matching and routing are tested in LauncherModel.
func runLauncherEntry(_ entry: LauncherEntry) -> String {
    switch entry {
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

struct GioLauncherView: View {
    @State private var text = ""
    @State private var status = "Type to search apps, `> ` for Gio commands, `! ` for shell."
    @State private var apps: [LauncherEntry] = scanApplications(directories: defaultApplicationDirectories())

    private var matches: [LauncherEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return Array(apps.prefix(8))
        }
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("!") {
            return []
        }
        return Array(searchLauncherEntries(trimmed, in: apps).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("> vscode · > workspace 2 · !ls", text: $text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
            List(matches, id: \.title) { entry in
                Text(entry.title)
            }
            .frame(minHeight: 160)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
    }

    private func commit() {
        switch routeLauncherInput(text, apps: apps) {
        case .empty:
            NSApplication.shared.terminate(nil)
        case .runEntry(let entry):
            status = runLauncherEntry(entry)
            if case .app = entry {
                NSApplication.shared.terminate(nil)
            }
        case .noMatch:
            status = "no match"
        case .invalid(let message):
            status = message
        }
    }
}

@main
struct GioLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            GioLauncherView()
        }
    }
}
