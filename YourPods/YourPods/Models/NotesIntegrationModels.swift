import Foundation

/// User-selectable Obsidian export mode.
/// Default: `.perEpisode`.
enum ObsidianExportMode: String, CaseIterable, Sendable {
    /// One note per episode in `YourPods Notes/<Podcast>/<Episode>.md`
    case perEpisode
    /// Append to today's daily note (requires Advanced URI plugin)
    case dailyNote
    /// Export per-episode `.md` files via iOS share sheet
    case shareSheet
}

/// User-selectable Nextcloud notes sync backend.
/// Default: `.webdav`.
enum NextcloudNotesMode: String, CaseIterable, Sendable {
    /// Original WebDAV PUT to user-specified folder
    case webdav
    /// Nextcloud Notes REST API v1 (requires Notes app on server)
    case notesApi
}
