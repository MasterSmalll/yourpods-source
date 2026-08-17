import SwiftUI
// ─── YourPods Sync ─────────────────────────────────────────────────────────
// YourPods Sync sign-in is optional. The onboarding flow supports four
// modes: Vault (local-only), Nextcloud/self-hosted gPodder, gpodder.net,
// and YourPods Sync.
// Firebase is NOT required for Vault or gPodder — see https://opensource.yourpods.app
// ───────────────────────────────────────────────────────────────────────────
import FirebaseAuth

/// Multi-page onboarding flow for new users.
/// Page 1: Welcome
/// Page 2: Vault vs gPodder vs YourPods Pro comparison card
/// Page 3a (Vault): Creates profile and jumps to Add Podcasts tab
/// Page 3b (Sync): Server setup form
/// Page 3c (Pro): YourPods Sync sign-in / signup form
struct OnboardingView: View {
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(NavigationState.self) private var navigationState
    @Environment(SubscriptionManager.self) private var subscriptionManager
    // Needed to reach refreshAndSync — the first pull after linking must bring down
    // playback positions, queue and settings, not just subscriptions and actions.
    @Environment(PlayerManager.self) private var playerManager
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentPage = 0
    @State private var selectedMode: OnboardingMode? = nil
    
    // Server setup fields
    @State private var profileName = ""
    @State private var serverUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var deviceId = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    
    // YourPods Pro fields
    @State private var proEmail = ""
    @State private var proPassword = ""
    @State private var proIsConnecting = false
    @State private var proErrorMessage: String?
    @State private var showMigrationConfirmation = false
    @State private var migrationResult: String?
    @State private var proIsCreatingAccount = false
    @State private var showDataTransparency = false
    @State private var showProPaywall = false
    
    // Login Flow v2 (onboarding, Nextcloud only)
    @State private var useLoginFlow = true
    @StateObject private var loginCoordinator = LoginFlowCoordinator()
    
    enum OnboardingMode {
        case vault
        case sync       // Nextcloud / self-hosted gPodder
        case gpodderNet // gpodder.net public service
        case free       // YourPods Free (sync-only account)
        case pro        // YourPods Pro (account + paywall)
    }
    
