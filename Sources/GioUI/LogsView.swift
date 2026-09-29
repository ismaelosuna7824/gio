import GioCore
import SwiftUI

/// Live tail of `~/.config/gio/gio.log` with a severity filter and text
/// search. "Clear view" only hides what is already in the file.
struct LogsView: View {
    @State private var filter = LogFilter()
    @State private var entries: [LogEntry] = []
    @State private var autoScroll = true
    @State private var clearedOffset: UInt64 = 0
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let displayLimit = 1000

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
                Button("Clear view") {
                    clearedOffset = logFileSize()
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
                                .textSelection(.enabled)
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
        .onReceive(ticker) { _ in reload() }
    }

    private func reload() {
        entries = readLogEntries(fromOffset: clearedOffset)
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
