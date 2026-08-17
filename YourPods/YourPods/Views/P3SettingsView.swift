import SwiftUI

/// P3 — Privacy Preserving Playback settings screen.
///
/// Dedicated screen accessible from Settings → Playback → P3.
/// Provides the global P3 toggle with detailed explanations of what it does.
/// P3 targets download/listener tracking redirects only — it is not an ad blocker.
struct P3SettingsView: View {
    @Environment(SettingsManager.self) private var settings
    @State private var showP3EnabledAlert = false
    
    var body: some View {
        Form {
            // MARK: - Main Toggle
            Section {
                Toggle(isOn: Binding(
                    get: { settings.p3Enabled },
                    set: { settings.p3Enabled = $0 }
                )) {
                    Label("Enable P3", systemImage: "shield.checkered")
                }
            } footer: {
                Text("When enabled, YourPods removes known tracking redirects from episode URLs before playback. Your device connects directly to the audio host.")
            }
            
            // MARK: - What P3 Does
            Section {
                InfoRow(
                    icon: "chart.bar.xaxis",
                    title: "Removes Download Tracking",
                    detail: "Many podcast analytics services track when you download or stream an episode. P3 bypasses these trackers."
                )
                
                InfoRow(
                    icon: "network.slash",
                    title: "No Network to Trackers",
                    detail: "Your device never contacts tracking servers — not even a single request. The URL is cleaned locally on your device before playback begins."
                )
            } header: {
                Text("What P3 Does")
            }
            
            // MARK: - Good to Know
            Section {
                InfoRow(
                    icon: "speaker.wave.2.bubble",
                    title: "Not an Ad Blocker",
                    detail: "P3 removes tracking redirects, not ads. Many podcasts stitch ads directly into the audio file, and P3 does not change that."
                )

                InfoRow(
                    icon: "exclamationmark.triangle",
                    title: "Some Podcasts May Not Play",
                    detail: "If P3 causes playback issues, you'll see a notification with a link to turn it off for that specific podcast. You can override P3 per-podcast in Library → Podcast → Settings."
                )
                
                InfoRow(
                    icon: "heart",
                    title: "Support Your Favorite Podcasts",
                    detail: "Podcast creators use download tracking to measure their audience, which affects their ad revenue. Consider turning P3 off for podcasts you want to support."
                )
                
                InfoRow(
                    icon: "slider.horizontal.3",
                    title: "Per-Podcast Control",
                    detail: "You can override this global setting for individual podcasts. Go to Library → tap a podcast → Settings → Privacy to enable or disable P3 for specific shows."
                )
            } header: {
                Text("Good to Know")
            }
            
            // MARK: - Learn More
            Section {
                Link(destination: URL(string: "https://yourpods.app/p3")!) {
                    HStack {
                        Label("Learn More", systemImage: "safari")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint("Opens yourpods.app/p3 in Safari")
            } footer: {
                Text("Visit yourpods.app/p3 for a detailed explanation of how P3 works and why we built it.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("P3")
        #if os(iOS)
        .inlineNavigationBarTitle()
        #endif
        .onChange(of: settings.p3Enabled) { _, newValue in
            if newValue {
                showP3EnabledAlert = true
            }
        }
        .alert("P3 is Now Active", isPresented: $showP3EnabledAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Tracking redirects will be stripped from episode URLs for all podcasts.\n\nYou can override this for individual podcasts in Library → Podcast → Settings.")
        }
    }
}

// MARK: - Info Row

/// A row with an icon, title, and multi-line detail text for informational sections.
private struct InfoRow: View {
    let icon: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .padding(.top, 2)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "a11y.settings.titleWithDetail",
                                   defaultValue: "\(String(localized: title)). \(String(localized: detail))",
                                   comment: "VoiceOver label for a settings row that has an explanatory subtitle. Argument 1 is the setting's name, 2 the explanation."))
    }
}
