import SwiftUI
import FirebaseAuth
import os

/// Profile management view for gPodder sync accounts, Vault Mode, and YourPods Pro profiles.
/// - Shows which profile is currently active with a clear checkmark
/// - Tap a profile to edit its details
/// - Explicit "Sync Now" button to trigger sync
/// - Limits Vault Mode profiles to 1
struct ProfileSelectionView: View {
    /// When true, the Done button is disabled until at least one profile exists.
    var isOnboarding: Bool = false
    
    @Environment(SettingsManager.self) private var settings
    @Environment(PodcastManager.self) private var podcastManager
    // Needed to reach refreshAndSync — sync must go through the orchestrator factory
    // rather than calling individual steps.
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var profiles: [ServerProfile] = []
    @State private var showAddProfile = false
    @State private var showAddGpodderNetProfile = false
    @State private var showAddProProfile = false
    @State private var syncStatusMessage: String?
    @State private var isSyncing = false
    
    private var hasLocalProfile: Bool {
        profiles.contains { $0.isLocal }
    }
    
    private var hasProProfile: Bool {
        profiles.contains { $0.profileType == .yourpodsPro }
    }
    
    private var activeProfile: ServerProfile? {
        profiles.first { $0.id == settings.activeProfileId }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Info section
                Section {
                    NavigationLink {
                        AboutSyncView()
                    } label: {
                        HStack {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                            Text("Learn about sync options")
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
                            Text("Add a sync profile to sync your subscriptions and progress across devices, or use Vault Mode — everything stays on this device, no sync required.")
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
                
                // Vault → Sync promotion (only if active profile is local)
                if let active = activeProfile, active.isLocal {
                    VaultToSyncSection(
                        profile: active,
                        podcastManager: podcastManager,
                        settings: settings,
                        onResult: { message in
                            syncStatusMessage = message
                            loadProfiles()
                        }
                    )
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
                    // Nextcloud / Self-Hosted gPodder
                    Button {
                        showAddProfile = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Nextcloud / Self-Hosted", systemImage: "server.rack")
                                .foregroundStyle(.green)
                            Text(AccountTypeDescriptions.selfHostedShort)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // gpodder.net (public service)
                    Button {
                        showAddGpodderNetProfile = true
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("gpodder.net", systemImage: "globe")
                                .foregroundStyle(.orange)
                            Text(AccountTypeDescriptions.thirdPartyGPodderShort)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if !hasProProfile {
                        Button {
                            showAddProProfile = true
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("YourPods Sync", systemImage: "star.circle")
                                    .foregroundStyle(.purple)
                                Text(AccountTypeDescriptions.yourPodsFreeShort)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Label("YourPods Sync", systemImage: "star.circle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Already added")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    if !hasLocalProfile {
                        Button {
                            addLocalProfile()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Vault Mode", systemImage: "lock.iphone")
                                Text(AccountTypeDescriptions.vaultShort)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Label("Vault Mode", systemImage: "lock.iphone")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Already added")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Text("Add Account")
                }
            }
            .navigationTitle("Profiles")
            #if os(iOS)
            .inlineNavigationBarTitle()
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
                AddProfileSheet(profileType: .gpodder, profiles: $profiles, onSave: { newProfile in
                    saveProfiles()
                    activateProfile(newProfile)
                })
                .environment(settings)
            }
            .sheet(isPresented: $showAddGpodderNetProfile) {
                AddProfileSheet(profileType: .gpodderNet, profiles: $profiles, onSave: { newProfile in
                    saveProfiles()
                    activateProfile(newProfile)
                })
                .environment(settings)
            }
            .sheet(isPresented: $showAddProProfile) {
                AddProProfileSheet(profiles: $profiles, onSave: { newProfile in
                    saveProfiles()
                    activateProfile(newProfile)
                })
                .environment(settings)
                .environment(podcastManager)
            }


            .onAppear {
                loadProfiles()
                if settings.activeProfileId == nil, let first = profiles.first {
                    settings.activeProfileId = first.id
                }
                // Re-wire GPodder client on appear for active profile
                wireActiveProfile()
            }
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 450)
            #endif
        }
    }
    
    // MARK: - Profile Actions
    
    private func wireActiveProfile() {
        guard let active = activeProfile, !active.isLocal,
              let baseUrl = active.baseUrl, let username = active.username else {
            return
        }
        switch active.profileType {
        case .yourpodsPro:
            let authProvider = FirebaseAuthProvider()
            let client = YourPodsProClient(baseUrl: baseUrl, authProvider: authProvider)
            podcastManager.setSyncClient(client, deviceId: active.deviceId)
        case .gpodder:
            let password = KeychainHelper.shared.password(forProfileId: active.id) ?? ""
            // NOTE: HTTP is intentionally allowed here. Users may self-host gPodder on
            // local networks without TLS. URLSanitizer defaults bare domains to HTTPS;
            // the UI warns if HTTP is used. Do NOT make this init throwing for HTTPS enforcement.
            let client = GPodderClient(baseUrl: baseUrl, username: username, password: password)
            podcastManager.setSyncClient(client, deviceId: active.deviceId)
        case .gpodderNet:
            let password = KeychainHelper.shared.password(forProfileId: active.id) ?? ""
            let client = GPodderClient(baseUrl: baseUrl, username: username, password: password, flavor: .gpodderNet)
            podcastManager.setSyncClient(client, deviceId: active.deviceId)
        }
    }
    
    private func activateProfile(_ profile: ServerProfile) {
        settings.activeProfileId = profile.id
        syncStatusMessage = nil
        // Swap episode-action state to this profile before any sync, so the previous
        // profile's positions don't leak into this profile's conflict detection.
        podcastManager.switchActiveProfile(to: profile.id)

        if !profile.isLocal, let baseUrl = profile.baseUrl, let username = profile.username {
            switch profile.profileType {
            case .yourpodsPro:
                let authProvider = FirebaseAuthProvider()
                let client = YourPodsProClient(baseUrl: baseUrl, authProvider: authProvider)
                podcastManager.setSyncClient(client, deviceId: profile.deviceId)
            case .gpodder:
                let password = KeychainHelper.shared.password(forProfileId: profile.id) ?? ""
                let client = GPodderClient(baseUrl: baseUrl, username: username, password: password)
                podcastManager.setSyncClient(client, deviceId: profile.deviceId)
            case .gpodderNet:
                let password = KeychainHelper.shared.password(forProfileId: profile.id) ?? ""
                let client = GPodderClient(baseUrl: baseUrl, username: username, password: password, flavor: .gpodderNet)
                podcastManager.setSyncClient(client, deviceId: profile.deviceId)
            }
            // Reload library for this profile's subscriptions
            podcastManager.loadSubscriptions()
            // Auto-sync on activation
            syncActiveProfile()
        } else {
            podcastManager.setSyncClient(nil, deviceId: "local")
            // Reload library for this profile's subscriptions
            podcastManager.loadSubscriptions()
            syncStatusMessage = "Vault Mode activated ✓"
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
            // Start a progress-polling task to show real-time feedback
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    if let progress = podcastManager.subscriptionSyncProgress {
                        syncStatusMessage = "Syncing \(progress.completed) of \(progress.total) subscriptions..."
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            
            // Route through refreshAndSync, not the individual steps. Calling
            // syncSubscriptions + syncEpisodeActions directly synced exactly those two
            // things and nothing else — no playback positions, no queue, no settings, no
            // notes — so the Sync button could not fix the state users press it to fix.
            // It also skipped the orchestrator factory, and passed no strategy, so it
            // silently resolved as .serverWins whatever the user had chosen.
            podcastManager.lastSyncError = nil
            _ = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settings,
                strategy: settings.syncConflictStrategy
            )
            progressTask.cancel()
            // refreshAndSync does not throw — it reports through lastSyncError — so
            // reporting success unconditionally would claim a sync that may not have
            // happened. That is the failure mode this guards against.
            if let failure = podcastManager.lastSyncError {
                syncStatusMessage = "Sync failed: \(failure)"
            } else {
                syncStatusMessage = "Sync complete ✓"
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
        let local = ServerProfile(name: "Vault Mode")
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
                podcastManager.setSyncClient(nil, deviceId: "local")
                podcastManager.loadSubscriptions()
            }
        }
    }
    
    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "serverProfiles"),
           var decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            // Migrate old "yourpodspro" default profile names to "yourpodssync"
            var didMigrate = false
            for i in decoded.indices where decoded[i].profileType == .yourpodsPro && decoded[i].proProfileName == "yourpodspro" {
                decoded[i].proProfileName = "yourpodssync"
                decoded[i].deviceId = "yourpodssync"
                didMigrate = true
            }
            profiles = decoded
            if didMigrate { saveProfiles() }
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
            Image(systemName: profileIcon)
                .foregroundColor(profileColor)
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
                    Text("On-device only · No sync required")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if profile.profileType == .yourpodsPro {
                    Text("YourPods Sync · \(profile.proProfileName)")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                } else if profile.profileType == .gpodderNet {
                    Text("gpodder.net · Public sync service")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if profile.profileType == .gpodder {
                    Text("Nextcloud / Self-Hosted")
                        .font(.caption2)
                        .foregroundStyle(.green)
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
    
    private var profileIcon: String {
        if profile.isLocal { return "lock.iphone" }
        switch profile.profileType {
        case .yourpodsPro: return "star.circle"
        case .gpodderNet: return "globe"
        case .gpodder: return "server.rack"
        }
    }
    
    private var profileColor: Color {
        if profile.isLocal { return .blue }
        switch profile.profileType {
        case .yourpodsPro: return .purple
        case .gpodderNet: return .orange
        case .gpodder: return .green
        }
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
    @State private var proProfileName: String = "yourpodssync"
    @State private var pendingProProfileName: String = ""
    @State private var savePassword: Bool = true
    @State private var showSavedConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showForkAlert = false
    @State private var isForkingProfile = false
    
    // Account deletion (Pro only)

    /// The word the user types to confirm permanent account deletion.
    ///
    /// The prompt, the field placeholder, the VoiceOver hint and the comparison
    /// that unlocks the button all read this one value. They used to be four
    /// separate literals, three of them localizable and the fourth — the
    /// comparison — hardcoded English, so translating the app would have made
    /// account deletion impossible in every translated language.
    static let deleteConfirmationWord = String(
        localized: "account.delete.confirmWord",
        defaultValue: "DELETE",
        comment: "The exact word the user must type to confirm permanent account deletion. Translate it, but keep it ONE all-capitals word with no spaces or punctuation — the app compares the typed text against this string character for character, and the field force-uppercases what is typed.")

    @State private var showDeleteAccount = false
    @State private var deleteConfirmation = ""
    @State private var deleteReason = ""
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showDataTransparency = false

    // GDPR Export
    @State private var isExportingData = false
    @State private var exportError: String?
    @State private var exportFileURL: URL?
    
    // Login Flow re-authentication (Nextcloud only)
    @StateObject private var loginCoordinator = LoginFlowCoordinator()

    private var isProProfile: Bool { profile.profileType == .yourpodsPro }
    
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
                serverAndCredentialsSections
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
            
            // Change Password (YourPods Sync only)
            if isProProfile {
                Section {
                    NavigationLink {
                        ChangePasswordView {
                            // After successful password change, clean up and dismiss
                            KeychainHelper.shared.deletePassword(forProfileId: profile.id)
                            profiles.removeAll { $0.id == profile.id }
                            onSave()
                            if settings.activeProfileId == profile.id {
                                if let first = profiles.first {
                                    settings.activeProfileId = first.id
                                } else {
                                    settings.activeProfileId = nil
                                    podcastManager.setSyncClient(nil, deviceId: "local")
                                }
                            }
                            podcastManager.loadSubscriptions()
                            onDelete?()
                            dismiss()
                        }
                    } label: {
                        Label("Change Password", systemImage: "lock.rotation")
                    }
                }
            }

            // GDPR Data Export (Pro only)
            if isProProfile {
                gdprExportSection
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
            } footer: {
                if isProProfile {
                    Text("Deleting a profile disconnects this device. Your account and synced data remain on the server.")
                }
            }
            
            // Delete Account (Pro only — permanently destroys the server account)
            if isProProfile {
                Section {
                    if !showDeleteAccount {
                        Button(role: .destructive) {
                            withAnimation { showDeleteAccount = true }
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete My Account", systemImage: "person.crop.circle.badge.minus")
                                Spacer()
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Danger Zone", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.red)
                            
                            Text("This will permanently delete your YourPods Sync account and all synced data — subscriptions, playback history, and any other data stored on the server. This cannot be undone.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            Text("A minimal record (hashed email + deletion date) is retained for 3 years per legal requirements.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        
                        TextField("Why are you leaving? (optional)", text: $deleteReason)
                            .font(.subheadline)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: "account.delete.confirmPrompt",
                                        defaultValue: "Type \(Self.deleteConfirmationWord) to confirm:",
                                        comment: "Instruction above the account-deletion confirmation field. Argument 1 is the confirmation word itself, already localized."))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            // The label goes through the closure form rather
                            // than an empty title string: `TextField("", …)`
                            // extracts the empty literal as a catalog key, and
                            // an empty key is not a translatable string.
                            TextField(text: $deleteConfirmation,
                                      prompt: Text(verbatim: Self.deleteConfirmationWord)) {
                                Text("Confirmation field")
                            }
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                #endif
                                .autocorrectionDisabled()
                                .accessibilityLabel("Confirmation field")
                                .accessibilityHint(String(localized: "a11y.account.delete.confirmHint",
                                                          defaultValue: "Type the word \(Self.deleteConfirmationWord) in all capitals to confirm account deletion",
                                                          comment: "VoiceOver hint on the account-deletion confirmation field. Argument 1 is the confirmation word, already localized."))
                        }
                        
                        if let error = deleteAccountError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        
                        HStack {
                            Button("Cancel") {
                                withAnimation {
                                    showDeleteAccount = false
                                    deleteConfirmation = ""
                                    deleteReason = ""
                                    deleteAccountError = nil
                                }
                            }
                            .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            Button(role: .destructive) {
                                Task { await performAccountDeletion() }
                            } label: {
                                HStack {
                                    if isDeletingAccount {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text("Permanently Delete")
                                        .fontWeight(.semibold)
                                }
                            }
                            .disabled(deleteConfirmation != Self.deleteConfirmationWord || isDeletingAccount)
                            .accessibilityLabel("Permanently delete account")
                            .accessibilityHint(isDeletingAccount ? "Deleting account" : "Double-tap to permanently delete your YourPods Sync account and all data")
                        }
                    }
                } header: {
                    if showDeleteAccount {
                        Text("Delete Account")
                    }
                } footer: {
                    Text("Unlike Delete Profile (which only disconnects this device), deleting your account permanently removes your YourPods Sync account and all data from the server. This cannot be undone.")
                }
            }
        }
        .navigationTitle("Edit Profile")
        #if os(iOS)
        .inlineNavigationBarTitle()
        .scrollDismissesKeyboard(.interactively)
        #else
        // On macOS, the sheet has a fixed size — give it enough room for all fields.
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .alert("Delete Profile?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteProfile()
            }
        } message: {
            Text("This will remove \"\(profile.name)\" and its saved credentials. This cannot be undone.")
        }
        .alert("Change Sync Profile?", isPresented: $showForkAlert) {
            Button("Cancel", role: .cancel) {
                // Revert to original name
                proProfileName = profile.proProfileName
            }
            Button("Change Profile") {
                Task { await forkAndSave() }
            }
        } message: {
            Text("Changing your Sync Profile Name to \"\(pendingProProfileName)\" will link this device to a new shared profile. Devices with the old name will stay on \"\(profile.proProfileName)\".")
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { exportFileURL != nil },
            set: { if !$0 { exportFileURL = nil } }
        )) {
            if let url = exportFileURL {
                ShareSheet(url: url)
            }
        }
        #endif
        .onAppear {
            profileName = profile.name
            serverUrl = profile.baseUrl ?? ""
            username = profile.username ?? ""
            password = KeychainHelper.shared.password(forProfileId: profile.id) ?? ""
            deviceId = profile.deviceId
            proProfileName = profile.proProfileName
        }
        .onChange(of: loginCoordinator.state) { _, newState in
            if case .success(_, _, let appPassword) = newState {
                // Re-auth success — update Keychain with new app password
                KeychainHelper.shared.save(password: appPassword, forProfileId: profile.id)
                if isActive { onReconnect() }
                withAnimation { showSavedConfirmation = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    showSavedConfirmation = false
                }
            }
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
                podcastManager.setSyncClient(nil, deviceId: "local")
            }
        }
        
        podcastManager.loadSubscriptions()
        
        onDelete?()
        dismiss()
    }
    
    /// Permanently delete the user's YourPods Sync account on the server,
    /// then clean up locally. On error, does NOT sign out — user data is still intact.
    private func performAccountDeletion() async {
        let logger = Logger(subsystem: "com.yourpods", category: "AccountDeletion")
        isDeletingAccount = true
        deleteAccountError = nil
        
        do {
            // 1. Get the Pro client from the podcast manager
            guard let proClient = podcastManager.currentSyncClient as? YourPodsProClient else {
                deleteAccountError = "Not connected to YourPods Sync. Please try again."
                isDeletingAccount = false
                return
            }
            
            // 2. Call server — deletes everything including Firebase Auth (server-side)
            let reason = deleteReason.trimmingCharacters(in: .whitespacesAndNewlines)
            try await proClient.deleteAccount(reason: reason.isEmpty ? nil : reason)
            
            // 3. Server returned 200 — sign out locally (Firebase Auth record is already gone)
            await FirebaseAuthProvider().signOut()
            
            // 4. Clean up local profile data
            KeychainHelper.shared.deletePassword(forProfileId: profile.id)
            podcastManager.clearProfileData(profileId: profile.id)
            profiles.removeAll { $0.id == profile.id }
            onSave()
            
            // 5. Switch to first remaining profile or clear
            if settings.activeProfileId == profile.id {
                if let first = profiles.first {
                    settings.activeProfileId = first.id
                } else {
                    settings.activeProfileId = nil
                    podcastManager.setSyncClient(nil, deviceId: "local")
                }
            }
            
            podcastManager.loadSubscriptions()
            logger.info("Account deletion completed — local cleanup done")
            
            onDelete?()
            dismiss()
        } catch {
            // Do NOT sign out on error — user data is still intact on the server
            logger.error("Account deletion failed: \(error.localizedDescription)")
            deleteAccountError = "Deletion failed: \(error.localizedDescription). Please try again or contact support."
            isDeletingAccount = false
        }
    }

    /// GDPR: Download all user data as JSON and present a share sheet.
    private func performDataExport() async {
        isExportingData = true
        exportError = nil

        do {
            guard let proClient = podcastManager.currentSyncClient as? YourPodsProClient else {
                exportError = "Not connected to YourPods Sync."
                isExportingData = false
                return
            }

            let data = try await proClient.exportAccountData()

            // Write to a temp file for the share sheet
            let filename = "yourpods-export-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).json"
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: tempURL)
            exportFileURL = tempURL
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }

        isExportingData = false
    }

    @ViewBuilder
    private var serverAndCredentialsSections: some View {
        Section {
            TextField("Server URL", text: $serverUrl, prompt: Text("https://cloud.example.com"))
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()

            if isInsecure {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("This URL uses HTTP. Your credentials and data will be sent unencrypted. We recommend using HTTPS for security.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    .accessibilityLabel("Security warning: This URL uses HTTP. Your credentials and data will be sent unencrypted. We recommend using HTTPS for security.")

                    if let suggested = URLSanitizer.suggestedHTTPSURL(serverUrl) {
                        Button {
                            serverUrl = suggested
                        } label: {
                            Label("Switch to HTTPS", systemImage: "lock.shield")
                                .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .controlSize(.small)
                        .accessibilityHint("Replaces http with https in the server URL")
                    }
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

            if profile.resolvedAuthMethod == .loginFlow {
                HStack {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Authenticated via Login Flow")
                        .foregroundStyle(.secondary)
                }

                Button {
                    startReAuthentication()
                } label: {
                    Label("Re-authenticate with Nextcloud", systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                RevealableSecureField(label: "Password", text: $password)
                    .textContentType(.password)

                Toggle("Save Password", isOn: $savePassword)
            }
        }

        if isProProfile {
            Section {
                TextField("Sync Profile Name", text: $proProfileName)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("Sync Profile")
            } footer: {
                Text("Devices sharing the same profile name sync subscriptions, settings, and groups together. Change this to join or create a different profile.")
            }
        } else {
            Section {
                TextField("Device ID", text: $deviceId)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                Text("Identifies this device to the sync server. Change only if you need to match an existing device name on the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Device")
            }
        }
    }

    @ViewBuilder
    private var gdprExportSection: some View {
        Section {
            Button {
                Task { await performDataExport() }
            } label: {
                HStack {
                    Label("Export My Data", systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExportingData {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isExportingData)
            .accessibilityLabel("Export My Data")
            .accessibilityHint("Downloads all your synced data as a JSON file")

            if let error = exportError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } header: {
            Text("Data & Privacy")
        } footer: {
            Text("Download a copy of all your synced data (subscriptions, playback history, settings) as a JSON file.")
        }
    }

    private func saveChanges() {
        // For Pro profiles, check if the sync profile name changed — show fork alert first
        if isProProfile {
            let trimmed = proProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = trimmed.isEmpty ? "yourpodssync" : trimmed
            if newName != profile.proProfileName {
                pendingProProfileName = newName
                showForkAlert = true
                return  // Wait for alert response before saving
            }
        }
        commitSave()
    }

    /// Forks the Pro profile on the server (if possible) then commits the save.
    private func forkAndSave() async {
        if let proClient = podcastManager.currentSyncClient as? YourPodsProClient {
            isForkingProfile = true
            do {
                try await proClient.forkProfile(from: profile.proProfileName, to: pendingProProfileName)
            } catch {
                // 409 Conflict = destination already exists — safe to proceed (just switch)
                // Any other error: log and continue so the user isn't stuck
                let logger = Logger(subsystem: "com.yourpods", category: "ProfileUI")
                logger.warning("forkProfile failed (continuing): \(error.localizedDescription)")
            }
            isForkingProfile = false
        }
        proProfileName = pendingProProfileName
        commitSave()
    }

    private func commitSave() {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }

        profiles[idx].name = profileName
        if isProProfile {
            let trimmed = proProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
            profiles[idx].proProfileName = trimmed.isEmpty ? "yourpodssync" : trimmed
            // deviceId for Pro = proProfileName (the server key)
            profiles[idx].deviceId = profiles[idx].proProfileName
        } else {
            profiles[idx].deviceId = deviceId.isEmpty ? "yourpods-ios" : deviceId
        }

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

        // Re-wire client with updated credentials / profile name
        if isActive && !profile.isLocal {
            onReconnect()
        }
        withAnimation { showSavedConfirmation = true }
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            dismiss()
        }
    }
    
    // MARK: - Login Flow Re-authentication
    
    private func startReAuthentication() {
        let sanitized = URLSanitizer.sanitize(serverUrl)
        loginCoordinator.startLoginFlow(serverURL: sanitized)
    }
}

// MARK: - Add Profile Sheet

private struct AddProfileSheet: View {
    /// Which type of gPodder account: `.gpodder` (Nextcloud/self-hosted) or `.gpodderNet`.
    let profileType: ProfileType
    
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
    @State private var connectionError: String?
    
    // Login Flow v2 (Nextcloud only)
    @State private var showManualEntry = false
    @StateObject private var loginCoordinator = LoginFlowCoordinator()
    
    private var isGpodderNet: Bool { profileType == .gpodderNet }
    private var isNextcloud: Bool { profileType == .gpodder }
    
    private var isInsecure: Bool {
        serverUrl.lowercased().hasPrefix("http://")
    }
    
    private var navTitle: String {
        isGpodderNet ? "Add gpodder.net" : "Add Self-Hosted Sync"
    }
    
    private var canStartLoginFlow: Bool {
        !serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && loginCoordinator.state != .initiating
            && loginCoordinator.state != .waitingForBrowser
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Profile Name", text: $profileName)
                }
                
                Section {
                    // Editable server URL — defaults to gpodder.net, user can change for self-hosted instances
                    TextField("Server URL", text: $serverUrl, prompt: Text(isGpodderNet ? "https://gpodder.net" : "https://cloud.example.com"))
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    
                    if isInsecure {
                        VStack(alignment: .leading, spacing: 6) {
                            Label {
                                Text("This URL uses HTTP. Your credentials and data will be sent unencrypted. We recommend using HTTPS for security.")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                            .accessibilityLabel("Security warning: This URL uses HTTP. Your credentials and data will be sent unencrypted. We recommend using HTTPS for security.")
                            
                            if let suggested = URLSanitizer.suggestedHTTPSURL(serverUrl) {
                                Button {
                                    serverUrl = suggested
                                } label: {
                                    Label("Switch to HTTPS", systemImage: "lock.shield")
                                        .font(.caption.bold())
                                }
                                .buttonStyle(.bordered)
                                .tint(.blue)
                                .controlSize(.small)
                                .accessibilityHint("Replaces http with https in the server URL")
                            }
                        }
                    }
                    
                    if isGpodderNet {
                        Text("Defaults to gpodder.net. Change this if you run your own gpodder.net-compatible server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Use the base URL of your Nextcloud or gPodder-compatible server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Server")
                }
                
                // Login Flow v2 — Nextcloud only (not gpodder.net)
                if isNextcloud {
                    Section {
                        Button(action: startLoginFlow) {
                            HStack {
                                Spacer()
                                switch loginCoordinator.state {
                                case .initiating:
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 4)
                                    Text("Connecting…")
                                        .fontWeight(.semibold)
                                case .waitingForBrowser:
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 4)
                                    Text("Waiting for browser…")
                                        .fontWeight(.semibold)
                                default:
                                    Image(systemName: "person.badge.key.fill")
                                    Text("Sign in with Nextcloud")
                                        .fontWeight(.semibold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(!canStartLoginFlow)
                        .accessibilityLabel(
                            loginCoordinator.state == .waitingForBrowser
                                ? "Waiting for browser login"
                                : "Sign in with Nextcloud"
                        )
                        .accessibilityHint("Opens your Nextcloud login page in a browser window")
                    } header: {
                        Text("Sign In")
                    } footer: {
                        Text("Opens your Nextcloud server in a browser. Log in and grant access — your credentials stay in the browser, never in this app.")
                    }
                }
                
                if let error = connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                
                // Manual entry — primary for gpodder.net, collapsible fallback for Nextcloud
                if isNextcloud {
                    Section {
                        DisclosureGroup("Enter app password manually", isExpanded: $showManualEntry) {
                            manualCredentialFields
                            deviceIdField
                        }
                    } footer: {
                        Text("For servers that don't support Login Flow, create an app password in Nextcloud → Settings → Security.")
                    }
                } else {
                    // gpodder.net — always show credentials directly
                    Section("Credentials") {
                        manualCredentialFields
                    }
                    
                    Section("Device") {
                        deviceIdField
                    }
                }
            }
            .navigationTitle(navTitle)
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        loginCoordinator.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    // Only show Add button for manual entry (Login Flow auto-saves on success)
                    if isGpodderNet || showManualEntry {
                        Button("Add") {
                            addProfile(authMethod: .manual)
                        }
                        .disabled(profileName.isEmpty || serverUrl.isEmpty || username.isEmpty || password.isEmpty)
                    }
                }
            }
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 400)
            #endif
            .onAppear {
                if isGpodderNet {
                    serverUrl = "https://gpodder.net"
                    if profileName.isEmpty { profileName = "gpodder.net" }
                }
            }
            .onChange(of: loginCoordinator.state) { _, newState in
                handleLoginFlowState(newState)
            }
        }
    }
    
    // MARK: - Shared UI Components
    
    @ViewBuilder
    private var manualCredentialFields: some View {
        TextField("Username", text: $username)
            #if os(iOS)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
        
        RevealableSecureField(label: "App Password", text: $password)
            .textContentType(.password)
        
        Toggle("Save Password", isOn: $savePassword)
    }
    
    @ViewBuilder
    private var deviceIdField: some View {
        TextField("Device ID", text: $deviceId)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
        
        Text("Identifies this device to the sync server.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    
    // MARK: - Login Flow
    
    private func startLoginFlow() {
        connectionError = nil
        let sanitized = URLSanitizer.sanitize(serverUrl)
        serverUrl = sanitized
        loginCoordinator.startLoginFlow(serverURL: sanitized)
    }
    
    private func handleLoginFlowState(_ state: LoginFlowCoordinator.State) {
        switch state {
        case .success(let server, let loginName, let appPassword):
            // Create profile directly from Login Flow credentials
            let name = profileName.isEmpty ? loginName : profileName
            let profile = ServerProfile(
                name: name,
                baseUrl: server,
                username: loginName,
                deviceId: deviceId.isEmpty ? "yourpods-ios" : deviceId,
                profileType: .gpodder,
                authMethod: .loginFlow
            )
            
            // Store app password in Keychain
            settings.saveGPodderPassword = true
            KeychainHelper.shared.save(password: appPassword, forProfileId: profile.id)
            
            profiles.append(profile)
            onSave(profile)
            dismiss()
        case .error(let message):
            connectionError = message
        default:
            break
        }
    }
    
    // MARK: - Manual Entry
    
    private func addProfile(authMethod: AuthMethod) {
        let profile = ServerProfile(
            name: profileName,
            baseUrl: serverUrl,
            username: username,
            deviceId: deviceId.isEmpty ? "yourpods-ios" : deviceId,
            profileType: profileType,
            authMethod: authMethod
        )
        
        if savePassword {
            settings.saveGPodderPassword = true
            KeychainHelper.shared.save(password: password, forProfileId: profile.id)
        }
        
        // Clear password from @State immediately after Keychain save
        password = ""
        
        profiles.append(profile)
        onSave(profile)
        dismiss()
    }
}


// MARK: - Add YourPods Pro Profile Sheet

// ─── YourPods Pro ────────────────────────────────────────────────────────
// This sheet is used to add a YourPods Pro account from the profile
// management screen. Firebase is NOT required for Vault or gPodder.
// See: https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────
private struct AddProProfileSheet: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(SubscriptionManager.self) private var subscriptionManager
    // Needed to reach refreshAndSync — see ProfileSelectionView.
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss
    @Binding var profiles: [ServerProfile]
    let onSave: (ServerProfile) -> Void
    
    @State private var email = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showMigrationConfirmation = false
    @State private var migrationResult: String?
    @State private var createdProfile: ServerProfile?
    @State private var isCreatingAccount = false
    @State private var showDataTransparency = false
    
    private var canConnect: Bool {
        !email.isEmpty && !password.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Sign In / Create Account picker
                    Picker("Account Action", selection: $isCreatingAccount.animation()) {
                        Text("Sign In").tag(false)
                        Text("Create Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("you@example.com", text: $email)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            #endif
                            .textContentType(.emailAddress)
                            .autocorrectionDisabled()
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        RevealableSecureField(label: isCreatingAccount ? "Create a password (6+ characters)" : "password", text: $password)
                            .textContentType(isCreatingAccount ? .newPassword : .password)
                    }
                } header: {
                    Text(isCreatingAccount ? "Create YourPods Sync Account" : "Sign In to YourPods Sync")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            showDataTransparency = true
                        } label: {
                            Label("What data does YourPods Sync collect?", systemImage: "hand.raised")
                                .font(.caption2.weight(.medium))
                        }
                        
                        Text("Your account is free. No payment required.")
                        HStack(spacing: 4) {
                            Text(isCreatingAccount ? "By creating an account, you agree to our" : "By signing in, you agree to our")
                            Link("Terms of Service", destination: AppURLs.termsOfService)
                            Text(String(localized: "legal.termsAndPrivacy.conjunction",
                                        defaultValue: "and",
                                        comment: "Joins the two links in the row [Terms of Service] and [Privacy Policy]. It sits between two separately tappable links, so it cannot be folded into either one."))
                            Link("Privacy Policy", destination: AppURLs.privacyPolicy)
                        }
                        .font(.caption2)
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                
                if let result = migrationResult {
                    Section {
                        Label(result, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                
                Section {
                    Button {
                        Task { await connectToPro() }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                                Text(isCreatingAccount ? "Creating Account..." : "Signing In...")
                                    .fontWeight(.semibold)
                            } else {
                                Label(isCreatingAccount ? "Create Account & Connect" : "Sign In & Connect", systemImage: "star.circle")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect || isConnecting)
                    .foregroundStyle(canConnect ? .purple : .secondary)
                }
            }
            .navigationTitle(isCreatingAccount ? "Create Account" : "Add YourPods Sync")
            #if os(iOS)
            .inlineNavigationBarTitle()
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(minWidth: 450, minHeight: 350)
            #endif
            .sheet(isPresented: $showDataTransparency) {
                NavigationStack {
                    DataTransparencyView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showDataTransparency = false }
                            }
                        }
                }
            }
            .alert("Migrate Local Data?", isPresented: $showMigrationConfirmation) {
                Button("Upload") {
                    Task { await performMigration() }
                }
                Button("Skip", role: .cancel) {
                    finishAndDismiss()
                }
            } message: {
                Text("Upload your \(podcastManager.subscriptions.count) subscriptions and listening history to YourPods Sync?")
            }
        }
    }
    
    private func connectToPro() async {
        isConnecting = true
        errorMessage = nil
        
        let authProvider = FirebaseAuthProvider()
        
        do {
            // Sign in or create account with Firebase
            if isCreatingAccount {
                _ = try await authProvider.createUser(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
            } else {
                _ = try await authProvider.signIn(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
            }
            
            let baseUrl = "https://sync.yourpods.app"
            let client = YourPodsProClient(baseUrl: baseUrl, authProvider: authProvider)
            
            // Validate session with backend
            let session = try await client.validateSession()

            // Reflect the account's Pro entitlement immediately so an already-Pro
            // account isn't shown the upgrade nudge after signing in.
            subscriptionManager.applyServerSession(session)

            // Identify to RevenueCat by Firebase UID so this account's purchases
            // (web or app) resolve to the same customer. Never anonymous.
            if let uid = session.user.firebaseUid {
                subscriptionManager.identify(
                    firebaseUID: uid,
                    earlyAdopterPricingEligible: session.earlyAdopterPricingEligible ?? false)
            }

            // Create Pro profile with default sync profile name "yourpodssync".
            // All devices using the same proProfileName share subscriptions, settings, and groups.
            let profile = ServerProfile(
                name: session.user.email,
                baseUrl: baseUrl,
                username: session.user.email,
                deviceId: "yourpodssync",
                profileType: .yourpodsPro,
                proProfileName: "yourpodssync"
            )
            
            // Store password in Keychain (kSecAttrAccessibleAfterFirstUnlock,
            // so background sync can still re-auth after a reboot)
            _ = KeychainHelper.shared.save(password: password, forProfileId: profile.id)
            
            profiles.append(profile)
            createdProfile = profile
            
            // Wire up the sync client
            podcastManager.setSyncClient(client, deviceId: profile.deviceId)
            
            // Ask about migration if there's local data
            if !podcastManager.subscriptions.isEmpty {
                showMigrationConfirmation = true
            } else {
                onSave(profile)
                // First pull after linking. Through refreshAndSync so the initial sync
                // brings down playback positions, queue and settings too — pulling only
                // subscriptions and actions left a freshly linked device with none of the
                // state the user linked it for.
                _ = await podcastManager.refreshAndSync(
                    playerManager: playerManager,
                    downloadManager: downloadManager,
                    settingsManager: settings,
                    strategy: settings.syncConflictStrategy
                )
                dismiss()
            }
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    private func performMigration() async {
        do {
            let (subs, actions) = try await podcastManager.migrateLocalDataToPro()
            migrationResult = "Migrated \(subs) subscriptions and \(actions) episode actions."
        } catch {
            errorMessage = "Migration failed: \(error.localizedDescription)"
        }
        
        finishAndDismiss()
    }
    
    private func finishAndDismiss() {
        if let profile = createdProfile {
            onSave(profile)
        }
        dismiss()
    }
}
