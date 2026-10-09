import CoreGraphics
import Foundation
import GioCore

/// DD-03 follow-up: the preset widths Alt+R cycles through, edited as chips
/// ("33%", "800 pt") instead of raw text. Config keeps the same numbers:
/// values up to 1 are fractions of the screen, larger ones points.

/// How a chip reads: "33%" for a fraction, "800 pt" for points.
public func presetWidthLabel(_ value: Double) -> String {
    value <= 1 ? "\(Int((value * 100).rounded()))%" : "\(Int(value.rounded())) pt"
}

/// The chips of a preset list; empty when the text does not parse.
public func presetWidthValues(_ text: String) -> [Double] {
    parsePresetList(text) ?? []
}

/// Config text for chips, spelled as `LayoutSettingsForm` spells numbers.
public func presetWidthsText(_ values: [Double]) -> String {
    values.map { $0 == $0.rounded() ? String(Int($0)) : "\($0)" }.joined(separator: ", ")
}

/// NC-08: which preset list a chip row edits; the chips and the editor are
/// shared, only the words change.
public enum PresetAxis: Sendable {
    case width, height

    /// "width" / "height", for titles and help texts.
    public var noun: String {
        switch self {
        case .width: return "width"
        case .height: return "height"
        }
    }

    /// The editor's caption for a resolved value (a fraction or points).
    public func caption(_ resolved: Double) -> String {
        switch self {
        case .width:
            return resolved <= 1 ? "\(presetWidthLabel(resolved)) of the screen width" : "A fixed \(presetWidthLabel(resolved)) wide"
        case .height:
            return resolved <= 1 ? "\(presetWidthLabel(resolved)) of the screen height" : "A fixed \(presetWidthLabel(resolved)) tall"
        }
    }
}

public enum PresetWidthUnit: String, CaseIterable, Sendable {
    case percent, points

    public var title: String {
        switch self {
        case .percent: return "Percent"
        case .points: return "Points"
        }
    }

    public var suffix: String {
        switch self {
        case .percent: return "%"
        case .points: return "pt"
        }
    }
}

/// The chip editor: an amount typed in a unit. Percent maps to a fraction
/// (up to 5 decimals, so 33.333% stays 0.33333), points stay points.
public struct PresetWidthEditorValue: Equatable, Sendable {
    public var amount: String
    public var unit: PresetWidthUnit

    public init(amount: String, unit: PresetWidthUnit) {
        self.amount = amount
        self.unit = unit
    }

    /// Seed from an existing chip, or 50% for a new one.
    public init(value: Double?) {
        guard let value else {
            self.init(amount: "50", unit: .percent)
            return
        }
        if value <= 1 {
            self.init(amount: Self.trimmed((value * 100 * 1000).rounded() / 1000), unit: .percent)
        } else {
            self.init(amount: Self.trimmed(value), unit: .points)
        }
    }

    private static func trimmed(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : "\(number)"
    }

    private var number: Double? {
        var text = amount.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in ["%", "pt"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let number = Double(text), number.isFinite else {
            return nil
        }
        return number
    }

    /// The config number, or nil while the amount is not valid.
    public var resolved: Double? {
        guard let number else {
            return nil
        }
        switch unit {
        case .percent:
            guard number > 0, number <= 100 else {
                return nil
            }
            return (number / 100 * 100_000).rounded() / 100_000
        case .points:
            return number > 1 ? number : nil
        }
    }

    public var problem: String? {
        guard resolved == nil else {
            return nil
        }
        switch unit {
        case .percent: return "Must be above 0 and at most 100%."
        case .points: return "Must be more than 1 pt."
        }
    }
}

/// Ruler label rows: a label closer than `minimumSpacing` to the previous
/// label in the top row drops to the second row (0 = top, 1 = below), so
/// "50%" and "800 pt" never print over each other.
public func rulerLabelLanes(_ positions: [CGFloat], minimumSpacing: CGFloat) -> [Int] {
    var lanes = Array(repeating: 0, count: positions.count)
    var lastInLane: [CGFloat?] = [nil, nil]
    for index in positions.indices.sorted(by: { positions[$0] < positions[$1] }) {
        let x = positions[index]
        let lane = lastInLane[0].map { x - $0 < minimumSpacing } == true ? 1 : 0
        if lane == 1, let previous = lastInLane[1], x - previous < minimumSpacing {
            lanes[index] = 0
            lastInLane[0] = x
            continue
        }
        lanes[index] = lane
        lastInLane[lane] = x
    }
    return lanes
}
