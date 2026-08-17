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
                    Label {
                        Text(AccountTypeDescriptions.vault.title)
                    } icon: {
                        Image(systemName: AccountTypeDescriptions.vault.icon)
                    }
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
                    Label {
                        Text(AccountTypeDescriptions.selfHosted.title)
                    } icon: {
                        Image(systemName: AccountTypeDescriptions.selfHosted.icon)
                    }
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
            
            // MARK: - YourPods Free
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(AccountTypeDescriptions.yourPodsFree.title)
                    } icon: {
                        Image(systemName: AccountTypeDescriptions.yourPodsFree.icon)
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.purple)
                    
                    Text("Create a free account to sync subscriptions and listen positions across all your Apple devices. Just an email and password — no payment required.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("No analytics, no tracking, no ad identifiers. Upgrade to Pro anytime for extra features.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // MARK: - YourPods Pro
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(AccountTypeDescriptions.yourPodsPro.title)
                    } icon: {
                        Image(systemName: AccountTypeDescriptions.yourPodsPro.icon)
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.purple)
                    
                    Text("The full cloud experience. Web player, cross-device queue sync, listening stats, annotations, gPodder bridge, and media proxy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("Your subscription directly funds development, keeps the servers running, and ensures YourPods stays independent and open source.")
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
