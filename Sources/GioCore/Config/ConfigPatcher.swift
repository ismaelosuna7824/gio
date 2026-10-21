import Foundation

/// A value the patcher can write. Rendering matches the parser subset:
/// bare numbers/bools, double-quoted strings, flat number lists.
public enum ConfigEditValue: Equatable, Sendable {
    case int(Int)
    case number(Double)
    case bool(Bool)
    case string(String)
    case numbers([Double])
}

/// One text-level change to `config.toml`. Rule indices count only
/// `[[window-rules]]` blocks that have at least one key (the ones the
/// parser turns into rules), in file order; workspace indices count
/// `[[workspace]]` blocks the same way. Edits apply sequentially.
public enum ConfigEdit: Equatable, Sendable {
    case set(table: String, key: String, value: ConfigEditValue)
    case remove(table: String, key: String)
    case addRule(WindowRule)
    case updateRule(index: Int, WindowRule)
    case removeRule(index: Int)
    /// Moves the block (with the comments inside it) to position `to`.
    case moveRule(from: Int, to: Int)
    /// NW-01: new blocks go after the last `[[workspace]]` (or at the end).
    case addWorkspace(WorkspaceDefinition)
    case updateWorkspace(index: Int, WorkspaceDefinition)
    case removeWorkspace(index: Int)
    case moveWorkspace(from: Int, to: Int)
    /// DA-07: point a combo at an action or at `"none"`. The first
    /// `[keybindings]` line whose key parses to the same combo (any
    /// spelling) is rewritten and later duplicates are dropped; otherwise a
    /// quoted line goes after the last binding (the table is created when
    /// missing).
    case setKeybinding(HotkeyCombo, KeybindingTarget)
    /// DA-07: drop every `[keybindings]` line for the combo.
    case removeKeybinding(HotkeyCombo)
}

/// A patched file body that the parser accepts, with what it parses to.
public struct PatchedConfig: Sendable {
    public let text: String
    public let config: GioConfig
    public let warnings: [String]
}

/// Apply `edits` to the config TEXT, keeping every unrelated line, comment
/// and ordering. Missing tables/keys are created (tables at the end of the
/// file). The result is re-parsed: text the parser rejects is never
/// returned, so callers can write it safely.
public func patchGioConfig(_ text: String, edits: [ConfigEdit]) -> Result<PatchedConfig, ConfigErrors> {
    if case .failure(let errors) = parseGioConfig(text) {
        return .failure(errors)
    }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" {
        lines.removeLast()
    }
    for edit in edits {
        if let problem = apply(edit, to: &lines) {
            return .failure(ConfigErrors(messages: [problem]))
        }
    }
    let patched = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    switch parseGioConfig(patched) {
    case .success(let (config, warnings)):
        return .success(PatchedConfig(text: patched, config: config, warnings: warnings))
    case .failure(let errors):
        return .failure(errors)
    }
}

// MARK: - Line model

private struct TableSpan {
    let name: String
    let isArray: Bool
    let header: Int
    /// Exclusive: index of the next header or `lines.count`.
    let end: Int
}

private func headerName(_ line: String) -> (name: String, isArray: Bool)? {
    let stripped = stripComment(line).trimmingCharacters(in: .whitespaces)
    if stripped.hasPrefix("[["), stripped.hasSuffix("]]"), stripped.count >= 4 {
        return (String(stripped.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces), true)
    }
    if stripped.hasPrefix("["), stripped.hasSuffix("]") {
        return (String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces), false)
    }
    return nil
}

private func keyName(_ line: String) -> String? {
    let stripped = stripComment(line).trimmingCharacters(in: .whitespaces)
    guard !stripped.isEmpty, headerName(line) == nil, let equals = stripped.firstIndex(of: "=") else {
        return nil
    }
    return String(stripped[..<equals]).trimmingQuotes()
}

private func isBlank(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces).isEmpty
}

private func spans(of lines: [String]) -> [TableSpan] {
    let headers = lines.enumerated().compactMap { offset, line in
        headerName(line).map { (offset, $0.name, $0.isArray) }
    }
    return headers.enumerated().map { position, header in
        let end = position + 1 < headers.count ? headers[position + 1].0 : lines.count
        return TableSpan(name: header.1, isArray: header.2, header: header.0, end: end)
    }
}

// MARK: - Editing

