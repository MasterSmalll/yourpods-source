import Foundation
import os

/// Syncs notes to a user's Nextcloud instance via WebDAV PUT.
///
/// Each episode gets one `.md` file under `/remote.php/dav/files/<username>/Notes/YourPods/`.
/// No YAML frontmatter — matches the web's Nextcloud export format.
/// Uses the same credentials already stored for gPodder sync.
struct NextcloudNotesService {
    private static let logger = Logger(subsystem: "com.yourpods", category: "nextcloud.notes")

    /// Default remote folder path (relative to user's WebDAV root).
    static let defaultFolder = "Notes/YourPods"

    // MARK: - Public API

    /// Result of a sync operation.
    struct SyncResult {
        let uploaded: Int
        let failed: Int
        let errors: [String]
    }

    /// Sync all non-deleted annotations to Nextcloud as `.md` files via WebDAV PUT.
    ///
    /// - Parameters:
    ///   - annotations: All annotations to export.
    ///   - baseUrl: Nextcloud server URL (e.g. `https://cloud.example.com`).
    ///   - username: Nextcloud username.
    ///   - password: App password from Keychain.
    ///   - folder: Remote folder path (default: `Notes/YourPods`).
    /// - Returns: A `SyncResult` with counts and any errors.
    static func syncToNextcloud(
        annotations: [Annotation],
        baseUrl: String,
        username: String,
        password: String,
        folder: String = defaultFolder
    ) async -> SyncResult {
        let liveAnnotations = annotations.filter { !$0.deleted }
        guard !liveAnnotations.isEmpty else {
            return SyncResult(uploaded: 0, failed: 0, errors: [])
        }

        // Normalize base URL
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl

        // Group by episode
        let grouped = Dictionary(grouping: liveAnnotations) { $0.episodeUrl }

        // Ensure directory exists
        let dirPath = "/remote.php/dav/files/\(username)/\(folder)/"
        do {
            try await ensureDirectory(base: base, path: dirPath, username: username, password: password)
        } catch {
            logger.error("Failed to create Nextcloud directory: \(error.localizedDescription)")
            return SyncResult(uploaded: 0, failed: grouped.count, errors: ["Directory creation failed: \(error.localizedDescription)"])
        }

        var uploaded = 0
        var failed = 0
        var errors: [String] = []

        for (_, notes) in grouped {
            let sorted = notes.sorted { $0.timestampSec < $1.timestampSec }
            guard let first = sorted.first else { continue }

            let markdown = generateEpisodeMarkdown(notes: sorted)
            let filename = sanitizeFilename(first.episodeTitle ?? first.episodeUrl) + ".md"
            let filePath = dirPath + filename

            do {
                try await putFile(base: base, path: filePath, content: markdown, username: username, password: password)
                uploaded += 1
            } catch {
                failed += 1
                errors.append("\(filename): \(error.localizedDescription)")
                logger.warning("Failed to upload \(filename): \(error.localizedDescription)")
            }
        }

        logger.info("Nextcloud sync complete: \(uploaded) uploaded, \(failed) failed")
        return SyncResult(uploaded: uploaded, failed: failed, errors: errors)
    }

    // MARK: - Markdown Generation

    /// Generate Markdown for a single episode's notes — no YAML frontmatter.
    /// Matches the web's Nextcloud export format.
    static func generateEpisodeMarkdown(notes: [Annotation]) -> String {
        guard let first = notes.first else { return "" }

        var md = "# \(first.episodeTitle ?? "Unknown Episode")\n"
        md += "**\(first.podcastTitle ?? "Unknown Podcast")**\n\n"

        for (i, note) in notes.enumerated() {
            md += "**[\(NotesExportService.formatTime(note.timestampSec))]**"
            if let chapter = note.chapterTitle {
                md += " · \(chapter)"
            }
            md += "\n\n"

            if let transcript = note.transcriptText {
                md += "> \"\(transcript)\"\n\n"
            }

            md += "\(note.noteText)\n\n"

            if !note.tags.isEmpty {
                md += note.tags.map { "#\($0)" }.joined(separator: " ") + "\n\n"
            }

            if i < notes.count - 1 {
                md += "---\n\n"
            }
        }

        return md
    }

    // MARK: - WebDAV Operations

    /// Create directory via MKCOL if it doesn't exist.
    /// Silently succeeds if directory already exists (405 Method Not Allowed).
    static func ensureDirectory(base: String, path: String, username: String, password: String) async throws {
        // Create each path component to handle nested directories
        let components = path.split(separator: "/").filter { !$0.isEmpty }
        // Skip "remote.php/dav/files/<username>" prefix (4 components)
        let userComponents = Array(components.dropFirst(4))

        var currentPath = "/remote.php/dav/files/\(username)/"
        for component in userComponents {
            currentPath += "\(component)/"
            guard let url = URL(string: base + currentPath) else {
                throw NextcloudError.invalidURL(currentPath)
            }

            var request = URLRequest(url: url)
            request.httpMethod = "MKCOL"
            addAuth(to: &request, username: username, password: password)

            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 201 Created, 405 Already Exists — both OK
            guard status == 201 || status == 405 else {
                throw NextcloudError.mkcolFailed(path: currentPath, status: status)
            }
        }
    }

    /// Upload a file via WebDAV PUT.
    static func putFile(base: String, path: String, content: String, username: String, password: String) async throws {
        guard let url = URL(string: base + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) else {
            throw NextcloudError.invalidURL(path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = content.data(using: .utf8)
        addAuth(to: &request, username: username, password: password)

        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 201 Created, 204 No Content (overwritten) — both OK
        guard status == 201 || status == 204 else {
            throw NextcloudError.putFailed(status: status)
        }
    }

    // MARK: - Helpers

    private static func addAuth(to request: inout URLRequest, username: String, password: String) {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }

    /// Sanitize a string for use as a filename.
    /// Removes characters invalid on most filesystems, collapses whitespace.
    static func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var sanitized = name.components(separatedBy: invalidChars).joined(separator: "")
        sanitized = sanitized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        sanitized = sanitized.trimmingCharacters(in: .whitespaces)
        if sanitized.isEmpty { sanitized = WireString.untitledEpisode }
        // Limit length to avoid filesystem issues
        if sanitized.count > 200 {
            sanitized = String(sanitized.prefix(200))
        }
        return sanitized
    }

    /// Errors specific to Nextcloud WebDAV operations.
    enum NextcloudError: LocalizedError {
        case invalidURL(String)
        case mkcolFailed(path: String, status: Int)
        case putFailed(status: Int)
        case missingCredentials

        var errorDescription: String? {
            switch self {
            case .invalidURL(let path): return "Invalid WebDAV URL: \(path)"
            case .mkcolFailed(let path, let status): return "Failed to create directory \(path) (HTTP \(status))"
            case .putFailed(let status): return "Failed to upload file (HTTP \(status))"
            case .missingCredentials: return "Nextcloud credentials not found"
            }
        }
    }
}
