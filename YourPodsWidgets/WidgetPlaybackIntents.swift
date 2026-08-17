import AppIntents
import WidgetKit
import OSLog

// DIAGNOSTIC (temporary — remove once the "widget pause opens the app" root cause is
// confirmed): records which PROCESS actually runs each intent. If `bundle` is the
// app's (com.asecretcompany.yourpods), the intent reached the app process and the
// in-process bridge handler should be wired. If `bundle` is the widget extension's,
// AudioPlaybackIntent did NOT route to the app — the bridge handler is nil there, the
// audio engine is never touched, and iOS foregrounds the app to "finish" the action.
private let diagLog = Logger(subsystem: "com.yourpods", category: "widget")
private func diagProcessTag() -> String {
    "bundle=\(Bundle.main.bundleIdentifier ?? "?") pid=\(ProcessInfo.processInfo.processIdentifier)"
}

// MARK: - Widget Playback Intents (AudioPlaybackIntent + iOS 26 supportedModes)
//
// iOS 26 note: `supportedModes { [.background] }` + explicit `openAppWhenRun = false`
// mirrors Pocket Casts' shipped fix for "widget play sends the app to the foreground"
// on iOS 26 (Automattic/pocket-casts-ios PR #3846, released in 8.3) — the only
// known-shipping AudioPlaybackIntent widget configuration on iOS 26. Declaring
// `.foreground(.dynamic)` as well registers the ForegroundContinuable
// route, which invites the system to foreground; background-only keeps perform() in
// the app process without foregrounding. supportedModes is availability-guarded
// (IntentModes is iOS 26+); AudioPlaybackIntent is retained for its background
// audio-start grant.
//
// Used by the Home Screen widget's Button(intent:) controls. Conforming to
// AudioPlaybackIntent makes the system run perform() in the *main app's* process
// (not the widget extension), so each intent can reach the live audio engine
// through WidgetPlaybackBridge. AudioPlaybackIntent is retained deliberately: it
// is the only one of the four app-process protocols that also grants a
// background-launched process permission to activate AVAudioSession and start
// audio, which the play-from-suspended (cold-play) path needs.
//
// These structs are `public` (and so are their protocol witnesses). On a RELEASE
// build the AppIntents metadata processor can fail to register an `internal`
// widget intent, so iOS finds no dispatchable intent for the button tap and just
// launches the app — perform() never runs. That exactly matched the captured
// signature: app foregrounds, zero ⟦intent⟧ markers. Making
// the intents public is protocol-independent and preserves the audio-start grant,
// so it fixes that failure mode without risking cold-play (unlike swapping to
// LiveActivityIntent / ForegroundContinuableIntent, which share the same dispatch
// path but drop the audio grant). See Apple Developer Forums 731852 / 674287.
//
// Each intent updates ComplicationDataStore + reloads the timeline first for
// instant visual feedback, then AWAITS the bridge so playback is actually
// playing/paused before perform() returns .result(). The await is load-bearing:
// a fire-and-forget NotificationCenter post returns before any audio starts, so
// when the app was suspended iOS launches it to service the intent, finds no
// audio established, and foregrounds the app — the "tapping the widget opens the
// app instead of acting" bug. See WidgetPlaybackBridge for the full rationale.

@available(iOS 17.0, *)
public struct WidgetTogglePlayIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Toggle Playback"
    public static var description = IntentDescription("Play or pause the current episode.")

    // iOS-26-native dispatch route (see file header): background-only, never foreground.
    public static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { [.background] }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        diagLog.notice("⟦intent⟧ TogglePlay START \(diagProcessTag(), privacy: .public)")  // DIAGNOSTIC
        // Flip state in the data store immediately so the widget re-renders with
        // the correct icon before the audio pipeline catches up.
        let store = ComplicationDataStore.shared
        var data = store.read()
        data.isPlaying.toggle()
        store.write(data)
        WidgetCenter.shared.reloadTimelines(ofKind: "YourPodsPlayback")

        // Drive — and wait for — the actual toggle in the app process.
        await WidgetPlaybackBridge.shared.perform(.togglePlay)
        diagLog.notice("⟦intent⟧ TogglePlay END")  // DIAGNOSTIC
        return .result()
    }
}

@available(iOS 17.0, *)
public struct WidgetSkipForwardIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Skip Forward"
    public static var description = IntentDescription("Skip forward 30 seconds.")

    public static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { [.background] }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        diagLog.notice("⟦intent⟧ SkipForward START \(diagProcessTag(), privacy: .public)")  // DIAGNOSTIC
        // Optimistically advance the position in the data store.
        let store = ComplicationDataStore.shared
        var data = store.read()
        data.positionSeconds = min(data.positionSeconds + 30, data.durationSeconds)
        store.write(data)
        WidgetCenter.shared.reloadTimelines(ofKind: "YourPodsPlayback")

        await WidgetPlaybackBridge.shared.perform(.skipForward)
        diagLog.notice("⟦intent⟧ SkipForward END")  // DIAGNOSTIC
        return .result()
    }
}

@available(iOS 17.0, *)
public struct WidgetSkipBackwardIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Skip Backward"
    public static var description = IntentDescription("Skip backward 15 seconds.")

    public static var openAppWhenRun: Bool { false }

    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { [.background] }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        diagLog.notice("⟦intent⟧ SkipBackward START \(diagProcessTag(), privacy: .public)")  // DIAGNOSTIC
        // Optimistically rewind the position in the data store.
        let store = ComplicationDataStore.shared
        var data = store.read()
        data.positionSeconds = max(data.positionSeconds - 15, 0)
        store.write(data)
        WidgetCenter.shared.reloadTimelines(ofKind: "YourPodsPlayback")

        await WidgetPlaybackBridge.shared.perform(.skipBackward)
        diagLog.notice("⟦intent⟧ SkipBackward END")  // DIAGNOSTIC
        return .result()
    }
}