private func apply(_ edit: ConfigEdit, to lines: inout [String]) -> String? {
    switch edit {
    case .set(let table, let key, let value):
        guard let rendered = render(value) else {
            return "cannot write value for \(table).\(key)"
        }
        setKey(table: table, key: key, rendered: rendered, in: &lines)
        return nil
    case .remove(let table, let key):
        removeKey(table: table, key: key, from: &lines)
        return nil
    case .addRule(let rule):
        guard let block = renderRule(rule) else {
            return "rule app/values contain characters that cannot be written"
        }
        appendBlock(block, to: &lines)
        return nil
    case .updateRule(let index, let rule):
        guard let block = renderRule(rule) else {
            return "rule app/values contain characters that cannot be written"
        }
        guard let range = ruleBlockRange(index, in: lines) else {
            return "rule \(index) does not exist"
        }
        lines.replaceSubrange(range, with: block)
        return nil
    case .removeRule(let index):
        return removeBlock(arrayTable: "window-rules", index: index, noun: "rule", from: &lines)
    case .moveRule(let from, let to):
        return moveBlock(arrayTable: "window-rules", from: from, to: to, noun: "rule", in: &lines)
    case .addWorkspace(let definition):
        guard let block = renderWorkspace(definition) else {
            return "workspace values contain characters that cannot be written"
        }
        let existing = arrayBlockRanges("workspace", in: lines)
        if let last = existing.last {
            insertBlock(block, at: last.upperBound, in: &lines)
        } else {
            appendBlock(block, to: &lines)
        }
        return nil
    case .updateWorkspace(let index, let definition):
        guard let block = renderWorkspace(definition) else {
            return "workspace values contain characters that cannot be written"
        }
        let ranges = arrayBlockRanges("workspace", in: lines)
        guard ranges.indices.contains(index) else {
            return "workspace \(index) does not exist"
        }
        lines.replaceSubrange(ranges[index], with: block)
        return nil
    case .removeWorkspace(let index):
        return removeBlock(arrayTable: "workspace", index: index, noun: "workspace", from: &lines)
    case .moveWorkspace(let from, let to):
        return moveBlock(arrayTable: "workspace", from: from, to: to, noun: "workspace", in: &lines)
    case .setKeybinding(let combo, let target):
        guard let rendered = quoted(keybindingValue(target)), let key = quoted(combo.describe()) else {
            return "cannot write key binding \(combo.describe())"
        }
        setKeybinding(combo, key: key, rendered: rendered, in: &lines)
        return nil
    case .removeKeybinding(let combo):
        let doomed = keybindingLines(combo, in: lines)
        for index in doomed.reversed() {
            lines.remove(at: index)
        }
        return nil
    }
}

private func removeBlock(arrayTable: String, index: Int, noun: String, from lines: inout [String]) -> String? {
    let ranges = arrayBlockRanges(arrayTable, in: lines)
    guard ranges.indices.contains(index) else {
        return "\(noun) \(index) does not exist"
    }
    let range = ranges[index]
    lines.removeSubrange(range)
    let at = range.lowerBound
    if at > 0, isBlank(lines[at - 1]), at == lines.count || isBlank(lines[at]) {
        lines.remove(at: at - 1)
    }
    return nil
}

/// Cut the block out, then put it before the block now at `to` (or after
/// the last one when `to` is the last position).
private func moveBlock(arrayTable: String, from: Int, to: Int, noun: String, in lines: inout [String]) -> String? {
    let ranges = arrayBlockRanges(arrayTable, in: lines)
    guard ranges.indices.contains(from), ranges.indices.contains(to) else {
        return "cannot move \(noun) \(from) to \(to)"
    }
    guard from != to else {
        return nil
    }
    let block = Array(lines[ranges[from]])
    _ = removeBlock(arrayTable: arrayTable, index: from, noun: noun, from: &lines)
    let remaining = arrayBlockRanges(arrayTable, in: lines)
    if to < remaining.count {
        lines.insert(contentsOf: block + [""], at: remaining[to].lowerBound)
    } else {
        insertBlock(block, at: remaining[remaining.count - 1].upperBound, in: &lines)
    }
    return nil
}

