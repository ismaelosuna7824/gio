import GioCore
import XCTest
@testable import GioUI

/// DD-05: onboarding step state, the menu-bar model and launcher keyboard
/// selection.
final class ShellPresentationTests: XCTestCase {
    // MARK: - Onboarding

    func testShowsOnFirstLaunchOrWhenAccessibilityIsMissing() {
        XCTAssertTrue(shouldShowOnboarding(hasCompleted: false, accessibilityGranted: true))
        XCTAssertTrue(shouldShowOnboarding(hasCompleted: false, accessibilityGranted: nil))
        XCTAssertTrue(shouldShowOnboarding(hasCompleted: true, accessibilityGranted: false))
        XCTAssertFalse(shouldShowOnboarding(hasCompleted: true, accessibilityGranted: true))
        // Before the first facts arrive nothing is known yet.
        XCTAssertFalse(shouldShowOnboarding(hasCompleted: true, accessibilityGranted: nil))
    }

    func testStepsRunInOrder() {
        var state = OnboardingState(accessibilityGranted: true, screenRecordingGranted: false)
        XCTAssertEqual(state.step, .welcome)
        XCTAssertFalse(state.canGoBack)
        state.advance()
        XCTAssertEqual(state.step, .accessibility)
        state.advance()
        XCTAssertEqual(state.step, .screenRecording)
        state.advance()
        XCTAssertEqual(state.step, .keys)
        XCTAssertTrue(state.isLastStep)
        state.advance()
        XCTAssertEqual(state.step, .keys)
        state.back()
        XCTAssertEqual(state.step, .screenRecording)
    }

    func testAccessibilityBlocksContinueUntilGranted() {
        var state = OnboardingState(accessibilityGranted: false, screenRecordingGranted: false)
        state.advance()
        XCTAssertEqual(state.step, .accessibility)
        XCTAssertFalse(state.canAdvance)
        state.advance()
        XCTAssertEqual(state.step, .accessibility)
        state.update(accessibilityGranted: true, screenRecordingGranted: false)
        XCTAssertTrue(state.canAdvance)
        state.advance()
        XCTAssertEqual(state.step, .screenRecording)
    }

    func testUpdatingKeepsTheStepAndTakesTheLatestPermissions() {
        var stored = OnboardingState(accessibilityGranted: false, screenRecordingGranted: false)
        stored.advance()

        let current = stored.updating(accessibilityGranted: true, screenRecordingGranted: true)

        XCTAssertEqual(current.step, .accessibility)
        XCTAssertTrue(current.accessibilityGranted)
        XCTAssertTrue(current.screenRecordingGranted)
        XCTAssertTrue(current.canAdvance)
        XCTAssertFalse(stored.canAdvance)
    }

    func testScreenRecordingIsSkippable() {
        var state = OnboardingState(accessibilityGranted: true, screenRecordingGranted: false)
        state.advance()
        state.advance()
        XCTAssertEqual(state.step, .screenRecording)
        XCTAssertTrue(state.canAdvance)
        XCTAssertEqual(state.primaryTitle, "Skip")
        state.update(accessibilityGranted: true, screenRecordingGranted: true)
        XCTAssertEqual(state.primaryTitle, "Continue")
    }

    func testPrimaryTitlesAndProgress() {
        var state = OnboardingState(accessibilityGranted: true, screenRecordingGranted: true)
        XCTAssertEqual(state.primaryTitle, "Get Started")
        XCTAssertEqual(state.progress, OnboardingProgress(index: 0, count: 4))
        state.advance()
        state.advance()
        state.advance()
        XCTAssertEqual(state.primaryTitle, "Done")
        XCTAssertEqual(state.progress, OnboardingProgress(index: 3, count: 4))
    }

