import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Export annotations as Markdown, Obsidian URI, or Nextcloud zip.
///
/// Format matches the web's `exportUtils.ts` for cross-platform parity.
struct NotesExportService {
    private static let logger = Logger(subsystem: "com.yourpods", category: "notes.export")

    // MARK: - Markdown Export

    /// Generate a single Markdown string with YAML frontmatter, grouped by episode.
    /// Format matches web's `exportUtils.ts`.
    static func exportAsMarkdown(annotations: [Annotation]) -> String {
        guard !annotations.isEmpty else { return "" }

        // Group by episodeUrl, preserving order of first appearance
        var episodeOrder: [String] = []
        var grouped: [String: [Annotation]] = [:]
        for annotation in annotations where !annotation.deleted {
            if grouped[annotation.episodeUrl] == nil {
                episodeOrder.append(annotation.episodeUrl)
            }
            grouped[annotation.episodeUrl, default: []].append(annotation)
        }

        var md = ""
        for episodeUrl in episodeOrder {
            guard let notes = grouped[episodeUrl] else { continue }
            let sorted = notes.sorted { $0.timestampSec < $1.timestampSec }
            guard let first = sorted.first else { continue }

            // YAML frontmatter
            md += "---\n"
            md += "podcast: \(first.podcastTitle ?? "Unknown Podcast")\n"
            md += "episode: \(first.episodeTitle ?? "Unknown Episode")\n"
            if let dur = first.durationSec {
                md += "duration: \(formatTime(dur))\n"
            }
            md += "feed: \(first.podcastUrl)\n"
            md += "audio: \(first.episodeUrl)\n"
            let allTags = Set(sorted.flatMap(\.tags))
            if !allTags.isEmpty {
                md += "tags: \(allTags.sorted().joined(separator: ", "))\n"
            }
            md += "---\n\n"

            md += "# \(first.episodeTitle ?? "Unknown Episode")\n"
            md += "**\(first.podcastTitle ?? "Unknown Podcast")**\n\n"

            for (i, note) in sorted.enumerated() {
                md += "**[\(formatTime(note.timestampSec))]**"
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

                if i < sorted.count - 1 {
                    md += "---\n\n"
                }
            }

            md += "\n"
        }

        return md
    }

    // MARK: - Obsidian URI

    /// Build an `obsidian://new` URI for the given markdown content.
    ///
    /// - Parameters:
    ///   - markdown: The markdown content to write.
    ///   - vaultName: The user's Obsidian vault name.
    /// - Returns: A URL if vault name is non-empty, nil otherwise.
    static func obsidianURI(markdown: String, vaultName: String) -> URL? {
        guard !vaultName.isEmpty else { return nil }

        // Pinned to POSIX/Gregorian/UTC: this date is a path segment, not
        // interface text. Under a non-Gregorian calendar or non-Western
        // digits the user's locale would silently rename the folder.
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: Date())

