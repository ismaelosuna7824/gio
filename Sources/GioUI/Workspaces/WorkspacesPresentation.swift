import Foundation
import GioCore

/// NW-03 pure logic behind the Workspaces section: named workspaces as
/// editable cards with the apps assigned to them, and the config edits a
/// draft becomes. `[[workspace]]` blocks hold the workspaces; assignments are
/// `[[window-rules]]` with `open-on-workspace` (plus `bundle-id`, `follow`).

// MARK: - Model

/// One app assigned to a workspace. Identity is the bundle id when known,
/// else the app name (rules match the same way).
public struct WorkspaceAppAssignment: Equatable, Sendable, Identifiable {
    public var app: String
    public var bundleID: String?
    public var follow: WorkspaceFollowPolicy

    public init(app: String, bundleID: String? = nil, follow: WorkspaceFollowPolicy = .whenActive) {
        self.app = app
        self.bundleID = bundleID
        self.follow = follow
    }

    public var id: String { bundleID.map { "bundle:\($0)" } ?? "app:\(app)" }

    /// Same app: equal bundle ids when both are known, else equal names.
    public func isSameApp(as other: WorkspaceAppAssignment) -> Bool {
        if let bundleID, let otherBundle = other.bundleID {
            return bundleID == otherBundle
        }
        return !app.isEmpty && app == other.app
    }

    func isSameApp(as rule: WindowRule) -> Bool {
        if let bundleID, let ruleBundle = rule.bundleID {
            return bundleID == ruleBundle
        }
        return !app.isEmpty && app == rule.app
    }
}

/// One named workspace being edited. `origin` is its index among the
/// config's `[[workspace]]` blocks when it was loaded (nil for new ones);
/// the edits address existing blocks through it.
public struct WorkspaceCardDraft: Equatable, Sendable, Identifiable {
    public let id: String
    public let origin: Int?
    public var name: String
    public var icon: String?
    public var color: String?
    public var display: WorkspaceDisplayAssignment?
    public var apps: [WorkspaceAppAssignment]
    /// DW-03 `[[workspace]] layout`; nil follows `[layout] default-layout`.
    public var layout: WorkspaceLayoutKind?

    public init(
        id: String, origin: Int?, name: String, icon: String? = nil, color: String? = nil,
        display: WorkspaceDisplayAssignment? = nil, apps: [WorkspaceAppAssignment] = [],
        layout: WorkspaceLayoutKind? = nil
    ) {
        self.id = id
        self.origin = origin
        self.name = name
        self.icon = icon
        self.color = color
        self.display = display
        self.apps = apps
        self.layout = layout
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    public var definition: WorkspaceDefinition {
        WorkspaceDefinition(name: trimmedName, icon: icon, color: color, display: display, layout: layout)
    }
}

/// DW-03: the per-workspace layout picker's choices (nil: the default layout).
public let workspaceLayoutOptions: [(WorkspaceLayoutKind?, String)] = [
    (nil, "Default"), (.scrolling, "Scrolling"), (.dwindle, "Dwindle"),
]

/// DW-03: "Default (Dwindle)", "Scrolling", "Dwindle".
public func workspaceLayoutLabel(_ layout: WorkspaceLayoutKind?, default fallback: WorkspaceLayoutKind) -> String {
    func title(_ kind: WorkspaceLayoutKind) -> String {
        kind == .dwindle ? "Dwindle" : "Scrolling"
    }
    return layout.map(title) ?? "Default (\(title(fallback)))"
}

/// An app that would leave another workspace when assigned here.
public struct WorkspaceAppConflict: Equatable, Sendable {
    public let app: String
    public let from: String

    public init(app: String, from: String) {
        self.app = app
        self.from = from
    }
}

/// Quick-add presets for the empty state: icon and color, no apps.
public enum WorkspaceTemplate: String, CaseIterable, Sendable, Identifiable {
    case code, browsers, chat, design

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .code: return "Code"
        case .browsers: return "Browsers"
        case .chat: return "Chat"
        case .design: return "Design"
        }
    }

    public var icon: String {
        switch self {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .browsers: return "globe"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .design: return "paintbrush.pointed.fill"
        }
    }

    public var color: String {
        switch self {
        case .code: return "#5e9eff"
        case .browsers: return "#34c3a0"
        case .chat: return "#a77bff"
        case .design: return "#ff7eb6"
        }
    }
}

