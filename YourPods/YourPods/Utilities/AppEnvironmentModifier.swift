import SwiftUI

/// A view modifier that injects all shared app environment objects into a view.
///
/// On macOS, SwiftUI `.sheet()` and `.fullScreenCover()` create a new window
/// that does NOT inherit `@Observable` environments from the parent view hierarchy.
/// This modifier provides a reusable way to inject all required environments
/// into any presented view (sheets, covers, navigation destinations).
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $show) {
///     SomeView()
///         .injectAppEnvironment(
///             settings: settings,
///             podcastManager: podcastManager,
///             playerManager: playerManager,
///             downloadManager: downloadManager
///         )
/// }
/// ```
struct AppEnvironmentModifier: ViewModifier {
    let settings: SettingsManager?
    let podcastManager: PodcastManager?
    let playerManager: PlayerManager?
    let downloadManager: DownloadManager?
    let sleepTimer: SleepTimerManager?
    let navigationState: NavigationState?
    
    func body(content: Content) -> some View {
        var view = AnyView(content)
        if let settings { view = AnyView(view.environment(settings)) }
        if let podcastManager { view = AnyView(view.environment(podcastManager)) }
        if let playerManager { view = AnyView(view.environment(playerManager)) }
        if let downloadManager { view = AnyView(view.environment(downloadManager)) }
        if let sleepTimer { view = AnyView(view.environment(sleepTimer)) }
        if let navigationState { view = AnyView(view.environment(navigationState)) }
        return view
    }
}

extension View {
    /// Inject all available app environment objects.
    ///
    /// Pass only the environments that are available in the current scope.
    /// On macOS, this is **required** for all `.sheet()` presentations
    /// because sheets don't inherit `@Observable` environments.
    func injectAppEnvironment(
        settings: SettingsManager? = nil,
        podcastManager: PodcastManager? = nil,
        playerManager: PlayerManager? = nil,
        downloadManager: DownloadManager? = nil,
        sleepTimer: SleepTimerManager? = nil,
        navigationState: NavigationState? = nil
    ) -> some View {
        modifier(AppEnvironmentModifier(
            settings: settings,
            podcastManager: podcastManager,
            playerManager: playerManager,
            downloadManager: downloadManager,
            sleepTimer: sleepTimer,
            navigationState: navigationState
        ))
    }
}