        let notePath = "\(WireString.obsidianVaultRoot)/\(dateString)"

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "name", value: notePath),
            URLQueryItem(name: "content", value: markdown)
        ]

        return components.url
    }

    /// Check if Obsidian is installed on the device.
    static func canOpenObsidian() -> Bool {
        #if os(iOS)
        guard let url = URL(string: "obsidian://") else { return false }
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }

    /// Generate a Markdown file with no YAML frontmatter for Nextcloud export.
    /// One section per episode, matching web's Nextcloud export format.
    static func exportAsNextcloudMarkdown(annotations: [Annotation]) -> Data? {
        let liveAnnotations = annotations.filter { !$0.deleted }
        guard !liveAnnotations.isEmpty else { return nil }

        let grouped = Dictionary(grouping: liveAnnotations) { $0.episodeUrl }
        var md = ""
        for (_, notes) in grouped {
            md += NextcloudNotesService.generateEpisodeMarkdown(notes: notes.sorted { $0.timestampSec < $1.timestampSec })
            md += "\n"
        }
        return md.data(using: .utf8)
    }

    // MARK: - Helpers

    /// Format seconds as `h:mm:ss` or `mm:ss`.
    ///
    /// Forwards to `DurationFormatting.timestamp`. This output is written into
    /// exported Markdown on the user's disk and Nextcloud server — safe to
    /// share only because `timestamp` is locale-independent by construction.
    /// Do not later make `timestamp` locale-aware without revisiting this file;
    /// the wire-boundary guard does not cover `DurationFormatting`.
    static func formatTime(_ seconds: Double) -> String {
        DurationFormatting.timestamp(seconds)
    }

    // MARK: - Per-Episode Obsidian URI

    /// Build an `obsidian://new` URI for a single episode's notes.
    /// Path: `YourPods Notes/<Podcast>/<Episode>`
    ///
    /// Returns nil if notes or vaultName are empty.
    static func obsidianPerEpisodeURI(notes: [Annotation], vaultName: String) -> URL? {
        guard !vaultName.isEmpty else { return nil }
        let liveNotes = notes.filter { !$0.deleted }
        guard let first = liveNotes.first else { return nil }

        let sorted = liveNotes.sorted { $0.timestampSec < $1.timestampSec }
        let markdown = exportMarkdownForSingleEpisode(notes: sorted)

        let podcastFolder = NextcloudNotesService.sanitizeFilename(first.podcastTitle ?? WireString.unknownPodcast)
        let episodeFile = NextcloudNotesService.sanitizeFilename(
            WireString.episodeIdentity(title: first.episodeTitle, url: first.episodeUrl))
        let notePath = "\(WireString.obsidianVaultRoot)/\(podcastFolder)/\(episodeFile)"

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "name", value: notePath),
            URLQueryItem(name: "content", value: markdown),
            URLQueryItem(name: "overwrite", value: "true")
        ]
        return components.url
    }

    // MARK: - Daily Note Append (Advanced URI Plugin)

    /// Build an `obsidian://advanced-uri` URI to append notes to today's daily note.
    /// Requires the Advanced URI community plugin in Obsidian.
    ///
    /// Returns nil if notes or vaultName are empty.
    static func obsidianDailyNoteURI(notes: [Annotation], vaultName: String) -> URL? {
        guard !vaultName.isEmpty else { return nil }
        let liveNotes = notes.filter { !$0.deleted }
        guard !liveNotes.isEmpty else { return nil }

        let sorted = liveNotes.sorted { $0.timestampSec < $1.timestampSec }
        let markdown = exportMarkdownForSingleEpisode(notes: sorted)

        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "advanced-uri"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "daily", value: "true"),
            URLQueryItem(name: "data", value: markdown),
            URLQueryItem(name: "mode", value: "append")
        ]
        return components.url
    }

    // MARK: - Bulk Per-Episode File Export

    /// A single exported note file (filename + content).
    struct ExportedNoteFile {
        let filename: String
        let content: String
    }

    /// Export annotations as individual per-episode `.md` files.
    /// Returns one `ExportedNoteFile` per unique episode URL.
    /// Excludes deleted annotations.
    static func exportPerEpisodeFiles(annotations: [Annotation]) -> [ExportedNoteFile] {
        let liveAnnotations = annotations.filter { !$0.deleted }
        guard !liveAnnotations.isEmpty else { return [] }

        // Group by episode URL, preserving first-seen order
        var episodeOrder: [String] = []
        var grouped: [String: [Annotation]] = [:]
        for annotation in liveAnnotations {
            if grouped[annotation.episodeUrl] == nil {
                episodeOrder.append(annotation.episodeUrl)
            }
            grouped[annotation.episodeUrl, default: []].append(annotation)
        }

        var files: [ExportedNoteFile] = []
        for episodeUrl in episodeOrder {
            guard let notes = grouped[episodeUrl] else { continue }
            let sorted = notes.sorted { $0.timestampSec < $1.timestampSec }
            guard let first = sorted.first else { continue }

            let markdown = exportMarkdownForSingleEpisode(notes: sorted)
            let filename = NextcloudNotesService.sanitizeFilename(
                first.episodeTitle ?? first.episodeUrl
            ) + ".md"
            files.append(ExportedNoteFile(filename: filename, content: markdown))
        }
        return files
    }

    // MARK: - Single Episode Markdown (shared)

    /// Generate Markdown for a single episode's notes with YAML frontmatter.
    /// Used by per-episode Obsidian URIs and bulk file export.
    private static func exportMarkdownForSingleEpisode(notes: [Annotation]) -> String {
        guard let first = notes.first else { return "" }

        var md = "---\n"
        md += "podcast: \(first.podcastTitle ?? "Unknown Podcast")\n"
        md += "episode: \(first.episodeTitle ?? "Unknown Episode")\n"
        if let dur = first.durationSec {
            md += "duration: \(formatTime(dur))\n"
        }
        md += "feed: \(first.podcastUrl)\n"
        md += "audio: \(first.episodeUrl)\n"
        let allTags = Set(notes.flatMap(\.tags))
        if !allTags.isEmpty {
            md += "tags: \(allTags.sorted().joined(separator: ", "))\n"
        }
        md += "---\n\n"

        md += "# \(first.episodeTitle ?? "Unknown Episode")\n"
        md += "**\(first.podcastTitle ?? "Unknown Podcast")**\n\n"

        for (i, note) in notes.enumerated() {
            md += "**[\(formatTime(note.timestampSec))]**"
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
}
