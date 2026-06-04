import SwiftUI

/// Listening Profile — per-podcast settings sheet.
struct PodcastSettingsSheet: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    @State private var feedUsername = ""
    @State private var feedPassword = ""
    @State private var credentialsSaved = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: Binding<AutoQueueMode?>(
                        get: { podcast.effectiveSettings.autoQueueMode },
                        set: { podcast.effectiveSettings.autoQueueMode = $0 }
                    )) {
                        Text("Global Setting").tag(AutoQueueMode?.none)
                        ForEach(AutoQueueMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(AutoQueueMode?.some(mode))
                        }
                    }
                } header: {
                    Text("AutoPilot")
                } footer: {
                    if let mode = podcast.effectiveSettings.autoQueueMode {
                        Text(mode.subtitle)
                    } else {
                        Text("Uses your global AutoPilot setting from Settings.")
                    }
                }
                
                Section("Playback") {
                    Stepper(
                        "Skip Intro: \(podcast.effectiveSettings.skipIntroSeconds ?? 0)s",
                        value: Binding(
                            get: { podcast.effectiveSettings.skipIntroSeconds ?? 0 },
                            set: { podcast.effectiveSettings.skipIntroSeconds = $0 > 0 ? $0 : nil }
                        ),
                        in: 0...999,
                        step: 5
                    )
                    
                    Stepper(
                        "Skip Outro: \(podcast.effectiveSettings.skipOutroSeconds ?? 0)s",
                        value: Binding(
                            get: { podcast.effectiveSettings.skipOutroSeconds ?? 0 },
                            set: { podcast.effectiveSettings.skipOutroSeconds = $0 > 0 ? $0 : nil }
                        ),
                        in: 0...999,
                        step: 5
                    )
                    
                    if let speed = podcast.effectiveSettings.playbackSpeed {
                        HStack {
                            Text("Speed Override")
                            Spacer()
                            Text("\(speed, specifier: "%.1f")×")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Section("Auto-Download") {
                    Toggle("Download New Episodes", isOn: Binding(
                        get: { podcast.effectiveSettings.autoDownloadNewEpisodes ?? false },
                        set: { podcast.effectiveSettings.autoDownloadNewEpisodes = $0 }
                    ))
                    
                    Picker("Download Cleanup", selection: Binding<DownloadCleanupPolicy?>(
                        get: { podcast.effectiveSettings.downloadCleanupPolicy },
                        set: { podcast.effectiveSettings.downloadCleanupPolicy = $0 }
                    )) {
                        Text("Default").tag(DownloadCleanupPolicy?.none)
                        ForEach(DownloadCleanupPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(DownloadCleanupPolicy?.some(policy))
                        }
                    }
                    
                    if podcast.effectiveSettings.downloadCleanupPolicy != nil {
                        Button("Reset to Default", role: .destructive) {
                            podcast.effectiveSettings.downloadCleanupPolicy = nil
                        }
                        .font(.caption)
                    }
                }
                
                Section("Completion") {
                    Toggle("Archive on Complete", isOn: Binding(
                        get: { podcast.effectiveSettings.archiveOnComplete ?? false },
                        set: { podcast.effectiveSettings.archiveOnComplete = $0 }
                    ))
                }
                
                Section {
                    Picker("P3", selection: Binding<Bool?>(
                        get: { podcast.effectiveSettings.privacyMode },
                        set: { podcast.effectiveSettings.privacyMode = $0 }
                    )) {
                        Text("Global Setting").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    .accessibilityLabel("Privacy Preserving Playback")
                } header: {
                    Label("Privacy", systemImage: "shield.checkered")
                } footer: {
                    Text("Privacy Preserving Playback. Overrides your global P3 setting for this podcast. When on, tracking and ad-insertion redirects are removed from episode URLs.")
                }
                
                Section {
                    Toggle("New Episode Notifications", isOn: Binding(
                        get: { podcast.effectiveSettings.notificationsEnabled ?? false },
                        set: { podcast.effectiveSettings.notificationsEnabled = $0 ? true : nil }
                    ))
                    .accessibilityLabel("New Episode Notifications")
                    .accessibilityHint("When on, you'll be notified when new episodes are found during background refresh")
                } header: {
                    Label("Notifications", systemImage: "bell.badge")
                } footer: {
                    Text("Get a local notification when new episodes are discovered. Requires notifications to be enabled in Settings → Background Refresh.")
                }
                
                // Feed Credentials (only for protected feeds)
                if podcast.requiresAuth {
                    Section {
                        TextField("Username", text: $feedUsername)
                            #if os(iOS)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        
                        RevealableSecureField(label: "Password", text: $feedPassword)
                            .textContentType(.password)
                        
                        Button {
                            saveCredentials()
                        } label: {
                            Label("Save Credentials", systemImage: "key.fill")
                        }
                        .disabled(feedUsername.isEmpty || feedPassword.isEmpty)
                        
                        if credentialsSaved {
                            Label("Credentials updated", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    } header: {
                        Label("Feed Credentials", systemImage: "lock.fill")
                    } footer: {
                        Text("Credentials are stored securely in your device's Keychain and are never synced to any server.")
                    }
                }
                
                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        podcast.effectiveSettings = PodcastSettings()
                    }
                }
            }
            .navigationTitle("Listening Profile")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        modelContext.guardedSave(storeURL: YourPodsApp.modelStoreURL())
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Pre-populate username from model (password stays blank for security)
                feedUsername = podcast.feedUsername ?? ""
            }
        }
    }
    
    private func saveCredentials() {
        KeychainHelper.shared.saveFeedCredentials(
            username: feedUsername,
            password: feedPassword,
            forPodcastUrl: podcast.url
        )
        podcast.feedUsername = feedUsername
        credentialsSaved = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            credentialsSaved = false
        }
    }
}
