import SwiftUI

/// Data transparency screen explaining what YourPods collects (and doesn't).
///
/// Shown when users tap "What data do we collect?" during YourPods Sync
/// account creation flows (onboarding, profile management, Vault promotion).
/// Also accessible from AboutSyncView.
struct DataTransparencyView: View {
    var body: some View {
        Form {
            // MARK: - No Account
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Zero data collection", systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))
                    
                    Text("YourPods collects no data when used without a YourPods Sync account. In Vault Mode, everything stays on your device — nothing is sent anywhere.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("With self-hosted gPodder sync (e.g. Nextcloud), your data goes to your own server, never to us.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Without an Account")
            }
            
            // MARK: - Third-Party Services
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Third-party services", systemImage: "globe")
                        .font(.subheadline.weight(.semibold))
                    
                    Text("If you use a third-party gPodder-compatible service (e.g. gpodder.net), your subscription and playback data is handled by that service under its own privacy policy. YourPods does not receive or store any data from third-party sync accounts.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Third-Party Sync Services")
            }
            
            // MARK: - YourPods Sync
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Minimal data for sync", systemImage: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    
                    Text("When you create a YourPods Sync account, we collect and store only the minimum data necessary for sync functionality:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        dataRow(icon: "envelope", label: "Email address", detail: "For authentication only")
                        dataRow(icon: "antenna.radiowaves.left.and.right", label: "Podcast subscriptions", detail: "RSS feed URLs you subscribe to")
                        dataRow(icon: "play.circle", label: "Playback positions", detail: "So you can resume across devices")
                    }
                    .accessibilityElement(children: .combine)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("No tracking. Ever.", systemImage: "hand.raised.slash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    
                    Text("We do not collect analytics, tracking data, ad identifiers, or usage telemetry.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("With a YourPods Sync Account")
            }
            
            // MARK: - Firebase
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Account authentication uses Firebase Auth, which stores your email and a user ID. Firebase Auth may collect minimal diagnostic data required for service operation. No analytics or tracking data is collected through Firebase.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Authentication")
            }
            
            // MARK: - Legal
            Section {
                Link(destination: URL(string: "https://asecretcompany.com/yourpods-terms-of-service/")!) {
                    Label("Terms of Service", systemImage: "doc.text")
                }
                
                Link(destination: URL(string: "https://asecretcompany.com/yourpods-privacy-policy/")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            } header: {
                Text("Full Details")
            }
        }
        .navigationTitle("Your Data & Privacy")
        #if os(iOS)
        .inlineNavigationBarTitle()
        #endif
    }
    
    private func dataRow(icon: String, label: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.purple)
                .frame(width: 20)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(detail)")
    }
}
