import Foundation

/// DD-06: the two motion presets the first-run setup offers at the end and
/// Settings → Animations repeats, so someone who skipped the setup can still
/// find them. Pure: a preset is only the `[animations]` change it writes, so
/// both entry points share one definition.
public enum MotionPreset: String, CaseIterable, Sendable {
    /// Gio's spring motion: the default experience.
    case recommended
    /// Every move is instant — the most fluid feel, with no animations.
    case fast

    /// The preset a config runs with: `animations.enabled` off is Fast.
    public init(animations: AnimationsSectionConfig) {
        self = animations.enabled ? .recommended : .fast
    }
}

/// The config change a preset applies.
public func motionPresetEdits(_ preset: MotionPreset) -> [ConfigEdit] {
    [.set(table: "animations", key: "enabled", value: .bool(preset == .recommended))]
}