/// The Workspaces section's editable value.
public struct WorkspacesDraft: Equatable, Sendable {
    public var cards: [WorkspaceCardDraft]

    public init(cards: [WorkspaceCardDraft]) {
        self.cards = cards
    }

    /// Workspaces in config order; each app shows under the first
    /// workspace a rule sends it to (the first matching rule wins).
    public init(config: GioConfig) {
        var claimed: [WorkspaceAppAssignment] = []
        var appsByName: [String: [WorkspaceAppAssignment]] = [:]
        // WR-01: a title rule is narrower than "this app's windows": it is
        // the Rules section's, never a card's app.
        for rule in config.rules where rule.title == nil {
            guard let target = rule.openOnWorkspace else {
                continue
            }
            let assignment = WorkspaceAppAssignment(app: rule.app, bundleID: rule.bundleID, follow: rule.follow)
            guard !claimed.contains(where: { $0.isSameApp(as: assignment) }) else {
                continue
            }
            claimed.append(assignment)
            appsByName[target, default: []].append(assignment)
        }
        cards = config.workspaces.enumerated().map { index, definition in
            WorkspaceCardDraft(
                id: "saved-\(index)", origin: index, name: definition.name, icon: definition.icon,
                color: definition.color, display: definition.display, apps: appsByName[definition.name] ?? [],
                layout: definition.layout
            )
        }
    }

    public func card(_ id: String) -> WorkspaceCardDraft? {
        cards.first { $0.id == id }
    }

    private func position(_ id: String) -> Int? {
        cards.firstIndex { $0.id == id }
    }

    // MARK: Workspaces

    /// Appends a workspace (from a template, or "Workspace N") with a name
    /// no other card uses; returns its id.
    @discardableResult
    public mutating func addWorkspace(template: WorkspaceTemplate? = nil) -> String {
        let base = template?.name ?? "Workspace"
        let taken = Set(cards.map { $0.trimmedName.lowercased() })
        var name = template == nil ? "\(base) 1" : base
        var counter = 1
        while taken.contains(name.lowercased()) {
            counter += 1
            name = "\(base) \(counter)"
        }
        let next = (cards.compactMap { Int($0.id.dropFirst("new-".count)) }.max() ?? 0) + 1
        let id = "new-\(next)"
        cards.append(WorkspaceCardDraft(id: id, origin: nil, name: name, icon: template?.icon, color: template?.color))
        return id
    }

    public mutating func removeWorkspace(_ id: String) {
        cards.removeAll { $0.id == id }
    }

    public mutating func rename(_ id: String, to name: String) {
        guard let index = position(id) else {
            return
        }
        cards[index].name = name
    }

    // MARK: Order

    public func canMoveUp(_ id: String) -> Bool {
        (position(id) ?? 0) > 0
    }

    public func canMoveDown(_ id: String) -> Bool {
        position(id).map { $0 < cards.count - 1 } ?? false
    }

    public mutating func moveUp(_ id: String) {
        guard let index = position(id), index > 0 else {
            return
        }
        cards.swapAt(index, index - 1)
    }

    public mutating func moveDown(_ id: String) {
        guard let index = position(id), index < cards.count - 1 else {
            return
        }
        cards.swapAt(index, index + 1)
    }

    /// Drag and drop: `id` lands just before `target` (at the end for nil).
    public mutating func move(_ id: String, before target: String?) {
        guard id != target, let index = position(id) else {
            return
        }
        let card = cards.remove(at: index)
        let destination = target.flatMap(position) ?? cards.count
        cards.insert(card, at: destination)
    }

    /// Drag and drop onto a card: the dragged card takes the target's place
    /// (after it when dragged down, before it when dragged up).
    public mutating func drop(_ id: String, onto target: String) {
        guard id != target, let from = position(id), let to = position(target) else {
            return
        }
        let card = cards.remove(at: from)
        cards.insert(card, at: to)
    }

