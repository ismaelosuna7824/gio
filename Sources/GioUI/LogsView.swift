import AppKit
import GioCore
import SwiftUI

/// DD-04 Logs: live tail of `~/.config/gio/gio.log` as a readable list —
/// level pills, relative times (absolute on hover), repeated lines grouped
/// ×N, level chips, search, pause and auto-scroll. The file is read
/// incrementally (only new bytes) and only while this section is on screen
/// in a visible window; pausing stops reading until resumed.
struct LogsView: View {
    @ObservedObject var model: DesktopModel
    @State private var filter = LogLevelFilter()
    @State private var tail = LogTail()
    @State private var entries: [LogEntry]
    @State private var autoScroll = true
    @State private var paused: Bool
    @State private var now: Date
    @State private var ticks = 0
    @State private var toast: ApplyToast?
    private let isSeeded: Bool
    private let displayLimit = 500

    /// `seed`, `now` and `paused` are for snapshot tests (no file reads).
    init(
        model: DesktopModel, seed: [LogEntry]? = nil, now: Date? = nil, paused: Bool = false,
        filter: LogLevelFilter = LogLevelFilter(), toast: ApplyToast? = nil
    ) {
        self.model = model
        isSeeded = seed != nil
        _entries = State(initialValue: seed ?? [])
        _now = State(initialValue: now ?? Date())
        _paused = State(initialValue: paused)
        _filter = State(initialValue: filter)
        _toast = State(initialValue: toast)
    }

    var body: some View {
        let visible = Array(filter.apply(to: entries).suffix(displayLimit))
        let groups = groupLogEntries(visible)
        let counts = logLevelCounts(entries)
        GioPage("Logs", subtitle: "Events, counts and timings from gio.log. Never window titles.", scrolls: false) {
            HStack(spacing: GioSpacing.xs) {
                fileLevelPicker
                Divider().frame(height: 16)
                GioButton(title: "Copy Visible", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logCopyText(groups), forType: .string)
                }
                .disabled(groups.isEmpty)
                .help("Copy the lines shown below")
                GioButton(title: "Reveal Log File", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: GioLog.logFilePath)])
                }
                .help(GioLog.logFilePath)
            }
            // The subtitle wraps before a button label truncates.
            .fixedSize()
        } content: {
            VStack(alignment: .leading, spacing: GioSpacing.s) {
                HStack(spacing: GioSpacing.s) {
                    GioSearchField(prompt: "Filter messages", text: $filter.search, large: false)
                        .frame(maxWidth: 260)
                    Text("Show")
                        .font(GioFont.callout)
                        .foregroundStyle(GioColor.secondaryText)
                        .help("Filters this view only; the Log file level decides what gio.log records")
                    levelChips(counts)
                    Spacer(minLength: 0)
                }
                logList(groups)
                footer(lines: visible.count, groups: groups.count)
            }
        }
        .applyToastOverlay($toast)
        .onAppear { reload() }
        .pollWhileVisible(model, every: 1) { reload() }
    }

    // MARK: Pieces

    /// DA-07: `[logging] level`, written through config.toml and reloaded
    /// live. Lives here because this page is the tail of the file it tunes.
    private var fileLevelPicker: some View {
        let current = model.snapshot.config.logging.level
        return HStack(spacing: GioSpacing.xxs) {
            Text("Log file level")
                .font(GioFont.callout)
                .foregroundStyle(GioColor.secondaryText)
            GioPopup(
                title: "Log file level",
                selection: Binding(
                    get: { current },
                    set: { chosen in
                        let edits = logFileLevelEdits(current: current, chosen: chosen)
                        guard !edits.isEmpty else {
                            return
                        }
                        toast = logFileLevelToast(model.apply(edits), level: chosen)
                    }
                ),
                options: logFileLevelOptions.map { ($0.level, $0.title) },
                width: 100
            )
        }
        .fixedSize()
        .help("The lowest severity Gio writes to gio.log ([logging] level). Debug and Trace add detail for troubleshooting.")
    }

    private func levelChips(_ counts: [LogLevel: Int]) -> some View {
        HStack(spacing: GioSpacing.xs - 2) {
            ForEach(LogLevel.allCases.reversed(), id: \.self) { level in
                FilterChip(
                    title: logLevelTitle(level), count: counts[level] ?? 0, dot: LogLevelStyle(level).dot,
                    isSelected: filter.levels.contains(level)
                ) { filter.toggle(level) }
            }
        }
        .fixedSize()
    }

    private func logList(_ groups: [LogGroup]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: GioSpacing.s) {
                GioButton(
                    title: paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill", role: .borderless
                ) { paused.toggle() }
                .help(paused ? "Resume reading new lines" : "Stop reading new lines for now")
                Toggle(isOn: $autoScroll) {
                    Text("Follow new lines").font(GioFont.callout)
                }
                .toggleStyle(.checkbox)
                .opacity(isStatic ? 0 : 1)
                Spacer(minLength: 0)
                if paused {
                    StatusBadge(.warning, "Paused", symbol: "pause.circle.fill")
                } else {
                    StatusBadge(.ok, "Live", symbol: "dot.radiowaves.left.and.right")
                }
            }
            .padding(.horizontal, GioSpacing.s)
            .frame(height: 36)
            Divider()
            if groups.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: entries.isEmpty ? "No log lines yet" : "No lines match",
                    message: entries.isEmpty
                        ? "New lines appear here as Gio writes them."
                        : "Turn on more levels or change the filter."
                )
                .frame(maxHeight: .infinity)
            } else if isStatic {
                VStack(spacing: 0) { rows(groups) }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) { rows(groups) }
                    }
                    .onChange(of: groups.last?.id) { _ in scrollToEnd(proxy, groups) }
                    .onChange(of: groups.last?.count) { _ in scrollToEnd(proxy, groups) }
                    .onAppear { scrollToEnd(proxy, groups) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous))
    }

    @Environment(\.gioStaticPage) private var isStatic

    @ViewBuilder
    private func rows(_ groups: [LogGroup]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            LogRow(group: group, now: now)
                .background(index.isMultiple(of: 2) ? Color.clear : GioColor.well.opacity(0.5))
                .id(group.id)
        }
    }

    private func footer(lines: Int, groups: Int) -> some View {
        let hidden = entries.count - lines
        return Text(
            "\(lines) of \(entries.count) recent lines"
                + (groups < lines ? " · \(lines - groups) repeats grouped" : "")
                + (hidden > 0 ? " · \(hidden) hidden by filters" : "")
        )
        .font(GioFont.caption.monospacedDigit())
        .foregroundStyle(GioColor.secondaryText)
        .padding(.horizontal, GioSpacing.xxs)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ groups: [LogGroup]) {
        guard autoScroll, let last = groups.last else {
            return
        }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    private func reload() {
        guard !isSeeded, !paused else {
            return
        }
        ticks += 1
        let changed = tail.poll()
        if changed {
            entries = tail.entries
        }
        // Relative times move on every 15 s (or with new lines).
        if changed || ticks % 15 == 0 {
            now = Date()
        }
    }
}

