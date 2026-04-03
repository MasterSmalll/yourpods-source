import SwiftUI

/// Profile management view for gPodder sync accounts and local profiles.
/// - Shows which profile is currently active with a clear checkmark
/// - Tap a profile to edit its details
/// - Explicit "Sync Now" button to trigger sync
/// - Limits local-only profiles to 1
struct ProfileSelectionView: View {
    /// When true, the Done button is disabled until at least one profile exists.
    var isOnboarding: Bool = false
    
    @Environment(SettingsManager.self) private var settings
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var profiles: [ServerProfile] = []
    @State private var showAddProfile = false
    @State private var showInfoAlert = false
    @State private var syncStatusMessage: String?
    @State private var isSyncing = false
    
    private var hasLocalProfile: Bool {
        profiles.contains { $0.isLocal }
    }
    
    private var activeProfile: ServerProfile? {
        profiles.first { $0.id == settings.activeProfileId }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Info section
                Section {
                    Button {
                        showInfoAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("Learn about gPodder Sync")
                                .font(.subheadline)
                        }
                    }
                }
                
                // Profiles
                Section {
                    if profiles.isEmpty {
                        VStack(spacing: 8) {
                            Text("No profiles configured")
                                .foregroundStyle(.secondary)
                            Text("Add a sync profile to sync your subscriptions and progress across devices, or use a local-only profile.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 8)
                    } else {
                        ForEach(profiles) { profile in
                            NavigationLink {
                                EditProfileView(
                                    profile: profile,
                                    profiles: $profiles,
                                    onSave: saveProfiles,
                                    isActive: settings.activeProfileId == profile.id,
                                    onActivate: { activateProfile(profile) },
                                    onReconnect: { wireActiveProfile() },
                                    onDelete: nil
                                )
                            } label: {
                                ProfileRow(
                                    profile: profile,
                                    isActive: settings.activeProfileId == profile.id,
                                    isSyncing: isSyncing && settings.activeProfileId == profile.id && !profile.isLocal
                                ) {
                                    activateProfile(profile)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { indexSet in
                            deleteProfiles(at: indexSet)
                        }
                    }
                } header: {
                    Text("Your Profiles")
                }
                
                // Sync button (only if active profile is a server profile)
                if let active = activeProfile, !active.isLocal {
                    Section {
                        Button {
                            syncActiveProfile()
                        } label: {
                            HStack {
                                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(isSyncing)
                    }
                }
                
                // Sync status
                if let msg = syncStatusMessage {
                    Section {
                        Label(msg, systemImage: msg.contains("✓") ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(msg.contains("✓") ? .green : .orange)
                            .font(.caption)
                    }
                }
                
                // Add actions
                Section {
                    Button {
                        showAddProfile = true
                    } label: {
                        Label("Add Sync Profile", systemImage: "plus.circle")
                    }
                    
                    if !hasLocalProfile {
                        Button {
                            addLocalProfile()
                        } label: {
                            Label("Add Local Profile", systemImage: "iphone")
                        }
                    } else {
                        HStack {
                            Label("Local Profile", systemImage: "iphone")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Already added")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Actions")
                }
            }
            .navigationTitle("Profiles")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if isOnboarding {
                            settings.hasCompletedOnboarding = true
                        }
                        dismiss()
                    }
                    .disabled(isOnboarding && profiles.isEmpty)
                }
            }
            .sheet(isPresented: $showAddProfile) {
                AddProfileSheet(profiles: $profiles, onSave: { newProfile in
                    saveProfiles()
                    activateProfile(newProfile)
                })
            }

            .alert("About gPodder Sync", isPresented: $showInfoAlert) {
                Button("OK") { }
            } message: {
                Text("YourPods works best with a gPodder-compatible sync server like Nextcloud + gPodder Sync app.\n\nYour subscriptions, listening progress, and queue positions will sync between all your devices.\n\nYou can also use the app entirely offline without any sync server.")
            }
            .onAppear {
                loadProfiles()
                if settings.activeProfileId == nil, let first = profiles.first {
                    settings.activeProfileId = first.id
                }
                // Re-wire GPodder client on appear for active profile
                wireActiveProfile()
            }
        }
    }
    
    // MARK: - Profile Actions
    
    private func wireActiveProfile() {
        guard let active = activeProfile, !active.isLocal,
              let baseUrl = active.baseUrl, let username = active.username else {
            return
        }
        let password = KeychainHelper.shared.password(forProfileId: active.id) ?? ""
        // NOTE: HTTP is intentionally allowed here. Users may self-host gPodder on
        // local networks without TLS. URLSanitizer defaults bare domains to HTTPS;
        // the UI warns if HTTP is used. Do NOT make this init throwing for HTTPS enforcement.
        let client = GPodderClient(baseUrl: baseUrl, username: username, password: password)
        podcastManager.setGPodderClient(client, deviceId: active.deviceId)
    }
    
    private func activateProfile(_ profile: ServerProfile) {
        settings.activeProfileId = profile.id
        syncStatusMessage = nil
        
        if !profile.isLocal, let baseUrl = profile.baseUrl, let username = profile.username {
            let password = KeychainHelper.shared.password(forProfileId: profile.id) ?? ""
            let client = GPodderClient(baseUrl: baseUrl, username: username, password: password)
            podcastManager.setGPodderClient(client, deviceId: profile.deviceId)
            // Reload library for this profile's subscriptions
            podcastManager.loadSubscriptions()
            // Auto-sync on activation
            syncActiveProfile()
        } else {
            podcastManager.setGPodderClient(nil, deviceId: "local")
            // Reload library for this profile's subscriptions
            podcastManager.loadSubscriptions()
            syncStatusMessage = "Local profile activated ✓"
            Task {
                try? await Task.sleep(for: .seconds(3))
                syncStatusMessage = nil
            }
        }
    }
    
    private func syncActiveProfile() {
        isSyncing = true
        syncStatusMessage = "Syncing subscriptions..."
        Task {
            do {
                _ = try await podcastManager.syncSubscriptions()
                syncStatusMessage = "Syncing episode progress..."
                _ = try await podcastManager.syncEpisodeActions()
                syncStatusMessage = "Sync complete ✓"
            } catch {
                syncStatusMessage = "Sync failed: \(error.localizedDescription)"
            }
            isSyncing = false
            Task {
                try? await Task.sleep(for: .seconds(5))
                syncStatusMessage = nil
            }
        }
    }
    
    private func addLocalProfile() {
        guard !hasLocalProfile else { return }
        let local = ServerProfile(name: "Local Only")
        profiles.append(local)
        saveProfiles()
        activateProfile(local)
    }
    
    private func deleteProfiles(at indexSet: IndexSet) {
        let deletedIds = indexSet.map { profiles[$0].id }
        // Clean up profile-scoped data before removing
        for id in deletedIds {
            podcastManager.clearProfileData(profileId: id)
        }
        profiles.remove(atOffsets: indexSet)
        saveProfiles()
        
        if let activeId = settings.activeProfileId, deletedIds.contains(activeId) {
            if let first = profiles.first {
                activateProfile(first)
            } else {
                settings.activeProfileId = nil
                podcastManager.setGPodderClient(nil, deviceId: "local")
                podcastManager.loadSubscriptions()
            }
        }
    }
    
    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
    }
    
    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "serverProfiles")
        }
    }
}

