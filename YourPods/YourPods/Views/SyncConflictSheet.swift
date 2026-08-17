import SwiftUI

/// Sheet that presents unresolved sync conflicts for user resolution.
/// Shown when the sync conflict strategy is set to "Ask".
struct SyncConflictSheet: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(PlayerManager.self) private var playerManager
    /// Written when "Always use this choice" is on — the sheet is the only place the
    /// user is looking at a concrete conflict, so it is the natural place to say
    /// "and do this every time" without hunting through Settings.
    @Environment(SettingsManager.self) private var settings

    @Environment(\.dismiss) private var dismiss

    /// When on, the side the user picks next becomes their saved `syncConflictStrategy`.
    /// Deliberately off by default and not persisted itself: a preference this broad
    /// should be an explicit act each time it is set, not a sticky checkbox that silently
    /// re-arms the next time two devices disagree.
    @State private var rememberChoice = false

    /// Rewrites with a resolve call in flight. Since the decision now waits on the server
    /// rather than committing locally first, a second tap would start a second resolve —
    /// the first renames the feed, the second finds it already gone and reports failure,
    /// leaving a prompt on screen for a change that actually succeeded.
    @State private var resolvingRewrites: Set<String> = []

    /// Whether any conflict has been seen more than once (triggers the info banner).
    private var hasRecurringConflicts: Bool {
        playerManager.pendingConflicts.contains { $0.occurrenceCount > 1 }
    }
    
    private var hasPositionConflicts: Bool {
        !playerManager.pendingConflicts.isEmpty
    }
    
    private var hasUrlRewrites: Bool {
        !playerManager.pendingUrlRewrites.isEmpty
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Position conflicts
                if hasPositionConflicts {
                    Section {
                        Text("Your device and server have different playback positions for these episodes. Choose which position to keep.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    
                    Section {
                        Toggle("Always use this choice", isOn: $rememberChoice)
                            .accessibilityHint(Text("Future position conflicts will be resolved the same way, without asking."))
                    } footer: {
                        Text("Future position conflicts will be resolved the same way, without asking.")
                    }

                    // Show info banner when conflicts keep reappearing
                    if hasRecurringConflicts {
                        Section {
                            Label {
                                Text("Recurring conflicts are usually caused by other podcast clients (e.g. gPodder) updating the same server. Each client writes its own position, causing repeated mismatches.")
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                            .listRowBackground(Color.blue.opacity(0.08))
                        }
                    }
                    
                    ForEach(playerManager.pendingConflicts) { conflict in
                        ConflictRow(conflict: conflict) { resolution in
                            resolveConflict(conflict, resolution: resolution)
                        }
                    }
                }
                
                // URL rewrite conflicts
                if hasUrlRewrites {
                    Section {
                        Text("The server has rewritten these feed URLs. Accept to update locally, or keep your current URLs.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                    
                    ForEach(playerManager.pendingUrlRewrites) { rewrite in
                        URLRewriteRow(
                            rewrite: rewrite,
                            isResolving: resolvingRewrites.contains(rewrite.id)
                        ) { accepted in
                            resolveUrlRewrite(rewrite, accepted: accepted)
                        }
                    }
                }
            }
            .navigationTitle("Sync Conflicts")
            .inlineNavigationBarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Dismiss") { dismiss() }
                }
                // "All Local", not "All from Device": the listed conflicts can
                // have been recorded by several different devices, so naming one
                // is wrong for the batch in exactly the way it is wrong for
                // the individual rows. Both buttons share one bottom bar with
                // a Spacer, so both have to stay short — which is also why
                // neither is a verb plus a bare noun ("Use All Device"), a shape
                // no Romance language reproduces without inserting an article.
                if hasPositionConflicts {
                    #if os(iOS)
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            resolveAll(resolution: .device)
                        } label: {
                            Label("All Local", systemImage: "iphone")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        Spacer()
                        Button {
                            resolveAll(resolution: .server)
                        } label: {
                            Label("All from Server", systemImage: "cloud")
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                    }
                    #else
                    ToolbarItemGroup(placement: .automatic) {
                        Button {
                            resolveAll(resolution: .device)
                        } label: {
                            Label("All Local", systemImage: "iphone")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        Button {
                            resolveAll(resolution: .server)
                        } label: {
                            Label("All from Server", systemImage: "cloud")
                        }
                        .buttonStyle(.bordered)
                        .tint(.purple)
                    }
                    #endif
                }
            }
            #if os(macOS)
            .frame(minWidth: 550, minHeight: 450)
            #endif
        }
    }
    
    /// Persists the side the user just chose as their standing preference.
    ///
    /// Saved BEFORE the resolve runs, so a resolve that fails partway still leaves the
    /// preference the user expressed — the two are separate decisions, and losing the
    /// second because the first errored would be silent.
    private func persistChoiceIfRequested(_ resolution: ConflictResolution) {
        guard rememberChoice else { return }
        settings.syncConflictStrategy = resolution.standingStrategy
    }

    private func resolveConflict(_ conflict: SyncConflict, resolution: ConflictResolution) {
        persistChoiceIfRequested(resolution)
        let position: Int
        switch resolution {
        case .device:
            position = conflict.localPosition
        case .server:
            position = conflict.serverPosition
        }
        
        // If the resolved episode is currently playing, seek the player to the chosen position
        playerManager.resolveConflictIfPlaying(conflict, chosenPosition: position)

        // Also resolve for queue items — updates QueueItem position and pushes to server
        playerManager.resolveQueueConflict(conflict, chosenPosition: position)

        // Remove from pending list
        playerManager.pendingConflicts.removeAll { $0.id == conflict.id }

        if playerManager.pendingConflicts.isEmpty && playerManager.pendingUrlRewrites.isEmpty {
            dismiss()
        }

        // Resolve via PodcastManager — updates local model, actionMap, AND uploads to server
        Task { await resolveOnServer(conflict, position: position) }
    }

    private func resolveAll(resolution: ConflictResolution) {
        persistChoiceIfRequested(resolution)
        let batch = playerManager.pendingConflicts
        var positions: [(SyncConflict, Int)] = []
        for conflict in batch {
            let position: Int
            switch resolution {
            case .device:
                position = conflict.localPosition
            case .server:
                position = conflict.serverPosition
            }
            positions.append((conflict, position))

            // If the resolved episode is currently playing, seek the player to the chosen position
            playerManager.resolveConflictIfPlaying(conflict, chosenPosition: position)

            // Also resolve for queue items
            playerManager.resolveQueueConflict(conflict, chosenPosition: position)
        }

        playerManager.pendingConflicts.removeAll()
        if playerManager.pendingUrlRewrites.isEmpty {
            dismiss()
        }

        // Sequentially, not concurrently: these share the actionMap and its persist, and a
        // single refresh after the batch is what the user needs — not one per stale row.
        Task {
            var sawStale = false
            for (conflict, position) in positions {
                if await podcastManager.resolveConflict(conflict, chosenPosition: position) == .stale {
                    sawStale = true
                }
            }
            if sawStale { await refreshAfterStaleResolution() }
        }
    }

    private func resolveOnServer(_ conflict: SyncConflict, position: Int) async {
        if await podcastManager.resolveConflict(conflict, chosenPosition: position) == .stale {
            await refreshAfterStaleResolution()
        }
    }

    /// `409 conflict_stale` says the row we answered no longer described current state, so
    /// the server pruned it instead of writing its snapshot over live values.
    ///
    /// Retrying is the one thing that cannot work — the row is gone, and the same request
    /// gets the same answer forever. Re-reading is what the user needs: if the episode is
    /// still in disagreement the current numbers come back and the sheet re-presents itself
    /// (`ContentView` binds presentation to the list being non-empty), and if it is not,
    /// nothing does. The local write already happened and stands: it is the user's
    /// statement about their own device, which a server refusal does not overturn.
    ///
    /// `bypassStrategyGate` because the user is looking at this sheet right now — the
    /// gate exists to stop *unprompted* delivery under Server Wins / Device Wins.
    private func refreshAfterStaleResolution() async {
        guard let fresh = await podcastManager.refreshServerConflicts() else { return }
        playerManager.deliverConflicts(
            fresh,
            strategy: settings.syncConflictStrategy,
            bypassStrategyGate: true
        )
    }
    
    /// Clears the prompt **only once the decision has landed**. Removing it on *send* is what
    /// made a failed resolve unrecoverable: a discarded prompt is a decision the user cannot
    /// make again, so the feed stays split between local and server with nothing left to
    /// retry from. Web has always worked this way; this brings iOS in line.
    private func resolveUrlRewrite(_ rewrite: URLRewriteConflict, accepted: Bool) {
        guard !resolvingRewrites.contains(rewrite.id) else { return }
        resolvingRewrites.insert(rewrite.id)

        Task {
            defer { resolvingRewrites.remove(rewrite.id) }

            let landed = accepted
                ? await podcastManager.acceptUrlRewrite(rewrite)
                : await podcastManager.rejectUrlRewrite(rewrite)

            guard landed else { return }

            playerManager.pendingUrlRewrites.removeAll { $0.id == rewrite.id }

            if playerManager.pendingConflicts.isEmpty && playerManager.pendingUrlRewrites.isEmpty {
                dismiss()
            }
        }
    }
}

// MARK: - Whose position the local side is

/// Who authored the position the sheet shows on the left.
///
/// "Local" on a `sync_conflicts` row means *the device that wrote the row*, not the one
/// reading it. Rendering it unconditionally as "This Device" held only while those were
/// the same device, and stopped the moment CAS rows started being authored: a row is
/// written by whichever client pushes a stale `baseVersion`, so any other device opening
/// the sheet reads someone else's position as its own.
///
/// That is not a cosmetic problem. Resolution is authoritative under the sync contract, so
/// tapping the mislabelled side writes it everywhere — the erase this workstream exists to
/// prevent, reached through the UI instead of the merge predicate.
///
/// The three cases match the web client's `localSideLabel` exactly, so the two clients
/// cannot describe the same row differently.
enum ConflictSideLabel: Equatable {
    /// The row was authored by this install.
    case thisDevice
    /// Authored by another device on the account — another phone, an iPad, the web player.
    case otherDevice
    /// No device authored it: a bridge-written row, where the local side is YourPods' own
    /// stored position facing a remote gPodder host.
    case service

    /// - Parameter deviceId: the row's author. Absent — nil **or** empty, since the column
    ///   is nullable `TEXT` and empty-string handling exists on the way out — means no
    ///   device authored it, which is a different statement from "an id that matches
    ///   nothing" and must not read as another device.
    static func local(deviceId: String?, installId: String) -> ConflictSideLabel {
        guard let deviceId, !deviceId.isEmpty else { return .service }
        return deviceId == installId ? .thisDevice : .otherDevice
    }
}

extension SyncConflict {
    func localSideLabel(installId: String = InstallIdentity.installId) -> ConflictSideLabel {
        ConflictSideLabel.local(deviceId: deviceId, installId: installId)
    }
}

// MARK: - What one side of a conflict shows

/// One side of a position conflict is not always a position.
///
/// A completed row stores `position_sec = duration`, so a finished episode and one paused
/// a second from the end render as the same timestamp. The sheet then asks the user to
/// choose between two numbers when one of them is not a position at all — the owner's
/// report: *"I'd expect the sync conflict wizard to be aware of marked as played."*
///
/// Modelled as a value rather than an `if` in the view body so the decision is assertable
/// without rendering, and so the visible text and the VoiceOver sentence cannot disagree
/// about which case they are in.
enum ConflictSideDisplay: Equatable {
    case position(Int)
    case played
}

extension SyncConflict {

    /// What to show for the server side. The flag wins over the number whatever the
    /// number is: the sync contract lets an explicit completion land with a position
    /// short of the duration, and "Played at 59:59" is a contradiction the sheet must
    /// not print.
    var serverSideDisplay: ConflictSideDisplay {
        serverCompleted ? .played : .position(serverPosition)
    }

    /// Read as one sentence — VoiceOver gets only this string, so when one side stops
    /// being a position the sentence has to stop calling it one.
    var positionsAccessibilityLabel: String {
        let local = DurationFormatting.timestamp(TimeInterval(localPosition))
        // VoiceOver gets only this sentence, so it has to name WHOSE position the first
        // number is — the whole point of the side label is that it is not always this
        // device's, and a user who cannot see the label has nothing else to go on.
        let side = localSideAccessibilityName
        switch serverSideDisplay {
        case .played:
            return String(localized: "sync.conflict.positions.a11y.serverPlayed",
                defaultValue: "\(side) is at \(local). The server has this episode marked as played.",
                comment: "VoiceOver description of a sync conflict where the server holds the episode as finished. First placeholder names whose position it is (This device / The other device / YourPods); second is a timestamp like 13:48."
            )
        case let .position(serverPosition):
            let server = DurationFormatting.timestamp(TimeInterval(serverPosition))
            return String(localized: "sync.conflict.positions.a11y",
                defaultValue: "\(side) is at \(local). The server is at \(server).",
                comment: "VoiceOver description comparing the two playback positions in a sync conflict. First placeholder names whose position it is (This device / The other device / YourPods); the other two are timestamps like 13:48."
            )
        }
    }

    /// Sentence-position name for the side that holds `localPosition`.
    var localSideAccessibilityName: String {
        switch localSideLabel() {
        case .thisDevice:
            return String(localized: "sync.conflict.side.thisDevice.a11y",
                defaultValue: "This device",
                comment: "VoiceOver: names the device that recorded a playback position, used as the subject of a sentence like 'This device is at 13:48.'"
            )
        case .otherDevice:
            return String(localized: "sync.conflict.side.otherDevice.a11y",
                defaultValue: "Your other device",
                comment: "VoiceOver: names a DIFFERENT device of the user's that recorded a playback position, used as the subject of a sentence like 'Your other device is at 13:48.'"
            )
        case .service:
            return String(localized: "sync.conflict.side.service.a11y",
                defaultValue: "YourPods",
                comment: "VoiceOver: names YourPods' own stored position (no device recorded it), used as the subject of a sentence like 'YourPods is at 13:48.' YourPods is the app name — do not translate."
            )
        }
    }

    /// The local-side button's VoiceOver label, which has to agree with the visible one:
    /// out of context "Use this device's position" for a row another device wrote is how a
    /// user keeps the value they meant to discard, and resolution then writes it everywhere.
    var useDeviceAccessibilityLabel: String {
        let position = DurationFormatting.timestamp(TimeInterval(localPosition))
        switch localSideLabel() {
        case .thisDevice:
            return String(localized: "sync.conflict.useDevice.a11y",
                defaultValue: "Use this device's position, \(position)",
                comment: "VoiceOver label for the button that keeps the position recorded by this device. Placeholder is a timestamp like 13:48."
            )
        case .otherDevice:
            return String(localized: "sync.conflict.useOtherDevice.a11y",
                defaultValue: "Use your other device's position, \(position)",
                comment: "VoiceOver label for the button that keeps the position recorded by a different device of the user's. Placeholder is a timestamp like 13:48."
            )
        case .service:
            return String(localized: "sync.conflict.useService.a11y",
                defaultValue: "Use the position YourPods has stored, \(position)",
                comment: "VoiceOver label for the button that keeps YourPods' own stored position. Placeholder is a timestamp like 13:48."
            )
        }
    }

    /// Reached directly by VoiceOver, out of the row's context, so it has to carry the
    /// same fact the row does — offering "the server's position, 1:00:00" for a row that
    /// has no position is how a user chooses the opposite of what they meant.
    var useServerAccessibilityLabel: String {
        switch serverSideDisplay {
        case .played:
            return String(localized: "sync.conflict.useServer.a11y.played",
                defaultValue: "Use the server's state: played",
                comment: "VoiceOver label for the button that adopts the server's state when the server holds the episode as finished."
            )
        case let .position(serverPosition):
            let server = DurationFormatting.timestamp(TimeInterval(serverPosition))
            return String(localized: "sync.conflict.useServer.a11y",
                defaultValue: "Use the server's position, \(server)",
                comment: "VoiceOver label for the button that adopts the server's playback position. Placeholder is a timestamp like 13:48."
            )
        }
    }

    /// Episode title for VoiceOver, falling back to the GUID the row already shows when a
    /// title is missing — so the hint never says "for " with nothing after it.
    var accessibleEpisodeName: String { episodeTitle ?? episodeGuid }

    var useServerAccessibilityHint: String {
        switch serverSideDisplay {
        case .played:
            return String(localized: "sync.conflict.useServer.a11yHint.played",
                defaultValue: "Keeps the server's played state for \(accessibleEpisodeName) and replaces this device's position",
                comment: "VoiceOver hint for the button that adopts the server's finished state. Placeholder is the episode title."
            )
        case .position:
            return String(localized: "sync.conflict.useServer.a11yHint",
                defaultValue: "Keeps this position for \(accessibleEpisodeName) and replaces this device's",
                comment: "VoiceOver hint for the button that adopts the server's playback position. Placeholder is the episode title."
            )
        }
    }
}

// MARK: - Conflict Resolution Type

enum ConflictResolution {
    case device
    case server

    /// The standing preference this choice implies, when the user asks to remember it.
    ///
    /// Deliberately a value-level mapping rather than two lines inside the sheet: it is
    /// the one place an inversion would be invisible. Saving the opposite of what the
    /// user tapped only shows up later, when the wrong side wins without prompting, and
    /// by then it looks like a sync bug rather than a settings bug.
    var standingStrategy: SyncStrategy {
        switch self {
        case .device: return .deviceWins
        case .server: return .serverWins
        }
    }
}

// MARK: - Conflict Row

private struct ConflictRow: View {
    let conflict: SyncConflict
    let onResolve: (ConflictResolution) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Episode info with album art
            HStack(alignment: .top, spacing: 12) {
                // Album art
                CachedAsyncImage(url: URL(string: conflict.artworkUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .foregroundStyle(.tertiary)
                        }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // Decorative: the episode and podcast titles beside it carry the same
                // information, so announcing the artwork only adds a stop to swipe past.
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    if let title = conflict.episodeTitle {
                        Text(title)
                            .font(.headline)
                            .lineLimit(2)
                    } else {
                        Text(conflict.episodeGuid)
                            .font(.headline)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let podcast = conflict.podcastTitle {
                        Text(podcast)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    // Occurrence count badge. "Seen" read as "you have looked at
                    // this N times"; the count is how many times the *conflict*
                    // has come back (occurrenceCount, incremented by sync, not
                    // by the user opening the sheet), which is what the banner
                    // above calls a recurring conflict.
                    if conflict.occurrenceCount > 1 {
                        Text("Recurred \(conflict.occurrenceCount) times")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
            // One element rather than three separate stops for title, show and badge.
            .accessibilityElement(children: .combine)

            // Position comparison
            HStack(spacing: 0) {
                // Device position
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        // Whose position this is. Not always this device.
                        switch conflict.localSideLabel() {
                        case .thisDevice:
                            Text("This Device")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        case .otherDevice:
                            Text("Other Device")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        case .service:
                            Text("YourPods")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(formatDuration(conflict.localPosition))
                            .font(.subheadline.monospacedDigit().weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                
                // Server position
                HStack(spacing: 6) {
                    Image(systemName: "cloud")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Server")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        switch conflict.serverSideDisplay {
                        case .played:
                            // A completed row stores position = duration; printing that
                            // timestamp claims a position the server does not hold.
                            Text("Played")
                                .font(.subheadline.weight(.medium))
                        case let .position(serverPosition):
                            Text(formatDuration(serverPosition))
                                .font(.subheadline.monospacedDigit().weight(.medium))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Read as one sentence. Left to itself this is four fragments and an
            // undescribed arrow glyph — "Device, 13:48, Server, 36:07" — which states the
            // two numbers without ever saying they are in conflict.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(conflict.positionsAccessibilityLabel)

            // Resolution buttons
            HStack(spacing: 10) {
                Button {
                    onResolve(.device)
                } label: {
                    // The button follows the label: offering "Use Device" for a row another
                    // device wrote is how a user keeps a position they meant to discard.
                    switch conflict.localSideLabel() {
                    case .thisDevice:
                        Label("Use This Device", systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                    case .otherDevice:
                        Label("Use Other Device", systemImage: "iphone")
                            .frame(maxWidth: .infinity)
                    case .service:
                        Label("Use YourPods", systemImage: "headphones")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .controlSize(.small)
                // Out of context "Use Device" says neither which episode nor which
                // position it keeps — and keeping the wrong one silently discards
                // listening done elsewhere, which is the whole reason this sheet exists.
                .accessibilityLabel(conflict.useDeviceAccessibilityLabel)
                .accessibilityHint(String(localized: "sync.conflict.useDevice.a11yHint",
                    defaultValue: "Keeps this position for \(episodeName) and replaces the server's",
                    comment: "VoiceOver hint for the button that keeps the local playback position. Placeholder is the episode title."
                ))

                Button {
                    onResolve(.server)
                } label: {
                    Label("Use Server", systemImage: "cloud")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.small)
                .accessibilityLabel(conflict.useServerAccessibilityLabel)
                .accessibilityHint(conflict.useServerAccessibilityHint)
            }
        }
        .padding(.vertical, 6)
    }

    /// Episode title for VoiceOver, falling back to the GUID the row already shows when a
    /// title is missing — so the hint never says "for " with nothing after it.
    private var episodeName: String {
        conflict.episodeTitle ?? conflict.episodeGuid
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        DurationFormatting.timestamp(TimeInterval(seconds))
    }
}

// MARK: - URL Rewrite Row

private struct URLRewriteRow: View {
    let rewrite: URLRewriteConflict
    let isResolving: Bool
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CachedAsyncImage(url: URL(string: rewrite.artworkUrl ?? "")) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "link")
                                .foregroundStyle(.tertiary)
                        }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    if let title = rewrite.podcastTitle {
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Label {
                        Text("Server rewrote feed URL")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(localized: "sync.conflict.oldUrl",
                                defaultValue: "Old:",
                                comment: "Label on the previous feed URL in a feed-moved conflict row; the URL follows on the same line. Keep the trailing colon only if your language uses one."))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(rewrite.oldUrl)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(String(localized: "sync.conflict.newUrl",
                                defaultValue: "New:",
                                comment: "Label on the replacement feed URL in a feed-moved conflict row; the URL follows on the same line. Keep the trailing colon only if your language uses one."))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                    Text(rewrite.newUrl)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                }
            }
            // Spelled character by character, a feed URL is unusable as speech. The part
            // that actually differs is nearly always the host, so announce that and leave
            // the full URLs on screen for anyone reading them.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "sync.conflict.rewriteHosts.a11y",
                defaultValue: "Moving from \(host(rewrite.oldUrl)) to \(host(rewrite.newUrl))",
                comment: "VoiceOver description of a feed address change. Placeholders are website host names such as feeds.example.com."
            ))

            HStack(spacing: 10) {
                Button {
                    onResolve(true)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
                .disabled(isResolving)
                .accessibilityLabel(String(localized: "sync.conflict.acceptRewrite.a11y",
                    defaultValue: "Accept the new feed address",
                    comment: "VoiceOver label for the button that follows a podcast to its new feed address."
                ))
                .accessibilityHint(String(localized: "sync.conflict.acceptRewrite.a11yHint",
                    defaultValue: "Follows \(showName) to \(host(rewrite.newUrl)). Your settings and groups move with it.",
                    comment: "VoiceOver hint for accepting a feed address change. First placeholder is the podcast title, second is a website host name."
                ))

                Button {
                    onResolve(false)
                } label: {
                    Label("Keep Local", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
                .disabled(isResolving)
                .accessibilityLabel(String(localized: "sync.conflict.keepLocalRewrite.a11y",
                    defaultValue: "Keep the current feed address",
                    comment: "VoiceOver label for the button that declines a podcast's feed address change."
                ))
                .accessibilityHint(String(localized: "sync.conflict.keepLocalRewrite.a11yHint",
                    defaultValue: "Keeps \(showName) on \(host(rewrite.oldUrl)) and stops asking",
                    comment: "VoiceOver hint for declining a feed address change. First placeholder is the podcast title, second is a website host name."
                ))
            }
        }
        .padding(.vertical, 6)
    }

    /// Podcast title for VoiceOver, falling back to the old host so a hint never trails off.
    private var showName: String {
        rewrite.podcastTitle ?? host(rewrite.oldUrl)
    }

    /// Host only — the readable part of a feed URL. Falls back to the whole string if it
    /// won't parse, which is still better than announcing nothing.
    private func host(_ urlString: String) -> String {
        URL(string: urlString)?.host() ?? urlString
    }
}
