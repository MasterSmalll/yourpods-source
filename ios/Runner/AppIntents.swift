import AppIntents
import Flutter
import UIKit

@available(iOS 16.0, *)
struct PlayQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Play My Queue"
    static var description = IntentDescription("Resume playback or play your queue.")
    static var openAppWhenRun: Bool = true 

    @MainActor
    func perform() async throws -> some IntentResult {
        playQueue()
        return .result()
    }

    @MainActor
    func playQueue() {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            let controller = appDelegate.window?.rootViewController as? FlutterViewController
            let messenger = controller?.binaryMessenger ?? appDelegate.flutterEngine.binaryMessenger
            
            let channel = FlutterMethodChannel(name: "com.asecretcompany.yourpods/siri", binaryMessenger: messenger)
            channel.invokeMethod("playQueue", arguments: nil)
        }
    }
}

@available(iOS 16.0, *)
struct PlayLatestIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Latest Episode"
    static var description = IntentDescription("Play the latest episode from a specific podcast.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Podcast Name")
    var podcastName: String

    @MainActor
    func perform() async throws -> some IntentResult {
        playLatest(podcastName: podcastName)
        return .result()
    }

    @MainActor
    func playLatest(podcastName: String) {
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            let controller = appDelegate.window?.rootViewController as? FlutterViewController
           let messenger = controller?.binaryMessenger ?? appDelegate.flutterEngine.binaryMessenger
            
            let channel = FlutterMethodChannel(name: "com.asecretcompany.yourpods/siri", binaryMessenger: messenger)
            channel.invokeMethod("playLatest", arguments: podcastName)
        }
    }
}

@available(iOS 16.0, *)
struct YourPodsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayQueueIntent(),
            phrases: [
                "Play my queue in \(.applicationName)",
                "Resume playback in \(.applicationName)",
                "Play \(.applicationName)"
            ],
            shortTitle: "Play Queue",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayLatestIntent(),
            phrases: [
                "Play latest episode of \(\.$podcastName) in \(.applicationName)",
                "Play podcast \(\.$podcastName) in \(.applicationName)"
            ],
            shortTitle: "Play Podcast",
            systemImageName: "mic.circle.fill"
        )
    }
}
