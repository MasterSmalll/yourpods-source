import Foundation

/// String literals that are **identifiers, not interface text**.
///
/// Every value here ends up in a durable position — a remote note title
/// matched by string equality, a Nextcloud category, an Obsidian vault path,
/// a WebDAV filename. They are compared against values written by *other*
/// devices, possibly running other languages, possibly months ago.
///
/// ## Never localize these
///
/// `NextcloudNotesAPIService.syncToNextcloud` decides PUT-update vs
/// POST-create by matching `title` **and** `category` against the notes
/// already on the server. If a Spanish device sends `"Sin título"` where an
/// English device wrote `"Untitled"`, the match fails, the create path runs,
/// and the user's note corpus silently duplicates. `NotesExportService`
/// writes Obsidian paths with `overwrite=true`, where the same mismatch
/// silently destroys the previous export instead.
///
/// There is no error and no log when this goes wrong, and it cannot happen on
/// a developer's English device. `LocalizationWireBoundaryGuardTests` is the
/// only enforcement.
///
/// ## Prefer a stable identifier
///
/// These are last-resort fallbacks. Where a stable identifier is available,
/// use it instead — `NextcloudNotesService.swift:69` already does
/// (`first.episodeTitle ?? first.episodeUrl`). An `episodeUrl` is unique and
/// locale-independent; `"Untitled"` is neither, and two untitled episodes of
/// the same podcast collide on it.
///
/// ## Changing a value here is a data migration
///
/// Every value is the existing identity of data already written to users'
/// servers and disks. Changing one orphans all of it.
enum WireString {

    /// Fallback note title when an episode has none.
    /// Part of the Nextcloud Notes create-vs-update identity key.
    static let untitledEpisode = "Untitled"

    /// Fallback podcast name in an Obsidian vault path segment.
    static let unknownPodcast = "Unknown Podcast"

    /// Fallback episode name in an Obsidian vault path segment.
    static let unknownEpisode = "Unknown Episode"

    /// Generic fallback for decode-side wire payloads.
    static let unknownTitle = "Unknown"

    /// Root Nextcloud Notes category. Yields `YourPods` or `YourPods/<Show>`.
    /// Asserted as a literal by `NotesExportServiceTests` (`name=YourPods`).
    static let notesCategoryRoot = "YourPods"

    /// Root folder inside the user's Obsidian vault.
    /// Asserted as a literal by `NotesIntegrationTests` (`YourPods%20Notes`).
    static let obsidianVaultRoot = "YourPods Notes"

    /// Identity for an episode that may have no title.
    ///
    /// Prefers the real title; falls back to `episodeUrl`, which is unique
    /// and locale-independent. Generalizes the pattern already correct at
    /// `NextcloudNotesService.swift:69`.
    ///
    /// Without this, two untitled episodes of the same podcast share one
    /// identity: the Obsidian export writes both to the same path with
    /// `overwrite=true` (the second destroys the first), and the Nextcloud
    /// sync PUTs both to the same note (the second overwrites the first).
    ///
    /// - Note: for Nextcloud this value *is* the remote create-vs-update key.
    ///   Users with notes already stored under the old `"Untitled"` title get
    ///   one new note created beside each old one, once. That is a bounded,
    ///   one-time duplication affecting only untitled episodes — the
    ///   alternative is permanent silent overwriting.
    static func episodeIdentity(title: String?, url: String) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return url
    }
}
