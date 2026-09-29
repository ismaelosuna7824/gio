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

public struct GioLauncherView: View {
    var dismiss: () -> Void = {}
    private let focusWindow: (String) -> Bool
    @State private var text = ""
    @State private var status = "Type to search apps and windows, `> ` for Gio commands, `! ` for shell."
    @State private var apps: [LauncherEntry]
    @State private var windows: [LauncherEntry]

    /// `windows` are the session's managed windows at summon time and
    /// `focusWindow` asks the session to focus one by its `pid:elementID`.
    public init(
        windows: [WindowFact] = [],
        focusWindow: @escaping (String) -> Bool = { _ in false },
        apps: [LauncherEntry]? = nil,
        dismiss: @escaping () -> Void = {}
    ) {
        self.dismiss = dismiss
        self.focusWindow = focusWindow
        _apps = State(initialValue: apps ?? scanApplications(directories: defaultApplicationDirectories()))
        _windows = State(initialValue: launcherWindowEntries(from: windows))
    }

    private var entries: [LauncherEntry] { windows + apps }

    private var matches: [LauncherEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return Array(entries.prefix(8))
        }
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("!") {
            return []
        }
        return Array(searchLauncherEntries(trimmed, in: entries).prefix(8))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("> vscode · > workspace 2 · !ls", text: $text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
            List(matches, id: \.listID) { entry in
                HStack {
                    Image(systemName: entry.symbol).frame(width: 18).foregroundStyle(.secondary)
                    Text(entry.title).lineLimit(1)
                    Spacer()
                    Text(entry.kindLabel).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { run(entry) }
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
        switch routeLauncherInput(text, apps: entries) {
        case .empty:
            dismiss()
        case .runEntry(let entry):
            run(entry)
        case .noMatch:
            status = "no match"
        case .invalid(let message):
            status = message
        }
    }

    private func run(_ entry: LauncherEntry) {
        status = runLauncherEntry(entry, focusWindow: focusWindow)
        switch entry {
        case .app, .window:
            dismiss()
        default:
            break
        }
    }
}
