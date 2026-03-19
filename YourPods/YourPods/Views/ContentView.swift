import SwiftUI
import SwiftData

/// Root content view with tab navigation and persistent mini-player.
///
/// The TabView **always** renders immediately to prevent any black screen.
/// Migration runs inline on first appear, and a fullScreenCover dialog
/// is shown afterwards if Flutter data was detected.
struct ContentView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    
    /// Show the migration success dialog (fullScreenCover).
    @State private var showMigrationDialog = false
    /// True when the migrated profile is a server profile (needs password re-entry).
    @State private var migratedServerProfile = false
    /// Show profile edit sheet after the user taps "Continue" in migration dialog.
    @State private var showProfileSheet = false
    /// Prevent migration from running more than once per app session.
    @State private var migrationChecked = false
    /// Show onboarding profile setup for fresh installs (no migration data).
    @State private var showOnboarding = false
    
    var body: some View {
        @Bindable var nav = navigationState
        
        // ── TabView always renders — no black screen possible ──
        ZStack(alignment: .bottom) {
            TabView(selection: $nav.selectedTab) {
                HomeView()
                    .tabItem {
                        tabLabel("Home", systemImage: "house.fill")
                    }
                    .tag(0)
                
                LibraryView()
                    .tabItem {
                        tabLabel("Library", systemImage: "books.vertical.fill")
                    }
                    .tag(1)
                
                QueueView()
                    .tabItem {
                        tabLabel("Up Next", systemImage: "list.bullet")
                    }
                    .tag(2)
                
                PodcastSearchView()
                    .tabItem {
                        tabLabel("Add Podcasts", systemImage: "plus.circle")
                    }
                    .tag(3)
                
                SettingsView()
                    .tabItem {
                        tabLabel("Settings", systemImage: "gear")
                    }
                    .tag(4)
            }
            .padding(.bottom, playerManager.currentEpisodeGuid != nil ? 90 : 0)
            
            // Persistent mini-player
            if playerManager.currentEpisodeGuid != nil {
                NowPlayingBar()
                    .transition(.move(edge: .bottom))
            }
        }
        // ── Migration / Onboarding: runs once, shows dialog if needed ──
        .task {
            guard !migrationChecked else { return }
            migrationChecked = true
            
            // Give the UI a moment to render the first frame (the TabView).
            // This prevents a black screen on launch if the synchronous 
            // migration takes several seconds on the main thread.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            
            if FlutterDataMigrator.needsMigration {
                let hasServerProfile = FlutterDataMigrator.migrateIfNeeded(
                    podcastManager: podcastManager,
                    settingsManager: settingsManager,
                    modelContext: modelContext
                )
                
                podcastManager.loadSubscriptions()
                
                // Migration creates profiles — mark onboarding as done
                settingsManager.hasCompletedOnboarding = true
                
                migratedServerProfile = hasServerProfile
                showMigrationDialog = true
            } else if !settingsManager.hasCompletedOnboarding {
                // Fresh install with no migration data — show onboarding
                showOnboarding = true
            }
        }
        // ── Migration success dialog ──
        .fullScreenCover(isPresented: $showMigrationDialog) {
            MigrationWelcomeView(hasServerProfile: migratedServerProfile) {
                showMigrationDialog = false
                if migratedServerProfile {
                    // Give the cover a moment to dismiss, then open profile sheet
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        navigationState.selectedTab = 4
                        showProfileSheet = true
                    }
                }
            }
        }
        // ── Profile sheet (for post-migration password re-entry) ──
        .sheet(isPresented: $showProfileSheet) {
            NavigationStack {
                ProfileSelectionView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showProfileSheet = false }
                        }
                    }
            }
        }
        // ── First-launch onboarding: require profile before use ──
        .fullScreenCover(isPresented: $showOnboarding) {
            ProfileSelectionView(isOnboarding: true)
                .interactiveDismissDisabled()
        }
        // ── Sync conflict resolution (shown when strategy = .ask) ──
        .sheet(isPresented: Binding(
            get: { !playerManager.pendingConflicts.isEmpty },
            set: { if !$0 { playerManager.pendingConflicts.removeAll() } }
        )) {
            SyncConflictSheet()
        }
    }
    
    // MARK: - Tab Bar Display Mode
    
    @ViewBuilder
    private func tabLabel(_ title: String, systemImage: String) -> some View {
        switch settingsManager.tabBarDisplayMode {
        case .textOnly:
            Text(title)
        case .iconOnly:
            Image(systemName: systemImage)
        case .textAndIcon:
            Label(title, systemImage: systemImage)
        }
    }
}
