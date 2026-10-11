import CoreGraphics
import Foundation
import GioCore

/// What a hotkey action asks of the session once its logical change is
/// stored. The host applies it in field order: shown workspace sync, the
/// native-zoom request, the fullscreen toggle, the focus intent, the sizing
/// focus, the cursor warp to an empty display, then one reflow.
public struct ActionEffect: Equatable, Sendable {
    /// A fullscreen toggle of `id`, filling `frame` (the host's book flips it).
    public struct FullscreenToggle: Equatable, Sendable {
        public var id: WindowID
        public var frame: CGRect
    }

    /// The current workspace changed display membership: point displays at it.
    public var syncsShownWorkspace = false
    /// Maximize: the workspace before the toggle, for the native-zoom request.
    public var zoomRequest: Workspace?
    public var fullscreenToggle: FullscreenToggle?
    /// Keyboard focus intent (HD-01): center, raise, warp after the pass.
    public var carriesFocusIntent = false
    /// The focused window before the action (centering reference).
    public var previousFocus: WindowID?
    /// A sizing action grew the focused window (focused-grow at start).
    public var growsFocusedWindow = false
    /// MM-02: focus moved to another display that has no window to focus:
    /// its usable frame, for `mouse-follows-focus` to put the cursor there
    /// (a focused window takes the cursor after the pass as usual).
    public var warpsToDisplay: CGRect?
}

/// `SessionHost.apply(_:)`: maps a hotkey action onto the pure Core use
/// cases and stores the result in the workspace manager. Never writes a
/// window and never reaches the OS; the few session effects are returned as
/// an `ActionEffect`. The switch is exhaustive: a new `HotkeyAction` case
/// fails to compile here until it is handled.
public enum ActionApplier {
    /// Session reads an action may need (lazily: the tileability probe and
    /// the layout engine only run for the actions that use them).
    public struct Context {
        public var registry: WindowRegistry
        public var displays: [DisplayState]
        public var visibleFrames: [DisplayID: CGRect]
        public var layout: LayoutSectionConfig
        /// MM-06: `move-crosses-monitor-at-edge` lives here.
        public var behavior: BehaviorSectionConfig
        public var engine: () -> ScrollableLayoutEngine
        public var modes: () -> [WindowID: WindowMode]
        /// The primary screen's usable frame, used without any display.
        public var fallbackViewport: () -> CGRect?

        public init(
            registry: WindowRegistry, displays: [DisplayState], visibleFrames: [DisplayID: CGRect],
            layout: LayoutSectionConfig, behavior: BehaviorSectionConfig,
            engine: @escaping () -> ScrollableLayoutEngine,
            modes: @escaping () -> [WindowID: WindowMode], fallbackViewport: @escaping () -> CGRect?
        ) {
            self.registry = registry
            self.displays = displays
            self.visibleFrames = visibleFrames
            self.layout = layout
            self.behavior = behavior
            self.engine = engine
            self.modes = modes
            self.fallbackViewport = fallbackViewport
        }
    }