private func setKey(table: String, key: String, rendered: String, in lines: inout [String]) {
    let tables = spans(of: lines).filter { !$0.isArray && $0.name == table }
    for span in tables.reversed() {
        for index in stride(from: span.end - 1, to: span.header, by: -1) where keyName(lines[index]) == key {
            lines[index] = rewrite(lines[index], key: key, rendered: rendered)
            return
        }
    }
    if let span = tables.last {
        var insertAt = span.header + 1
        for index in (span.header + 1)..<span.end where keyName(lines[index]) != nil {
            insertAt = index + 1
        }
        lines.insert("\(key) = \(rendered)", at: insertAt)
        return
    }
    let block = ["[\(table)]", "\(key) = \(rendered)"]
    if let at = familyEnd(of: table, in: lines) {
        insertBlock(block, at: at, in: &lines)
        return
    }
    appendBlock(block, to: &lines)
}

/// Lines of `[keybindings]` tables whose key parses to `combo`, in order.
private func keybindingLines(_ combo: HotkeyCombo, in lines: [String]) -> [Int] {
    spans(of: lines).filter { !$0.isArray && $0.name == "keybindings" }.flatMap { span in
        ((span.header + 1)..<span.end).filter { index in
            keyName(lines[index]).flatMap(parseHotkey) == combo
        }
    }
}

private func setKeybinding(_ combo: HotkeyCombo, key: String, rendered: String, in lines: inout [String]) {
    let matches = keybindingLines(combo, in: lines)
    if let first = matches.first {
        lines[first] = rewrite(lines[first], key: key, rendered: rendered)
        for index in matches.dropFirst().reversed() {
            lines.remove(at: index)
        }
        return
    }
    let tables = spans(of: lines).filter { !$0.isArray && $0.name == "keybindings" }
    if let span = tables.last {
        var insertAt = span.header + 1
        for index in (span.header + 1)..<span.end where keyName(lines[index]) != nil {
            insertAt = index + 1
        }
        lines.insert("\(key) = \(rendered)", at: insertAt)
        return
    }
    appendBlock(["[keybindings]", "\(key) = \(rendered)"], to: &lines)
}

private func keybindingValue(_ target: KeybindingTarget) -> String {
    switch target {
    case .action(let action): return configActionName(action)
    case .none: return unbindActionName
    }
}

/// NA-04: a dotted table (`animations.window-open`) goes right after its
/// family (`[animations]` and its other sub-tables), before trailing blank
/// lines; nil when the family is absent.
private func familyEnd(of table: String, in lines: [String]) -> Int? {
    guard let dot = table.firstIndex(of: ".") else {
        return nil
    }
    let parent = String(table[..<dot])
    guard let last = spans(of: lines).last(where: {
        !$0.isArray && ($0.name == parent || $0.name.hasPrefix(parent + "."))
    }) else {
        return nil
    }
    var end = last.end
    while end > last.header + 1, isBlank(lines[end - 1]) {
        end -= 1
    }
    return end
}

/// A block with one blank line on each side (none added where one is).
private func insertBlock(_ block: [String], at index: Int, in lines: inout [String]) {
    var framed = [""] + block
    if index < lines.count, !isBlank(lines[index]) {
        framed.append("")
    }
    lines.insert(contentsOf: framed, at: index)
}

/// Same indentation and inline comment, new value.
private func rewrite(_ line: String, key: String, rendered: String) -> String {
    let code = stripComment(line)
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    let comment = String(line.dropFirst(code.count))
    let keyText = code.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        .first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? key
    return indent + keyText + " = " + rendered + (comment.isEmpty ? "" : "  " + comment)
}

private func removeKey(table: String, key: String, from lines: inout [String]) {
    let tables = spans(of: lines).filter { !$0.isArray && $0.name == table }
    var doomed: [Int] = []
    for span in tables {
        for index in (span.header + 1)..<span.end where keyName(lines[index]) == key {
            doomed.append(index)
        }
    }
    for index in doomed.reversed() {
        lines.remove(at: index)
    }
    if table.contains(".") {
        dropEmptyTables(named: table, from: &lines)
    }
}

/// NA-04: a dotted table left without keys or comments goes away (its
/// header and blank body; the blank line before it stays as the separator),
/// so resetting to "inherit" leaves no clutter.
private func dropEmptyTables(named table: String, from lines: inout [String]) {
    for span in spans(of: lines).reversed() where !span.isArray && span.name == table {
        guard ((span.header + 1)..<span.end).allSatisfy({ isBlank(lines[$0]) }) else {
            continue
        }
        lines.removeSubrange(span.header..<span.end)
    }
    while let last = lines.last, isBlank(last) {
        lines.removeLast()
    }
}

