import AppKit
import GioCore
import GioMacOS
import SwiftUI

/// DD-04 Diagnostics: a health checklist (Permissions, Session,
/// Configuration, Displays, Renderer, Logging) and the maintenance actions
/// in a bottom toolbar; outcomes appear as toasts.
struct DiagnosticsView: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.updateController) private var updates

    var body: some View {
        DiagnosticsPage(
            facts: model.snapshot.facts,
            config: model.snapshot.config,
            updates: updates,
            actions: DiagnosticsActions(
                reloadConfig: { model.reloadConfig() },
                restoreAllWindows: { model.restoreAllWindows(completion: $0) },
                testSnapshotCapture: { model.testSnapshotCapture(completion: $0) },
                requestAccessibility: {
                    _ = requestAXPermission()
                    model.refresh()
                },
                requestScreenRecording: {
                    _ = requestScreenRecordingPermission()
                    model.markScreenRecordingRequested()
                    model.refresh()
                },
                createReport: { createIssueReport($0, completion: $1) }
            )
        )
        .onAppear { model.refresh() }
        .pollWhileVisible(model, every: 3) { model.refresh() }
    }
}

@MainActor
struct DiagnosticsActions {
    var reloadConfig: () -> Void = {}
    var restoreAllWindows: (@escaping @MainActor (Int) -> Void) -> Void = { $0(0) }
    var testSnapshotCapture: (@escaping @MainActor (String) -> Void) -> Void = { $0("") }
    var requestAccessibility: () -> Void = {}
    var requestScreenRecording: () -> Void = {}
    /// DA-08: build the report zip and open the prefilled issue.
    var createReport: (IssueReportRequest, @escaping @MainActor (Result<URL, Error>) -> Void) -> Void = { _, _ in }
}

/// Presentational page; the seeds are for snapshot tests.
struct DiagnosticsPage: View {
    let facts: SessionFacts?
    let config: GioConfig
    /// UP-11: update settings card; nil hides it (snapshots).
    var updates: UpdateController?
    var actions = DiagnosticsActions()
    @State private var toast: ApplyToast?
    @State private var measurement: String?
    @State private var busy = false
    @State private var confirmQuit = false
    @State private var reportDescription = ""
    @State private var reportTitle = ""
    @State private var reportIncludesConfig = false
    @State private var reportBusy = false
    @State private var reportStatus: (kind: StatusKind, text: String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        facts: SessionFacts?, config: GioConfig, updates: UpdateController? = nil,
        actions: DiagnosticsActions = DiagnosticsActions(), toast: ApplyToast? = nil, measurement: String? = nil
    ) {
        self.facts = facts
        self.config = config
        self.updates = updates
        self.actions = actions
        _toast = State(initialValue: toast)
        _measurement = State(initialValue: measurement)
    }

    private var checks: [DiagnosticCheck] {
        guard let facts else {
            return []
        }
        let info = Bundle.main.infoDictionary
        let socket = defaultSocketPath()
        return diagnosticChecklist(
            facts: facts, config: config,
            version: gioVersion,
            build: info?["CFBundleVersion"] as? String,
            socketPath: socket, socketExists: FileManager.default.fileExists(atPath: socket),
            logPath: GioLog.logFilePath
        )
    }

