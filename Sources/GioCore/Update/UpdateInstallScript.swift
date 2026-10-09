import Foundation

/// UP-05: Gio cannot replace its own bundle while it runs. It stages the
/// verified app next to the installed one, starts this helper detached,
/// and quits through the normal path (windows restored, guardian told
/// `clean`). The helper waits for Gio and its guardian to exit, swaps the
/// bundles, checks the swapped app's signature again (UP-12), rolls back
/// on any failure, clears quarantine and reopens Gio.

private func sibling(of target: String, named name: String) -> String {
    ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
}

private let stagingPrefix = ".gio-update-"

/// `mkdtemp` template for the private (0700) folder that holds the staged
/// `Gio.app`: same folder (same volume) as the target, hidden, a fresh name
/// every time, so nothing planted beforehand is ever reused (UP-12).
public func updateStagingTemplate(target: String) -> String {
    sibling(of: target, named: stagingPrefix + "XXXXXX")
}

/// `mktemp -d` template for the private folder the helper moves the
/// installed app into while it swaps (UP-12).
public func updateAsideTemplate(target: String) -> String {
    sibling(of: target, named: ".gio-previous-XXXXXX")
}

/// The private staging folder of a staged app (`<folder>/.gio-update-<suffix>/Gio.app`),
/// or nil when the path was not staged that way.
public func updateStagingDirectory(ofStagedApp staged: String) -> String? {
    let app = staged as NSString
    guard app.lastPathComponent == "Gio.app" else {
        return nil
    }
    let folder = app.deletingLastPathComponent
    let name = (folder as NSString).lastPathComponent
    guard name.hasPrefix(stagingPrefix), name.count > stagingPrefix.count else {
        return nil
    }
    return folder
}

public struct UpdateInstallPlan: Equatable, Sendable {
    public var target: String
    /// `<stagingDirectory>/Gio.app`, verified by the preparer.
    public var staged: String
    /// The private folder holding `staged`; removed with `rmdir` only.
    public var stagingDirectory: String
    /// Code requirement the swapped app must satisfy (`codesign -R`).
    public var requirement: String
    /// Gio and its guardian; the swap starts after both exited.
    public var waitPIDs: [Int32]
    public var logPath: String
    public var relaunch: Bool
    /// Give up (and touch nothing) when a pid is still alive after this.
    public var waitSeconds: Int

    public init(
        target: String, staged: String, stagingDirectory: String, requirement: String, waitPIDs: [Int32],
        logPath: String, relaunch: Bool = true, waitSeconds: Int = 60
    ) {
        self.target = target
        self.staged = staged
        self.stagingDirectory = stagingDirectory
        self.requirement = requirement
        self.waitPIDs = waitPIDs
        self.logPath = logPath
        self.relaunch = relaunch
        self.waitSeconds = waitSeconds
    }
}

public func updateInstallScript(_ plan: UpdateInstallPlan) -> String {
    let pids = plan.waitPIDs.map(String.init).joined(separator: " ")
    let ticks = max(plan.waitSeconds, 1) * 10
    let relaunch = plan.relaunch ? "open \"$TARGET\" --args \(relaunchArgument)\n" : ""
    let reopenOld = plan.relaunch ? "  open \"$TARGET\" --args \(relaunchArgument)\n" : ""
    return """
    #!/bin/sh
    # Gio update helper (generated; deletes itself). Logs paths and steps only.
    TARGET=\(shellQuoted(plan.target))
    STAGED=\(shellQuoted(plan.staged))
    STAGE_DIR=\(shellQuoted(plan.stagingDirectory))
    ASIDE_TEMPLATE=\(shellQuoted(updateAsideTemplate(target: plan.target)))
    REQ=\(shellQuoted(plan.requirement))
    LOG=\(shellQuoted(plan.logPath))
    mkdir -p "$(dirname "$LOG")"
    log() { printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG"; }
    discard() { rm -rf "$STAGED"; rmdir "$STAGE_DIR" 2>/dev/null; }
    rm -f "$0"
    log "helper started target=$TARGET"
    for pid in \(pids); do
      n=0
      while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [ "$n" -ge \(ticks) ]; then
          log "pid $pid still running after \(plan.waitSeconds)s; update abandoned, nothing changed"
          discard
          exit 1
        fi
        sleep 0.1
      done
    done
    log "gio exited; swapping bundles"
    if ! ASIDE_DIR="$(mktemp -d "$ASIDE_TEMPLATE")"; then
      log "could not create a private folder for the installed app; nothing changed"
      discard
    \(reopenOld)  exit 1
    fi
    ASIDE="$ASIDE_DIR/Gio.app"
    if ! mv "$TARGET" "$ASIDE"; then
      log "could not move the installed app aside; nothing changed"
      rmdir "$ASIDE_DIR"
      discard
    \(reopenOld)  exit 1
    fi
    if ! mv "$STAGED" "$TARGET"; then
      log "could not put the new app in place; restoring the previous version"
      if [ -e "$TARGET" ] || ! mv "$ASIDE" "$TARGET"; then
        log "restore failed; previous app left in ASIDE_DIR=$ASIDE_DIR"
      fi
      rmdir "$ASIDE_DIR" 2>/dev/null
      discard
    \(reopenOld)  exit 1
    fi
    if ! /usr/bin/codesign --verify --strict --deep "-R=$REQ" "$TARGET" 2>/dev/null; then
      log "the new app failed its signature check after the swap; restoring the previous version"
      rm -rf "$TARGET"
      if [ -e "$TARGET" ] || ! mv "$ASIDE" "$TARGET"; then
        log "restore failed; previous app left in ASIDE_DIR=$ASIDE_DIR"
      fi
      rmdir "$ASIDE_DIR" 2>/dev/null
      discard
    \(reopenOld)  exit 1
    fi
    xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    rm -rf "$ASIDE_DIR"
    rmdir "$STAGE_DIR" 2>/dev/null
    log "installed; relaunching"
    \(relaunch)exit 0

    """
}
