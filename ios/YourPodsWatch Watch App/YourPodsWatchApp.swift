import SwiftUI
import WatchKit

@main
struct YourPodsWatch_Watch_AppApp: App {
    @StateObject private var sessionManager = WatchSessionManager()
    @StateObject private var backgroundRefresh = BackgroundRefreshManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .onAppear {
                    // Schedule first background refresh on launch
                    backgroundRefresh.scheduleNextRefresh()
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshManager.refreshTaskId)) {
            await withCheckedContinuation { continuation in
                BackgroundRefreshManager.shared.handleRefresh {
                    continuation.resume()
                }
            }
        }
    }
}