    func testScreenRecordingStepPhaseFollowsPermissionAndRequest() {
        XCTAssertEqual(screenRecordingStepPhase(granted: false, requested: false), .notRequested)
        XCTAssertEqual(screenRecordingStepPhase(granted: false, requested: true), .awaitingRelaunch)
        XCTAssertEqual(screenRecordingStepPhase(granted: true, requested: false), .granted)
        XCTAssertEqual(screenRecordingStepPhase(granted: true, requested: true), .granted)
    }

    func testResumeMarkerForcesOnboardingEvenWhenCompleted() {
        XCTAssertTrue(shouldShowOnboarding(hasCompleted: true, accessibilityGranted: true, resumeStep: .screenRecording))
        XCTAssertFalse(shouldShowOnboarding(hasCompleted: true, accessibilityGranted: true, resumeStep: nil))
    }

    private func temporaryDefaults() -> UserDefaults {
        let suite = "gio.tests.onboarding.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func temporaryStore() -> OnboardingStore {
        OnboardingStore(defaults: temporaryDefaults())
    }

    func testStoreConsumesTheResumeStepOnce() {
        let store = temporaryStore()
        XCTAssertNil(store.consumeResumeStep())
        store.markResume(.screenRecording)
        XCTAssertEqual(store.consumeResumeStep(), .screenRecording)
        XCTAssertNil(store.consumeResumeStep())
    }

    func testStoreClearsTheResumeStep() {
        let store = temporaryStore()
        store.markResume(.screenRecording)
        store.clearResume()
        XCTAssertNil(store.consumeResumeStep())
    }

    func testStoreIgnoresAnUnknownResumeValue() {
        let defaults = temporaryDefaults()
        defaults.set(99, forKey: OnboardingStore.resumeKey)
        XCTAssertNil(OnboardingStore(defaults: defaults).consumeResumeStep())
    }

    @MainActor
    func testPresenterReopensOnTheResumeStepOnceAfterCompletion() {
        let store = temporaryStore()
        store.markCompleted()
        store.markResume(.screenRecording)
        let presenter = OnboardingPresenter(store: store)
        presenter.evaluate(grantedFacts())
        XCTAssertTrue(presenter.isPresented)
        XCTAssertEqual(presenter.startStep, .screenRecording)
        XCTAssertNil(store.consumeResumeStep())
    }

    @MainActor
    func testPresenterStaysClosedAfterCompletionWithoutResume() {
        let store = temporaryStore()
        store.markCompleted()
        let presenter = OnboardingPresenter(store: store)
        presenter.evaluate(grantedFacts())
        XCTAssertFalse(presenter.isPresented)
        XCTAssertEqual(presenter.startStep, .welcome)
    }

    @MainActor
    func testPrepareRelaunchStoresTheStepAndFinishOrLaterClearIt() {
        let store = temporaryStore()
        let presenter = OnboardingPresenter(store: store)
        presenter.prepareRelaunch(at: .screenRecording)
        presenter.later()
        XCTAssertNil(store.consumeResumeStep())
        presenter.prepareRelaunch(at: .screenRecording)
        presenter.finish()
        XCTAssertNil(store.consumeResumeStep())
        presenter.prepareRelaunch(at: .screenRecording)
        XCTAssertEqual(store.consumeResumeStep(), .screenRecording)
    }

    @MainActor
    func testModelTracksScreenRecordingRequestAndRelaunches() {
        let relaunches = RelaunchCounter()
        var actions = DesktopActions.unavailable
        actions.relaunch = { relaunches.count += 1 }
        let model = DesktopModel(fetch: { SessionSnapshot() }, actions: actions)
        XCTAssertFalse(model.screenRecordingRequested)
        model.markScreenRecordingRequested()
        XCTAssertTrue(model.screenRecordingRequested)
        model.relaunch()
        XCTAssertEqual(relaunches.count, 1)
    }

    private func grantedFacts() -> SessionFacts {
        SessionFacts(
            configPath: "/c", configExists: true, configMessages: [], accessibilityGranted: true,
            currentWorkspace: 1, displays: [], windows: []
        )
    }

