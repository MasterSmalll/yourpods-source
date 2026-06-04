import SwiftUI

/// Full-page view explaining all sync options available in YourPods.
///
/// Replaces the previous "About gPodder Sync" alert in SettingsView and
/// the "About Account Types" section in ProfileSelectionView. Provides
/// comprehensive information about each sync mode plus links to legal
/// documentation and the DataTransparencyView.
struct AboutSyncView: View {
    var body: some View {
        Form {
            // MARK: - Tagline
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AccountTypeDescriptions.tagline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    
                    Text(AccountTypeDescriptions.switchAnytime)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } footer: {
                Link(destination: AppURLs.accountTypes) {
                    HStack(spacing: 4) {
                        Text("View on yourpods.app")
                        Image(systemName: "arrow.up.right.square")
                    }
                    .font(.caption)
                }
                .accessibilityLabel("View account types on the YourPods website")
            }
            
            // MARK: - Vault Mode
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(AccountTypeDescriptions.vault.title, systemImage: AccountTypeDescriptions.vault.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                    
                    Text("Your podcasts stay entirely on your device. No servers, no accounts, no data leaves your phone. Just install and listen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("Maximum privacy, zero setup. You can convert a Vault profile to any sync mode anytime without losing your data.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // MARK: - Nextcloud / Self-Hosted
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(AccountTypeDescriptions.selfHosted.title, systemImage: AccountTypeDescriptions.selfHosted.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    
                    Text("Connect to your own gPodder-compatible server — like Nextcloud gPodder Sync. Your data, your server, your rules.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("Syncs subscriptions and episode listen positions across all your devices through infrastructure you control.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // MARK: - Third-Party gPodder Services
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Third-Party gPodder Services", systemImage: AccountTypeDescriptions.thirdPartyGPodder.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    
                    Text("Sync via community-run gPodder-compatible services like gpodder.net. Your subscriptions and listen progress sync across any app that speaks the gPodder protocol.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("The third-party service's privacy policy applies — YourPods itself stores nothing from these accounts.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // MARK: - YourPods Sync
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(AccountTypeDescriptions.yourPodsSync.title, systemImage: AccountTypeDescriptions.yourPodsSync.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.purple)
                    
                    Text("Seamlessly sync subscriptions and listen positions across all your Apple devices. Sign up directly in the app — just an email and password.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("We collect the bare minimum: authentication credentials and sync data. No analytics, no tracking, no ad identifiers. Ever.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // MARK: - Data & Privacy
            Section {
                NavigationLink {
                    DataTransparencyView()
                } label: {
                    Label("Your Data & Privacy", systemImage: "hand.raised")
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Learn exactly what data YourPods collects in each mode.")
            }
            
            // MARK: - Legal
            Section {
                Link(destination: AppURLs.termsOfService) {
                    Label("Terms of Service", systemImage: "doc.text")
                }
                
                Link(destination: AppURLs.privacyPolicy) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            } header: {
                Text("Legal")
            }
        }
        .navigationTitle("About Account Types")
        #if os(iOS)
        .inlineNavigationBarTitle()
        #endif
    }
}
