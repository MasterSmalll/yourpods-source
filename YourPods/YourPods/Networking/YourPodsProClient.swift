// ─── YourPods Pro ────────────────────────────────────────────────────────
// This client is used EXCLUSIVELY for YourPods Pro enhanced sync.
// It is NOT required to build or run the app — Vault Mode (local-only)
// and gPodder sync work without it.
//
// For up-to-date information on the app source and YourPods Pro
// spec/source, visit: https://opensource.yourpods.app
// ─────────────────────────────────────────────────────────────────────────

import Foundation
import os

/// Enhanced sync client for the YourPods Pro API (`/api/yourpods/`).
///
/// Supports all gPodder-compatible operations via `SyncClient` protocol,
/// plus queue sync, settings sync, and playback handoff that the gPodder
/// protocol does not support.
///
/// Authentication is delegated to an `AuthProvider` (Firebase, Supabase, etc.)
/// which supplies JWT Bearer tokens for each request.
actor YourPodsProClient: SyncClient, GroupsSyncCapable {
    private let logger = Logger(subsystem: "com.yourpods", category: "YourPodsProClient")
    
    let baseUrl: String
    private let authProvider: any AuthProvider
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    init(baseUrl: String, authProvider: any AuthProvider, session: URLSession = .shared) {
        self.baseUrl = URLSanitizer.sanitize(baseUrl)
        self.authProvider = authProvider
        self.session = session
        
        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        self.encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }
    
    // MARK: - SyncClient Protocol
    
    var supportsQueueSync: Bool { true }
    var supportsSettingsSync: Bool { true }
    var supportsPlaybackReconciliation: Bool { true }
    var returnsFullSubscriptionList: Bool { true }
    
    func pushSubscriptions(add: [String], remove: [String], deviceId: String) async throws -> [URLRewrite] {
        for url in add {
            try await addSubscription(podcastUrl: url)
        }
        for url in remove {
            try await removeSubscription(podcastUrl: url)
        }
        // YourPods Pro doesn't return URL rewrites — it's not a gPodder quirk
        return []
    }
    
    func pullSubscriptionChanges(deviceId: String, since: Int) async throws -> SubscriptionDelta {
        // YourPods Pro returns a full list (not delta); timestamp is ISO8601 string
        let data = try await performGET(path: "/api/yourpods/subscriptions")
        
        struct SubsResponse: Codable {
            let subscriptions: [String]?
            let timestamp: String?  // ISO8601 from server
        }
        
        let response = try decoder.decode(SubsResponse.self, from: data)
        let ts = Self.parseTimestamp(response.timestamp) ?? Int(Date().timeIntervalSince1970)
        return SubscriptionDelta(
            add: response.subscriptions ?? [],
            remove: [],
            timestamp: ts
        )
    }
    
    func uploadEpisodeActions(_ actions: [EpisodeAction]) async throws -> [URLRewrite] {
        _ = try await uploadEpisodeActionsRecordingVersions(actions)
        // No URL rewrites from YourPods Pro
        return []
    }

    /// Per the sync contract: the same batch, with the acks read back instead of thrown
    /// away. See the protocol requirement for why these pushes stay versionless but their
    /// answer cannot be discarded.
    func uploadEpisodeActionsRecordingVersions(
        _ actions: [EpisodeAction]
    ) async throws -> [ProPlaybackSyncResponse.Accepted] {
        // Filter to play actions only; batch all into a single POST (server prefers this)
        let playActions = actions.filter { $0.action == "play" }
        guard !playActions.isEmpty else { return [] }

        let items = playActions.map { action in
            ProPlaybackSyncRequest(
                podcastUrl: action.podcast,
                episodeUrl: action.episode,
                episodeGuid: action.guid,
                positionSec: Double(action.position ?? 0),
                durationSec: action.total.map { Double($0) },
                nowPlaying: nil,
                completed: nil,
                deviceId: action.device,
                // The action already carries its own event time; sending it nil made an
                // iOS-origin write indistinguishable from a gPodder one, which is the gate
                // on the server's `position >= duration` auto-complete. With a frozen or
                // short duration that marks an episode paused near the end as played.
                //
                // The action's OWN timestamp, never now(): a re-sent outbox entry stamped
                // now() would beat newer server state. Omitted when there is no usable
                // timestamp — the epoch is not "unknown", it is an event time that loses
                // every comparison, which discards the push just as silently.
                clientUpdatedAt: action.timestamp > 0
                    ? Date(timeIntervalSince1970: TimeInterval(action.timestamp))
                    : nil,
                // Legacy last-write-wins: these are gPodder-shaped actions replayed from
                // the outbox, with no per-episode baseline to speak for.
                baseVersion: nil
            )
        }
        let body = try encoder.encode(items)   // encode as JSON array
        let data = try await performPOST(path: "/api/yourpods/playback/sync", body: body)
        logger.info("Batch uploaded \(items.count) playback positions")

        // A deployment predating the ack half of the sync contract answers with no arrays,
        // and a decode failure here must not fail an upload the server already committed —
        // the actions ARE pushed, we simply learn nothing about versions. Same tolerance as
        // the CAS seam.
        guard let response = try? decoder.decode(ProPlaybackSyncResponse.self, from: data) else {
            logger.debug("Batch upload: no ack payload — versions not advanced")
            return []
        }
        return response.accepted
    }
    
    func getEpisodeActions(since: Int) async throws -> [EpisodeAction] {
        // Protocol conformance — discard hidden + completed + uncompleted changes.
        // ⚠️ This signature must keep matching the `SyncClient` requirement EXACTLY:
        // an extra or defaulted parameter stops it witnessing and silently falls
        // through to the no-op protocol default (shipped regression, twice).
        //
        // The Int is the shared SyncClient Unix cursor, but the server parses
        // `?since=` as RFC3339 only (per the sync contract) and silently full-syncs
        // anything else — so convert rather than send an integer it will ignore.
        let token = since > 0
            ? Self.cursorFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(since)))
            : nil
        return try await getEpisodeActionsWithHiddenChanges(sinceToken: token).actions
    }

    /// Fetch episode actions AND hidden state changes from a single
    /// `GET /playback/recent` call. Eliminates the duplicate network
    /// round-trip that `getHiddenStateChanges(since:)` previously made
    /// to the same endpoint.
    ///
    /// - Parameter sinceToken: The `timestamp` from the previous response, passed
    ///   back **verbatim** as an opaque cursor. `nil` requests a full sync. Treating
    ///   it as opaque is deliberate: a cursor re-derived from action timestamps is a
    ///   *client* clock, and a device running fast would starve itself of changes
    ///   (per the sync contract).
    /// - Returns: the parsed changes plus the server's new cursor token.
    func getEpisodeActionsWithHiddenChanges(
        sinceToken: String?
    ) async throws -> (actions: [EpisodeAction], hiddenChanges: [HiddenStateChange], completedChanges: [CompletedStateChange], uncompletedChanges: [UncompletedStateChange], serverToken: String?) {
        // Server key is "states" (not "actions"); timestamp is ISO8601 string
        var path = "/api/yourpods/playback/recent"
        if let sinceToken, !sinceToken.isEmpty,
           let encoded = sinceToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?since=\(encoded)"
        }
        let data = try await performGET(path: path)
        let parsed = try Self.parseRecentResponse(data)
        return (actions: parsed.actions, hiddenChanges: parsed.hidden, completedChanges: parsed.completed, uncompletedChanges: parsed.uncompleted, serverToken: parsed.serverToken)
    }

    /// RFC3339 with fractional seconds — the only `?since=` form the server accepts.
    nonisolated static let cursorFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Pure decode of a `GET /playback/recent` response into episode actions +
    /// hidden + completed side-channels. Extracted from
    /// `getEpisodeActionsWithHiddenChanges` so the decode is unit-testable
    /// without a network round-trip.
    nonisolated static func parseRecentResponse(
        _ data: Data
    ) throws -> (actions: [EpisodeAction], hidden: [HiddenStateChange], completed: [CompletedStateChange], uncompleted: [UncompletedStateChange], serverToken: String?) {
        struct RecentResponse: Codable {
            let states: [ProPlaybackAction]?   // key changed: actions → states
            let timestamp: String?
        }
        struct ProPlaybackAction: Codable {
            let podcastUrl: String
            let episodeUrl: String
            let episodeGuid: String?
            let positionSec: Double
            let durationSec: Double?
            let updatedAt: String?
            let completed: Bool?
            let hidden: Bool?      // ← added in a later release
        }

        let response = try JSONDecoder().decode(RecentResponse.self, from: data)
        let states = response.states ?? []

        // Map episode actions (same as before)
        let actions = states.map { action in
            EpisodeAction(
                podcast: action.podcastUrl,
                episode: action.episodeUrl,
                guid: action.episodeGuid,
                action: "play",
                timestamp: Self.parseTimestamp(action.updatedAt) ?? Int(Date().timeIntervalSince1970),
                position: Int(action.positionSec),
                started: 0,
                total: action.durationSec.map { Int($0) },
                device: nil
            )
        }

        // Extract hidden state changes from the same response
        let hidden: [HiddenStateChange] = states.compactMap { action in
            guard let hidden = action.hidden else { return nil }
            let guid = action.episodeGuid ?? action.episodeUrl
            return HiddenStateChange(guid: guid, hidden: hidden)
        }

        // Extract completed (finished) state changes. Emit ONLY for completed==true:
        // the server is authoritative for *completion*, and the pull side must never
        // un-complete an episode (that would re-introduce the resurrection bug).
        let completed: [CompletedStateChange] = states.compactMap { action in
            guard action.completed == true else { return nil }
            let guid = action.episodeGuid ?? action.episodeUrl
            return CompletedStateChange(guid: guid)
        }

        // Emit ONLY when position has been reset to zero. Genuine un-completes
        // (re-add / relisten) always reset position to 0 via the server's
        // MarkPlaybackUncompleted; a high-position completed:false row is a
        // "paused near the end" episode, and emitting for it would un-play an
        // episode the position>=threshold inference (applyActionsForPodcast) just
        // marked played — a played->unplayed regression.
        let uncompleted: [UncompletedStateChange] = states.compactMap { action in
            guard action.completed == false, action.positionSec == 0 else { return nil }
            let guid = action.episodeGuid ?? action.episodeUrl
            return UncompletedStateChange(guid: guid)
        }

        // The server's own cursor. Surfaced verbatim — never re-derived from the action
        // timestamps above, which carry whichever client's clock wrote them.
        return (actions: actions, hidden: hidden, completed: completed, uncompleted: uncompleted, serverToken: response.timestamp)
    }
    
    @discardableResult
    func syncQueue(items: [QueueSyncItem]) async throws -> QueueSyncResult {
        try await syncQueue(items: items, baseVersion: nil)
    }

    func syncQueue(items: [QueueSyncItem], baseVersion: Int64?) async throws -> QueueSyncResult {
        let proItems = items.map { item in
            ProQueueSyncItem(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.episodeUrl,
                episodeGuid: item.episodeGuid,
                sortOrder: item.sortOrder,
                positionSec: item.positionSec,
                title: item.title,
                podcastTitle: item.podcastTitle,
                artworkUrl: item.artworkUrl,
                durationSec: item.durationSec
            )
        }
        let request = ProQueueSyncRequest(items: proItems, baseVersion: baseVersion)
        let body = try encoder.encode(request)
        logger.info("Queue sync: pushing \(items.count) items (\(body.count) bytes, baseVersion=\(baseVersion.map(String.init) ?? "nil"))")
        let data = try await performPOST(path: "/api/yourpods/queue/sync", body: body)
        
        // Parse the server's authoritative response queue
        let response = try decoder.decode(ProQueueResponse.self, from: data)
        let droppedCount = response.droppedItems?.count ?? 0
        logger.info("Queue synced: pushed \(items.count) items, server returned \(response.queue.count) (explicitly dropped \(droppedCount))")
        
        // Diagnostic: detect items the server silently dropped (bug tracking)
        // Only count it as silently dropped if it's NOT in the explicit droppedItems list
        if response.queue.count + droppedCount < items.count {
            let responseGuids = Set(response.queue.compactMap(\.episodeGuid))
            let responseUrls = Set(response.queue.map(\.episodeUrl))
            let explicitDroppedGuids = Set(response.droppedItems?.compactMap(\.guid) ?? [])
            let explicitDroppedUrls = Set(response.droppedItems?.map(\.episodeUrl) ?? [])
            
            for pushed in items {
                let guidMatch = pushed.episodeGuid.map { responseGuids.contains($0) || explicitDroppedGuids.contains($0) } ?? false
                let urlMatch = responseUrls.contains(pushed.episodeUrl) || explicitDroppedUrls.contains(pushed.episodeUrl)
                if !guidMatch && !urlMatch {
                    logger.warning("Queue sync: SERVER SILENTLY DROPPED item: \(pushed.title ?? "nil") guid=\(pushed.episodeGuid ?? "nil") url=\(pushed.episodeUrl) sortOrder=\(pushed.sortOrder)")
                }
            }
        }
        
        let mappedItems = response.queue.map { item in
            QueueSyncItem(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.episodeUrl,
                episodeGuid: item.episodeGuid,
                sortOrder: item.sortOrder,
                positionSec: item.positionSec,
                title: item.title,
                podcastTitle: item.podcastTitle,
                artworkUrl: item.artworkUrl,
                durationSec: item.durationSec
            )
        }
        
        let mappedDropped = response.droppedItems?.map { dropped in
            QueueDroppedItem(
                episodeUrl: dropped.episodeUrl,
                title: dropped.title,
                guid: dropped.guid,
                reason: dropped.reason
            )
        } ?? []
        
        return QueueSyncResult(items: mappedItems, droppedItems: mappedDropped, version: response.version)
    }

    func getQueue() async throws -> [QueueSyncItem] {
        try await getQueueWithVersion().items
    }

    func getQueueWithVersion() async throws -> QueueSyncPullResult {
        let data = try await performGET(path: "/api/yourpods/queue")
        let response = try decoder.decode(ProQueueResponse.self, from: data)
        let items = response.queue.map { item in
            QueueSyncItem(
                podcastUrl: item.podcastUrl,
                episodeUrl: item.episodeUrl,
                episodeGuid: item.episodeGuid,
                sortOrder: item.sortOrder,
                positionSec: item.positionSec,
                title: item.title,
                podcastTitle: item.podcastTitle,
                artworkUrl: item.artworkUrl,
                durationSec: item.durationSec
            )
        }
        return QueueSyncPullResult(items: items, version: response.version)
    }
    
    func deleteQueueItem(episodeUrl: String) async throws {
        guard let encoded = episodeUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            logger.error("Failed to encode episodeUrl for queue deletion: \(episodeUrl)")
            return
        }
        try await performDELETE(path: "/api/yourpods/queue?episodeUrl=\(encoded)")
        logger.info("Deleted queue item: \(episodeUrl)")
    }

    func addToQueue(item: QueueSyncItem, addToTop: Bool) async throws {
        struct AddRequest: Encodable {
            let podcastUrl: String
            let episodeUrl: String
            let episodeGuid: String?
            let title: String?
            let podcastTitle: String?
            let artUrl: String?
            let addToTop: Bool
        }
        let req = AddRequest(
            podcastUrl: item.podcastUrl, episodeUrl: item.episodeUrl, episodeGuid: item.episodeGuid,
            title: item.title, podcastTitle: item.podcastTitle, artUrl: item.artworkUrl, addToTop: addToTop
        )
        // camelCase endpoint — do NOT use self.encoder (.convertToSnakeCase). The server
        // decodes json:"episodeUrl","addToTop", etc.; snake_case keys silently 400.
        // Same fix as encodeAnnotationSyncBody (line ~847).
        let body = try JSONEncoder().encode(req)
        try await performPOST(path: "/api/yourpods/queue/add", body: body)
        logger.info("Added queue item on server (additive): \(item.episodeUrl)")
    }

    // MARK: - Enhanced API (Non-Protocol)
    
    /// Validate the session and get user info.
    func validateSession() async throws -> ProSessionResponse {
        let data = try await performPOST(path: "/auth/session", body: nil)
        do {
            return try decoder.decode(ProSessionResponse.self, from: data)
        } catch {
            // Log raw server response to help diagnose shape mismatches
            let raw = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
            logger.error("validateSession decode failed: \(error.localizedDescription)")
            logger.error("Server response was: \(raw)")
            throw error
        }
    }
    
    /// Permanently delete the user's YourPods Sync account and all associated data.
    ///
    /// The server handles Firebase Auth deletion via the Admin SDK — the iOS app
    /// must NOT call `user.delete()`. After a successful 200 response, call
    /// `Auth.auth().signOut()` locally and clear Keychain/profile data.
    ///
    /// - Parameter reason: Optional user feedback about why they're leaving.
    func deleteAccount(reason: String? = nil) async throws {
        struct DeleteRequest: Encodable {
            let confirmation: String
            let reason: String?
        }
        let request = DeleteRequest(confirmation: "DELETE", reason: reason)
        let body = try encoder.encode(request)
        try await performPOST(path: "/account/delete", body: body)
        logger.info("Server account and all data deleted")
    }

    /// Change the user's password. The server verifies the current password
    /// and updates to the new one. All refresh tokens are revoked server-side.
    ///
    /// After success, the caller should sign out locally and navigate to login.
    ///
    /// - Parameters:
    ///   - currentPassword: The user's current password (verified server-side).
    ///   - newPassword: The new password (min 6 characters, enforced server-side).
    func changePassword(currentPassword: String, newPassword: String) async throws {
        struct ChangePasswordRequest: Encodable {
            let currentPassword: String
            let newPassword: String
        }
        let request = ChangePasswordRequest(currentPassword: currentPassword, newPassword: newPassword)
        let body = try encoder.encode(request)
        try await performPOST(path: "/account/change-password", body: body)
        logger.info("Password changed successfully")
    }


    /// Push current playback position to the server.
    ///
    /// ⚠️ This signature must keep matching the `SyncClient` requirement EXACTLY —
    /// including `baseVersion`, which is intentionally NOT defaulted here. A defaulted
    /// parameter changes the declaration name, stops it witnessing the requirement, and
    /// every `any SyncClient` call site silently reaches the no-op default instead. That
    /// exact failure has shipped twice (`getCurrentPlayback`, `uncompletePlayback`).
    @discardableResult
    func syncPlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        positionSec: Double,
        durationSec: Double?,
        nowPlaying: Bool?,
        completed: Bool?,
        deviceId: String?,
        clientUpdatedAt: Date?,
        baseVersion: Int64?
    ) async throws -> ProPlaybackSyncResponse? {
        let request = ProPlaybackSyncRequest(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid,
            positionSec: positionSec,
            durationSec: durationSec,
            nowPlaying: nowPlaying,
            completed: completed,
            deviceId: deviceId,
            clientUpdatedAt: clientUpdatedAt,
            baseVersion: baseVersion
        )
        let body = try encoder.encode(request)
        let data = try await performPOST(path: "/api/yourpods/playback/sync", body: body)
        // `try?`, not `try`: the push itself already succeeded (non-2xx throws inside
        // performPOST). A body we cannot parse — an empty one, a proxy that stripped it,
        // an older server — means there is no CAS answer to act on, which is
        // not the same as a failed write and must not be reported as one.
        return try? decoder.decode(ProPlaybackSyncResponse.self, from: data)
    }
    
    /// Get the most recent playback state from the server.
    /// Server wraps the state in `{ "state": { ... } }`.
    // Signature MUST stay `getCurrentPlayback()` — exactly matching the
    // `SyncClient` protocol requirement. An extra (even defaulted) parameter
    // changes the declaration name to `getCurrentPlayback(episodeUrl:)`, which
    // no longer witnesses the requirement; every call site holds the client as
    // `any SyncClient`, so the call would silently dispatch to the protocol's
    // default no-op (`return nil`) and the now-playing read would vanish.
    func getCurrentPlayback() async throws -> ProPlaybackState? {
        let data = try await performGET(path: "/api/yourpods/playback/current")
        struct Wrapper: Codable { let state: ProPlaybackState? }
        // Diagnostic: a silent `try?` here was indistinguishable from "server has no
        // state." Log the decode outcome so a "device isn't pulling" report can be
        // pinned to decode-failure vs genuinely-empty vs a populated state.
        do {
            let state = try decoder.decode(Wrapper.self, from: data).state
            if let state {
                // Public: decode-shape booleans/ints (no PII). Private: the episode
                // title (user content — redacted in archived/exported logs).
                logger.info("getCurrentPlayback: decoded state nowPlaying=\(state.nowPlaying.map(String.init) ?? "nil", privacy: .public) completed=\(state.completed.map(String.init) ?? "nil", privacy: .public) pos=\(Int(state.positionSec), privacy: .public)s title='\(state.title ?? "?")'")
            } else {
                logger.info("getCurrentPlayback: server returned state=nil (no active playback)")
            }
            return state
        } catch {
            // Non-PII decode breadcrumb: the SET of top-level key names the body
            // carried (field names, not values) pinpoints a shape/rename mismatch
            // without logging any user content. Body length is public; the raw body
            // and decode-error text stay default-private (redacted in archived logs).
            var keyReport = "unparseable-json"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let inner = (obj["state"] as? [String: Any]) ?? obj
                keyReport = inner.keys.sorted().joined(separator: ",")
            }
            let body = String(data: data.prefix(512), encoding: .utf8) ?? "<non-utf8>"
            logger.error("getCurrentPlayback: DECODE FAILED bodyLen=\(data.count, privacy: .public) keys=[\(keyReport, privacy: .public)] — \(error.localizedDescription) body=\(body)")
            return nil
        }
    }
    
    func uncompletePlayback(
        podcastUrl: String,
        episodeUrl: String,
        episodeGuid: String?,
        clientUpdatedAt: Date?
    ) async throws {
        struct UncompleteRequest: Encodable {
            let podcastUrl: String
            let episodeUrl: String
            let episodeGuid: String?
            let clientUpdatedAt: String?
        }
        let iso8601: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let req = UncompleteRequest(
            podcastUrl: podcastUrl,
            episodeUrl: episodeUrl,
            episodeGuid: episodeGuid,
            clientUpdatedAt: clientUpdatedAt.map { iso8601.string(from: $0) }
        )
        // camelCase endpoint — do NOT use self.encoder (.convertToSnakeCase). The server
        // decodes json:"episodeUrl","clientUpdatedAt", etc.; snake_case keys silently 400.
        // Same fix as encodeAnnotationSyncBody (line ~847).
        let body = try JSONEncoder().encode(req)
        try await performPOST(path: "/api/yourpods/playback/uncomplete", body: body)
        logger.info("Un-completed episode on server: \(episodeUrl)")
    }

    /// Subscribe to a podcast.
    func addSubscription(podcastUrl: String) async throws {
        let request = ProSubscriptionAddRequest(podcastUrl: podcastUrl)
        let body = try encoder.encode(request)
        try await performPOST(path: "/api/yourpods/subscriptions/add", body: body)
    }
    
    /// Unsubscribe from a podcast.
    /// Server contract: POST /api/yourpods/subscriptions/remove
    /// Body: { "podcast_url": "..." } — server accepts podcastUrl, podcast_url, feedUrl, url, etc.
    func removeSubscription(podcastUrl: String) async throws {
        let request = ProSubscriptionRemoveRequest(podcastUrl: podcastUrl)
        let body = try encoder.encode(request)
        try await performPOST(path: "/api/yourpods/subscriptions/remove", body: body)
    }

    
    /// Bulk migrate local data to the server (first-time Pro connect).
    func migrate(subscriptions: [String], episodeActions: [EpisodeAction]) async throws -> ProMigrateResponse {
        let actions = episodeActions.map { action in
            ProMigrateAction(
                podcast: action.podcast,
                episode: action.episode,
                guid: action.guid,
                action: action.action,
                position: action.position,
                total: action.total,
                timestamp: action.timestamp
            )
        }
        let request = ProMigrateRequest(subscriptions: subscriptions, episodeActions: actions)
        let body = try encoder.encode(request)
        let data = try await performPOST(path: "/api/yourpods/migrate", body: body)
        return try decoder.decode(ProMigrateResponse.self, from: data)
    }
    
    // ⚠️ v1 global settings endpoints (`/settings/global`, `/settings/podcasts`)
    // were removed — all settings sync uses v2 profile-scoped endpoints:
    //   GET/PATCH /settings/profile         → global profile settings
    //   GET/PATCH /settings/profile/podcasts → per-podcast overrides

    // MARK: - Profile Settings (v2)

    /// Get profile-level settings for the given profile name.
    func getProfileSettings(profileName: String) async throws -> ProProfileSettings? {
        guard let encoded = profileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw YourPodsProError.invalidURL
        }
        let data = try await performGET(path: "/api/yourpods/settings/profile?profileName=\(encoded)")
        return try? decoder.decode(ProProfileSettings.self, from: data)
    }

    /// Push profile-level settings to the server.
    func patchProfileSettings(profileName: String, payload: [String: AnyCodableValue]) async throws {
        // Build payload manually via JSONSerialization to handle mixed-type dict
        var dict: [String: Any] = ["profileName": profileName]
        var payloadDict: [String: Any] = [:]
        for (k, v) in payload {
            switch v {
            case .string(let s): payloadDict[k] = s
            case .int(let i): payloadDict[k] = i
            case .double(let d): payloadDict[k] = d
            case .bool(let b): payloadDict[k] = b
            case .null: payloadDict[k] = NSNull()
            }
        }
        dict["payload"] = payloadDict
        let data = try JSONSerialization.data(withJSONObject: dict)
        try await performPATCH(path: "/api/yourpods/settings/profile", body: data)
    }

    /// Get per-podcast overrides for the given profile.
    func getProfilePodcastSettings(profileName: String) async throws -> [ProPodcastSetting] {
        guard let encoded = profileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw YourPodsProError.invalidURL
        }
        let data = try await performGET(path: "/api/yourpods/settings/profile/podcasts?profileName=\(encoded)")
        struct Response: Codable { let settings: [ProPodcastSetting]? }
        let response = try decoder.decode(Response.self, from: data)
        return response.settings ?? []
    }

    /// Upsert a per-podcast override for the given profile.
    func patchProfilePodcastSetting(profileName: String, podcastUrl: String, payload: [String: AnyCodableValue]) async throws {
        var dict: [String: Any] = ["profileName": profileName, "podcastUrl": podcastUrl]
        var payloadDict: [String: Any] = [:]
        for (k, v) in payload {
            switch v {
            case .string(let s): payloadDict[k] = s
            case .int(let i): payloadDict[k] = i
            case .double(let d): payloadDict[k] = d
            case .bool(let b): payloadDict[k] = b
            case .null: payloadDict[k] = NSNull()
            }
        }
        dict["payload"] = payloadDict
        let data = try JSONSerialization.data(withJSONObject: dict)
        try await performPOST(path: "/api/yourpods/settings/profile/podcasts", body: data)
    }

    // MARK: - SyncClient Protocol: Per-Podcast Settings

    /// Protocol-conforming pull — delegates to `getProfilePodcastSettings`.
    /// The `since` parameter is not yet used (full pull each time); delta sync
    /// can be added later when the server supports it via the profile endpoint.
    func pullPodcastSettings(profileName: String, since: Date?) async throws -> [ProPodcastSetting] {
        try await getProfilePodcastSettings(profileName: profileName)
    }

    /// Protocol-conforming push — delegates to `patchProfilePodcastSetting`.
    func pushPodcastSetting(profileName: String, podcastUrl: String, payload: [String: AnyCodableValue]) async throws {
        try await patchProfilePodcastSetting(profileName: profileName, podcastUrl: podcastUrl, payload: payload)
    }

    /// Batch push all per-podcast setting overrides in a single PATCH request.
    /// Uses `PATCH /api/yourpods/settings/profile/podcasts` with an `items` array body.
    /// Reduces N individual POST calls to 1 PATCH call, avoiding 429 rate limits.
    ///
    /// Falls back to per-item POST calls if the batch PATCH fails with 400
    /// (e.g., older server version that doesn't support the batch endpoint).
    func pushPodcastSettingsBatch(
        profileName: String,
        items: [(podcastUrl: String, payload: [String: AnyCodableValue])]
    ) async throws {
        guard !items.isEmpty else { return }
        
        // Build batch payload: { "profileName": "...", "items": [ { "podcastUrl": "...", "payload": {...} }, ... ] }
        var batchItems: [[String: Any]] = []
        for item in items {
            var payloadDict: [String: Any] = [:]
            for (k, v) in item.payload {
                switch v {
                case .string(let s): payloadDict[k] = s
                case .int(let i): payloadDict[k] = i
                case .double(let d): payloadDict[k] = d
                case .bool(let b): payloadDict[k] = b
                case .null: payloadDict[k] = NSNull()
                }
            }
            batchItems.append([
                "podcastUrl": item.podcastUrl,
                "payload": payloadDict
            ])
        }
        
        let body: [String: Any] = [
            "profileName": profileName,
            "items": batchItems
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        
        try await performPATCH(path: "/api/yourpods/settings/profile/podcasts", body: data)
        logger.info("Batch pushed \(items.count) per-podcast settings in single PATCH request")
    }

    /// List all profile names for this user.
    func listProfiles() async throws -> [ProProfileInfo] {
        let data = try await performGET(path: "/api/yourpods/settings/profiles")
        struct Response: Codable { let profiles: [ProProfileInfo]? }
        let response = try? decoder.decode(Response.self, from: data)
        return response?.profiles ?? []
    }

    /// Fork the current profile into a new profile name, preserving all settings.
    /// Returns the new profile name, or throws if the fork fails (409 = already exists).
    func forkProfile(from source: String, to destination: String) async throws {
        let body = try encoder.encode(["from": source, "to": destination])
        try await performPOST(path: "/api/yourpods/settings/profile/fork", body: body)
        logger.info("Profile forked: \(source) → \(destination)")
    }

    // MARK: - Listening Stats (v2)

    /// Push a batch of listening/skip events to the server.
    /// The server accepts a raw JSON array of event objects per the API spec.
    /// Client batches via `StatsEventBuffer`.
    func pushStatsEvents(_ events: [ProStatsEvent]) async throws {
        guard !events.isEmpty else { return }
        let body = try encoder.encode(events)
        try await performPOST(path: "/api/yourpods/stats/events", body: body)
        logger.info("Pushed \(events.count) stats events to server")
    }

    /// Get aggregated listening stats for the current user.
    /// The `since` parameter uses ISO 8601 (RFC 3339) format per backend spec.
    func getStats(since: Date? = nil) async throws -> ProStatsResponse? {
        var path = "/api/yourpods/stats"
        if let since {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            path += "?since=\(formatter.string(from: since))"
        }
        let data = try await performGET(path: path)
        return try? decoder.decode(ProStatsResponse.self, from: data)
    }

    // MARK: - Groups Sync (v2)

    /// Pull the full groups list for the given profile.
    func getGroups(profileName: String) async throws -> ProGroupsResponse? {
        guard let encoded = profileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw YourPodsProError.invalidURL
        }
        let data = try await performGET(path: "/api/yourpods/groups?profileName=\(encoded)")
        return try? decoder.decode(ProGroupsResponse.self, from: data)
    }

    /// Full-replace sync: push all local groups to the server.
    /// The server replaces its groups list with the supplied array.
    func syncGroups(profileName: String, groups: [ProGroup]) async throws {
        struct Payload: Encodable {
            let profileName: String
            let groups: [ProGroup]
        }
        let payload = Payload(profileName: profileName, groups: groups)
        let data = try encoder.encode(payload)
        try await performPOST(path: "/api/yourpods/groups/sync", body: data)
        logger.info("Groups synced: \(groups.count) groups pushed to server")
    }

    /// Pull the full group assignment list for the given profile.
    func getGroupAssignments(profileName: String) async throws -> ProGroupAssignmentsResponse? {
        guard let encoded = profileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw YourPodsProError.invalidURL
        }
        let data = try await performGET(path: "/api/yourpods/groups/assignments?profileName=\(encoded)")
        return try? decoder.decode(ProGroupAssignmentsResponse.self, from: data)
    }

    /// Full-replace sync: push all local group assignments to the server.
    func syncGroupAssignments(profileName: String, assignments: [ProGroupAssignment]) async throws {
        struct Payload: Encodable {
            let profileName: String
            let assignments: [ProGroupAssignment]
        }
        let payload = Payload(profileName: profileName, assignments: assignments)
        let data = try encoder.encode(payload)
        try await performPOST(path: "/api/yourpods/groups/assignments/sync", body: data)
        logger.info("Group assignments synced: \(assignments.count) assignments pushed to server")
    }
    
    // MARK: - Hidden Episodes
    
    /// Hide episodes on the server.
    /// Sets hidden flag (and isPlayed = true) for the specified episodes.
    /// Accepts a single object or array body per the API spec.
    func hideEpisodes(_ episodes: [ProHideEpisodeRequest]) async throws {
        let body = try encoder.encode(episodes)
        try await performPOST(path: "/api/yourpods/episodes/hide", body: body)
        logger.info("Hidden \(episodes.count) episode(s) on server")
    }
    
    /// Unhide a single episode on the server.
    func unhideEpisode(episodeUrl: String) async throws {
        struct UnhideRequest: Codable {
            let episodeUrl: String
        }
        let body = try encoder.encode(UnhideRequest(episodeUrl: episodeUrl))
        try await performPOST(path: "/api/yourpods/episodes/unhide", body: body)
        logger.info("Unhidden episode on server: \(episodeUrl)")
    }

    // MARK: - Sync Conflicts

    /// Fetch all unresolved conflicts from the server.
    /// Returns position conflicts and URL-rewrite conflicts separately.
    func getSyncConflicts() async throws -> ProSyncConflictsResponse {
        let data = try await performGET(path: "/api/yourpods/sync-conflicts")
        return try decoder.decode(ProSyncConflictsResponse.self, from: data)
    }

    /// Resolve a single position conflict authoritatively, per the sync contract.
    ///
    /// Sends the position the user actually chose rather than a preference the server
    /// has to look up. That decoupling is the point: a conflict this device detected
    /// locally, which the server never recorded, resolves the same way as one it did.
    ///
    /// The write is authoritative — no `GREATEST`, no `nowPlaying` gate — so resolving
    /// *backwards* (the phone is behind the server, the common reason the sheet appears)
    /// lands instead of being silently refused. Pass `duration` whenever it is known;
    /// without it the server cannot prove the position is short of the end and cannot
    /// clear a stale `completed`.
    func resolveConflict(
        episodeUrl: String,
        podcastUrl: String?,
        position: Int,
        duration: Int?
    ) async throws {
        let request = ProResolveConflictRequest(
            episodeUrl: episodeUrl,
            podcastUrl: podcastUrl,
            position: position,
            duration: duration
        )
        let body = try encoder.encode(request)
        try await performPOST(path: "/api/yourpods/sync-conflicts/resolve", body: body)
        logger.info("Resolved conflict for \(episodeUrl) at position \(position)")
    }

    /// Bulk-resolve all conflicts with a single strategy.
    func resolveAllConflicts(resolution: String) async throws {
        let request = ProResolveAllConflictsRequest(resolution: resolution)
        let body = try encoder.encode(request)
        try await performPOST(path: "/api/yourpods/sync-conflicts/resolve-all", body: body)
        logger.info("Resolved all conflicts with resolution: \(resolution)")
    }

    /// Resolve a URL rewrite conflict (CDN domain change).
    /// Returns how many playback records were updated.
    func resolveUrlRewrite(oldUrl: String, newUrl: String, accept: Bool) async throws -> ProResolveUrlRewriteResponse {
        let request = ProResolveUrlRewriteRequest(oldUrl: oldUrl, newUrl: newUrl, accept: accept)
        // camelCase endpoint — do NOT use self.encoder (.convertToSnakeCase). The handler's
        // tags are `oldUrl`/`newUrl`/`accept`, and Go's decoder is case-insensitive but not
        // punctuation-insensitive, so `old_url` matched nothing and every request answered
        // 400 "oldUrl required" before looking at the feed. The server now decodes both
        // casings as a compatibility shim for shipped builds; camelCase is still the contract.
        let body = try JSONEncoder().encode(request)
        let data = try await performPOST(path: "/api/yourpods/sync-conflicts/resolve-url-rewrite", body: body)
        return try decoder.decode(ProResolveUrlRewriteResponse.self, from: data)
    }
    
    /// Extract hidden state changes from the delta sync response.
    /// Called by ProSyncOrchestrator after getEpisodeActions() to update
    /// the local hidden set without changing the SyncClient protocol.
    ///
    /// Returns tuples of (guid, hidden) for states where `hidden` is non-nil.
    func getHiddenStateChanges(since: Int) async throws -> [(guid: String, episodeUrl: String, hidden: Bool)] {
        let data = try await performGET(path: "/api/yourpods/playback/recent?since=\(since)")
        
        struct RecentResponse: Codable {
            let states: [HiddenCheckAction]?
        }
        struct HiddenCheckAction: Codable {
            let episodeUrl: String
            let episodeGuid: String?
            let hidden: Bool?
        }
        
        let response = try decoder.decode(RecentResponse.self, from: data)
        return (response.states ?? []).compactMap { action in
            guard let hidden = action.hidden else { return nil }
            let guid = action.episodeGuid ?? action.episodeUrl
            return (guid: guid, episodeUrl: action.episodeUrl, hidden: hidden)
        }
    }

    // MARK: - Telemetry

    /// Report a playback error to the server for ops visibility.
    ///
    /// Fire-and-forget: failures are silently ignored. Telemetry must never
    /// affect playback or user experience.
    func reportPlaybackError(
        episodeUrl: String?,
        episodeGuid: String?,
        podcastUrl: String?,
        errorDescription: String,
        recoveryAttempt: Int,
        deviceId: String?,
        platform: String = "ios"
    ) async {
        let payload: [String: Any] = [
            "episodeUrl": episodeUrl ?? "",
            "episodeGuid": episodeGuid ?? "",
            "podcastUrl": podcastUrl ?? "",
            "error": errorDescription,
            "recoveryAttempt": recoveryAttempt,
            "deviceId": deviceId ?? "",
            "platform": platform,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            try await performPOST(path: "/api/yourpods/telemetry/playback-error", body: body)
        } catch {
            // Silent — telemetry must never disrupt playback
        }
    }

    // MARK: - GDPR Data Export

    /// Download all user data from the server as JSON (GDPR export).
    ///
    /// Returns the raw JSON `Data` from `POST /account/export-data`.
    func exportAccountData() async throws -> Data {
        return try await performPOST(path: "/account/export-data", body: nil)
    }

    // MARK: - Annotations Sync

    /// Push dirty annotations to the server in a single batch.
    /// Server upserts by client UUID — safe to retry (idempotent).
    ///
    /// **Response returns FULL annotation state** (all user annotations),
    /// not a delta-since. The `syncedAt` cursor is for subsequent GET pulls.
    ///
    /// Sending an empty annotations array returns the full current state —
    /// usable as a "pull everything" shortcut for initial sync.
    func syncAnnotations(_ items: [SyncAnnotationItem]) async throws -> AnnotationSyncResponse {
        let body = try Self.encodeAnnotationSyncBody(items)
        let data = try await performPOST(path: "/api/yourpods/annotations/sync", body: body)
        return try decoder.decode(AnnotationSyncResponse.self, from: data)
    }

    /// Encode the `/annotations/sync` push body.
    ///
    /// Unlike every other endpoint on this client, the annotations API speaks a
    /// **camelCase** wire contract — the server's annotation-item field tags, the web
    /// client's annotation store, and the contract's own response fixtures all use it.
    /// We therefore use the encoder's default keys here — NOT the shared
    /// `.convertToSnakeCase` encoder. Encoding snake_case made the server's
    /// required-field guard (`episodeUrl`/`podcastUrl`) drop every item, so
    /// pushed creates and deletes silently no-op'd (`synced: 0`).
    static func encodeAnnotationSyncBody(_ items: [SyncAnnotationItem]) throws -> Data {
        struct Payload: Encodable { let annotations: [SyncAnnotationItem] }
        // Default keys = camelCase, matching the server. Do NOT add
        // `.convertToSnakeCase` here, or the server drops every item.
        return try JSONEncoder().encode(Payload(annotations: items))
    }

    /// Pull annotation changes since last sync.
    /// Omit `since` for a full sync.
    /// Response shape is identical to the `annotations` array in the push response.
    func pullAnnotations(since: String?) async throws -> AnnotationSyncResponse {
        var path = "/api/yourpods/annotations"
        if let since, let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?since=\(encoded)"
        }
        let data = try await performGET(path: path)
        return try decoder.decode(AnnotationSyncResponse.self, from: data)
    }

    // MARK: - Private HTTP Helpers
    
    private func performGET(path: String) async throws -> Data {
        let request = try await buildRequest(method: "GET", path: path)
        do {
            let (data, response) = try await session.data(for: request)
            try validateResponse(response, data: data)
            return data
        } catch let error as YourPodsProError { throw error }
        catch { throw translateNetworkError(error, path: path) }
    }
    
    @discardableResult
    private func performPOST(path: String, body: Data?) async throws -> Data {
        var request = try await buildRequest(method: "POST", path: path)
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            try validateResponse(response, data: data)
            return data
        } catch let error as YourPodsProError { throw error }
        catch { throw translateNetworkError(error, path: path) }
    }
    
    @discardableResult
    private func performPATCH(path: String, body: Data) async throws -> Data {
        var request = try await buildRequest(method: "PATCH", path: path)
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            try validateResponse(response, data: data)
            return data
        } catch let error as YourPodsProError { throw error }
        catch { throw translateNetworkError(error, path: path) }
    }
    
    @discardableResult
    private func performDELETE(path: String) async throws -> Data {
        let request = try await buildRequest(method: "DELETE", path: path)
        do {
            let (data, response) = try await session.data(for: request)
            try validateResponse(response, data: data)
            return data
        } catch let error as YourPodsProError { throw error }
        catch { throw translateNetworkError(error, path: path) }
    }

    
    private func buildRequest(method: String, path: String) async throws -> URLRequest {
        guard let url = URL(string: "\(baseUrl)\(path)") else {
            throw YourPodsProError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("YourPods/2.0", forHTTPHeaderField: "User-Agent")
        
        // Get a valid JWT from the auth provider (auto-refreshes if expired)
        let token = try await authProvider.getValidToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return request
    }
    
    private func validateResponse(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw YourPodsProError.invalidResponse
        }
        switch http.statusCode {
        case 200...299: return
        case 401: throw YourPodsProError.unauthorized
        case 402:
            // Parse the enriched 402 body if available
            let info: PaymentRequiredInfo?
            if let data, let parsed = try? JSONDecoder().decode(PaymentRequiredInfo.self, from: data) {
                info = parsed
            } else {
                info = nil
            }
            throw YourPodsProError.subscriptionRequired(info)
        case 403: throw YourPodsProError.forbidden
        case 409:
            // Two different meanings behind one status code, told apart by the body's
            // `code` — which is why the server sends one (per the sync contract):
            //
            //   • `conflict_stale` — the conflict row no longer describes current state
            //     and was NOT written. Refresh the list; retrying re-sends a row the
            //     server has already pruned and gets the same answer forever.
            //   • anything else — a queue version conflict (stale
            //     `baseVersion` on /queue/sync). Re-pull, re-merge intent, retry.
            //
            // Absent, unreadable, or differently-coded bodies keep the retryable meaning:
            // guessing the other way turns a recoverable queue push into a refresh that
            // never retries.
            if let data, let parsed = try? JSONDecoder().decode(ErrorCodeBody.self, from: data),
               parsed.code == "conflict_stale" {
                throw YourPodsProError.conflictStale
            }
            throw YourPodsProError.conflict
        case 429:
            let retryAfter = (http as HTTPURLResponse).value(forHTTPHeaderField: "Retry-After")
            throw YourPodsProError.rateLimited(retryAfterSec: Int(retryAfter ?? "") ?? 10)
        case 500...599: throw YourPodsProError.serverError(http.statusCode)
        default: throw YourPodsProError.httpError(http.statusCode)
        }
    }
    
    // MARK: - Helpers
    
    private static func parseTimestamp(_ isoString: String?) -> Int? {
        guard let s = isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: s).map { Int($0.timeIntervalSince1970) }
    }
    
    /// Translate a raw `URLError` or other network error into a `YourPodsProError.connectionFailed`
    /// with a message that names the host and distinguishes TLS failures from connectivity failures.
    private func translateNetworkError(_ error: Error, path: String) -> YourPodsProError {
        let host = URL(string: baseUrl)?.host ?? baseUrl
        if let urlError = error as? URLError {
            let reason: String
            switch urlError.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateUntrusted, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected,
                 .clientCertificateRequired:
                reason = "A TLS/SSL error occurred. The server certificate may be invalid or the server may not be reachable."
            case .notConnectedToInternet, .networkConnectionLost:
                reason = "No internet connection."
            case .timedOut:
                reason = "The connection timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                reason = "The server could not be found. Check that sync.yourpods.app is running."
            case .cancelled:
                // Task cancellation from app lifecycle transitions (foreground → background).
                // This is NOT a connectivity failure — suppress from the user-facing banner.
                logger.info("Request cancelled on \(path) — expected lifecycle event, not a network error")
                return .requestCancelled
            default:
                reason = urlError.localizedDescription
            }
            logger.error("Network error on \(path): [\(urlError.code.rawValue)] \(urlError.localizedDescription)")
            return .connectionFailed(host: host, reason: reason)
        }
        logger.error("Unexpected error on \(path): \(error.localizedDescription)")
        return .connectionFailed(host: host, reason: error.localizedDescription)
    }

    /// Test-accessible wrapper for `translateNetworkError`.
    /// Allows unit tests to verify error classification without making the method non-private.
    func testTranslateNetworkError(_ error: Error, path: String) -> YourPodsProError {
        translateNetworkError(error, path: path)
    }
}

