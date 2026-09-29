import GioCore
import SwiftUI

/// Searchable reference of every action and its live shortcut(s).
struct ShortcutsView: View {
    @ObservedObject var model: DesktopModel
    @State private var query = ""
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let entries = filterShortcuts(
            shortcutCatalog(configKeybindings: model.snapshot.keybindings), query: query
        )
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts").font(.title2)
            TextField("Search actions, keys or config names", text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(ShortcutCategory.allCases, id: \.self) { category in
                    let rows = entries.filter { $0.category == category }
                    if !rows.isEmpty {
                        Section(category.title) {
                            ForEach(rows) { ShortcutRow(entry: $0) }
                        }
                    }
                }
            }
            if entries.isEmpty {
                Text("No action matches \"\(query)\".").foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { model.refresh() }
        .onReceive(ticker) { _ in model.refresh() }
    }
}

private struct ShortcutRow: View {
    let entry: ShortcutEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body)
                Text(entry.summary).font(.callout).foregroundStyle(.secondary)
                if let configName = entry.configName {
                    Text(configName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if entry.bindings.isEmpty {
                    Text("unbound").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(entry.bindings.enumerated()), id: \.offset) { _, binding in
                    HStack(spacing: 4) {
                        if binding.source == .config {
                            Text("config").font(.caption2).foregroundStyle(.orange)
                        }
                        ForEach(Array(keycaps(for: binding.combo).enumerated()), id: \.offset) { _, key in
                            Text(key)
                                .font(.system(.callout, design: .rounded).weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
