import Foundation
#if canImport(Intents)
import Intents
#endif

// MARK: - Protocol

/// Abstraction for donating media playback intents to the system.
/// The system uses these donations to surface episodes in Control Center
/// media suggestions (the "recently played" row).
protocol MediaIntentDonating: Sendable {
    /// Donate a playback intent for the given queue item.
    /// Implementations should deduplicate: calling twice with the same item ID
    /// should only donate once.
    func donatePlayback(for item: QueueItem)
}

// MARK: - Production Implementation

/// Donates `INPlayMediaIntent` interactions to the system so episodes
/// appear in Control Center / Lock Screen media suggestions.
///
/// `INPlayMediaIntent`, `INMediaItem` and `INImage` are unavailable on macOS
/// even though `Intents` itself imports there — `canImport(Intents)` is true
/// but the media classes do not exist. The donation body is therefore gated
/// on `os(iOS)`, while the type and its `MediaIntentDonating` conformance stay
/// cross-platform so `AudioManager.mediaIntentDonor` and `YourPodsApp` compile
/// unchanged. On macOS donation is a no-op; there is no Control Center media
/// suggestions surface to donate to.
final class MediaIntentDonationService: MediaIntentDonating, @unchecked Sendable {
    #if os(iOS)
    /// The last episode ID that was donated, used to prevent duplicate donations
    /// when the user pauses/resumes the same episode.
    private var lastDonatedId: String?

    /// Creates the `INPlayMediaIntent` for a queue item. Extracted for testability.
    func makePlayMediaIntent(for item: QueueItem) -> INPlayMediaIntent {
        let mediaItem = INMediaItem(
            identifier: item.id,
            title: item.title,
            type: .podcastEpisode,
            artwork: item.artworkUrl.flatMap(URL.init(string:)).flatMap { INImage(url: $0) },
            artist: item.podcastTitle
        )

        let container = INMediaItem(
            identifier: item.podcastUrl,
            title: item.podcastTitle,
            type: .podcastShow,
            artwork: nil
        )

        return INPlayMediaIntent(
            mediaItems: [mediaItem],
            mediaContainer: container,
            playShuffled: false,
            playbackRepeatMode: .none,
            resumePlayback: true,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: nil
        )
    }

    func donatePlayback(for item: QueueItem) {
        // Dedup: don't re-donate the same episode
        guard item.id != lastDonatedId else { return }
        lastDonatedId = item.id

        let intent = makePlayMediaIntent(for: item)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.donate { error in
            if let error {
                // Fire-and-forget: log but don't crash
                print("Media intent donation failed: \(error.localizedDescription)")
            }
        }
    }
    #else
    /// No-op on macOS — see the type documentation.
    func donatePlayback(for item: QueueItem) {}
    #endif
}
