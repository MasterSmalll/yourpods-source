import Foundation
import os

/// REST client for the Nextcloud Notes API v1.
///
/// Uses `POST/PUT /index.php/apps/notes/api/v1/notes` to create/update notes
/// as first-class Nextcloud Notes objects. Requires the Nextcloud Notes app
/// to be installed on the server.
///
/// Available to ALL users with a Nextcloud/gPodder profile — not gated behind Pro.
struct NextcloudNotesAPIService {
    private static let logger = Logger(subsystem: "com.yourpods", category: "nextcloud.notes.api")

    /// Base API path for Nextcloud Notes v1.
    static let apiPath = "/index.php/apps/notes/api/v1/notes"

    // MARK: - Note JSON Construction

    /// Build a JSON dictionary for creating/updating a Nextcloud note.
    ///
    /// Returns nil if notes array is empty.
    static func buildNoteJSON(notes: [Annotation], category: String) -> [String: Any]? {
        let liveNotes = notes.filter { !$0.deleted }
        guard let first = liveNotes.first else { return nil }

        let sorted = liveNotes.sorted { $0.timestampSec < $1.timestampSec }
        let markdown = NextcloudNotesService.generateEpisodeMarkdown(notes: sorted)

        return [
            "title": WireString.episodeIdentity(title: first.episodeTitle, url: first.episodeUrl),
            "content": markdown,
            "category": category,
            "favorite": false
        ] as [String: Any]
    }

    /// Build a category string from a podcast title.
    /// Format: `YourPods/<Podcast Title>` or just `YourPods` if nil.
    ///
    /// Part of the create-vs-update identity key — see `WireString`.
    static func category(for podcastTitle: String?) -> String {
        if let title = podcastTitle, !title.isEmpty {
            return "\(WireString.notesCategoryRoot)/\(title)"
        }
        return WireString.notesCategoryRoot
    }

    // MARK: - Sync Result

    /// Result of a Notes API sync operation.
    struct SyncResult {
        let created: Int
        let updated: Int
        let failed: Int
        let errors: [String]
    }

    // MARK: - API Operations

    /// Sync all non-deleted annotations to Nextcloud via the Notes REST API.
    ///
    /// Groups annotations by episode, creates/updates one note per episode.
    /// Uses GET to check for existing notes, then POST (create) or PUT (update).
    static func syncToNextcloud(
        annotations: [Annotation],
        baseUrl: String,
        username: String,
        password: String
    ) async -> SyncResult {
        let liveAnnotations = annotations.filter { !$0.deleted }
        guard !liveAnnotations.isEmpty else {
            return SyncResult(created: 0, updated: 0, failed: 0, errors: [])
        }

        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let grouped = Dictionary(grouping: liveAnnotations) { $0.episodeUrl }

        // Fetch existing notes to detect updates vs creates
        let existingNotes: [[String: Any]]
        do {
            existingNotes = try await listNotes(base: base, username: username, password: password)
        } catch {
            logger.error("Failed to list existing notes: \(error.localizedDescription)")
            return SyncResult(created: 0, updated: 0, failed: grouped.count,
                              errors: ["Failed to list notes: \(error.localizedDescription)"])
        }

        var created = 0
        var updated = 0
        var failed = 0
        var errors: [String] = []

        for (_, notes) in grouped {
            let sorted = notes.sorted { $0.timestampSec < $1.timestampSec }
            guard let first = sorted.first else { continue }

            let cat = category(for: first.podcastTitle)
            guard let json = buildNoteJSON(notes: sorted, category: cat) else { continue }

            let title = WireString.episodeIdentity(title: first.episodeTitle, url: first.episodeUrl)

            // Check if note already exists (match by title + category)
            let existingId = existingNotes.first(where: {
                ($0["title"] as? String) == title && ($0["category"] as? String) == cat
            }).flatMap { $0["id"] as? Int }

            do {
                if let noteId = existingId {
                    try await updateNote(base: base, noteId: noteId, json: json,
                                         username: username, password: password)
                    updated += 1
                } else {
                    try await createNote(base: base, json: json,
                                         username: username, password: password)
                    created += 1
                }
            } catch {
                failed += 1
                errors.append("\(title): \(error.localizedDescription)")
                logger.warning("Failed to sync note '\(title)': \(error.localizedDescription)")
            }
        }

        logger.info("Notes API sync complete: \(created) created, \(updated) updated, \(failed) failed")
        return SyncResult(created: created, updated: updated, failed: failed, errors: errors)
    }

    // MARK: - HTTP Operations

    /// List all notes via GET /api/v1/notes.
    static func listNotes(base: String, username: String, password: String) async throws -> [[String: Any]] {
        guard let url = URL(string: base + apiPath) else {
            throw NotesAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        addAuth(to: &request, username: username, password: password)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            throw NotesAPIError.listFailed(status: status)
        }

        guard let notes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return notes
    }

    /// Create a new note via POST /api/v1/notes.
    static func createNote(base: String, json: [String: Any], username: String, password: String) async throws {
        guard let url = URL(string: base + apiPath) else {
            throw NotesAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        addAuth(to: &request, username: username, password: password)

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 || status == 201 else {
            throw NotesAPIError.createFailed(status: status)
        }
    }

    /// Update an existing note via PUT /api/v1/notes/{id}.
    static func updateNote(base: String, noteId: Int, json: [String: Any], username: String, password: String) async throws {
        guard let url = URL(string: base + apiPath + "/\(noteId)") else {
            throw NotesAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        addAuth(to: &request, username: username, password: password)

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            throw NotesAPIError.updateFailed(status: status)
        }
    }

    /// Check if the Notes API is available on this Nextcloud instance.
    /// Returns true if GET /api/v1/notes returns 200.
    static func isAvailable(base: String, username: String, password: String) async -> Bool {
        do {
            _ = try await listNotes(base: base, username: username, password: password)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private static func addAuth(to request: inout URLRequest, username: String, password: String) {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }

    /// Errors specific to Nextcloud Notes API operations.
    enum NotesAPIError: LocalizedError {
        case invalidURL
        case listFailed(status: Int)
        case createFailed(status: Int)
        case updateFailed(status: Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Nextcloud Notes API URL"
            case .listFailed(let status): return "Failed to list notes (HTTP \(status))"
            case .createFailed(let status): return "Failed to create note (HTTP \(status))"
            case .updateFailed(let status): return "Failed to update note (HTTP \(status))"
            }
        }
    }
}