// MARK: - Profile Row

private struct ProfileRow: View {
    let profile: ServerProfile
    let isActive: Bool
    let isSyncing: Bool
    let onSetActive: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: profile.isLocal ? "iphone" : "cloud")
                .foregroundColor(profile.isLocal ? .blue : .green)
                .font(.title3)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.body.bold())
                    .foregroundColor(.primary)
                
                if let baseUrl = profile.baseUrl {
                    Text(baseUrl)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                if let username = profile.username {
                    Text("User: \(username)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                if profile.isLocal {
                    Text("No server sync")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            // Active indicator / set active button
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)
            } else {
                Button {
                    onSetActive()
                } label: {
                    Text("Set Active")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Edit Profile Sheet

/// Pushed via NavigationLink — no sheet-in-sheet issues.
struct EditProfileView: View {
    let profile: ServerProfile
    @Binding var profiles: [ServerProfile]
    let onSave: () -> Void
    let isActive: Bool
    let onActivate: () -> Void
    let onReconnect: () -> Void
    let onDelete: (() -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsManager.self) private var settings
    @Environment(PodcastManager.self) private var podcastManager
    
    @State private var profileName: String = ""
    @State private var serverUrl: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var deviceId: String = "yourpods-ios"
    @State private var savePassword: Bool = true
    @State private var showSavedConfirmation = false
    @State private var showDeleteConfirmation = false
    
    private var isInsecure: Bool {
        serverUrl.lowercased().hasPrefix("http://")
    }
    
    var body: some View {
        Form {
            Section("Profile") {
                TextField("Profile Name", text: $profileName)
                
                if !isActive {
                    Button("Set as Active Profile") {
                        onActivate()
                        dismiss()
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Active Profile")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            if !profile.isLocal {
                Section {
                    TextField("Server URL", text: $serverUrl, prompt: Text("https://cloud.example.com"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    if isInsecure {
                        Label {
                            Text("Credentials will be sent unencrypted over HTTP. Use HTTPS for security.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                } header: {
                    Text("Server")
                }
                
                Section("Credentials") {
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    
                    Toggle("Save Password", isOn: $savePassword)
                }
                
                Section("Device") {
                    TextField("Device ID", text: $deviceId)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    Text("Identifies this device to the sync server. Change only if you need to match an existing device name on the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section {
                Button {
                    saveChanges()
                } label: {
                    HStack {
                        Text("Save")
                            .fontWeight(.semibold)
                        Spacer()
                        if showSavedConfirmation {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            
            // Delete profile
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Delete Profile", systemImage: "trash")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Edit Profile")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Delete Profile?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteProfile()
            }
        } message: {
            Text("This will remove \"\(profile.name)\" and its saved credentials. This cannot be undone.")
        }
        .onAppear {
            profileName = profile.name
            serverUrl = profile.baseUrl ?? ""
            username = profile.username ?? ""
            password = KeychainHelper.shared.password(forProfileId: profile.id) ?? ""
            deviceId = profile.deviceId
        }
    }
    
    private func deleteProfile() {
        // Clean up stored password
        KeychainHelper.shared.deletePassword(forProfileId: profile.id)
        
        // Clean up profile-scoped subscription and sync data
        podcastManager.clearProfileData(profileId: profile.id)
        
        // Remove from profiles array
        profiles.removeAll { $0.id == profile.id }
        onSave()
        
        // If this was the active profile, switch to the first remaining or clear
        if settings.activeProfileId == profile.id {
            if let first = profiles.first {
                settings.activeProfileId = first.id
            } else {
                settings.activeProfileId = nil
                podcastManager.setGPodderClient(nil, deviceId: "local")
            }
        }
        
        podcastManager.loadSubscriptions()
        
        onDelete?()
        dismiss()
    }
    
    private func saveChanges() {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
            return
        }
        
        profiles[idx].name = profileName
        profiles[idx].deviceId = deviceId.isEmpty ? "yourpods-ios" : deviceId
        if !profile.isLocal {
            profiles[idx].baseUrl = serverUrl
            profiles[idx].username = username
            
            if savePassword {
                KeychainHelper.shared.save(password: password, forProfileId: profile.id)
            } else {
                KeychainHelper.shared.deletePassword(forProfileId: profile.id)
            }
        }
        
        onSave()
        
        // Re-wire GPodderClient with updated credentials
        if isActive && !profile.isLocal {
            onReconnect()
        }
        withAnimation {
            showSavedConfirmation = true
        }
        // Auto-dismiss after brief confirmation
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        }
    }
}

// MARK: - Add Profile Sheet

private struct AddProfileSheet: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Binding var profiles: [ServerProfile]
    let onSave: (ServerProfile) -> Void
    
    @State private var profileName = ""
    @State private var serverUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var deviceId = "yourpods-ios"
    @State private var savePassword = true
    
    private var isInsecure: Bool {
        serverUrl.lowercased().hasPrefix("http://")
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Profile Name", text: $profileName)
                }
                
                Section {
                    TextField("Server URL", text: $serverUrl, prompt: Text("https://cloud.example.com"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    if isInsecure {
                        Label {
                            Text("Credentials will be sent unencrypted over HTTP. Use HTTPS for security.")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Text("Use the base URL of your Nextcloud or gPodder-compatible server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Server")
                }
                
                Section("Credentials") {
                    TextField("Username", text: $username)
                        #if os(iOS)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    
                    Toggle("Save Password", isOn: $savePassword)
                }
                
                Section("Device") {
                    TextField("Device ID", text: $deviceId)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    Text("Identifies this device to the sync server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Sync Profile")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addProfile()
                    }
                    .disabled(profileName.isEmpty || serverUrl.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
        }
    }
    
    private func addProfile() {
        let profile = ServerProfile(
            name: profileName,
            baseUrl: serverUrl,
            username: username,
            deviceId: deviceId.isEmpty ? "yourpods-ios" : deviceId
        )
        
        if savePassword {
            settings.saveGPodderPassword = true
            KeychainHelper.shared.save(password: password, forProfileId: profile.id)
        }
        
        profiles.append(profile)
        onSave(profile)
        dismiss()
    }
}
