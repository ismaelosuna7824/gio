import CoreGraphics
import Foundation
import GioCore

/// What a hotkey action asks of the session once its logical change is
/// stored. The host applies it in field order: shown workspace sync, the
/// native-zoom request, the fullscreen toggle, the focus intent, the sizing
/// focus, then one reflow.
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
        public var engine: () -> ScrollableLayoutEngine
        public var modes: () -> [WindowID: WindowMode]
        /// The main screen's usable frame, used without any display.
        public var fallbackViewport: () -> CGRect?

        public init(
            registry: WindowRegistry, displays: [DisplayState], visibleFrames: [DisplayID: CGRect],
            layout: LayoutSectionConfig, engine: @escaping () -> ScrollableLayoutEngine,
            modes: @escaping () -> [WindowID: WindowMode], fallbackViewport: @escaping () -> CGRect?
        ) {
            self.registry = registry
            self.displays = displays
            self.visibleFrames = visibleFrames
            self.layout = layout
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
        case .moveColumnLeft:
            commit(moveColumn(in: workspace, direction: .left), over: workspace, manager: &manager)
        case .moveColumnRight:
            commit(moveColumn(in: workspace, direction: .right), over: workspace, manager: &manager)
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
        }
        effect.carriesFocusIntent = action.carriesFocusIntent
        effect.growsFocusedWindow = action.growsFocusedWindow
        return effect
    }

    /// Usable frame of the display showing the current workspace.
    public static func focusedViewport(manager: WorkspaceManager, context: Context) -> CGRect {
        focusedDisplay(manager: manager, context: context).map { context.visibleFrames[$0.id] ?? $0.frame }
            ?? context.fallbackViewport() ?? CGRect(x: 0, y: 0, width: 1800, height: 1000)
    }

    private static func focusedDisplay(manager: WorkspaceManager, context: Context) -> DisplayState? {
        let current = manager.currentID
        return context.displays.first { $0.workspace == current } ?? context.displays.first
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
