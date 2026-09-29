import Combine
import SwiftUI

/// A section's ticker: exists only while the main window is visible and the
/// section is on screen (see `shouldPoll`). Hidden or off-screen, the
/// `Timer` publisher is not even created, so there are no wakeups.
private struct PollWhileVisible: ViewModifier {
    @ObservedObject var model: DesktopModel
    let interval: TimeInterval
    let action: () -> Void
    @State private var onScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .background {
                if shouldPoll(windowVisible: model.windowVisible, sectionOnScreen: onScreen) {
                    PollTicker(interval: interval, action: action)
                }
            }
    }
}

private struct PollTicker: View {
    let action: () -> Void
    @State private var ticker: Publishers.Autoconnect<Timer.TimerPublisher>

    init(interval: TimeInterval, action: @escaping () -> Void) {
        self.action = action
        _ticker = State(initialValue: Timer.publish(every: interval, tolerance: interval / 2, on: .main, in: .common).autoconnect())
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).onReceive(ticker) { _ in action() }
    }
}

extension View {
    /// Run `action` every `interval` seconds, only while the main window is
    /// visible and this view is on screen.
    func pollWhileVisible(_ model: DesktopModel, every interval: TimeInterval, _ action: @escaping () -> Void) -> some View {
        modifier(PollWhileVisible(model: model, interval: interval, action: action))
    }
}
