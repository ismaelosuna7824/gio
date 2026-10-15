import AppKit
import GioCore
import SwiftUI

private struct UpdateControllerKey: EnvironmentKey {
    static let defaultValue: UpdateController? = nil
}

extension EnvironmentValues {
    /// UP-11: the app's updater; nil in previews and snapshot tests.
    var updateController: UpdateController? {
        get { self[UpdateControllerKey.self] }
        set { self[UpdateControllerKey.self] = newValue }
    }
}

/// UP-11 Overview card: current version, status, Check Now, Update and
/// Restart with progress, and the release notes.
struct UpdatesCard: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        let row = controller.presentation
        SectionCard("Updates") {
            CardRow(divider: false) {
                VStack(alignment: .leading, spacing: GioSpacing.xs) {
                    HStack(spacing: GioSpacing.s) {
                        SectionIcon(symbol: "arrow.down.circle.fill", tint: .teal, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.status).font(GioFont.body)
                            Text(row.detail ?? lastCheckCaption)
                                .font(GioFont.caption)
                                .foregroundStyle(row.kind == .error ? GioColor.errorInk : GioColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: GioSpacing.xs)
                        if controller.state.isBusy, row.progress == nil {
                            ProgressView().controlSize(.small)
                        }
                        if row.showsNotes {
                            Button("Release Notes…") { controller.notesPresented = true }
                                .controlSize(.small)
                        }
                        actionButton(row)
                    }
                    if let progress = row.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }

    private var lastCheckCaption: String {
        guard let lastCheck = controller.lastCheck else {
            return controller.automaticChecks ? "Gio checks GitHub for new versions once a day." : "Automatic checks are off."
        }
        return "Last checked " + lastCheck.formatted(.relative(presentation: .named)) + "."
    }

    @ViewBuilder
    private func actionButton(_ row: UpdateRowPresentation) -> some View {
        switch row.action {
        case .checkNow?:
            Button("Check Now") { controller.checkNow() }
                .controlSize(.small)
        case .updateAndRestart?:
            Button("Update and Restart") { controller.startUpdate() }
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.small)
        case .openReleasePage(let page)?:
            Button("Open Release Page") { openReleasePage(page) }
                .controlSize(.small)
        case nil:
            EmptyView()
        }
    }
}

@MainActor
func openReleasePage(_ page: String) {
    if let url = URL(string: page) {
        NSWorkspace.shared.open(url)
    }
}

/// UP-11 Diagnostics card: the automatic check and beta toggles and the
/// optional GitHub token. The token is write-only: the field starts empty
/// and Gio only says whether one is saved.
struct UpdateSettingsCard: View {
    @ObservedObject var controller: UpdateController
    @State private var tokenDraft = ""
    @State private var tokenMessage: String?

    var body: some View {
        SectionCard(
            "Updates",
            footer: "Gio \(controller.runningVersion). Updates come from GitHub releases, are checked against the published checksum and must be signed by the same developer as this copy."
        ) {
            EmptyView()
        } content: {
            CardRow {
                toggleRow(
                    title: "Automatically check for updates",
                    caption: "About 30 seconds after launch and then once a day, when macOS schedules it.",
                    isOn: $controller.automaticChecks
                )
            }
            CardRow {
                toggleRow(
                    title: "Include beta versions",
                    caption: "Offer prereleases too. A beta build always follows betas.",
                    isOn: $controller.includeBetas
                )
            }
            CardRow(divider: false) {
                VStack(alignment: .leading, spacing: GioSpacing.xs) {
                    Text("GitHub token (only for private repositories)").font(GioFont.body)
                    Text(controller.hasToken
                        ? "A token is saved in your Keychain."
                        : "No token saved. Public releases need none.")
                        .font(GioFont.caption)
                        .foregroundStyle(GioColor.secondaryText)
                    HStack(spacing: GioSpacing.xs) {
                        SecureField(controller.hasToken ? "Replace token" : "Paste a token with read access", text: $tokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                        Button("Save") {
                            tokenMessage = controller.saveToken(tokenDraft) ? "Saved in the Keychain." : "Could not save the token."
                            tokenDraft = ""
                        }
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Clear") {
                            controller.clearToken()
                            tokenDraft = ""
                            tokenMessage = "Token removed."
                        }
                        .disabled(!controller.hasToken)
                    }
                    .controlSize(.small)
                    if let tokenMessage {
                        Text(tokenMessage)
                            .font(GioFont.caption)
                            .foregroundStyle(GioColor.secondaryText)
                    }
                }
            }
        }
    }

    private func toggleRow(title: String, caption: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: GioSpacing.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(GioFont.body)
                Text(caption)
                    .font(GioFont.caption)
                    .foregroundStyle(GioColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: GioSpacing.xs)
            GioSwitch(title: title, isOn: isOn)
        }
    }
}

/// UP-11: the release body, rendered simply (headings, bullets, inline
/// markdown), with Update and Restart.
struct ReleaseNotesSheet: View {
    @ObservedObject var controller: UpdateController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let update = controller.state.update
        let row = controller.presentation
        VStack(alignment: .leading, spacing: GioSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(update.map { "Gio \($0.version)" } ?? "Release Notes").font(GioFont.pageTitle)
                Text(row.status).font(GioFont.callout).foregroundStyle(GioColor.secondaryText)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: GioSpacing.xs) {
                    ForEach(Array(releaseNoteBlocks(update?.notes ?? "").enumerated()), id: \.offset) { _, block in
                        blockView(block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(minHeight: 220)
            if let detail = row.detail, row.kind == .error || row.action != .updateAndRestart {
                Text(detail).font(GioFont.caption).foregroundStyle(GioColor.secondaryText)
            }
            HStack {
                if let page = update?.pageURL {
                    Button("View on GitHub") { openReleasePage(page) }
                }
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if row.action == .updateAndRestart {
                    Button("Update and Restart") {
                        controller.startUpdate()
                        dismiss()
                    }
                    .buttonStyle(BrandProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(GioSpacing.xl)
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNoteBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level <= 1 ? .title3.weight(.semibold) : GioFont.headline)
                .padding(.top, GioSpacing.xs)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: GioSpacing.xs) {
                Text("•")
                inline(text)
            }
            .font(GioFont.body)
        case .paragraph(let text):
            inline(text).font(GioFont.body)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

extension View {
    /// Presents the release notes sheet whenever the updater asks for it.
    @ViewBuilder
    func updateNotesSheet(_ controller: UpdateController?) -> some View {
        if let controller {
            modifier(UpdateNotesSheetHost(controller: controller))
        } else {
            self
        }
    }
}

private struct UpdateNotesSheetHost: ViewModifier {
    @ObservedObject var controller: UpdateController

    func body(content: Content) -> some View {
        content.sheet(isPresented: $controller.notesPresented) {
            ReleaseNotesSheet(controller: controller)
        }
    }
}