    public static func apply(
        _ action: HotkeyAction, manager: inout WorkspaceManager, context: Context
    ) -> ActionEffect {
        var effect = ActionEffect()
        var workspace = manager.currentWorkspace()
        effect.previousFocus = workspace.focusedWindow
        let startDisplay = manager.focusedDisplay
        switch action {
        case .focusLeft:
            focus(in: &workspace, .left, manager: &manager)
        case .focusRight:
            focus(in: &workspace, .right, manager: &manager)
        case .focusUp:
            focus(in: &workspace, .up, manager: &manager)
        case .focusDown:
            focus(in: &workspace, .down, manager: &manager)
        case .moveLeft:
            narrowMove(in: &workspace, .left, manager: &manager)
        case .moveRight:
            narrowMove(in: &workspace, .right, manager: &manager)
        case .moveColumnLeft, .moveColumnRight:
            let direction: FocusDirection = action == .moveColumnLeft ? .left : .right
            if context.behavior.moveCrossesMonitorAtEdge {
                effect.syncsShownWorkspace = manager.moveColumnOrToDisplay(
                    direction, frames: displayFrames(context)
                ) == .crossedDisplay
            } else {
                commit(moveColumn(in: workspace, direction: direction), over: workspace, manager: &manager)
            }
        case .moveUp:
            narrowMove(in: &workspace, .up, manager: &manager)
        case .moveDown:
            narrowMove(in: &workspace, .down, manager: &manager)
        case .workspace(let number):
            manager.switchTo(number)
            effect.syncsShownWorkspace = true
        case .moveToWorkspace(let number):
            if let id = workspace.focusedWindow {
                manager.moveWindow(id, to: number)
            }
        case .focusWorkspaceDown:
            manager.focusDown()
            effect.syncsShownWorkspace = true
        case .focusWorkspaceUp:
            manager.focusUp()
            effect.syncsShownWorkspace = true
        case .moveWindowToWorkspaceDown:
            if let id = workspace.focusedWindow {
                manager.moveWindowDown(id)
                effect.syncsShownWorkspace = true
            }
        case .moveWindowToWorkspaceUp:
            if let id = workspace.focusedWindow {
                manager.moveWindowUp(id)
                effect.syncsShownWorkspace = true
            }
        case .toggleFloating:
            if let id = workspace.focusedWindow {
                _ = try? context.registry.toggleFloating(for: id)
            }
        case .fullscreen:
            effect.fullscreenToggle = fullscreenToggle(manager: manager, context: context)
        case .switchPresetColumnWidth:
            let config = context.engine().config
            let viewportWidth = focusedViewport(manager: manager, context: context).width
            let next = switchPresetColumnWidth(
                in: workspace, presets: context.layout.presetColumnWidths,
                config: config, viewportWidth: viewportWidth
            )
            commit(next, over: workspace, manager: &manager)
        case .shrinkColumnWidth, .growColumnWidth:
            let config = context.engine().config
            let viewportWidth = focusedViewport(manager: manager, context: context).width
            let next = stepFocusedColumnWidth(
                in: workspace, by: action == .growColumnWidth ? 0.1 : -0.1,
                config: config, viewportWidth: viewportWidth
            )
            commit(next, over: workspace, manager: &manager)
        case .maximizeColumn:
            effect.zoomRequest = workspace
            commit(toggleMaximizeFocusedColumn(in: workspace), over: workspace, manager: &manager)
        case .consumeOrExpelLeft:
            commit(consumeOrExpelWindow(in: workspace, direction: .left), over: workspace, manager: &manager)
        case .consumeOrExpelRight:
            commit(consumeOrExpelWindow(in: workspace, direction: .right), over: workspace, manager: &manager)
        case .centerColumn:
            let viewport = focusedViewport(manager: manager, context: context)
            commit(
                centerFocusedColumn(
                    in: workspace, modes: context.modes(), engine: context.engine(), viewport: viewport
                ),
                over: workspace, manager: &manager
            )
        case .toggleOverview:
            // The app's panel; `SessionHost.handleCombo` hands it over before
            // this table, and the session state stays as it is.
            break
        case .focusMonitor(let direction):
            effect.syncsShownWorkspace = toNeighbour(direction, manager: &manager, context: context) {
                $0.focusDisplay($1)
            }
        case .moveColumnToMonitor(let direction):
            effect.syncsShownWorkspace = toNeighbour(direction, manager: &manager, context: context) {
                $0.moveColumn(toDisplay: $1)
            }
        case .moveWindowToMonitor(let direction):
            effect.syncsShownWorkspace = toNeighbour(direction, manager: &manager, context: context) {
                $0.moveWindow(toDisplay: $1)
            }
        case .moveWorkspaceToMonitor(let direction):
            effect.syncsShownWorkspace = toNeighbour(direction, manager: &manager, context: context) {
                $0.moveWorkspace(toDisplay: $1)
            }
        case .switchPresetWindowHeight:
            let config = context.engine().config
            let viewportHeight = focusedViewport(manager: manager, context: context).height
            let next = switchPresetWindowHeight(
                in: workspace, presets: context.layout.presetWindowHeights,
                config: config, viewportHeight: viewportHeight
            )
            commit(next, over: workspace, manager: &manager)
        case .shrinkWindowHeight, .growWindowHeight:
            let config = context.engine().config
            let viewportHeight = focusedViewport(manager: manager, context: context).height
            let next = stepFocusedWindowHeight(
                in: workspace, by: action == .growWindowHeight ? 0.1 : -0.1,
                config: config, viewportHeight: viewportHeight
            )
            commit(next, over: workspace, manager: &manager)
        case .resetWindowHeight:
            commit(resetWindowHeights(in: workspace), over: workspace, manager: &manager)
        case .focusColumnFirst:
            commit(focusColumnFirst(in: workspace), over: workspace, manager: &manager)
        case .focusColumnLast:
            commit(focusColumnLast(in: workspace), over: workspace, manager: &manager)
        case .moveColumnToFirst:
            commit(moveColumnToFirst(in: workspace), over: workspace, manager: &manager)
        case .moveColumnToLast:
            commit(moveColumnToLast(in: workspace), over: workspace, manager: &manager)
        case .swapWindowLeft:
            commit(swapWindow(in: workspace, direction: .left), over: workspace, manager: &manager)
        case .swapWindowRight:
            commit(swapWindow(in: workspace, direction: .right), over: workspace, manager: &manager)
        case .moveColumnToWorkspace(let number):
            effect.syncsShownWorkspace = manager.moveColumn(toWorkspace: number)
        case .moveColumnToWorkspaceDown:
            effect.syncsShownWorkspace = manager.moveColumnToWorkspaceDown()
        case .moveColumnToWorkspaceUp:
            effect.syncsShownWorkspace = manager.moveColumnToWorkspaceUp()
        case .focusWorkspacePrevious:
            effect.syncsShownWorkspace = manager.focusWorkspacePrevious()
        case .moveWorkspaceDown, .moveWorkspaceUp:
            // The shown workspace stays the same: nothing to sync.
            let moved = action == .moveWorkspaceDown ? manager.moveWorkspaceDown() : manager.moveWorkspaceUp()
            if !moved, manager.currentWorkspace().name != nil {
                GioLog.record(
                    .info,
                    "\(configActionName(action)) refused: workspace \(manager.currentID.rawValue) is named; config order places it"
                )
            }
        case .focusWindowOrWorkspaceDown:
            effect.syncsShownWorkspace = manager.focusWindowOrWorkspaceDown()
        case .focusWindowOrWorkspaceUp:
            effect.syncsShownWorkspace = manager.focusWindowOrWorkspaceUp()
        case .switchPresetColumnWidthBack:
            let config = context.engine().config
            let viewportWidth = focusedViewport(manager: manager, context: context).width
            let next = switchPresetColumnWidthBack(
                in: workspace, presets: context.layout.presetColumnWidths,
                config: config, viewportWidth: viewportWidth
            )
            commit(next, over: workspace, manager: &manager)
        case .expandColumnToAvailableWidth:
            let viewport = focusedViewport(manager: manager, context: context)
            commit(
                expandColumnToAvailableWidth(
                    in: workspace, modes: context.modes(), engine: context.engine(), viewport: viewport
                ),
                over: workspace, manager: &manager
            )
        case .centerVisibleColumns:
            let viewport = focusedViewport(manager: manager, context: context)
            commit(
                centerVisibleColumns(
                    in: workspace, modes: context.modes(), engine: context.engine(), viewport: viewport
                ),
                over: workspace, manager: &manager
            )
        case .moveColumnLeftOrToMonitorLeft, .moveColumnRightOrToMonitorRight:
            let direction: FocusDirection = action == .moveColumnLeftOrToMonitorLeft ? .left : .right
            effect.syncsShownWorkspace = manager.moveColumnOrToDisplay(
                direction, frames: displayFrames(context)
            ) == .crossedDisplay
        case .focusColumnOrMonitorLeft, .focusColumnOrMonitorRight:
            let direction: FocusDirection = action == .focusColumnOrMonitorLeft ? .left : .right
            effect.syncsShownWorkspace = manager.focusColumnOrDisplay(
                direction, frames: displayFrames(context)
            ) == .crossedDisplay
        }
        if manager.focusedDisplay != startDisplay, manager.currentWorkspace().focusedWindow == nil,
           let display = context.displays.first(where: { $0.id == manager.focusedDisplay })
        {
            effect.warpsToDisplay = context.visibleFrames[display.id] ?? display.frame
        }
        effect.carriesFocusIntent = action.carriesFocusIntent
        effect.growsFocusedWindow = action.growsFocusedWindow
        return effect
    }