    /// `List.onMove` semantics.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { cards[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) {
            cards.remove(at: index)
        }
        cards.insert(contentsOf: moving, at: min(destination - before, cards.count))
    }

    // MARK: Apps

    /// Apps among `apps` that some other workspace holds now.
    public func conflicts(assigning apps: [WorkspaceAppAssignment], to id: String) -> [WorkspaceAppConflict] {
        apps.compactMap { app in
            cards.first { $0.id != id && $0.apps.contains { $0.isSameApp(as: app) } }
                .map { WorkspaceAppConflict(app: app.app, from: $0.trimmedName) }
        }
    }

    /// Adds `apps` to the workspace, moving any held elsewhere (with its
    /// follow policy); apps already here stay as they are.
    public mutating func assign(_ apps: [WorkspaceAppAssignment], to id: String) {
        guard position(id) != nil else {
            return
        }
        for app in apps {
            guard let target = position(id), !cards[target].apps.contains(where: { $0.isSameApp(as: app) }) else {
                continue
            }
            var moved = app
            for index in cards.indices where index != target {
                if let found = cards[index].apps.firstIndex(where: { $0.isSameApp(as: app) }) {
                    moved.follow = cards[index].apps[found].follow
                    moved.bundleID = moved.bundleID ?? cards[index].apps[found].bundleID
                    cards[index].apps.remove(at: found)
                }
            }
            cards[target].apps.append(moved)
        }
    }

    public mutating func removeApp(_ appID: String, from id: String) {
        guard let index = position(id) else {
            return
        }
        cards[index].apps.removeAll { $0.id == appID }
    }

    public mutating func setFollow(_ policy: WorkspaceFollowPolicy, app appID: String, in id: String) {
        guard let index = position(id), let app = cards[index].apps.firstIndex(where: { $0.id == appID }) else {
            return
        }
        cards[index].apps[app].follow = policy
    }

    // MARK: Validation

    public func nameProblem(for id: String) -> String? {
        guard let card = card(id) else {
            return nil
        }
        let name = card.trimmedName
        if name.isEmpty {
            return "Give this workspace a name."
        }
        if name.contains("\"") || name.contains("\n") {
            return "Names can’t contain double quotes."
        }
        if cards.contains(where: { $0.id != id && $0.trimmedName.lowercased() == name.lowercased() }) {
            return "Another workspace is already named “\(name)”."
        }
        return nil
    }

    /// Every blocking problem, in card order (one per card at most).
    public var problems: [String] {
        cards.compactMap { nameProblem(for: $0.id) }
    }
}

// MARK: - Config edits

/// The edits that turn `config` into what `draft` shows. Workspace blocks:
/// removals, in-place updates, additions, then moves into draft order.
/// Rules: an assigned app reuses the first rule that matches it (so no
/// earlier rule shadows a new one) and gains `open-on-workspace`/`follow`;
/// an assignment rule no longer wanted is removed, or only loses its
/// workspace when it still holds other opinions (mode).
public func workspaceConfigEdits(config: GioConfig, draft: WorkspacesDraft) -> [ConfigEdit] {
    workspaceBlockEdits(config: config, draft: draft) + workspaceRuleEdits(config: config, draft: draft)
}

private func workspaceBlockEdits(config: GioConfig, draft: WorkspacesDraft) -> [ConfigEdit] {
    var edits: [ConfigEdit] = []
    let kept = Set(draft.cards.compactMap(\.origin))
    for index in config.workspaces.indices.reversed() where !kept.contains(index) {
        edits.append(.removeWorkspace(index: index))
    }
    // After removals the surviving blocks keep their relative order.
    var order: [String] = []
    let survivors = draft.cards.filter { $0.origin != nil }.sorted { $0.origin! < $1.origin! }
    for (position, card) in survivors.enumerated() {
        if let origin = card.origin, config.workspaces.indices.contains(origin),
           config.workspaces[origin] != card.definition {
            edits.append(.updateWorkspace(index: position, card.definition))
        }
        order.append(card.id)
    }
    for card in draft.cards where card.origin == nil {
        edits.append(.addWorkspace(card.definition))
        order.append(card.id)
    }
    for (target, card) in draft.cards.enumerated() {
        guard let current = order.firstIndex(of: card.id), current != target else {
            continue
        }
        edits.append(.moveWorkspace(from: current, to: target))
        order.remove(at: current)
        order.insert(card.id, at: target)
    }
    return edits
}

