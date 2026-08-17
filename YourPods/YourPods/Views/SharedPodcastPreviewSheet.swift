import SwiftUI

/// Preview of a shared podcast the user doesn't follow. Action: Follow.
/// Dependencies passed explicitly (macOS sheets don't inherit @Observable environments).
struct SharedPodcastPreviewSheet: View {
    let shared: SharedPodcast
    let podcastManager: PodcastManager
    @Environment(\.dismiss) private var dismiss
    @State private var isFollowing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CachedAsyncImage(url: shared.artworkUrl.flatMap(URL.init)) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.2))
                    }
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                    Text(shared.title).font(.title3.bold()).multilineTextAlignment(.center)
                    if let author = shared.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }

                    Button { Task { @MainActor in await follow() } } label: {
                        Label(isFollowing ? "Following" : "Follow Show",
                              systemImage: isFollowing ? "checkmark" : "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFollowing)
                    .padding(.horizontal)
                    .accessibilityLabel(isFollowing ? "Following \(shared.title)" : "Follow \(shared.title)")

                    if let desc = shared.podcastDescription, !desc.isEmpty {
                        Text(desc.strippingHTML()).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Shared Podcast")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func follow() async {
        do {
            try await podcastManager.addSubscription(url: shared.feedUrl)
            isFollowing = true
        } catch {
            // Subscription failed — leave the button actionable so the user can retry.
        }
    }
}