    var body: some View {
        #if os(iOS)
        TabView(selection: $currentPage) {
            welcomePage.tag(0)
            comparisonPage.tag(1)
            
            if selectedMode == .sync || selectedMode == .gpodderNet {
                syncSetupPage.tag(2)
            } else if selectedMode == .free || selectedMode == .pro {
                proSetupPage.tag(2)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Color(.systemBackground))
        #else
        Group {
            switch currentPage {
            case 0: welcomePage
            case 1: comparisonPage
            case 2 where selectedMode == .sync || selectedMode == .gpodderNet: syncSetupPage
            case 2 where selectedMode == .free || selectedMode == .pro: proSetupPage
            default: comparisonPage
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentPage)
        .background(Color(nsColor: .windowBackgroundColor))
        #endif
    }
    
    // MARK: - Page 1: Welcome
    
    private var welcomePage: some View {
        VStack(spacing: 32) {
            Spacer()
            
            Image("YourPodsLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                .accessibilityLabel("YourPods app icon")
            
            VStack(spacing: 16) {
                Text("Welcome to YourPods")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                
                Text("The premium podcast player.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                Text("No ads. No tracking. Ever.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button {
                withAnimation {
                    currentPage = 1
                }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding()
    }
    
    // MARK: - Page 2: Vault vs gPodder Comparison
    
    @State private var expandedMode: OnboardingMode? = nil
    
    private var comparisonPage: some View {
        VStack(spacing: 0) {
            // Fixed header
            VStack(spacing: 8) {
                Text("Choose Your Setup")
                    .font(.title.bold())
                
                HStack(spacing: 4) {
                    Text(AccountTypeDescriptions.tagline)
                        .foregroundStyle(.secondary)
                    Link(destination: AppURLs.accountTypes) {
                        HStack(spacing: 2) {
                            Text("Learn More")
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    .accessibilityLabel("Learn more about account types on the YourPods website")
                }
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)
            
            // Scrollable mode cards
            ScrollView {
                VStack(spacing: 8) {
                    modeRow(
                        mode: .vault,
                        title: AccountTypeDescriptions.vault.title,
                        subtitle: AccountTypeDescriptions.vault.subtitle,
                        icon: AccountTypeDescriptions.vault.icon,
                        color: .blue,
                        features: AccountTypeDescriptions.vault.features,
                        isRecommended: true
                    )
                    
                    // ☁️ YourPods Cloud section header
                    HStack {
                        Image(systemName: "cloud")
                            .font(.caption2)
                        Text("YourPods Cloud")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(.purple)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("YourPods Cloud")
                    
                    modeRow(
                        mode: .free,
                        title: AccountTypeDescriptions.yourPodsFree.title,
                        subtitle: AccountTypeDescriptions.yourPodsFree.subtitle,
                        icon: AccountTypeDescriptions.yourPodsFree.icon,
                        color: .purple,
                        features: AccountTypeDescriptions.yourPodsFree.features
                    )
                    
                    modeRow(
                        mode: .pro,
                        title: AccountTypeDescriptions.yourPodsPro.title,
                        subtitle: AccountTypeDescriptions.yourPodsPro.subtitle,
                        icon: AccountTypeDescriptions.yourPodsPro.icon,
                        color: .purple,
                        features: AccountTypeDescriptions.yourPodsPro.features
                    )
                    
                    // 🔧 Self-Hosted section header
                    HStack {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.caption2)
                        Text("SELF-HOSTED / THIRD-PARTY")
                            .font(.caption2.weight(.bold))
                            .tracking(0.8)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel("Self-hosted and third-party")
                    
                    modeRow(
                        mode: .sync,
                        title: AccountTypeDescriptions.selfHosted.title,
                        subtitle: AccountTypeDescriptions.selfHosted.subtitle,
                        icon: AccountTypeDescriptions.selfHosted.icon,
                        color: .green,
                        features: AccountTypeDescriptions.selfHosted.features
                    )
                    
                    modeRow(
                        mode: .gpodderNet,
                        title: AccountTypeDescriptions.thirdPartyGPodder.title,
                        subtitle: AccountTypeDescriptions.thirdPartyGPodder.subtitle,
                        icon: AccountTypeDescriptions.thirdPartyGPodder.icon,
                        color: .orange,
                        features: AccountTypeDescriptions.thirdPartyGPodder.features
                    )
                }
                .padding(.horizontal)
                // Reserve room at the top so the recommended card's "Quickstart"
                // badge (a .topLeading overlay offset y: -6) isn't clipped by the
                // ScrollView's top edge. Independent of translation length.
                .padding(.top, 12)
            }

            // Pinned action button
            VStack(spacing: 12) {
                if selectedMode == .vault {
                    Button {
                        createVaultProfileAndDismiss()
                    } label: {
                        Label("Use Vault Mode", systemImage: "lock.iphone")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else if selectedMode == .sync {
                    Button {
                        withAnimation {
                            #if os(iOS)
                            deviceId = UIDevice.current.name
                                .replacingOccurrences(of: " ", with: "-")
                                .lowercased()
                            #else
                            deviceId = Host.current().localizedName?
                                .replacingOccurrences(of: " ", with: "-")
                                .lowercased() ?? "yourpods-mac"
                            #endif
                            currentPage = 2
                        }
                    } label: {
                        Label("Set Up Server →", systemImage: "server.rack")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else if selectedMode == .gpodderNet {
                    Button {
                        withAnimation {
                            serverUrl = "https://gpodder.net"
                            profileName = "gpodder.net"
                            #if os(iOS)
                            deviceId = UIDevice.current.name
                                .replacingOccurrences(of: " ", with: "-")
                                .lowercased()
                            #else
                            deviceId = Host.current().localizedName?
                                .replacingOccurrences(of: " ", with: "-")
                                .lowercased() ?? "yourpods-mac"
                            #endif
                            currentPage = 2
                        }
                    } label: {
                        Label("Set Up gpodder.net →", systemImage: "globe")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else if selectedMode == .free {
                    Button {
                        withAnimation {
                            currentPage = 2
                        }
                    } label: {
                        Label("Create Free Account →", systemImage: "cloud")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                } else if selectedMode == .pro {
                    Button {
                        withAnimation {
                            currentPage = 2
                        }
                    } label: {
                        Label("Sign In or Create Account →", systemImage: "star.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
            .padding(.top, 12)
        }
    }
    
    // MARK: - Mode Row Component
    
    /// The title + subtitle stack for a mode row. Extracted so the large
    /// `modeRow` view expression stays within the Swift type-checker's budget
    /// (LocalizedStringResource `Text` overloads tipped it over otherwise).
    @ViewBuilder
    private func modeRowTitles(_ title: LocalizedStringResource,
                               _ subtitle: LocalizedStringResource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The expandable feature checklist for a mode row. Extracted to keep the
    /// `modeRow` view expression within the type-checker's budget. Indexed by
    /// offset since `LocalizedStringResource` is not `Hashable` for `id: \.self`.
    @ViewBuilder
    private func modeRowFeatures(_ features: [LocalizedStringResource], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.horizontal)

            ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(color)
                        .frame(width: 14)
                    Text(feature)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
        }
        .padding(.bottom, 14)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func modeRow(
        mode: OnboardingMode,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource,
        icon: String,
        color: Color,
        features: [LocalizedStringResource],
        isRecommended: Bool = false
    ) -> some View {
        let isSelected = selectedMode == mode
        let isExpanded = expandedMode == mode
        
        return VStack(spacing: 0) {
            // Main row — tap to select
            Button {
                selectedMode = mode
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    
                    modeRowTitles(title, subtitle)
                    
                    Spacer()
                    
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? color : Color.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "a11y.onboarding.option",
                                       defaultValue: "\(String(localized: title)). \(String(localized: subtitle))",
                                       comment: "VoiceOver label for a selectable onboarding option. Argument 1 is the option's name, 2 its one-line explanation."))
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            
            // More Info toggle
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedMode = isExpanded ? nil : mode
                }
            } label: {
                HStack(spacing: 4) {
                    Text("More Info")
                        .font(.caption.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(color)
                .padding(.bottom, isExpanded ? 6 : 8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "a11y.onboarding.moreInfo",
                                       defaultValue: "More Info for \(String(localized: title))",
                                       comment: "VoiceOver label for the button that expands an onboarding option's details. Placeholder is the option's name, such as 'Vault Mode'."))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            
            // Expandable checklist
            if isExpanded {
                modeRowFeatures(features, color: color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isRecommended && !isSelected
                      ? Color.blue.opacity(0.06)
                      : (isSelected ? color.opacity(0.08) : Color.gray.opacity(0.1)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isRecommended && !isSelected
                        ? Color.blue.opacity(0.3)
                        : (isSelected ? color : .clear),
                        lineWidth: isRecommended && !isSelected ? 1.5 : 2)
        )
        .overlay(alignment: .topLeading) {
            if isRecommended {
                Text("Quickstart")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue))
                    .offset(x: -6, y: -6)
                    .accessibilityLabel("Recommended quickstart option")
            }
        }
    }
    
    // MARK: - Page 3b: Sync Setup
    
    private var isGpodderNetSetup: Bool { selectedMode == .gpodderNet }
    
    private var syncSetupPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(isGpodderNetSetup ? "Connect to gpodder.net" : "Connect Your Server")
                    .font(.title.bold())
                    .padding(.top, 32)
                
                Text(isGpodderNetSetup
                     ? "Enter your gpodder.net account credentials."
                     : "Enter your gPodder-compatible server details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 16) {
                    if !isGpodderNetSetup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Profile Name").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("My Server", text: $profileName)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    if isGpodderNetSetup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Server URL").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("https://gpodder.net", text: $serverUrl)
                                #if os(iOS)
                                .keyboardType(.URL)
                                #endif
                                .textContentType(.URL)
                                #if os(iOS)
                                .autocapitalization(.none)
                                #endif
                                .disableAutocorrection(true)
                                .textFieldStyle(.roundedBorder)
                            Text("Defaults to gpodder.net. Change this if you run your own gpodder.net-compatible server.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Server URL").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("https://cloud.example.com", text: $serverUrl)
                                #if os(iOS)
                                .keyboardType(.URL)
                                #endif
                                .textContentType(.URL)
                                #if os(iOS)
                                .autocapitalization(.none)
                                #endif
                                .disableAutocorrection(true)
                                .textFieldStyle(.roundedBorder)
                            Text("Use the base URL of your Nextcloud or gPodder-compatible server.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    // Login Flow vs Manual picker — Nextcloud only
                    if !isGpodderNetSetup {
                        Picker("Authentication", selection: $useLoginFlow.animation()) {
                            Text("Sign in with Nextcloud").tag(true)
                            Text("Enter app password").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    if isGpodderNetSetup || !useLoginFlow {
                        // Manual credential entry
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Username").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            TextField("username", text: $username)
                                .textContentType(.username)
                                #if os(iOS)
                                .autocapitalization(.none)
                                #endif
                                .disableAutocorrection(true)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isGpodderNetSetup ? "Password" : "App Password")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            RevealableSecureField(label: "password", text: $password)
                                .textContentType(.password)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device ID").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("yourpods-ios", text: $deviceId)
                            #if os(iOS)
                            .autocapitalization(.none)
                            #endif
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                            .font(.footnote)
                        Text("Identifies this device to the sync server.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)
                
                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                // Action button — either Login Flow or manual Connect & Sync
                if !isGpodderNetSetup && useLoginFlow {
                    Button {
                        startOnboardingLoginFlow()
                    } label: {
                        HStack {
                            switch loginCoordinator.state {
                            case .initiating:
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text("Connecting…")
                                    .font(.headline)
                            case .waitingForBrowser:
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text("Waiting for browser…")
                                    .font(.headline)
                            default:
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with Nextcloud")
                                    .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canStartOnboardingLoginFlow ? Color.green : Color.gray)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canStartOnboardingLoginFlow)
                    .accessibilityLabel(
                        loginCoordinator.state == .waitingForBrowser
                            ? "Waiting for browser login"
                            : "Sign in with Nextcloud"
                    )
                    .accessibilityHint("Opens your Nextcloud login page in a browser window")
                    .padding(.horizontal, 32)
                    
                    Text("Opens your Nextcloud login page in a browser. Your credentials stay in the browser, never in this app.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 48)
                } else {
                    Button {
                        Task { await connectAndSync() }
                    } label: {
                        HStack {
                            Text("Connect & Sync")
                                .font(.headline)
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canConnect ? (isGpodderNetSetup ? Color.orange : Color.green) : Color.gray)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canConnect || isConnecting)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
            }
        }
        .onChange(of: loginCoordinator.state) { _, newState in
            handleOnboardingLoginFlowState(newState)
        }
    }
    
    private var canConnect: Bool {
        !username.isEmpty && !password.isEmpty && !serverUrl.isEmpty && (isGpodderNetSetup || !profileName.isEmpty)
    }
    
    private var canStartOnboardingLoginFlow: Bool {
        !serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && loginCoordinator.state != .initiating
            && loginCoordinator.state != .waitingForBrowser
    }
    
    private func startOnboardingLoginFlow() {
        errorMessage = nil
        let sanitized = URLSanitizer.sanitize(serverUrl)
        serverUrl = sanitized
        loginCoordinator.startLoginFlow(serverURL: sanitized)
    }
    
    private func handleOnboardingLoginFlowState(_ state: LoginFlowCoordinator.State) {
        switch state {
        case .success(let server, let loginName, let appPassword):
            // Auto-fill from Login Flow credentials and proceed with sync
            Task {
                await connectAndSyncViaLoginFlow(
                    server: server,
                    loginName: loginName,
                    appPassword: appPassword
                )
            }
        case .error(let message):
            errorMessage = message
        default:
            break
        }
    }
    
    private func connectAndSyncViaLoginFlow(server: String, loginName: String, appPassword: String) async {
        isConnecting = true
        errorMessage = nil
        
        let effectiveDeviceId = deviceId.isEmpty ? "yourpods-ios" : deviceId
        let effectiveProfileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? loginName : profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let client = GPodderClient(
            baseUrl: server,
            username: loginName,
            password: appPassword,
            flavor: .nextcloud
        )
        
        do {
            // Validate connection
            _ = try await client.getSubscriptionChanges(deviceId: effectiveDeviceId, since: 0)
            
            // Create sync profile with loginFlow auth method
            let profile = ServerProfile(
                name: effectiveProfileName,
                baseUrl: server,
                username: loginName,
                deviceId: effectiveDeviceId,
                profileType: .gpodder,
                authMethod: .loginFlow
            )
            
            var profiles = loadProfiles()
            profiles.append(profile)
            saveProfiles(profiles)
            
            _ = KeychainHelper.shared.save(password: appPassword, forProfileId: profile.id)
            
            settingsManager.activeProfileId = profile.id
            podcastManager.setSyncClient(client, deviceId: effectiveDeviceId)
            podcastManager.loadSubscriptions()
            
            // Initial sync
            _ = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                strategy: settingsManager.syncConflictStrategy
            )
            
            settingsManager.hasCompletedOnboarding = true
            dismiss()
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    // MARK: - Actions
    
    private func createVaultProfileAndDismiss() {
        // Create Vault profile
        let profile = ServerProfile(name: "Vault Mode")
        var profiles = loadProfiles()
        profiles.append(profile)
        saveProfiles(profiles)
        
        settingsManager.activeProfileId = profile.id
        podcastManager.setSyncClient(nil, deviceId: "local")
        podcastManager.loadSubscriptions()
        settingsManager.hasCompletedOnboarding = true
        
        dismiss()
        
        // Navigate to Add Podcasts tab
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            navigationState.switchToAddPodcasts()
        }
    }
    
    private func connectAndSync() async {
        isConnecting = true
        errorMessage = nil
        
        let effectiveDeviceId = deviceId.isEmpty ? "yourpods-ios" : deviceId
        let effectiveProfileType: ProfileType = isGpodderNetSetup ? .gpodderNet : .gpodder
        let effectiveServerUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveProfileName = isGpodderNetSetup ? (profileName.isEmpty ? "gpodder.net" : profileName.trimmingCharacters(in: .whitespacesAndNewlines)) : profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let client = GPodderClient(
            baseUrl: effectiveServerUrl,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            flavor: effectiveProfileType == .gpodderNet ? .gpodderNet : .nextcloud
        )
        
        do {
            // Validate connection
            _ = try await client.getSubscriptionChanges(deviceId: effectiveDeviceId, since: 0)
            
            // Create sync profile
            let profile = ServerProfile(
                name: effectiveProfileName,
                baseUrl: effectiveServerUrl,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceId: effectiveDeviceId,
                profileType: effectiveProfileType
            )
            
            var profiles = loadProfiles()
            profiles.append(profile)
            saveProfiles(profiles)
            
            _ = KeychainHelper.shared.save(password: password, forProfileId: profile.id)
            
            settingsManager.activeProfileId = profile.id
            podcastManager.setSyncClient(client, deviceId: effectiveDeviceId)
            podcastManager.loadSubscriptions()
            
            // Initial sync
            _ = await podcastManager.refreshAndSync(
                playerManager: playerManager,
                downloadManager: downloadManager,
                settingsManager: settingsManager,
                strategy: settingsManager.syncConflictStrategy
            )
            
            settingsManager.hasCompletedOnboarding = true
            dismiss()
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isConnecting = false
    }
    
    // MARK: - Profile Persistence
    
    private func loadProfiles() -> [ServerProfile] {
        guard let data = UserDefaults.standard.data(forKey: "serverProfiles"),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return []
        }
        return decoded
    }
    
    private func saveProfiles(_ profiles: [ServerProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "serverProfiles")
        }
    }
    
    // MARK: - Page 3c: YourPods Sync Setup
    
    private var proSetupPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(proIsCreatingAccount ? "Create a YourPods Sync Account" : "Sign In to YourPods Sync")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 32)
                    .padding(.horizontal)
                
                Text(proIsCreatingAccount ? "Create a free account to sync your podcasts across devices." : "Enter your YourPods Sync account credentials.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                // Sign In / Create Account picker
                Picker("Account Action", selection: $proIsCreatingAccount.animation()) {
                    Text("Sign In").tag(false)
                    Text("Create Account").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        TextField("you@example.com", text: $proEmail)
                            #if os(iOS)
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            #endif
                            .textContentType(.emailAddress)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        RevealableSecureField(label: proIsCreatingAccount ? "Create a password (6+ characters)" : "password", text: $proPassword)
                            .textContentType(proIsCreatingAccount ? .newPassword : .password)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.horizontal)
                
                if let error = proErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                if let result = migrationResult {
                    Label(result, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .padding(.horizontal)
                }
                
                VStack(spacing: 6) {
                    Button {
                        showDataTransparency = true
                    } label: {
                        Label("What data does YourPods Sync collect?", systemImage: "hand.raised")
                            .font(.caption2.weight(.medium))
                    }
                    
                    if proIsCreatingAccount {
                        Text("By creating an account, you agree to our")
                    } else {
                        Text("By signing in, you agree to our")
                    }
                    HStack(spacing: 4) {
                        Link("Terms of Service", destination: AppURLs.termsOfService)
                        Text(String(localized: "legal.termsAndPrivacy.conjunction",
                                    defaultValue: "and",
                                    comment: "Joins the two links in the row [Terms of Service] and [Privacy Policy]. It sits between two separately tappable links, so it cannot be folded into either one."))
                            .foregroundStyle(.secondary)
                        Link("Privacy Policy", destination: AppURLs.privacyPolicy)
                    }
                    
                    Text("Your account is free. No payment required.")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
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
                
                Button {
                    Task { await connectToPro() }
                } label: {
                    HStack {
                        Text(proIsCreatingAccount ? "Create Account & Sync" : "Sign In & Sync")
                            .font(.headline)
                        if proIsConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canConnectPro ? Color.purple : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!canConnectPro || proIsConnecting)
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .alert("Migrate Local Data?", isPresented: $showMigrationConfirmation) {
            Button("Upload") {
                Task { await performMigration() }
            }
            Button("Skip", role: .cancel) {
                finishProOnboarding()
            }
        } message: {
            Text("Upload your \(podcastManager.subscriptions.count) subscriptions and listening history to YourPods Sync?")
        }
        .sheet(isPresented: $showProPaywall) {
            NavigationStack {
                ProPaywallView(onSkip: {
                    showProPaywall = false
                    completeOnboarding()
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") {
                            showProPaywall = false
                            completeOnboarding()
                        }
                    }
                }
            }
        }
    }
    
    private var canConnectPro: Bool {
        !proEmail.isEmpty && !proPassword.isEmpty
    }
    
    private func connectToPro() async {
        proIsConnecting = true
        proErrorMessage = nil
        
        let authProvider = FirebaseAuthProvider()
        
        do {
            // Sign in or create account with Firebase
            if proIsCreatingAccount {
                _ = try await authProvider.createUser(
                    email: proEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: proPassword
                )
            } else {
                _ = try await authProvider.signIn(
                    email: proEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: proPassword
                )
            }
            
            let baseUrl = "https://sync.yourpods.app"
            let client = YourPodsProClient(baseUrl: baseUrl, authProvider: authProvider)
            
            // Validate session with backend
            let session = try await client.validateSession()

            // Reflect the account's Pro entitlement immediately so an already-Pro
            // account isn't shown the upgrade paywall/nudge after signing in.
            subscriptionManager.applyServerSession(session)

            // Identify to RevenueCat by Firebase UID so this account's purchases
            // (web or app) resolve to the same customer. Never anonymous.
            if let uid = session.user.firebaseUid {
                subscriptionManager.identify(
                    firebaseUID: uid,
                    earlyAdopterPricingEligible: session.earlyAdopterPricingEligible ?? false)
            }

            // Create Pro profile
            let profile = ServerProfile(
                name: session.user.email,
                baseUrl: baseUrl,
                username: session.user.email,
                deviceId: "yourpods-ios",
                profileType: .yourpodsPro
            )
            
            var profiles = loadProfiles()
            profiles.append(profile)
            saveProfiles(profiles)
            
            // Store password in Keychain for re-auth (kSecAttrAccessibleAfterFirstUnlock,
            // so background sync can still re-auth after a reboot)
            _ = KeychainHelper.shared.save(password: proPassword, forProfileId: profile.id)
            
            settingsManager.activeProfileId = profile.id
            podcastManager.setSyncClient(client, deviceId: profile.deviceId)
            podcastManager.loadSubscriptions()
            
            // Ask user about migration
            if !podcastManager.subscriptions.isEmpty {
                showMigrationConfirmation = true
            } else {
                // No local data to migrate — just sync
                _ = await podcastManager.refreshAndSync(
                    playerManager: playerManager,
                    downloadManager: downloadManager,
                    settingsManager: settingsManager,
                    strategy: settingsManager.syncConflictStrategy
                )
                finishProOnboarding()
            }
            
        } catch {
            proErrorMessage = error.localizedDescription
        }
        
        proIsConnecting = false
    }
    
    private func performMigration() async {
        guard let client = podcastManager.currentSyncClient as? YourPodsProClient else {
            finishProOnboarding()
            return
        }
        
        do {
            let subs = podcastManager.subscriptions.map(\.url)
            let actions = podcastManager.allEpisodeActions()
            let result = try await client.migrate(subscriptions: subs, episodeActions: actions)
            migrationResult = "Migrated \(result.subscriptionsImported) subscriptions and \(result.episodeActionsImported) episode actions."
        } catch {
            proErrorMessage = "Migration failed: \(error.localizedDescription)"
        }
        
        // Finish regardless of migration result
        finishProOnboarding()
    }
    
    private func finishProOnboarding() {
        // An account that already has Pro (paid or early adopter) gets no upsell.
        if !subscriptionManager.isPro && (selectedMode == .pro || selectedMode == .free) {
            // Show paywall after account creation (easy skip for free users)
            showProPaywall = true
        } else {
            completeOnboarding()
        }
    }
    
    private func completeOnboarding() {
        settingsManager.hasCompletedOnboarding = true
        dismiss()
        
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            navigationState.switchToAddPodcasts()
        }
    }
}
