import Foundation
import OSLog

/// A playback command issued by the Home Screen widget's interactive controls.
enum WidgetPlaybackCommand: Equatable, Sendable {
    case togglePlay
    case skipForward
    case skipBackward
}

/// In-process bridge that lets the Home Screen widget's `AudioPlaybackIntent`s
/// drive the live audio engine **directly and awaitably**, instead of firing a
/// `NotificationCenter` notification and returning before any audio starts.
///
/// `AudioPlaybackIntent.perform()` is run by the system in the **app's** process
/// (not the widget extension), so the singleton the intent reaches is the same
/// instance the app installs a handler on at launch. Crucially, `perform()`
/// `await`s `perform(_:)` here, so playback is actually playing/paused **before**
/// the intent returns `.result()`.
///
/// That await is the whole fix: with a fire-and-forget notification, `perform()`
/// returns before any audio is established. When the app was suspended/killed,
/// the system launches it solely to service the intent, the intent completes
/// having started no audio, and iOS foregrounds the app to let it begin — which
/// users see as "tapping the widget opens the app instead of playing/pausing."
///
/// In the widget-extension process `handler` is nil, so calls are graceful no-ops.
@MainActor
final class WidgetPlaybackBridge {
    static let shared = WidgetPlaybackBridge()
    private init() {}

    /// Installed by the app at launch. `nil` in the widget-extension process.
    var handler: (@MainActor (WidgetPlaybackCommand) async -> Void)?

    /// Runs `command` against the installed handler and waits for it to finish.
    func perform(_ command: WidgetPlaybackCommand) async {
        // DIAGNOSTIC (temporary): handlerSet=false means we are NOT in the app
        // process (or the app never installed the handler) — the command is a no-op
        // and the live audio engine is never touched.
        Logger(subsystem: "com.yourpods", category: "widget").notice(
            "⟦bridge⟧ \(String(describing: command), privacy: .public) handlerSet=\(self.handler != nil) bundle=\(Bundle.main.bundleIdentifier ?? "?", privacy: .public)")
        await handler?(command)
    }
}
