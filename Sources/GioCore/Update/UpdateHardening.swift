import Foundation

/// UP-17: the GitHub token only ever goes to the GitHub REST API over
/// HTTPS (default port, no user info). Release-list requests, asset
/// downloads and every redirect obey this; anything else is sent without
/// the token.
public func updateTokenAllowed(for url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.github.com",
          url.user == nil, url.password == nil else {
        return false
    }
    return url.port == nil || url.port == 443
}

/// What a staged entry is, for `stagedEntryDecision` (from `lstat`).
public enum StagedEntryKind: Equatable, Sendable {
    case file
    case directory
    case symlink
}

public enum StagedEntryDecision: Equatable, Sendable {
    case keep
    case setMode(UInt16)
    /// The whole update is refused; the reason names the kind of item only.
    case refuse(String)
}

/// UP-14: the staged copy's metadata is not covered by the code signature,
/// so it is normalised before the second signature check. Same result as
/// `chmod -R u+rwX,go+rX,go-w`: user read/write, everyone read, search bits
/// on directories and on files that were executable, never group/world
/// write. Items owned by another user and setuid/setgid items refuse the
/// update. Symlinks are owner-checked but never chmodded (chmod follows them).
public func stagedEntryDecision(mode: UInt16, owner: UInt32, currentUser: UInt32, kind: StagedEntryKind) -> StagedEntryDecision {
    guard owner == currentUser else {
        return .refuse("an item owned by another user")
    }
    if kind == .symlink {
        return .keep
    }
    let permissions = mode & 0o7777
    guard permissions & 0o6000 == 0 else {
        return .refuse("a setuid or setgid item")
    }
    var normalised = permissions | 0o644
    if kind == .directory || permissions & 0o111 != 0 {
        normalised |= 0o111
    }
    normalised &= ~UInt16(0o022)
    return normalised == permissions ? .keep : .setMode(normalised)
}
