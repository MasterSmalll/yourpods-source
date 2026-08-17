import XCTest

/// Guards the two invariants behind the "widget buttons open the app instead of
/// acting" regression (June–July 2026), so it cannot silently return:
///
/// 1. **No accented rendering modifier inside an interactive widget element's
///    label.** `widgetAccentedRenderingMode` (incl. the `accentedDesaturated()`
///    helper) applied to the label of a `Button(intent:)`, `Link`, or `Toggle`
///    silently disables the interactive region — the tap falls through to the
///    widget's default open-app action and `perform()` / the Link URL never
///    dispatches. Apple-acknowledged: FB15152620 (forums thread 763804); the
///    iOS 26 Link variant additionally delivers empty `urlContexts` (thread
///    795408). This exact mistake shipped in earlier releases.
///
/// 2. **Widget playback intents stay background-only.** `openAppWhenRun = false`
///    and `supportedModes = [.background]` — no `.foreground` mode. Declaring
///    `.foreground(.dynamic)` registers the foreground-continuation route and
///    invites the system to open the app. Background-only is the
///    configuration Pocket Casts shipped for the same iOS 26 regression
///    (Automattic/pocket-casts-ios PR #3846).
final class WidgetInteractivityGuardTests: XCTestCase {

    // MARK: - Source scanner

    /// Substrings banned inside an interactive element's label closure.
    /// `widgetAccentable` is deliberately NOT banned — it is safe on labels
    /// (Pocket Casts uses it on theirs).
    private static let bannedInLabels = ["widgetAccentedRenderingMode", "accentedDesaturated"]

    /// Tokens that open an interactive widget element whose trailing closure
    /// is the label.
    private static let interactiveTokens = ["Button(intent:", "Link(destination:", "Toggle("]

    /// Returns one violation description per banned modifier found inside an
    /// interactive element's trailing label closure. Scanner: from each token,
    /// walk past the balanced argument parens, take the next `{`, brace-match
    /// to the closure end, and search that span. (The widget sources contain no
    /// string literals with braces/parens that would confuse the counters.)
    private func labelViolations(in source: String, file: String) -> [String] {
        var violations: [String] = []
        let chars = Array(source)
        for token in Self.interactiveTokens {
            var searchStart = source.startIndex
            while let range = source.range(of: token, range: searchStart..<source.endIndex) {
                searchStart = range.upperBound
                var i = source.distance(from: source.startIndex, to: range.lowerBound)
                // Walk to the token's opening paren, then to its balanced close.
                while i < chars.count, chars[i] != "(" { i += 1 }
                var parenDepth = 0
                while i < chars.count {
                    if chars[i] == "(" { parenDepth += 1 }
                    if chars[i] == ")" { parenDepth -= 1; if parenDepth == 0 { i += 1; break } }
                    i += 1
                }
                // The next `{` (skipping whitespace) opens the label closure.
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                guard i < chars.count, chars[i] == "{" else { continue }
                let labelStart = i
                var braceDepth = 0
                while i < chars.count {
                    if chars[i] == "{" { braceDepth += 1 }
                    if chars[i] == "}" { braceDepth -= 1; if braceDepth == 0 { i += 1; break } }
                    i += 1
                }
                let label = String(chars[labelStart..<i])
                // One violation per label, even when both banned spellings appear
                // (e.g. `.widgetAccentedRenderingMode(.accentedDesaturated)`).
                if let banned = Self.bannedInLabels.first(where: { label.contains($0) }) {
                    let line = source[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                    violations.append("\(file):\(line): `\(banned)` inside \(token)…) label — FB15152620 kills this tap region")
                }
            }
        }
        return violations
    }

    private func widgetSourceFiles() throws -> [(name: String, contents: String)] {
        // <repo>/YourPodsTests/WidgetInteractivityGuardTests.swift → <repo>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widgetsDir = repoRoot.appendingPathComponent("YourPodsWidgets")
        let files = try FileManager.default.contentsOfDirectory(at: widgetsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No widget sources found at \(widgetsDir.path) — scanner is misrooted, fix the path instead of skipping")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    // MARK: - Scanner self-checks (prove the detector can fail)

    func test_scanner_flagsModifierInsideButtonLabel() {
        // The literal shape that shipped broken in earlier releases.
        let bad = """
        Button(intent: WidgetTogglePlayIntent()) {
            Image(systemName: data.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .accentedDesaturated()
                .font(.title)
        }
        .buttonStyle(.plain)
        """
        XCTAssertEqual(labelViolations(in: bad, file: "fixture").count, 1)
    }

    func test_scanner_flagsModifierInsideLinkLabel() {
        let bad = """
        Link(destination: URL(string: "yourpods://action/skipForward")!) {
            Image(systemName: "goforward.30")
                .widgetAccentedRenderingMode(.accentedDesaturated)
        }
        """
        XCTAssertEqual(labelViolations(in: bad, file: "fixture").count, 1)
    }

    func test_EDGE_scanner_allowsPlainLabels_andModifierOutsideInteractiveElements() {
        let good = """
        Button(intent: WidgetTogglePlayIntent()) {
            Image(systemName: "play.circle.fill")
                .font(.title)
                .widgetAccentable()
        }
        Image(systemName: "headphones.circle.fill")
            .accentedDesaturated()
            .font(.system(size: 32))
        """
        XCTAssertEqual(labelViolations(in: good, file: "fixture"), [])
    }

    // MARK: - Invariant 1: real widget sources

    func test_widgetSources_haveNoAccentedRenderingModifierInsideInteractiveLabels() throws {
        for (name, contents) in try widgetSourceFiles() {
            let violations = labelViolations(in: contents, file: name)
            XCTAssertEqual(violations, [], violations.joined(separator: "\n"))
        }
    }

    // MARK: - Invariant 2: background-only intent dispatch

    func test_widgetIntents_declareBackgroundOnlySupportedModes() throws {
        let source = try XCTUnwrap(
            try widgetSourceFiles().first { $0.name == "WidgetPlaybackIntents.swift" },
            "WidgetPlaybackIntents.swift missing from YourPodsWidgets"
        ).contents
        let declarations = source.components(separatedBy: "supportedModes: IntentModes { [.background] }").count - 1
        XCTAssertEqual(declarations, 3, "All 3 widget intents must declare supportedModes = [.background] exactly")
        // Comments may (and do) mention .foreground when explaining its history;
        // only code is banned from declaring it.
        let code = source
            .components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains(".foreground"),
                       "No widget intent may declare a .foreground supported mode — it invites the open-app dispatch route")
    }
}