// MARK: - Errors

/// The machine-readable half of an error body. Only `code` is read — the prose beside it
/// is for logs and changes without notice, so branching on it would be branching on copy.
private struct ErrorCodeBody: Decodable {
    let code: String?
}

enum YourPodsProError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    /// 403 — Firebase token is valid but Pro entitlement check failed.
    case forbidden
    case subscriptionRequired(PaymentRequiredInfo?)
    case serverError(Int)
    case httpError(Int)
    /// A URLSession-level failure (TLS, timeout, no network, DNS).
    case connectionFailed(host: String, reason: String)
    /// The request was cancelled (e.g. foreground sync task cancelled on backgrounding).
    /// This is an expected lifecycle event, NOT a connectivity failure.
    case requestCancelled
    /// Server returned 429 Too Many Requests. Client should back off.
    case rateLimited(retryAfterSec: Int)
    /// 409 — queue version conflict. The client's `baseVersion` was
    /// stale; re-pull, re-merge intent, and retry the queue push.
    case conflict
    /// 409 `{"code":"conflict_stale"}` — the conflict row no longer describes current
    /// state and was not written (per the sync contract). **Refresh the list, do not retry.**
    /// Shares a status code with `.conflict` and means the opposite thing about retrying:
    /// re-sending a pruned row gets the same answer forever.
    case conflictStale

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL"
        case .invalidResponse: return "Unexpected response format"
        case .unauthorized: return "Session expired. Please sign in again."
        case .forbidden: return "YourPods Sync is not authorized for this account. Your subscription may have lapsed."
        case .subscriptionRequired: return "YourPods Sync subscription required."
        case .serverError(let code): return "Server error (\(code))"
        case .httpError(let code): return "Request failed (\(code))"
        case .connectionFailed(let host, let reason):
            return "Could not connect to \(host). \(reason)"
        case .requestCancelled:
            return "Sync was interrupted."
        case .rateLimited(let sec):
            return "Server is busy. Please try again in \(sec) seconds."
        case .conflict:
            return "Queue changed on another device. Re-syncing."
        case .conflictStale:
            return "That conflict is out of date. Refreshing."
        }
    }
    
    // Equatable conformance — connectionFailed compares host + reason as strings
    static func == (lhs: YourPodsProError, rhs: YourPodsProError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }

    /// Convenience: true when this error is a 402 (any payload).
    var isSubscriptionRequired: Bool {
        if case .subscriptionRequired = self { return true }
        return false
    }

    /// Extract the enriched 402 info, if available.
    var paymentRequiredInfo: PaymentRequiredInfo? {
        if case .subscriptionRequired(let info) = self { return info }
        return nil
    }
}