    var body: some View {
        let checks = self.checks
        GioPage("Diagnostics", subtitle: "A health check of permissions, the session and your config.") {
            if !checks.isEmpty {
                overallBadge(checks)
            }
        } content: {
            if checks.isEmpty {
                SectionCard {
                    EmptyStateView(
                        symbol: "hourglass", title: "Waiting for the session",
                        message: "Checks appear as soon as the tiling session reports in."
                    )
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: GioSpacing.m), GridItem(.flexible(), spacing: GioSpacing.m)],
                    alignment: .leading, spacing: GioSpacing.m
                ) {
                    ForEach(checks) { check in
                        DiagnosticCard(check: check, action: cardAction(check))
                    }
                }
            }
            if let measurement, !measurement.isEmpty {
                measurementCard(measurement)
            }
            if let updates {
                UpdateSettingsCard(controller: updates)
            }
            reportCard
            commandCard
            Color.clear.frame(height: 60)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: GioSpacing.s) {
                if let toast {
                    ApplyToastView(toast: toast) { self.toast = nil }
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                toolbar
            }
            .padding(.horizontal, GioSpacing.xl)
            .padding(.bottom, GioSpacing.m)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: toast)
        .task(id: toast) {
            guard let shown = toast, shown.details.isEmpty else {
                return
            }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if toast == shown {
                toast = nil
            }
        }
        .confirmationDialog("Quit Gio?", isPresented: $confirmQuit) {
            Button("Quit Gio", role: .destructive) { NSApplication.shared.terminate(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Gio puts every window back on screen and stops tiling until you open it again.")
        }
    }

    // MARK: Pieces

    private func overallBadge(_ checks: [DiagnosticCheck]) -> some View {
        let errors = checks.filter { $0.status == .error }.count
        let warnings = checks.filter { $0.status == .warning }.count
        return Group {
            if errors > 0 {
                StatusBadge(.error, errors == 1 ? "1 problem" : "\(errors) problems")
            } else if warnings > 0 {
                StatusBadge(.warning, warnings == 1 ? "1 needs attention" : "\(warnings) need attention")
            } else {
                StatusBadge(.ok, "All good")
            }
        }
    }

    private func cardAction(_ check: DiagnosticCheck) -> DiagnosticCardAction? {
        guard check.id == "permissions", let facts else {
            return nil
        }
        if !facts.accessibilityGranted {
            return DiagnosticCardAction(title: "Grant Access…", prominent: true, perform: actions.requestAccessibility)
        }
        if !facts.screenRecordingGranted {
            return DiagnosticCardAction(title: "Request Screen Recording…", prominent: false, perform: actions.requestScreenRecording)
        }
        return nil
    }

    private func measurementCard(_ text: String) -> some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return SectionCard("Snapshot Capture", footer: "Counts and timings from one capture of the visible windows.") {
            GioButton(title: "Copy", systemImage: "doc.on.doc", role: .borderless) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line.isEmpty ? " " : line)
                        .font(index == 0 ? GioFont.mono.weight(.semibold) : GioFont.mono)
                        .foregroundStyle(index == 0 ? GioColor.primaryText : GioColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(GioSpacing.m - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// DA-08: describe the problem; Gio saves a zip with the logs and opens
    /// a prefilled GitHub issue to drag it into.
    private var reportCard: some View {
        let hasDescription = !reportDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let defaultTitle = issueReportDefaultTitle(description: reportDescription)
        return SectionCard(
            "Report a Problem",
            footer: "Gio saves a .zip with your logs and system info, shows it in Finder and opens a new GitHub issue. "
                + "Drag the zip into the issue and press Submit. Logs never contain window titles. "
                + "You need a GitHub account."
        ) {
            CardRow {
                VStack(alignment: .leading, spacing: GioSpacing.xs) {
                    Text("What happened?").font(GioFont.body)
                    GioTextEditor(
                        title: "What happened?", text: $reportDescription,
                        prompt: "What you did, what you expected, and what Gio did instead."
                    )
                }
            }
            CardRow {
                SettingRow("Title", caption: "Optional. Defaults to the first line of the description.") {
                    GioTextField(
                        title: "Title", text: $reportTitle,
                        prompt: defaultTitle.isEmpty ? "Short summary" : defaultTitle, width: 260
                    )
                }
            }
            CardRow {
                ToggleRow(
                    "Include my config file",
                    caption: "Adds config.toml to the zip. It may contain app names and paths.",
                    isOn: $reportIncludesConfig
                )
            }
            CardRow(divider: false) {
                HStack(spacing: GioSpacing.s) {
                    if let reportStatus {
                        Label {
                            Text(reportStatus.text)
                                .font(GioFont.caption)
                                .foregroundStyle(GioColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        } icon: {
                            Image(systemName: reportStatus.kind.symbol).foregroundStyle(reportStatus.kind.color)
                        }
                    }
                    Spacer(minLength: GioSpacing.s)
                    if reportBusy {
                        ProgressView().controlSize(.small)
                    }
                    GioButton(title: "Create Report…", systemImage: "ladybug", role: .prominent) { createReport() }
                        .disabled(!hasDescription || reportBusy)
                        .help("Save a .zip to Downloads and open a new GitHub issue")
                }
            }
        }
    }

    private func createReport() {
        reportBusy = true
        reportStatus = nil
        let request = IssueReportRequest(
            title: reportTitle, description: reportDescription, includeConfig: reportIncludesConfig,
            configPath: facts?.configPath ?? gioConfigPath(), healthLines: issueReportHealthLines(checks)
        )
        actions.createReport(request) { result in
            reportBusy = false
            switch result {
            case .success(let zip):
                reportStatus = (
                    .ok, "Report saved to Downloads as \(zip.lastPathComponent). Drag it into the issue page."
                )
            case .failure(let error):
                reportStatus = (.error, "Could not create the report: \(error.localizedDescription)")
            }
        }
    }

    /// SB-01: the app binary is the `gio` CLI; link it into ~/.local/bin.
    private var commandCard: some View {
        let target = cliToolTarget(bundlePath: Bundle.main.bundlePath, executablePath: Bundle.main.executablePath)
        let link = cliToolLinkPath(home: NSHomeDirectory())
        return SectionCard(
            "Command Line",
            footer: target == nil
                ? "Open Gio.app to install the gio command; this copy is not an app bundle."
                : "Links ~/.local/bin/gio to this app, which answers as the gio command (gio status, gio workspace 2, gio list-workspaces --json). The link keeps working after updates."
        ) {
            GioButton(title: "Install Command Line Tool", systemImage: "terminal") {
                toast = installGioCommand(target: target)
            }
            .disabled(target == nil)
            .help("Symlink ~/.local/bin/gio to Gio's own executable")
        } content: {
            Text("\(link) → \(target ?? "Gio.app/Contents/MacOS/Gio")")
                .font(GioFont.mono)
                .foregroundStyle(GioColor.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(GioSpacing.m - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolbar: some View {
        HStack(spacing: GioSpacing.xs) {
            GioButton(title: "Reload Config", systemImage: "arrow.clockwise") {
                actions.reloadConfig()
                toast = ApplyToast(kind: .success, title: "Config reloaded", details: [])
            }
            .help("Re-read config.toml (same as gio reload)")
            GioButton(title: "Restore All Windows", systemImage: "macwindow.on.rectangle") {
                busy = true
                actions.restoreAllWindows { moved in
                    busy = false
                    toast = ApplyToast(
                        kind: .success,
                        title: "Moved \(moved) window\(moved == 1 ? "" : "s") back on screen", details: []
                    )
                }
            }
            .help("Bring parked windows back on screen. Tiling stays on; the next layout change parks off-screen columns again.")
            if showsSnapshotCaptureTest(config: config, screenRecording: facts?.screenRecordingGranted ?? false) {
                GioButton(title: "Test Snapshot Capture", systemImage: "camera.viewfinder") {
                    busy = true
                    actions.testSnapshotCapture { line in
                        busy = false
                        measurement = line
                        toast = ApplyToast(kind: .success, title: "Capture finished", details: [])
                    }
                }
                .help("Capture the visible windows once and show counts and timings")
            }
            GioButton(title: "Open Config File", systemImage: "doc.text") { openConfigFileInEditor() }
            Spacer(minLength: GioSpacing.s)
            if busy {
                ProgressView().controlSize(.small)
            }
            GioButton(title: "Quit Gio…") { confirmQuit = true }
                .help("Restore every window and quit")
        }
        .disabled(busy)
        .padding(.horizontal, GioSpacing.s)
        .padding(.vertical, GioSpacing.s - 2)
        .frame(maxWidth: 760)
        .background(
            RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.large, style: .continuous)
                .strokeBorder(GioColor.hairline.opacity(0.7), lineWidth: 0.5)
        )
    }
}

struct DiagnosticCardAction {
    let title: String
    let prominent: Bool
    let perform: () -> Void
}

private struct DiagnosticCard: View {
    let check: DiagnosticCheck
    let action: DiagnosticCardAction?

    var body: some View {
        VStack(alignment: .leading, spacing: GioSpacing.s - 2) {
            HStack(spacing: GioSpacing.s - 2) {
                SectionIcon(symbol: check.symbol, tint: check.tint, size: 26)
                Text(check.title).font(GioFont.headline)
                Spacer(minLength: GioSpacing.xs)
                StatusBadge(check.status, check.badge)
            }
            Text(check.summary)
                .font(GioFont.callout)
                .foregroundStyle(GioColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !check.details.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(check.details, id: \.self) { line in
                        Text(line)
                            .font(GioFont.mono)
                            .foregroundStyle(GioColor.tertiaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let action {
                GioButton(title: action.title, role: action.prominent ? .prominent : .normal, action: action.perform)
            }
        }
        .padding(GioSpacing.m - 2)
        .frame(maxWidth: .infinity, minHeight: 132, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous).fill(GioColor.card))
        .overlay(
            RoundedRectangle(cornerRadius: GioRadius.medium, style: .continuous)
                .strokeBorder(
                    check.status == .error ? GioColor.error.opacity(0.45) : GioColor.hairline.opacity(0.6),
                    lineWidth: check.status == .error ? 1 : 0.5
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(check.title): \(check.badge)")
    }
}

/// Link ~/.local/bin/gio to the running app (`installCLITool`): replaces an
/// older Gio link, never a regular file.
@MainActor
func installGioCommand(target: String?) -> ApplyToast {
    let home = NSHomeDirectory()
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let pathHint = localBinOnPath(path, home: home)
        ? []
        : ["If gio is not found, add ~/.local/bin to PATH in your shell profile: export PATH=\"$HOME/.local/bin:$PATH\""]
    switch installCLITool(target: target, home: home, fileSystem: LiveCLIToolFileSystem()) {
    case .installed(let link, _, let replaced):
        GioLog.record(.info, "cli installed link=\(link) replaced=\(replaced != nil)")
        return ApplyToast(kind: .success, title: "Installed gio at ~/.local/bin/gio", details: pathHint)
    case .alreadyInstalled:
        return ApplyToast(kind: .success, title: "gio is already installed at ~/.local/bin/gio", details: pathHint)
    case .refused(let reason):
        return ApplyToast(kind: .failure, title: "Could not install gio", details: [reason])
    case .failed(let message):
        return ApplyToast(kind: .failure, title: "Could not install gio", details: [message])
    }
}
