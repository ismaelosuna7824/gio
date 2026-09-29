import CoreGraphics
import Foundation

/// Pure form models behind the Settings views: values in, validation
/// problems and `ConfigEdit`s out. Views own no rules of their own.

public func parsePresetList(_ text: String) -> [Double]? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    var numbers: [Double] = []
    for part in parts {
        guard let number = Double(part), number > 0, number.isFinite else {
            return nil
        }
        numbers.append(number)
    }
    return numbers.isEmpty ? nil : numbers
}

public struct LayoutSettingsForm: Equatable, Sendable {
    public enum WidthKind: String, CaseIterable, Sendable {
        case fraction, points
    }

    public var gaps: Double
    public var padding: Double
    public var widthKind: WidthKind
    public var widthValue: Double
    public var presetsText: String
    public var centerFocusedColumn: CenterFocusedColumnMode

    public init(config: LayoutSectionConfig) {
        gaps = Double(config.gaps)
        padding = Double(config.padding)
        if let points = config.defaultColumnWidthPoints {
            widthKind = .points
            widthValue = Double(points)
        } else {
            widthKind = .fraction
            widthValue = Double(config.defaultColumnWidthFraction ?? 0.5)
        }
        presetsText = config.presetColumnWidths.compactMap { spec -> String? in
            switch spec {
            case .proportion(let value), .points(let value):
                return Self.text(Double(value))
            case .standard:
                return nil
            }
        }.joined(separator: ", ")
        centerFocusedColumn = config.centerFocusedColumn
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : "\(value)"
    }

    public var problems: [String] {
        var found: [String] = []
        if !(gaps >= 0 && gaps.isFinite) { found.append("Gaps must be zero or more.") }
        if !(padding >= 0 && padding.isFinite) { found.append("Padding must be zero or more.") }
        switch widthKind {
        case .fraction:
            if !(widthValue > 0 && widthValue <= 1) {
                found.append("Default width as a fraction must be above 0 and at most 1.")
            }
        case .points:
            if !(widthValue > 1 && widthValue.isFinite) {
                found.append("Default width in points must be above 1.")
            }
        }
        if parsePresetList(presetsText) == nil {
            found.append("Preset widths must be a comma-separated list of positive numbers.")
        }
        return found
    }

    public var edits: [ConfigEdit] {
        [
            .set(table: "layout", key: "gaps", value: .number(gaps)),
            .set(table: "layout", key: "padding", value: .number(padding)),
            .set(table: "layout", key: "default-column-width", value: .number(widthValue)),
            .set(table: "layout", key: "center-focused-column", value: .string(centerFocusedColumn.rawValue)),
            .set(
                table: "layout", key: "preset-column-widths",
                value: .numbers(parsePresetList(presetsText) ?? [])
            ),
        ]
    }
}

public func animationEdits(enabled: Bool, durationMilliseconds: Int) -> [ConfigEdit] {
    [
        .set(table: "animations", key: "enabled", value: .bool(enabled)),
        .set(table: "animations", key: "duration-ms", value: .int(durationMilliseconds)),
    ]
}

public func behaviorEdits(focusFollowsMouse: Bool, mouseFollowsFocus: Bool) -> [ConfigEdit] {
    [
        .set(table: "behavior", key: "focus-follows-mouse", value: .bool(focusFollowsMouse)),
        .set(table: "behavior", key: "mouse-follows-focus", value: .bool(mouseFollowsFocus)),
    ]
}

/// Editable window rule. `mode`/`workspace` nil mean "no opinion".
public struct RuleForm: Equatable, Sendable {
    public var app: String
    public var mode: WindowMode?
    public var workspace: Int?

    public init(app: String = "", mode: WindowMode? = nil, workspace: Int? = nil) {
        self.app = app
        self.mode = mode
        self.workspace = workspace
    }

    public init(rule: WindowRule) {
        self.init(app: rule.app, mode: rule.mode, workspace: rule.workspace)
    }

    public var problems: [String] {
        var found: [String] = []
        let trimmed = app.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { found.append("App name is required.") }
        if trimmed.contains("\"") { found.append("App name cannot contain a double quote.") }
        if let workspace, !WorkspaceManager.range.contains(workspace) {
            found.append("Workspace must be 1 to 9.")
        }
        return found
    }

    public var rule: WindowRule {
        WindowRule(app: app.trimmingCharacters(in: .whitespaces), mode: mode, workspace: workspace)
    }
}