private func workspaceRuleEdits(config: GioConfig, draft: WorkspacesDraft) -> [ConfigEdit] {
    var updates: [ConfigEdit] = []
    var additions: [ConfigEdit] = []
    var claimed = Set<Int>()
    for card in draft.cards {
        for app in card.apps {
            let match = config.rules.indices.first {
                !claimed.contains($0) && config.rules[$0].title == nil && app.isSameApp(as: config.rules[$0])
            }
            guard let index = match else {
                additions.append(.addRule(WindowRule(
                    app: app.app, bundleID: app.bundleID, openOnWorkspace: card.trimmedName, follow: app.follow
                )))
                continue
            }
            claimed.insert(index)
            let existing = config.rules[index]
            var rule = existing
            rule.app = existing.app.isEmpty ? app.app : existing.app
            rule.bundleID = app.bundleID ?? existing.bundleID
            rule.openOnWorkspace = card.trimmedName
            rule.follow = app.follow
            rule.workspace = nil
            if rule != existing {
                updates.append(.updateRule(index: index, rule))
            }
        }
    }
    var removals: [ConfigEdit] = []
    for index in config.rules.indices.reversed()
    where config.rules[index].openOnWorkspace != nil && config.rules[index].title == nil && !claimed.contains(index) {
        var rule = config.rules[index]
        if rule.hasOpinionsBesidesPlacement {
            rule.openOnWorkspace = nil
            rule.follow = .whenActive
            updates.append(.updateRule(index: index, rule))
        } else {
            removals.append(.removeRule(index: index))
        }
    }
    return updates + removals + additions
}

private extension WindowRule {
    /// Unassigning the app keeps a rule that still says something else.
    var hasOpinionsBesidesPlacement: Bool {
        mode != nil || columnWidth != nil || openMaximized || openOnDisplay != nil || !openFocused
            || minWidth != nil || maxWidth != nil
    }
}

// MARK: - Small presentation

/// "⌥1 Code · ⌥2 Browsers · ⌥3 and up: other workspaces"; empty without
/// named workspaces. Named workspaces come first in the stack.
public func workspaceShortcutSummary(_ draft: WorkspacesDraft) -> String {
    guard !draft.cards.isEmpty else {
        return ""
    }
    let visible = draft.cards.prefix(9).enumerated().map { index, card in
        "⌥\(index + 1) \(card.trimmedName.isEmpty ? "Untitled" : card.trimmedName)"
    }
    let rest = draft.cards.count < 9 ? ["⌥\(draft.cards.count + 1) and up: other workspaces"] : []
    return (visible + rest).joined(separator: " · ")
}

/// Display popup options: Main, then each connected display after the
/// first; a saved display that is not connected stays listed.
public func workspaceDisplayOptions(
    displayCount: Int, current: WorkspaceDisplayAssignment?
) -> [(WorkspaceDisplayAssignment?, String)] {
    var options: [(WorkspaceDisplayAssignment?, String)] = [(nil, "Main")]
    if displayCount > 1 {
        options += (2...displayCount).map { (WorkspaceDisplayAssignment.index($0), "Display \($0)") }
    }
    switch current {
    case .main?:
        options.append((.main, "Main"))
    case .index(let number)? where !options.contains(where: { $0.0 == .index(number) }):
        options.append((.index(number), "Display \(number)"))
    default:
        break
    }
    return options
}

/// "Main display" / "Display 2".
public func workspaceDisplayLabel(_ display: WorkspaceDisplayAssignment?) -> String {
    switch display {
    case nil, .main?: return "Main display"
    case .index(let number)?: return number == 1 ? "Display 1" : "Display \(number)"
    }
}

public func workspaceFollowLabel(_ policy: WorkspaceFollowPolicy) -> String {
    switch policy {
    case .whenActive: return "When Active"
    case .always: return "Always"
    case .never: return "Never"
    }
}

