import GioCore
import GioMacOS
import SwiftUI

/// Session health, permission, displays and the managed window list.
/// Refreshes from the host snapshot while visible.
struct OverviewView: View {
    @ObservedObject var model: DesktopModel
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview").font(.title2)
            if let facts = model.snapshot.facts {
                content(makeOverview(facts))
            } else {
                Text("Waiting for the session…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.refresh() }
        .onReceive(ticker) { _ in model.refresh() }
    }

    @ViewBuilder
    private func content(_ overview: Overview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                statusRow("Session", "Running", ok: true)
                HStack {
                    statusRow(
                        "Accessibility", overview.accessibilityGranted ? "Granted" : "Missing",
                        ok: overview.accessibilityGranted
                    )
                    if !overview.accessibilityGranted {
                        Button("Request Access") {
                            _ = requestAXPermission()
                            model.refresh()
                        }
                    }
                }
                statusRow("Config", overview.configSummary, ok: overview.configIssues.isEmpty)
                ForEach(Array(overview.configIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                ForEach(overview.displayLines, id: \.self) { Text($0).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !overview.accessibilityGranted {
            Text("Without Accessibility access Gio cannot move windows or hear shortcuts.")
                .font(.callout).foregroundStyle(.secondary)
        }
        Text("Windows").font(.headline)
        Text(overview.windowSummary).font(.callout).foregroundStyle(.secondary)
        List(overview.windows) { row in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.application).font(.body)
                    Text(row.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(row.workspace.map { "Workspace \($0)" } ?? "No workspace")
                    .font(.callout).foregroundStyle(.secondary)
                Text(row.state.label)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
            }
        }
    }

    private func statusRow(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title).font(.headline)
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
