import SwiftUI
import SwiftData

/// Root content view with tab navigation and persistent mini-player.
///
/// The TabView **always** renders immediately to prevent any black screen.
/// First-launch onboarding shows a profile setup sheet for new installs.
struct ContentView: View {
    @Environment(PlayerManager.self) private var playerManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(\.modelContext) private var modelContext
    
    /// Show onboarding profile setup for fresh installs.
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
            .id(settingsManager.tabBarDisplayMode)
            #if os(iOS)
            .onAppear { applyTabBarTitlePosition() }
            .onChange(of: settingsManager.tabBarDisplayMode) { applyTabBarTitlePosition() }
            #endif
            .padding(.bottom, playerManager.currentEpisodeGuid != nil ? 90 : 0)
            
            // Persistent mini-player
            if playerManager.currentEpisodeGuid != nil {
                NowPlayingBar()
                    .transition(.move(edge: .bottom))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Mini player")
            }
        }
        // ── Onboarding: show profile setup on fresh installs ──
        .task {
            if !settingsManager.hasCompletedOnboarding {
                showOnboarding = true
            }
        }
        // ── First-launch onboarding: multi-page flow ──
        #if os(iOS)
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
                .environment(settingsManager)
                .environment(podcastManager)
                .environment(navigationState)
                .interactiveDismissDisabled()
        }
        #else
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environment(settingsManager)
                .environment(podcastManager)
                .environment(navigationState)
                .interactiveDismissDisabled()
                .frame(minWidth: 500, minHeight: 600)
        }
        #endif
        // ── Sync conflict resolution (shown when strategy = .ask) ──
        .sheet(isPresented: Binding(
            get: { !playerManager.pendingConflicts.isEmpty || !playerManager.pendingUrlRewrites.isEmpty },
            set: { if !$0 { playerManager.pendingConflicts.removeAll(); playerManager.pendingUrlRewrites.removeAll() } }
        )) {
            SyncConflictSheet()
                .environment(podcastManager)
                .environment(playerManager)
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
    
    /// Adjust tab bar title position — center text vertically when in text-only mode.
    #if os(iOS)
    private func applyTabBarTitlePosition() {
        let appearance = UITabBarItem.appearance()
        if settingsManager.tabBarDisplayMode == .textOnly {
            appearance.titlePositionAdjustment = UIOffset(horizontal: 0, vertical: -8)
        } else {
            appearance.titlePositionAdjustment = .zero
        }
    }
    #endif
}
