import AppKit
import GioCore
import SwiftUI

/// Doctor facts and the maintenance actions.
struct DiagnosticsView: View {
    @ObservedObject var model: DesktopModel
    @State private var actionNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.title2)
            if let facts = model.snapshot.facts {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows(for: facts)) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: symbol(row.status)).foregroundStyle(color(row.status))
                                Text(row.title).font(.headline).frame(width: 110, alignment: .leading)
                                Text(row.value).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        ForEach(facts.configMessages, id: \.self) { message in
                            Text(message).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Waiting for the session…").foregroundStyle(.secondary)
            }
            HStack {
                Button("Reload Config") {
                    model.reloadConfig()
                    actionNote = "Config reloaded."
                }
                Button("Restore All Windows") {
                    actionNote = "Restoring windows…"
                    model.restoreAllWindows { moved in
                        actionNote = "Moved \(moved) window\(moved == 1 ? "" : "s") back on screen. "
                            + "Tiling is still on: the next layout change parks off-screen columns again."
                    }
                }
                Button("Open Config File") { openConfigFileInEditor() }
                Spacer()
                Button("Quit Gio", role: .destructive) { NSApplication.shared.terminate(nil) }
            }
            if let actionNote {
                Text(actionNote).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refresh() }
        .pollWhileVisible(model, every: 3) { model.refresh() }
    }

    private func rows(for facts: SessionFacts) -> [DiagnosticRow] {
        let info = Bundle.main.infoDictionary
        let socket = defaultSocketPath()
        return makeDiagnostics(
            facts: facts,
            version: (info?["CFBundleShortVersionString"] as? String) ?? gioVersion,
            build: info?["CFBundleVersion"] as? String,
            socketPath: socket,
            socketExists: FileManager.default.fileExists(atPath: socket),
            logPath: GioLog.logFilePath
        )
    }

    private func symbol(_ status: DiagnosticStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func color(_ status: DiagnosticStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }
}
