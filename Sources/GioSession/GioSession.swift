import GioCore

/// `GioSession`: the live session's components (publication, render
/// verification, scheduling and system seams) extracted from `SessionHost`
/// so they can be unit tested. Components run on the session queue only.
public enum GioSessionModule {
    public static let name = "GioSession"
}