    /// MM-04: the overview (Alt+O) opens on the display the user is on
    /// (`overviewDisplay`: the focused window's display, else the one under
    /// the cursor, else the focused display). When that is not the focused
    /// display it becomes the focused one, so the overview's workspace picks
    /// (`workspace N` on the focused display) act where it is shown.
    @discardableResult
    public static func focusOverviewDisplay(
        manager: inout WorkspaceManager, focusedWindowFrame: CGRect?, cursor: CGPoint?, displays: [DisplayState]
    ) -> (display: DisplayID, reason: OverviewDisplayReason)? {
        let frames = Dictionary(displays.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        guard let choice = overviewDisplay(
            focusedWindowFrame: focusedWindowFrame, cursor: cursor, displays: frames,
            focusedDisplay: manager.focusedDisplay
        ) else {
            return nil
        }
        if choice.display != manager.focusedDisplay {
            manager.focusDisplay(choice.display)
        }
        return choice
    }

    /// Usable frame of the display showing the current workspace.
    public static func focusedViewport(manager: WorkspaceManager, context: Context) -> CGRect {
        focusedDisplay(manager: manager, context: context).map { context.visibleFrames[$0.id] ?? $0.frame }
            ?? context.fallbackViewport() ?? CGRect(x: 0, y: 0, width: 1800, height: 1000)
    }

    /// The display showing the current workspace; before the next
    /// `syncShownWorkspace` (a switch just happened) the focused display,
    /// where it is about to show (MM-01: never just the first display).
    private static func focusedDisplay(manager: WorkspaceManager, context: Context) -> DisplayState? {
        let current = manager.currentID
        return context.displays.first { $0.workspace == current }
            ?? context.displays.first { $0.id == manager.focusedDisplay }
    }

    /// MM-02: run `change` towards the display next to the focused one in
    /// `direction` (`displayNeighbour` over the display frames). False when
    /// there is no display that way or nothing changed.
    private static func toNeighbour(
        _ direction: FocusDirection, manager: inout WorkspaceManager, context: Context,
        _ change: (inout WorkspaceManager, DisplayID) -> Bool
    ) -> Bool {
        guard let target = displayNeighbour(
            of: manager.focusedDisplay, direction: direction, frames: displayFrames(context)
        ) else {
            return false
        }
        return change(&manager, target)
    }

    /// Full display frames, the geometry `displayNeighbour` works on (MM-01).
    private static func displayFrames(_ context: Context) -> [DisplayID: CGRect] {
        Dictionary(context.displays.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
    }

    /// Fullscreen is a layout mode: the registry flips and the reflow places
    /// the window (see `planDisplayLayout`). Never native Spaces.
    private static func fullscreenToggle(
        manager: WorkspaceManager, context: Context
    ) -> ActionEffect.FullscreenToggle? {
        guard let id = manager.currentWorkspace().focusedWindow,
              let display = focusedDisplay(manager: manager, context: context)
        else {
            return nil
        }
        let frame = fullscreenFrame(
            display: display.frame, usable: context.visibleFrames[display.id] ?? display.frame,
            gap: context.layout.resolvedFullscreenGap
        )
        return .init(id: id, frame: frame)
    }

    private static func focus(
        in workspace: inout Workspace, _ direction: FocusDirection, manager: inout WorkspaceManager
    ) {
        let next = moveFocus(in: workspace, direction: direction)
        if next != workspace {
            workspace = next
            manager.update(workspace)
        }
    }

    private static func narrowMove(
        in workspace: inout Workspace, _ direction: FocusDirection, manager: inout WorkspaceManager
    ) {
        let next = moveWindow(in: workspace, direction: direction)
        if next != workspace {
            workspace = next
            manager.update(workspace)
        }
    }

    /// Store `next` when an action changed anything.
    private static func commit(_ next: Workspace, over current: Workspace, manager: inout WorkspaceManager) {
        if next != current {
            manager.update(next)
        }
    }
}
