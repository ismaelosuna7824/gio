import AppKit
import GioCore
import SwiftUI

/// Live tail of `~/.config/gio/gio.log` with a severity filter and text
/// search. "Clear view" only hides what is already in the file. The file is
/// read incrementally (only new bytes) and only while this section is on
/// screen in a visible window; rows are capped and not selectable (use
/// "Copy visible").
struct LogsView: View {
    @ObservedObject var model: DesktopModel
    @State private var filter = LogFilter()
    @State private var tail = LogTail()
    @State private var entries: [LogEntry] = []
    @State private var autoScroll = true
    private let displayLimit = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Logs").font(.title2)
            HStack {
                Picker("Level", selection: $filter.minLevel) {
                    ForEach(LogLevel.allCases.reversed(), id: \.self) { level in
                        Text(level.name.capitalized).tag(level)
                    }
                }
                .frame(maxWidth: 180)
                TextField("Search", text: $filter.search).textFieldStyle(.roundedBorder)
                Toggle("Auto-scroll", isOn: $autoScroll)
                Button("Copy visible") {
                    let text = filter.apply(to: entries).suffix(displayLimit).map { $0.line() }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear view") {
                    tail.clear()
                    entries = []
                }
            }
            let shown = Array(filter.apply(to: entries).suffix(displayLimit))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                            Text(entry.line())
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(color(entry.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .border(Color.secondary.opacity(0.3))
                .onChange(of: shown.count) { count in
                    if autoScroll, count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            Text("Showing \(shown.count) of \(entries.count) recent entries.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { reload() }
        .pollWhileVisible(model, every: 1) { reload() }
    }

    private func reload() {
        if tail.poll() {
            entries = tail.entries
        }
    }

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warn: return .orange
        case .info: return .primary
        case .debug, .trace: return .secondary
        }
    }
}
