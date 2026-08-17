import SwiftUI

/// A persistent Settings row that surfaces the Pro upgrade option.
/// Visible for every non-Pro user (Pro users get the tier badge in the account
/// header instead). Tapping it presents the ProPaywallView as a sheet.
struct ProNudgeRow: View {
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @Environment(SettingsManager.self) private var settings
    @State private var showPaywall = false

    var body: some View {
        // Free users only; Pro users see the tier badge in the account header.
        if !subscriptionManager.isPro {
            Section {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "star.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.purple)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("YourPods Pro")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Support development & unlock extra features")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // Was `.tertiary` — too faint to read against the row
                            // background (reported on-device). Bumped to `.secondary`.
                            Text("Use gPodder or Nextcloud? You can still subscribe to help keep YourPods going.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                // `.plain` stops the list-row Button from tinting the whole label
                // with the accent colour, which washed the text out to a faint
                // blue and made it hard to read; the explicit foreground styles
                // above now render as intended.
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("YourPods Pro")
                .accessibilityHint("Support development and unlock extra features")
                .sheet(isPresented: $showPaywall) {
                    NavigationStack {
                        ProPaywallView(onSkip: {
                            showPaywall = false
                        }, onDoNotAskAgain: {
                            settings.proNudgeDismissed = true
                            showPaywall = false
                        })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showPaywall = false }
                            }
                        }
                    }
                }
            }
        }
    }
}
