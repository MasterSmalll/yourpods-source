/// Structural guard for the two sync entry-point rules:
///
///   * "All sync must route through `refreshAndSync()`" — bypassing the factory
///     breaks profile isolation.
///   * "Respect `syncConflictStrategy` in all code paths" — it's the user's source
///     of truth.
///
/// Both were being broken silently, and neither could be caught by a behavioural test
/// because the offending call sites are `private func`s inside SwiftUI views.
///
/// What it cost: "Sync Now" called `syncSubscriptions()` + `syncEpisodeActions()`
/// directly, so the button synced subscriptions and episode actions and NOTHING else —
/// no playback positions, no queue, no settings, no notes. A user pressing Sync because
/// their playhead was wrong was pressing a button that could not, by construction, fix
/// it. And because neither call passed a strategy, both defaulted to `.serverWins`,
/// overriding a user who had chosen "ask" or "this device wins".
///
/// A source scan is the right shape here: the rule is "no call site anywhere does X",
/// which is a property of the codebase, not of one object's behaviour.
import XCTest
@testable import YourPods

final class SyncEntryPointGuardTests: XCTestCase {

    private static let excludedFileName = "SyncEntryPointGuardTests.swift"

    /// `YourPods/YourPods` only — the floor guards against a scanner that silently
    /// misroots and passes by finding nothing. Real count at the time of writing: 171.
    private func sourceRoot() -> (root: URL, floor: Int) {
        var repoRoot = URL(fileURLWithPath: #filePath)   // …/YourPodsTests/ThisFile.swift
        repoRoot.deleteLastPathComponent()               // …/YourPodsTests
        repoRoot.deleteLastPathComponent()               // repo root
        return (repoRoot.appendingPathComponent("YourPods/YourPods"), 50)
    }

    private func swiftFiles() throws -> [URL] {
        let (root, floor) = sourceRoot()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != Self.excludedFileName } ?? []
        XCTAssertFalse(files.isEmpty, "source scan found no files under \(root.path) — sourceRoot() is wrong")
        XCTAssertGreaterThan(files.count, floor,
            "found only \(files.count) .swift files — implausibly low, sourceRoot() is likely misrooted")
        return files
    }

    /// Returns the full argument list of every `call(` in `text`, by walking forward
    /// from the opening paren until it balances. Multi-line calls are the norm here, so
    /// a per-line regex would miss almost all of them.
    private func argumentLists(of call: String, in text: String) -> [(line: Int, args: String)] {
        var results: [(Int, String)] = []
        var searchStart = text.startIndex
        while let callRange = text.range(of: call, range: searchStart..<text.endIndex) {
            searchStart = callRange.upperBound
            var depth = 1
            var idx = callRange.upperBound
            var args = ""
            while idx < text.endIndex, depth > 0 {
                let ch = text[idx]
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1; if depth == 0 { break } }
                args.append(ch)
                idx = text.index(after: idx)
            }
            let line = text[text.startIndex..<callRange.lowerBound].filter(\.isNewline).count + 1
            // Skip prose. `refreshAndSync()` is referenced by name in doc comments, and a
            // guard that reports comments is a guard people learn to ignore.
            let lineStart = text[text.startIndex..<callRange.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
            let prefix = text[lineStart..<callRange.lowerBound].trimmingCharacters(in: .whitespaces)
            if prefix.hasPrefix("//") || prefix.hasPrefix("*") || prefix.hasPrefix("///") { continue }
            results.append((line, args))
        }
        return results
    }

    // MARK: - Rule 1 — views never sync directly

    /// The UI layer must not reach past `refreshAndSync` into individual sync steps.
    /// `PodcastManager` and the orchestrators are exempt — they *are* the sync layer —
    /// as is `PlayerManager`, which coordinates playback-driven syncs internally.
    func test_noViewCallsIndividualSyncStepsDirectly() throws {
        let exemptPathFragments = [
            "/State/PodcastManager.swift",
            "/State/PlayerManager.swift",
            "/Services/Sync/",
        ]
        var violations: [String] = []

        for file in try swiftFiles() {
            if exemptPathFragments.contains(where: { file.path.contains($0) }) { continue }
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for (offset, line) in contents.components(separatedBy: .newlines).enumerated() {
                guard line.contains(".syncEpisodeActions(") || line.contains(".syncSubscriptions(") else { continue }
                // A definition or a doc comment is not a call site.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("func ") { continue }
                violations.append("\(file.lastPathComponent):\(offset + 1): \(trimmed)")
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            These call individual sync steps directly instead of routing through \
            PodcastManager.refreshAndSync(). A sync that skips the factory syncs only the \
            steps it names — no playback positions, no queue, no settings, no notes — so \
            the user presses Sync and the thing they wanted synced is exactly what is not:
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: - Rule 2 — every refreshAndSync passes the user's strategy

    /// Omitting `strategy:` silently selects `.serverWins`, which overrides a user who
    /// chose "ask" or "this device wins" — the setting exists precisely so the app does
    /// not decide this for them.
    func test_everyRefreshAndSyncCallPassesAStrategy() throws {
        var violations: [String] = []

        for file in try swiftFiles() {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for call in argumentLists(of: "refreshAndSync(", in: contents) {
                // The declaration itself carries `strategy: SyncStrategy = .serverWins`.
                if call.args.contains("strategy: SyncStrategy") { continue }
                if call.args.contains("strategy:") { continue }
                violations.append("\(file.lastPathComponent):\(call.line)")
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            These refreshAndSync() calls omit `strategy:` and so default to .serverWins, \
            silently overriding the user's syncConflictStrategy:
            \(violations.joined(separator: "\n"))
            """)
    }
}
