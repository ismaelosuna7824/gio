import Foundation
import GioCore

/// UP-11: pure presentation of the updater for the Overview row, the menu
/// bar and the release notes sheet. Views only draw what these return.
public enum UpdateRowAction: Equatable, Sendable {
    case checkNow
    case updateAndRestart
    /// The copy cannot replace itself: download from the release page.
    case openReleasePage(String)
}

public struct UpdateRowPresentation: Equatable, Sendable {
    public var status: String
    public var detail: String?
    public var kind: StatusKind
    /// 0...1 while downloading.
    public var progress: Double?
    public var action: UpdateRowAction?
    public var showsNotes: Bool
    /// Check Now is offered (not while a step runs or an install is staged).
    public var canCheck: Bool
}

public func updateRowPresentation(
    state: UpdateState, runningVersion: String, eligibility: InstallEligibility
) -> UpdateRowPresentation {
    let canCheck = !state.isBusy && {
        if case .readyToInstall = state {
            return false
        }
        return true
    }()
    let showsNotes = !(state.update?.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    var row = UpdateRowPresentation(
        status: "", detail: nil, kind: .neutral, progress: nil, action: nil, showsNotes: showsNotes, canCheck: canCheck
    )
    /// What installing this update means here.
    func installAction(_ update: AvailableUpdate) -> UpdateRowAction? {
        switch eligibility {
        case .installable: return .updateAndRestart
        case .notifyOnly: return update.pageURL.map(UpdateRowAction.openReleasePage)
        }
    }
    let ineligibleDetail: String? = {
        if case .notifyOnly(let reason) = eligibility {
            return reason.message + " " + reason.suggestion
        }
        return nil
    }()
    switch state {
    case .idle:
        row.status = "Version \(runningVersion)"
        row.action = .checkNow
    case .checking:
        row.status = "Checking for updates…"
        row.kind = .info
    case .upToDate:
        row.status = "Gio \(runningVersion) is up to date"
        row.kind = .ok
        row.action = .checkNow
    case .available(let update):
        row.status = "Gio \(update.version) is available"
        row.detail = ineligibleDetail ?? "You have \(runningVersion)." + (update.isPrerelease ? " This is a beta." : "")
        row.kind = .info
        row.action = installAction(update)
    case .downloading(let update, let progress):
        row.status = "Downloading Gio \(update.version)… \(Int((progress * 100).rounded()))%"
        row.kind = .info
        row.progress = progress
    case .verifying(let update):
        row.status = "Verifying Gio \(update.version)…"
        row.kind = .info
    case .readyToInstall(let update, _):
        row.status = "Gio \(update.version) is ready to install"
        row.kind = .info
        row.action = .updateAndRestart
    case .installing(let update):
        row.status = "Installing Gio \(update.version); Gio will reopen…"
        row.kind = .info
    case .failed(let failure, let update):
        row.kind = .error
        row.detail = failure.message
        if let update {
            row.status = "Updating to \(update.version) failed"
            row.action = installAction(update)
        } else {
            row.status = "Update check failed"
            row.action = .checkNow
        }
    }
    return row
}

/// The menu bar item while an update waits for the user.
public func updateMenuTitle(_ state: UpdateState) -> String? {
    switch state {
    case .available(let update), .readyToInstall(let update, _), .failed(_, let update?):
        return "Update to \(update.version.tag)…"
    default:
        return nil
    }
}

/// Release notes reduced to what the sheet renders: headings, bullets and
/// paragraphs (soft-wrapped lines joined). Inline markdown stays in the
/// text for `AttributedString(markdown:)`.
public enum ReleaseNoteBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(String)
    case paragraph(String)
}

public func releaseNoteBlocks(_ markdown: String) -> [ReleaseNoteBlock] {
    var blocks: [ReleaseNoteBlock] = []
    var paragraph: [String] = []
    func flush() {
        if !paragraph.isEmpty {
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
    }
    for raw in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            flush()
            continue
        }
        let hashes = line.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
            flush()
            blocks.append(.heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
            continue
        }
        if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
            flush()
            blocks.append(.bullet(line.dropFirst(2).trimmingCharacters(in: .whitespaces)))
            continue
        }
        paragraph.append(line)
    }
    flush()
    return blocks
}