func logLevelTitle(_ level: LogLevel) -> String {
    switch level {
    case .error: return "Error"
    case .warn: return "Warning"
    case .info: return "Info"
    case .debug: return "Debug"
    case .trace: return "Trace"
    }
}

/// Semantic color per level.
struct LogLevelStyle {
    let dot: Color
    let fill: Color
    let ink: Color

    init(_ level: LogLevel) {
        switch level {
        case .error:
            dot = GioColor.error; fill = GioColor.error; ink = GioColor.errorInk
        case .warn:
            dot = GioColor.warning; fill = GioColor.warning; ink = GioColor.warningInk
        case .info:
            dot = GioColor.info; fill = GioColor.info; ink = GioColor.infoInk
        case .debug:
            dot = GioColor.neutral; fill = GioColor.neutral; ink = GioColor.secondaryText
        case .trace:
            dot = GioColor.tertiaryText; fill = GioColor.neutral; ink = GioColor.tertiaryText
        }
    }
}

private struct LogRow: View {
    let group: LogGroup
    let now: Date

    var body: some View {
        let style = LogLevelStyle(group.level)
        HStack(alignment: .firstTextBaseline, spacing: GioSpacing.s - 2) {
            Text(group.level.name.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(style.ink)
                .frame(width: 44, height: 16)
                .background(Capsule().fill(style.fill.opacity(0.15)))
            Text(relativeLogTime(group.lastTimestamp, now: now) ?? group.lastTimestamp)
                .font(GioFont.caption.monospacedDigit())
                .foregroundStyle(GioColor.tertiaryText)
                .frame(width: 58, alignment: .leading)
                .help(timeHelp)
            Text(group.message)
                .font(GioFont.mono)
                .foregroundStyle(group.level >= .warn ? style.ink : GioColor.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(group.message)
            if group.count > 1 {
                InlineTag(text: "×\(group.count)")
                    .help("Repeated \(group.count) times in a row")
            }
        }
        .padding(.horizontal, GioSpacing.s)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var timeHelp: String {
        group.count > 1
            ? "\(absoluteLogTime(group.firstTimestamp)) – \(absoluteLogTime(group.lastTimestamp))"
            : absoluteLogTime(group.lastTimestamp)
    }
}