    func testKeysToKnowMatchTheDefaults() {
        let defaults = defaultHotkeyBindings()
        for key in onboardingKeys {
            // The launcher is handled by the app, not the action table.
            XCTAssertEqual(key.families.count, key.title == "Open launcher" ? 0 : key.combos.count)
            for (combo, family) in zip(key.combos, key.families) {
                XCTAssertTrue(
                    defaults.contains { $0.0 == combo && shortcutFamily(of: $0.1) == family },
                    "\(key.title): \(combo.describe())"
                )
            }
        }
        XCTAssertEqual(onboardingKeys.map(\.title), ["Focus left / right", "Maximize column", "Workspace down / up", "Open launcher"])
    }

    // MARK: - Menu bar

    private let state = BarSessionState(
        workspace: 2, windows: 5, columns: 3,
        stacks: [BarStack(display: 1, focused: true, workspaces: [
            WorkspaceEntry(index: 1, windows: 1, columns: 1, isActive: false),
            WorkspaceEntry(index: 2, windows: 5, columns: 3, isActive: true),
            WorkspaceEntry(index: 3, windows: 0, columns: 0, isActive: false),
        ])]
    )

    func testStatusBadgeIsTheWorkspaceIndex() {
        XCTAssertEqual(barBadgeText(state), "2")
        XCTAssertNil(barBadgeText(nil))
    }

    func testHeaderSummarizesTheSession() {
        let menu = barMenuModel(state)
        XCTAssertEqual(menu.title, "Gio")
        XCTAssertEqual(menu.subtitle, "Workspace 2 of 3 · 5 windows")
        XCTAssertEqual(barMenuModel(nil).subtitle, "Starting…")
        let single = BarSessionState(workspace: 4, windows: 1, columns: 1)
        XCTAssertEqual(barMenuModel(single).subtitle, "Workspace 4 · 1 window")
    }

    func testWorkspaceRowsCarryChecksAndOnlyTheFocusedDisplaySwitches() {
        var twoDisplays = state
        twoDisplays.stacks.append(BarStack(display: 2, focused: false, workspaces: [
            WorkspaceEntry(index: 1, windows: 2, columns: 2, isActive: true),
        ]))
        let menu = barMenuModel(twoDisplays)
        XCTAssertEqual(menu.sections.map(\.title), ["Display 1", "Display 2"])
        let rows = menu.sections[0].rows
        XCTAssertEqual(rows.map(\.title), ["Workspace 1", "Workspace 2", "Workspace 3"])
        XCTAssertEqual(rows.map(\.detail), ["1 window", "5 windows", "Empty"])
        XCTAssertEqual(rows.map(\.isChecked), [false, true, false])
        XCTAssertTrue(rows.allSatisfy(\.isEnabled))
        XCTAssertFalse(menu.sections[1].rows[0].isEnabled)
        XCTAssertEqual(barMenuModel(state).sections.map(\.title), ["Workspaces"])
    }

    // MARK: - Launcher selection

    func testSelectionMovesAndClamps() {
        var selection = LauncherSelection(count: 3)
        XCTAssertEqual(selection.index, 0)
        selection.moveUp()
        XCTAssertEqual(selection.index, 0)
        selection.moveDown()
        selection.moveDown()
        selection.moveDown()
        XCTAssertEqual(selection.index, 2)
        selection.reset(count: 1)
        XCTAssertEqual(selection.index, 0)
        selection.reset(count: 0)
        XCTAssertNil(selection.current)
    }

    func testCommandDigitsPickARow() {
        let selection = LauncherSelection(count: 4)
        XCTAssertEqual(selection.index(forDigit: 1), 0)
        XCTAssertEqual(selection.index(forDigit: 4), 3)
        XCTAssertNil(selection.index(forDigit: 5))
        XCTAssertNil(selection.index(forDigit: 0))
    }
}

private final class RelaunchCounter: @unchecked Sendable {
    var count = 0
}
