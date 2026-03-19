import SwiftUI
import UniformTypeIdentifiers

/// Comprehensive settings screen with all app preferences.
struct SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    
    @State private var showProfileSelection = false
    @State private var showGPodderInfo = false
    @State private var isExportingOPML = false
    @State private var isImportingOPML = false
    @State private var showOPMLExport = false
    @State private var opmlExportURL: URL?
    @State private var isForceSyncing = false
    
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
                            isForceSyncing = true
                            _ = try? await podcastManager.syncEpisodeActions()
                            isForceSyncing = false
                        }
                    } label: {
                        Label("Force Push to Server", systemImage: "arrow.up.circle")
                    }
                    .disabled(isForceSyncing)
                    
                    Button {
                        Task {
                            isForceSyncing = true
                            _ = try? await podcastManager.syncEpisodeActions()
                            isForceSyncing = false
                        }
                    } label: {
                        Label("Force Pull from Server", systemImage: "arrow.down.circle")
                    }
                    .disabled(isForceSyncing)
                    
                    NavigationLink {
                        EpisodeActivityView()
                    } label: {
                        Label("Episode Activity", systemImage: "waveform")
                    }
                    
                    Button {
                        showGPodderInfo = true
                    } label: {
                        Label("About gPodder Sync", systemImage: "info.circle")
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
                    
                    Picker("Tab Bar Style", selection: Binding(
                        get: { settings.tabBarDisplayMode },
                        set: { settings.tabBarDisplayMode = $0 }
                    )) {
                        Text("Text Only").tag(TabBarDisplayMode.textOnly)
                        Text("Icon Only").tag(TabBarDisplayMode.iconOnly)
                        Text("Text & Icon").tag(TabBarDisplayMode.textAndIcon)
                    }
                    
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
                            ), in: 0...120, step: 5)
                    
                    Stepper("Skip Outro: \(settings.skipOutroSeconds)s",
                            value: Binding(
                                get: { settings.skipOutroSeconds },
                                set: { settings.skipOutroSeconds = $0 }
                            ), in: 0...120, step: 5)
                } header: {
                    Label("Playback", systemImage: "play.circle")
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
                    Picker("Auto-Queue Mode", selection: Binding(
                        get: { settings.defaultAutoQueueMode },
                        set: { settings.defaultAutoQueueMode = $0 }
                    )) {
                        Text("Off").tag(AutoQueueMode.off)
                        Text("Normal").tag(AutoQueueMode.normal)
                        Text("Priority").tag(AutoQueueMode.priority)
                    }
                    
                    Toggle("Auto-Download New Episodes", isOn: Binding(
                        get: { settings.defaultAutoDownload },
                        set: { settings.defaultAutoDownload = $0 }
                    ))
                    
                    Toggle("Remove After Playing", isOn: Binding(
                        get: { settings.defaultRemoveAfterPlay },
                        set: { settings.defaultRemoveAfterPlay = $0 }
                    ))
                    
                    Toggle("Archive on Complete", isOn: Binding(
                        get: { settings.defaultArchiveOnComplete },
                        set: { settings.defaultArchiveOnComplete = $0 }
                    ))
                } header: {
                    Label("New Podcast Defaults", systemImage: "star")
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
                        
                        SecureField("API Secret", text: Binding(
                            get: { settings.podcastIndexApiSecret ?? "" },
                            set: { settings.podcastIndexApiSecret = $0.isEmpty ? nil : $0 }
                        ))
                        
                        Link("Get API Keys", destination: URL(string: "https://api.podcastindex.org")!)
                            .font(.caption)
                    }
                } header: {
                    Label("Search Provider", systemImage: "magnifyingglass")
                }
                
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
                    }
                } header: {
                    Label("Apple Watch", systemImage: "applewatch")
                }
                
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
                    }
                } header: {
                    Label("Background Refresh", systemImage: "arrow.clockwise")
                }
                
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
                } header: {
                    Label("Siri Commands", systemImage: "mic.circle")
                } footer: {
                    Text("Say \"Hey Siri\" followed by any command above. You can also add these as Shortcuts in the Shortcuts app.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showProfileSelection) {
                ProfileSelectionView()
            }
            .alert("About gPodder Sync", isPresented: $showGPodderInfo) {
                Button("OK") { }
            } message: {
                Text("YourPods is designed to work best with a gPodder-compatible sync server (like Nextcloud). You can sync your subscriptions, listening progress, and queue between devices.\n\nYou can also use the app in local-only mode without any server.")
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
        let xml = OPMLService.export(podcasts: podcastManager.subscriptions)
        
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
                let feedUrls = OPMLService.parseURLs(from: data)
                for feedUrl in feedUrls {
                    Task {
                        try? await podcastManager.addSubscription(url: feedUrl)
                    }
                }
            }
        case .failure:
            break
        }
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