private func appendBlock(_ block: [String], to lines: inout [String]) {
    if let last = lines.last, !isBlank(last) {
        lines.append("")
    }
    lines.append(contentsOf: block)
}

private func ruleBlockRange(_ index: Int, in lines: [String]) -> Range<Int>? {
    let ranges = arrayBlockRanges("window-rules", in: lines)
    return ranges.indices.contains(index) ? ranges[index] : nil
}

/// Each `[[name]]` block with at least one key, from its header through its
/// last key line: trailing blank lines and comments belong to whatever
/// follows.
private func arrayBlockRanges(_ name: String, in lines: [String]) -> [Range<Int>] {
    spans(of: lines).compactMap { span in
        guard span.isArray, span.name == name else {
            return nil
        }
        var last: Int?
        for line in (span.header + 1)..<span.end where keyName(lines[line]) != nil {
            last = line
        }
        return last.map { span.header..<($0 + 1) }
    }
}

// MARK: - Rendering

private func renderNumber(_ value: Double) -> String? {
    guard value.isFinite else {
        return nil
    }
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int(value))
    }
    return "\(value)"
}

private func quoted(_ text: String) -> String? {
    guard !text.contains("\""), !text.contains("\n"), !text.contains("\r") else {
        return nil
    }
    return "\"\(text)\""
}

private func render(_ value: ConfigEditValue) -> String? {
    switch value {
    case .int(let number): return String(number)
    case .number(let number): return renderNumber(number)
    case .bool(let flag): return flag ? "true" : "false"
    case .string(let text): return quoted(text)
    case .numbers(let numbers):
        let parts = numbers.compactMap(renderNumber)
        return parts.count == numbers.count ? "[" + parts.joined(separator: ", ") + "]" : nil
    }
}

private func renderRule(_ rule: WindowRule) -> [String]? {
    var block = ["[[window-rules]]"]
    if !rule.app.isEmpty || (rule.bundleID == nil && rule.title == nil) {
        guard let app = quoted(rule.app) else {
            return nil
        }
        block.append("app = \(app)")
    }
    if let bundleID = rule.bundleID {
        guard let text = quoted(bundleID) else {
            return nil
        }
        block.append("bundle-id = \(text)")
    }
    if let title = rule.title {
        guard let text = quoted(title.pattern) else {
            return nil
        }
        block.append("title = \(text)")
    }
    if let mode = rule.mode {
        block.append("mode = \"\(mode.rawValue)\"")
    }
    if let workspace = rule.workspace {
        block.append("workspace = \(workspace)")
    }
    if let name = rule.openOnWorkspace {
        guard let text = quoted(name) else {
            return nil
        }
        block.append("open-on-workspace = \(text)")
    }
    if rule.follow != .whenActive {
        block.append("follow = \"\(rule.follow.rawValue)\"")
    }
    switch rule.columnWidth {
    case .proportion(let value)?, .points(let value)?:
        guard let text = renderNumber(Double(value)) else {
            return nil
        }
        block.append("default-column-width = \(text)")
    case .standard?, nil:
        break
    }
    if rule.openMaximized {
        block.append("open-maximized = true")
    }
    if let display = rule.openOnDisplay {
        block.append("open-on-display = \(display)")
    }
    if let openFocused = rule.openFocused {
        block.append("open-focused = \(openFocused)")
    }
    for (key, value) in [("min-width", rule.minWidth), ("max-width", rule.maxWidth)] {
        guard let value else {
            continue
        }
        guard let text = renderNumber(Double(value)) else {
            return nil
        }
        block.append("\(key) = \(text)")
    }
    return block
}

private func renderWorkspace(_ definition: WorkspaceDefinition) -> [String]? {
    guard let name = quoted(definition.name) else {
        return nil
    }
    var block = ["[[workspace]]", "name = \(name)"]
    if let icon = definition.icon {
        guard let text = quoted(icon) else {
            return nil
        }
        block.append("icon = \(text)")
    }
    if let color = definition.color {
        guard let text = quoted(color) else {
            return nil
        }
        block.append("color = \(text)")
    }
    switch definition.display {
    case .main?: block.append("display = \"main\"")
    case .index(let number)?: block.append("display = \(number)")
    case nil: break
    }
    if let layout = definition.layout {
        block.append("layout = \"\(layout.rawValue)\"")
    }
    return block
}
