import SwiftUI
import os
import FirebaseAuth

/// Section view that allows promoting a Vault Mode profile to either
/// a gPodder sync profile or a YourPods Pro profile.
/// Shows a picker for the promotion target and the appropriate credentials form.
struct VaultToSyncSection: View {
    let profile: ServerProfile
    let podcastManager: PodcastManager
    let settings: SettingsManager
    let onResult: (String) -> Void
    
    @State private var isExpanded = false
    @State private var promotionTarget: PromotionTarget = .gpodder
    @State private var isPromoting = false
    @State private var errorMessage: String?
    
    // gPodder fields
    @State private var serverUrl = ""
    @State private var username = ""
    @State private var password = ""
    @State private var deviceId = ""
    
    // Pro fields
    @State private var proEmail = ""
    @State private var proPassword = ""
    @State private var isCreatingProAccount = false
    @State private var showDataTransparency = false
    
    enum PromotionTarget: String, CaseIterable {
        case gpodder = "gPodder Sync"
        case free = "YourPods Free"
        case pro = "YourPods Pro"
    }
    
    private static let logger = Logger(subsystem: "com.yourpods", category: "vault-promotion")
    
    var body: some View {
        Section {
            if !isExpanded {
                // Collapsed — show promotion button
                Button {
                    withAnimation { isExpanded = true }
                    #if os(iOS)
                    deviceId = UIDevice.current.name
                        .replacingOccurrences(of: " ", with: "-")
                        .lowercased()
                    #else
                    deviceId = Host.current().localizedName?
                        .replacingOccurrences(of: " ", with: "-")
                        .lowercased() ?? "yourpods-mac"
                    #endif
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Connect to Sync", systemImage: "arrow.triangle.2.circlepath.circle")
                                .font(.body.weight(.medium))
                            Text("Keep your library and sync your progress across devices")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                // Target picker
                Picker("Sync with", selection: $promotionTarget) {
                    ForEach(PromotionTarget.allCases, id: \.self) { target in
                        Text(target.rawValue).tag(target)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                
                if promotionTarget == .gpodder {
                    gpodderForm
                } else {
                    proForm
                }
                
                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                
                HStack {
                    Button("Cancel") {
                        withAnimation { isExpanded = false }
                        errorMessage = nil
                    }
                    .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Button {
                        Task {
                            if promotionTarget == .gpodder {
                                await promoteToGPodder()
                            } else {
                                await promoteToPro()
                            }
                        }
                    } label: {
                        HStack {
                            Text("Connect & Merge")
                                .fontWeight(.semibold)
                            if isPromoting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(isPromoting || !isFormValid)
                    .foregroundStyle(promotionTarget == .pro ? .purple : .accentColor)
                }
            }
        } header: {
            Text("Upgrade to Sync")
        } footer: {
            if isExpanded {
                if promotionTarget == .gpodder {
                    Text("Your local podcasts will be pushed to the server. Server podcasts will be merged into your library.")
                } else if isCreatingProAccount {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            showDataTransparency = true
                        } label: {
                            Label("What data do we collect?", systemImage: "hand.raised")
                                .font(.caption2.weight(.medium))
                        }
                        
                        Text("Your local podcasts and listening history will be migrated to YourPods Sync.")
                        HStack(spacing: 4) {
                            Text("By creating an account, you agree to our")
                            Link("Terms of Service", destination: AppURLs.termsOfService)
                            Text(String(localized: "legal.termsAndPrivacy.conjunction",
                                        defaultValue: "and",
                                        comment: "Joins the two links in the row [Terms of Service] and [Privacy Policy]. It sits between two separately tappable links, so it cannot be folded into either one."))
                            Link("Privacy Policy", destination: AppURLs.privacyPolicy)
                        }
                        .font(.caption2)
                    }
                } else {
                    Text("Your local podcasts and listening history will be migrated to YourPods Sync.")
                }
            }
        }
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
    }
    
    // MARK: - gPodder Form
    
    private var gpodderForm: some View {
        Group {
            TextField("Server URL", text: $serverUrl)
                #if os(iOS)
                .keyboardType(.URL)
                #endif
                .textContentType(.URL)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
            
            TextField("Username", text: $username)
                .textContentType(.username)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
            
            RevealableSecureField(label: "Password", text: $password)
                .textContentType(.password)
            
            TextField("Device ID", text: $deviceId)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
                .disableAutocorrection(true)
                .font(.footnote)
        }
    }
    
    // MARK: - Pro Form
    
    private var proForm: some View {
        Group {
            // Sign In / Create Account picker
            Picker("Account Action", selection: $isCreatingProAccount.animation()) {
                Text("Sign In").tag(false)
                Text("Create Account").tag(true)
            }
            .pickerStyle(.segmented)
            
            TextField("Email", text: $proEmail)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .autocapitalization(.none)
                #endif
                .textContentType(.emailAddress)
                .disableAutocorrection(true)
            
            RevealableSecureField(label: isCreatingProAccount ? "Create a password (6+ characters)" : "password", text: $proPassword)
                .textContentType(isCreatingProAccount ? .newPassword : .password)
        }
    }
    
    // MARK: - Validation
    
    private var isFormValid: Bool {
        switch promotionTarget {
        case .gpodder:
            return !serverUrl.isEmpty && !username.isEmpty && !password.isEmpty
        case .free, .pro:
            return !proEmail.isEmpty && !proPassword.isEmpty
        }
    }
    
    // MARK: - Promotion Actions
    
    private func promoteToGPodder() async {
        isPromoting = true
        errorMessage = nil
        
        do {
            let mergeCount = try await podcastManager.promoteVaultToSync(
                profile: profile,
                serverUrl: serverUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                deviceId: deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            
            Self.logger.info("Vault → gPodder promotion succeeded: \(mergeCount) subscriptions merged")
            isExpanded = false
            onResult("✓ Profile synced — \(mergeCount) subscriptions merged")
        } catch {
            Self.logger.error("Vault → gPodder promotion failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        
        isPromoting = false
    }
    
    private func promoteToPro() async {
        isPromoting = true
        errorMessage = nil
        
        let authProvider = FirebaseAuthProvider()
        
        do {
            // Sign in or create account with Firebase
            if isCreatingProAccount {
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
            
            // Save password for re-auth (kSecAttrAccessibleAfterFirstUnlock,
            // so background sync can still re-auth after a reboot)
            _ = KeychainHelper.shared.save(password: proPassword, forProfileId: profile.id)
            
            let mergeCount = try await podcastManager.promoteVaultToPro(
                profile: profile,
                authProvider: authProvider
            )
            
            Self.logger.info("Vault → Pro promotion succeeded: \(mergeCount) subscriptions merged")
            isExpanded = false
            onResult("✓ YourPods Sync connected — \(mergeCount) subscriptions synced")
        } catch {
            Self.logger.error("Vault → Pro promotion failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        
        isPromoting = false
    }
}
