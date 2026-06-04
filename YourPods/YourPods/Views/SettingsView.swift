import SwiftUI
import UniformTypeIdentifiers

/// Comprehensive settings screen with all app preferences.
struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    
    @State private var showProfileSelection = false

    @State private var isExportingOPML = false
    @State private var isImportingOPML = false
    @State private var showOPMLExport = false
    @State private var opmlExportURL: URL?
    @State private var isPushing = false
    @State private var isPulling = false
    @State private var showNotificationModePrompt = false
    
    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Account
                Section {
                    Button {
                        showProfileSelection = true
                    } label: {
                        Label("Manage Profiles", systemImage: "person.crop.circle")
                    }
                    
                    // Sync settings
                    Stepper("Sync Interval: \(settings.syncInterval)s",
                            value: Binding(
                                get: { settings.syncInterval },
                                set: { settings.syncInterval = $0 }
                            ), in: 10...300, step: 10)
                    
                    Picker("Conflict Resolution", selection: Binding(
                        get: { settings.syncConflictStrategy },
                        set: { settings.syncConflictStrategy = $0 }
                    )) {
                        Text("Always Server").tag(SyncStrategy.serverWins)
                        Text("Always Device").tag(SyncStrategy.deviceWins)
                        Text("Ask").tag(SyncStrategy.ask)
                    }
                    
                    Picker("Queue Sync Strategy", selection: Binding(
                        get: { settings.queueSyncStrategy },
                        set: { settings.queueSyncStrategy = $0 }
                    )) {
                        Text("Always Server").tag(QueueSyncStrategy.serverWins)
                        Text("Always Device").tag(QueueSyncStrategy.deviceWins)
                        Text("Ask").tag(QueueSyncStrategy.ask)
                    }
                    
                    // Force sync buttons
                    Button {
                        Task {
                            isPushing = true
                            // Force Push: push subscriptions AND episode actions to server
                            let conflicts = await podcastManager.forcePushToServer()
                            if !conflicts.isEmpty {
                                playerManager.pendingConflicts = conflicts
                            }
                            isPushing = false
                        }
                    } label: {
                        HStack {
                            Label("Force Push to Server", systemImage: "arrow.up.circle")
                            if isPushing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPushing || isPulling)
                    
                    Button {
                        Task {
                            isPulling = true
                            // Force Pull: reset timestamps and sync subscriptions + episode actions
                            let strategy = settings.syncConflictStrategy
                            let conflicts = try? await podcastManager.forcePullFromServer(
                                strategy: strategy
                            )
                            if let conflicts, !conflicts.isEmpty, strategy == .ask {
                                playerManager.pendingConflicts = conflicts
                            }
                            isPulling = false
                        }
                    } label: {
                        HStack {
                            Label("Force Pull from Server", systemImage: "arrow.down.circle")
                            if isPulling {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPushing || isPulling)
                    
                    NavigationLink {
                        EpisodeActivityView()
                    } label: {
                        Label("Episode Activity", systemImage: "waveform")
                    }
                    
                    NavigationLink {
                        AboutSyncView()
                    } label: {
                        Label("About Account Types", systemImage: "info.circle")
                    }
                    
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("Listening Stats", systemImage: "chart.bar")
                    }
                } header: {
                    Label("Account", systemImage: "person.circle")
                }
                
                // MARK: - Appearance
                Section {
                    Picker("Appearance", selection: Binding(
                        get: { settings.appearance },
                        set: { settings.appearance = $0 }
                    )) {
                        Text("System").tag(AppAppearance.system)
                        Text("Light").tag(AppAppearance.light)
                        Text("Dark").tag(AppAppearance.dark)
                    }
                    
                    #if os(iOS)
                    Picker("Tab Bar Style", selection: Binding(
                        get: { settings.tabBarDisplayMode },
                        set: { settings.tabBarDisplayMode = $0 }
                    )) {
                        Text("Text Only").tag(TabBarDisplayMode.textOnly)
                        Text("Icon Only").tag(TabBarDisplayMode.iconOnly)
                        Text("Text & Icon").tag(TabBarDisplayMode.textAndIcon)
                    }
                    #endif
                    
                    Picker("Start Page", selection: Binding(
                        get: { settings.defaultStartPage },
                        set: { settings.defaultStartPage = $0 }
                    )) {
                        Text("Home").tag("home")
                        Text("Library").tag("library")
                        Text("Up Next").tag("upnext")
                    }
                } header: {
                    Label("Appearance", systemImage: "paintbrush")
                }
                
                // MARK: - Storage
                Section {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Label("Storage", systemImage: "internaldrive")
                }
                
                // MARK: - Playback
                Section {
                    HStack {
                        Text("Playback Speed")
                        Spacer()
                        Text("\(settings.playbackSpeed, specifier: "%.1f")×")
                            .foregroundStyle(.secondary)
                    }
                    
                    SkipDurationPicker(
                        label: "Skip Forward",
                        seconds: Binding(
                            get: { settings.skipForwardSeconds },
                            set: { settings.skipForwardSeconds = $0 }
                        )
                    )
                    
                    SkipDurationPicker(
                        label: "Skip Back",
                        seconds: Binding(
                            get: { settings.skipBackwardSeconds },
                            set: { settings.skipBackwardSeconds = $0 }
                        )
                    )
                    
                    Stepper("Skip Intro: \(settings.skipIntroSeconds)s",
                            value: Binding(
                                get: { settings.skipIntroSeconds },
                                set: { settings.skipIntroSeconds = $0 }
                            ), in: 0...999, step: 5)
                    
                    Stepper("Skip Outro: \(settings.skipOutroSeconds)s",
                            value: Binding(
                                get: { settings.skipOutroSeconds },
                                set: { settings.skipOutroSeconds = $0 }
                            ), in: 0...999, step: 5)
                    
                    NavigationLink {
                        P3SettingsView()
                    } label: {
                        Label("P3", systemImage: "shield.checkered")
                    }
                } header: {
                    Label("Playback", systemImage: "play.circle")
                }
                
                // MARK: - Headphone Controls
                Section {
                    Picker("Next Track", selection: Binding(
                        get: { settings.nextTrackAction },
                        set: {
                            settings.nextTrackAction = $0
                            playerManager.audioManager.nextTrackAction = $0
                        }
                    )) {
                        Text("Next Episode").tag(RemoteCommandAction.nextEpisode)
                        Text("Skip Forward").tag(RemoteCommandAction.skipForward)
                        Text("Skip Back").tag(RemoteCommandAction.skipBack)
                    }
                    
                    Picker("Previous Track", selection: Binding(
                        get: { settings.previousTrackAction },
                        set: {
                            settings.previousTrackAction = $0
                            playerManager.audioManager.previousTrackAction = $0
                        }
                    )) {
                        Text("Skip Back").tag(RemoteCommandAction.skipBack)
                        Text("Restart Episode").tag(RemoteCommandAction.previousEpisode)
                        Text("Next Episode").tag(RemoteCommandAction.nextEpisode)
                        Text("Skip Forward").tag(RemoteCommandAction.skipForward)
                    }
                } header: {
                    Label("Headphone Controls", systemImage: "headphones")
                } footer: {
                    Text("Controls AirPods double/triple-tap and lock screen previous/next. Skip durations use your Playback settings above (\(settings.skipBackwardSeconds)s back, \(settings.skipForwardSeconds)s forward).")
                }
                
                // MARK: - Feed Cache
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cache Duration: \(settings.feedCacheDurationHours) hours")
                        Slider(
                            value: Binding(
                                get: { Double(settings.feedCacheDurationHours) },
                                set: { settings.feedCacheDurationHours = Int($0) }
                            ),
                            in: 1...48,
                            step: 1
                        )
                    }
                    
                    Text("Pull-to-refresh bypasses cache and fetches fresh data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Feed Cache", systemImage: "clock.arrow.circlepath")
                }
                
                // MARK: - New Podcast Defaults
                Section {
                    Picker("AutoPilot Mode", selection: Binding(
                        get: { settings.defaultAutoQueueMode },
                        set: { settings.defaultAutoQueueMode = $0 }
                    )) {
                        ForEach(AutoQueueMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    
                    Toggle("Auto-Download New Episodes", isOn: Binding(
                        get: { settings.defaultAutoDownload },
                        set: { settings.defaultAutoDownload = $0 }
                    ))
                    
                    Picker("Download Network", selection: Binding(
                        get: { settings.autoDownloadNetworkPolicy },
                        set: { settings.autoDownloadNetworkPolicy = $0 }
                    )) {
                        ForEach(AutoDownloadNetworkPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    Picker("Download Cleanup", selection: Binding(
                        get: { settings.defaultDownloadCleanupPolicy },
                        set: { settings.defaultDownloadCleanupPolicy = $0 }
                    )) {
                        ForEach(DownloadCleanupPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    
                    Toggle("Archive on Complete", isOn: Binding(
                        get: { settings.defaultArchiveOnComplete },
                        set: { settings.defaultArchiveOnComplete = $0 }
                    ))
                } header: {
                    Label("New Podcast Defaults", systemImage: "star")
                }
                
                // MARK: - Queue Management
                Section {
                    Picker("On Queue Removal", selection: Binding(
                        get: { settings.queueRemovalAction },
                        set: { settings.queueRemovalAction = $0 }
                    )) {
                        Text("Just Remove").tag(QueueRemovalAction.removeOnly)
                        Text("Remove & Mark Played").tag(QueueRemovalAction.removeAndMarkPlayed)
                        Text("Always Ask").tag(QueueRemovalAction.ask)
                    }
                } header: {
                    Label("Queue Management", systemImage: "list.bullet")
                } footer: {
                    Text("Choose what happens when you remove an episode from the Up Next queue.")
                }
                
                // MARK: - Search Provider
                Section {
                    Picker("Provider", selection: Binding(
                        get: { settings.searchProvider },
                        set: { settings.searchProvider = $0 }
                    )) {
                        Text("Apple Podcasts (iTunes)").tag(SearchProvider.itunes)
                        Text("Podcast Index").tag(SearchProvider.podcastIndex)
                    }
                    
                    if settings.searchProvider == .podcastIndex {
                        TextField("API Key", text: Binding(
                            get: { settings.podcastIndexApiKey ?? "" },
                            set: { settings.podcastIndexApiKey = $0.isEmpty ? nil : $0 }
                        ))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        
                        RevealableSecureField(label: "API Secret", text: Binding(
                            get: { settings.podcastIndexApiSecret ?? "" },
                            set: { settings.podcastIndexApiSecret = $0.isEmpty ? nil : $0 }
                        ))
                        .textContentType(.password)
                        
                        Link("Get API Keys", destination: URL(string: "https://api.podcastindex.org")!)
                            .font(.caption)
                    }
                } header: {
                    Label("Search Provider", systemImage: "magnifyingglass")
                }
                
                #if os(iOS)
                // MARK: - Apple Watch
                Section {
                    Toggle("Sync to Apple Watch", isOn: Binding(
                        get: { settings.watchSyncEnabled },
                        set: { settings.watchSyncEnabled = $0 }
                    ))
                    
                    if settings.watchSyncEnabled {
                        Stepper("Podcasts to Sync: \(settings.watchSyncPodcastLimit)",
                                value: Binding(
                                    get: { settings.watchSyncPodcastLimit },
                                    set: { settings.watchSyncPodcastLimit = $0 }
                                ), in: 1...20)
                        
                        Picker("Position Sync Interval", selection: Binding(
                            get: { settings.watchPositionSyncInterval },
                            set: { settings.watchPositionSyncInterval = $0 }
                        )) {
                            Text("10 seconds").tag(10)
                            Text("15 seconds").tag(15)
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                        }
                        
                        Toggle("Wi-Fi Only Downloads", isOn: Binding(
                            get: { settings.watchDownloadWiFiOnly },
                            set: { settings.watchDownloadWiFiOnly = $0 }
                        ))
                    }
                } header: {
                    Label("Apple Watch", systemImage: "applewatch")
                } footer: {
                    Text("Wi-Fi Only Downloads saves watch battery by avoiding cellular radio for episode downloads.")
                }
                #endif
                
                #if os(iOS)
                // MARK: - Background Refresh
                Section {
                    Toggle("Background Refresh", isOn: Binding(
                        get: { settings.backgroundRefreshEnabled },
                        set: { settings.backgroundRefreshEnabled = $0 }
                    ))
                    
                    if settings.backgroundRefreshEnabled {
                        Picker("Interval", selection: Binding(
                            get: { settings.backgroundRefreshInterval },
                            set: { settings.backgroundRefreshInterval = $0 }
                        )) {
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                            Text("2 hours").tag(120)
                            Text("4 hours").tag(240)
                        }
                        
                        Toggle("New Episode Notifications", isOn: Binding(
                            get: { settings.newEpisodeNotificationsEnabled },
                            set: { newValue in
                                if newValue {
                                    // Temporarily enable so toggle stays "on" while dialog shows.
                                    // Revert on Cancel.
                                    settings.newEpisodeNotificationsEnabled = true
                                    showNotificationModePrompt = true
                                } else {
                                    settings.newEpisodeNotificationsEnabled = false
                                }
                            }
                        ))
                        .accessibilityLabel("New Episode Notifications")
                        .accessibilityHint("Get notified when new episodes are found during background refresh")
                        
                        Toggle("App Badge", isOn: Binding(
                            get: { settings.appBadgeEnabled },
                            set: { newValue in
                                settings.appBadgeEnabled = newValue
                                if newValue {
                                    // Badge API requires notification authorization
                                    Task {
                                        _ = await NewEpisodeNotificationService.shared.requestPermissionIfNeeded()
                                        await BadgeService.shared.updateBadgeCount()
                                    }
                                } else {
                                    // Clear badge immediately when disabled
                                    Task {
                                        await BadgeService.shared.updateBadgeCount()
                                    }
                                }
                            }
                        ))
                        .accessibilityLabel("App Badge")
                        .accessibilityHint("Show unplayed episode count on the app icon")
                    }
                } header: {
                    Label("Background Refresh", systemImage: "arrow.clockwise")
                } footer: {
                    if settings.backgroundRefreshEnabled {
                        if settings.newEpisodeNotificationsEnabled && settings.appBadgeEnabled {
                            Text("Notifications and badges are 100% local — nothing is sent to any server. Enable notifications per podcast in Library → Podcast → Listening Profile → Notifications.")
                        } else if settings.newEpisodeNotificationsEnabled {
                            Text("Notifications are 100% local — nothing is sent to any server. Enable per podcast in Library → Podcast → Listening Profile → Notifications.")
                        } else if settings.appBadgeEnabled {
                            Text("The app icon shows the number of unplayed episodes across all your subscriptions.")
                        }
                    }
                }
                .confirmationDialog(
                    "How would you like to receive notifications?",
                    isPresented: $showNotificationModePrompt,
                    titleVisibility: .visible
                ) {
                    Button("All Podcasts") {
                        podcastManager.enableNotificationsForAllPodcasts()
                        Task {
                            await NewEpisodeNotificationService.shared.requestPermissionIfNeeded()
                        }
                    }
                    Button("Let Me Choose") {
                        // Toggle stays on; podcasts stay at default (silent).
                        Task {
                            await NewEpisodeNotificationService.shared.requestPermissionIfNeeded()
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        // Revert — user changed their mind
                        settings.newEpisodeNotificationsEnabled = false
                    }
                } message: {
                    Text("\"All Podcasts\" enables notifications for every podcast you're subscribed to. \"Let Me Choose\" keeps them off — turn on per podcast in Library → Podcast → Listening Profile.")
                }
                #endif
                
                // MARK: - Data
                Section {
                    Button {
                        exportOPML()
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isExportingOPML)
                    
                    Button {
                        isImportingOPML = true
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Label("Data", systemImage: "externaldrive")
                } footer: {
                    if let profileName = settings.activeProfile?.name {
                        Text("Exporting and importing for profile: \(profileName)")
                    }
                }

                
                // MARK: - Siri Commands
                Section {
                    Text("Use these voice commands with Siri to control YourPods hands-free.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                    
                    // Playback
                    SiriCommandRow(
                        icon: "play.circle.fill",
                        title: "Play / Resume",
                        phrases: ["\"Play YourPods\"", "\"Resume YourPods\""]
                    )
                    SiriCommandRow(
                        icon: "pause.circle.fill",
                        title: "Pause",
                        phrases: ["\"Pause YourPods\""]
                    )
                    SiriCommandRow(
                        icon: "stop.circle.fill",
                        title: "Stop",
                        phrases: ["\"Stop YourPods\""]
                    )
                    
                    // Navigation
                    SiriCommandRow(
                        icon: "goforward.30",
                        title: "Skip Forward",
                        phrases: ["\"Skip forward in YourPods\""]
                    )
                    SiriCommandRow(
                        icon: "gobackward.15",
                        title: "Skip Backward",
                        phrases: ["\"Rewind in YourPods\""]
                    )
                    SiriCommandRow(
                        icon: "forward.end.fill",
                        title: "Next Episode",
                        phrases: ["\"Next episode in YourPods\""]
                    )
                    SiriCommandRow(
                        icon: "sparkles",
                        title: "Play Latest Episode",
                        phrases: ["\"Play latest episode in YourPods\""]
                    )
                    
                    // Speed
                    SiriCommandRow(
                        icon: "gauge.with.dots.needle.67percent",
                        title: "Set Playback Speed",
                        phrases: ["\"Set playback speed to 1.5 in YourPods\""]
                    )
                    
                    // Timer
                    SiriCommandRow(
                        icon: "moon.zzz.fill",
                        title: "Set Sleep Timer",
                        phrases: ["\"Set sleep timer to 30 minutes in YourPods\""]
                    )
                    SiriCommandRow(
                        icon: "moon.fill",
                        title: "Cancel Sleep Timer",
                        phrases: ["\"Cancel sleep timer in YourPods\""]
                    )
                    
                    // Info
                    SiriCommandRow(
                        icon: "info.circle.fill",
                        title: "What's Playing",
                        phrases: ["\"What's playing in YourPods?\""]
                    )
                } header: {
                    Label("Siri Commands", systemImage: "mic.circle")
                } footer: {
                    Text("Say \"Hey Siri\" followed by any command above. You can also add these as Shortcuts in the Shortcuts app.")
                }
                
                // MARK: - About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Build")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("About", systemImage: "info.circle")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .sheet(isPresented: $showProfileSelection) {
                ProfileSelectionView()
                    .environment(settings)
                    .environment(podcastManager)
            }

            .sheet(isPresented: $showOPMLExport) {
                if let url = opmlExportURL {
                    ShareSheet(url: url)
                }
            }
            .fileImporter(
                isPresented: $isImportingOPML,
                allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
                allowsMultipleSelection: false
            ) { result in
                handleOPMLImport(result)
            }
        }
    }
    
    private func exportOPML() {
        isExportingOPML = true
        let profileId = settings.activeProfileId ?? "global"
        let groups = PodcastGroup.loadGroups(forProfileId: profileId)
        let xml = OPMLService.export(
            podcasts: podcastManager.subscriptions,
            groups: groups,
            profileName: settings.activeProfile?.name
        )
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("yourpods_subscriptions.opml")
        
        do {
            try xml.write(to: fileURL, atomically: true, encoding: .utf8)
            opmlExportURL = fileURL
            showOPMLExport = true
        } catch {
            // Silently fail
        }
        isExportingOPML = false
    }
    
    private func handleOPMLImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            
            if let data = try? Data(contentsOf: url) {
                let importResult = OPMLService.parseWithGroups(from: data)
                let profileId = settings.activeProfileId ?? "global"
                
                // Import groups if present
                if !importResult.groups.isEmpty {
                    var existingGroups = PodcastGroup.loadGroups(forProfileId: profileId)
                    for importedGroup in importResult.groups {
                        if !existingGroups.contains(where: { $0.name == importedGroup.name }) {
                            existingGroups.append(importedGroup)
                        }
                    }
                    PodcastGroup.saveGroups(existingGroups, forProfileId: profileId)
                }
                
                // Collect all feed URLs (grouped + ungrouped)
                let allGroupedUrls = importResult.groupedUrls  // [groupName: [url]]
                let allUngroupedUrls = importResult.ungroupedUrls
                
                // Subscribe to grouped podcasts and assign group + settings
                for (groupName, feedUrls) in allGroupedUrls {
                    for feedUrl in feedUrls {
                        Task {
                            try? await podcastManager.addSubscription(url: feedUrl)
                            applyImportSettings(
                                url: feedUrl, groupName: groupName,
                                podcastSettings: importResult.podcastSettings,
                                profileId: profileId
                            )
                        }
                    }
                }
                
                // Subscribe to ungrouped podcasts and apply settings only
                for feedUrl in allUngroupedUrls {
                    Task {
                        try? await podcastManager.addSubscription(url: feedUrl)
                        applyImportSettings(
                            url: feedUrl, groupName: nil,
                            podcastSettings: importResult.podcastSettings,
                            profileId: profileId
                        )
                    }
                }
            }
        case .failure:
            break
        }
    }
    
    /// Apply per-podcast settings and group assignment from an OPML import.
    private func applyImportSettings(
        url: String,
        groupName: String?,
        podcastSettings: [String: PodcastSettings],
        profileId: String
    ) {
        guard let podcast = podcastManager.subscriptions.first(where: { $0.url == url }) else { return }
        
        // Apply per-podcast settings
        if let importedSettings = podcastSettings[url] {
            podcast.settings = importedSettings
        }
        
        // Assign to group
        if let groupName {
            let groups = PodcastGroup.loadGroups(forProfileId: profileId)
            if let group = groups.first(where: { $0.name == groupName }) {
                podcast.groupId = group.id
            }
        }
        
        try? podcastManager.saveContext()
    }
}

// MARK: - Share Sheet

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
#else
struct ShareSheet: View {
    let url: URL
    var body: some View {
        Text("Export saved to: \(url.lastPathComponent)")
            .padding()
    }
}
#endif

// MARK: - Skip Duration Picker

/// Picker for skip forward/backward duration with SF Symbol-supported presets and a custom option.
private struct SkipDurationPicker: View {
    let label: String
    @Binding var seconds: Int
    
    /// The SF Symbol-supported skip durations.
    private static let presets = [5, 10, 15, 30, 45, 60, 75, 90]
    
    /// Whether the current value is a preset or custom.
    private var isCustom: Bool {
        !Self.presets.contains(seconds)
    }
    
    /// Picker selection: the preset value, or -1 for custom.
    private var pickerValue: Int {
        isCustom ? -1 : seconds
    }
    
    @State private var customText: String = ""
    @State private var showingCustom: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(label, selection: Binding(
                get: { pickerValue },
                set: { newValue in
                    if newValue == -1 {
                        customText = "\(seconds)"
                        showingCustom = true
                    } else {
                        seconds = newValue
                        showingCustom = false
                    }
                }
            )) {
                ForEach(Self.presets, id: \.self) { value in
                    Text("\(value)s").tag(value)
                }
                Text("Custom\(isCustom ? " (\(seconds)s)" : "")").tag(-1)
            }
            
            if showingCustom || isCustom {
                HStack {
                    TextField("Seconds", text: Binding(
                        get: { customText.isEmpty && isCustom ? "\(seconds)" : customText },
                        set: { customText = $0 }
                    ))
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    
                    Button("Set") {
                        if let val = Int(customText), val > 0 {
                            seconds = min(val, 300)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Siri Command Row

/// A row displaying a Siri command with its icon, title, and example phrases.
private struct SiriCommandRow: View {
    let icon: String
    let title: String
    let phrases: [String]
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                
                Text(phrases.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