public func workspaceFollowCaption(_ policy: WorkspaceFollowPolicy) -> String {
    switch policy {
    case .whenActive: return "Takes you there when you open or use the app."
    case .always: return "Always takes you to the workspace."
    case .never: return "Sends the window there quietly."
    }
}

// MARK: - Icons and colors

public struct WorkspaceSymbol: Equatable, Sendable {
    public let name: String
    public let keywords: [String]
}

private func symbol(_ name: String, _ keywords: String) -> WorkspaceSymbol {
    WorkspaceSymbol(name: name, keywords: keywords.split(separator: " ").map(String.init))
}

/// Curated SF Symbols for workspace icons (filled where one exists).
public let workspaceSymbolCatalog: [WorkspaceSymbol] = [
    symbol("chevron.left.forwardslash.chevron.right", "code dev programming editor ide"),
    symbol("terminal.fill", "terminal shell console command cli"),
    symbol("hammer.fill", "build tools make xcode"),
    symbol("ladybug.fill", "debug bug test"),
    symbol("cpu.fill", "server compute hardware"),
    symbol("server.rack", "server backend infra ops"),
    symbol("globe", "web browser internet safari chrome"),
    symbol("safari.fill", "web browser compass"),
    symbol("network", "web network api"),
    symbol("bubble.left.and.bubble.right.fill", "chat messages slack talk"),
    symbol("message.fill", "chat messages imessage"),
    symbol("envelope.fill", "mail email inbox"),
    symbol("phone.fill", "call phone meeting"),
    symbol("video.fill", "video meeting zoom call"),
    symbol("person.2.fill", "people team social"),
    symbol("paintbrush.pointed.fill", "design paint art figma"),
    symbol("paintpalette.fill", "design color art"),
    symbol("pencil.and.outline", "design draw sketch"),
    symbol("photo.fill", "photo image pictures"),
    symbol("camera.fill", "camera photo"),
    symbol("film.fill", "video movie edit"),
    symbol("music.note", "music audio spotify"),
    symbol("headphones", "music audio podcast"),
    symbol("doc.text.fill", "docs document writing text"),
    symbol("note.text", "notes writing"),
    symbol("book.fill", "read books docs"),
    symbol("newspaper.fill", "news read"),
    symbol("calendar", "calendar schedule plan"),
    symbol("checklist", "tasks todo plan"),
    symbol("folder.fill", "files finder folder"),
    symbol("tray.full.fill", "inbox tray files"),
    symbol("chart.bar.fill", "chart data stats analytics"),
    symbol("tablecells.fill", "spreadsheet table data"),
    symbol("briefcase.fill", "work office business"),
    symbol("building.2.fill", "office company work"),
    symbol("graduationcap.fill", "school study learn"),
    symbol("gamecontroller.fill", "games play fun"),
    symbol("sparkles", "ai magic misc"),
    symbol("brain.head.profile", "ai think research"),
    symbol("flask.fill", "lab research science"),
    symbol("gearshape.fill", "settings system tools"),
    symbol("wrench.and.screwdriver.fill", "tools utilities fix"),
    symbol("lock.fill", "security private vault"),
    symbol("cart.fill", "shopping store"),
    symbol("house.fill", "home personal"),
    symbol("star.fill", "star favorite"),
    symbol("heart.fill", "heart favorite personal"),
    symbol("bolt.fill", "fast power energy"),
    symbol("leaf.fill", "nature calm personal"),
    symbol("moon.fill", "night focus calm"),
    symbol("flame.fill", "hot focus"),
    symbol("square.stack.3d.up.fill", "workspace stack general"),
]

/// Symbols whose name or keywords contain `query` (case-insensitive).
public func filterWorkspaceSymbols(_ query: String) -> [String] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else {
        return workspaceSymbolCatalog.map(\.name)
    }
    return workspaceSymbolCatalog.filter { entry in
        entry.name.lowercased().contains(needle) || entry.keywords.contains { $0.contains(needle) }
    }.map(\.name)
}

/// Swatches for workspace colors: the templates' plus a few more.
public let workspaceColorPresets: [String] = [
    "#5e9eff", "#34c3a0", "#a77bff", "#ff7eb6", "#ff9f43", "#ffd43b", "#ff6b6b", "#8e8e93",
]
