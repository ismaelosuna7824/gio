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
/// parser turns into rules), in file order; edits apply sequentially.
public enum ConfigEdit: Equatable, Sendable {
    case set(table: String, key: String, value: ConfigEditValue)
    case remove(table: String, key: String)
    case addRule(WindowRule)
    case updateRule(index: Int, WindowRule)
    case removeRule(index: Int)
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
        guard let range = ruleBlockRange(index, in: lines) else {
            return "rule \(index) does not exist"
        }
        lines.removeSubrange(range)
        let at = range.lowerBound
        if at > 0, isBlank(lines[at - 1]), at == lines.count || isBlank(lines[at]) {
            lines.remove(at: at - 1)
        }
        return nil
    }
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
    appendBlock(["[\(table)]", "\(key) = \(rendered)"], to: &lines)
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
}

private func appendBlock(_ block: [String], to lines: inout [String]) {
    if let last = lines.last, !isBlank(last) {
        lines.append("")
    }
    lines.append(contentsOf: block)
}

/// Header through the last non-blank, non-comment line of the block:
/// trailing blank lines and comments belong to whatever follows.
private func ruleBlockRange(_ index: Int, in lines: [String]) -> Range<Int>? {
    let blocks = spans(of: lines).filter { span in
        span.isArray && span.name == "window-rules"
            && ((span.header + 1)..<span.end).contains { keyName(lines[$0]) != nil }
    }
    guard blocks.indices.contains(index) else {
        return nil
    }
    let block = blocks[index]
    var last = block.header
    for line in (block.header + 1)..<block.end where keyName(lines[line]) != nil {
        last = line
    }
    return block.header..<(last + 1)
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
    guard let app = quoted(rule.app) else {
        return nil
    }
    var block = ["[[window-rules]]", "app = \(app)"]
    if let mode = rule.mode {
        block.append("mode = \"\(mode.rawValue)\"")
    }
    if let workspace = rule.workspace {
        block.append("workspace = \(workspace)")
    }
    return block
}
