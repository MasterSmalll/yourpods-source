import SwiftUI

/// Apple Music-style offline banner.
/// Shows a non-intrusive notification when the device has no network connectivity.
/// Suppressed in Vault Mode (local-only profile) since there's no server dependency.
///
/// Usage:
/// ```
/// OfflineBanner(onRetry: { await refreshFeeds() })
/// ```
struct OfflineBanner: View {
    @Environment(NetworkMonitor.self) private var networkMonitor
    @Environment(SettingsManager.self) private var settings
    
    /// Optional retry action — called when the user taps "Retry".
    /// If nil, the retry button is hidden (informational-only mode).
    var onRetry: (() -> Void)?
    
    var body: some View {
        let shouldShow = OfflineBannerLogic.shouldShowBanner(
            isConnected: networkMonitor.isConnected,
            isVaultMode: settings.isVaultMode
        )
        
        if shouldShow {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Connection")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Downloaded episodes are still available.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                
                Spacer()
                
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.orange, Color.orange.opacity(0.85)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.3), value: shouldShow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("No network connection. Downloaded episodes are still available.")
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

/// Playback error banner with retry button.
/// Shows when AudioManager's stream recovery is exhausted.
/// Always visible regardless of Vault Mode — streaming errors affect all profiles.
struct PlaybackErrorBanner: View {
    let errorMessage: String?
    var onRetry: (() -> Void)?
    
    var body: some View {
        if let message = errorMessage, !message.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                
                Spacer()
                
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [Color.red.opacity(0.85), Color.red.opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback error: \(message)")
            .accessibilityAddTraits(.isStaticText)
        }
    }
}
