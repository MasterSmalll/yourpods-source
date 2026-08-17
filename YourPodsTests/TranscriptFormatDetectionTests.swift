import XCTest
@testable import YourPods

/// Format detection + parser coverage for the transcript pipeline.
///
/// Context: the Transcript button is gated on the parsed transcript having >= 1 item
/// (EpisodeDetailSheet:547, PlayerView:205, NowPlayingBar:537) — never on transcriptUrl.
/// So every detection miss below lands in `parseSRT`, yields zero items, and the button
/// silently disappears. These tests pin the detection contract that prevents that.
final class TranscriptFormatDetectionTests: XCTestCase {

    /// Two blank-line-separated segments, no markup — parses under any text-ish format.
    private let timestamped = """
    [00:00:00] Host: Welcome to the show.

    [00:00:05] Guest: Thanks for having me.
    """

    // MARK: - URL normalization

    func test_detectsFormatFromUrl_acrossRealWorldVariants() {
        let cases: [(url: String, expected: String, line: UInt)] = [
            // Query strings are routine on CDN/S3 presigned transcript URLs.
            ("https://cdn.example.com/t.txt?token=abc", "text/plain", #line),
            ("https://cdn.example.com/t.html?updated=1720000000", "text/html", #line),
            // Fragments.
            ("https://cdn.example.com/t.txt#start", "text/plain", #line),
            // hasSuffix is case-sensitive; feeds are not.
            ("https://cdn.example.com/T.TXT", "text/plain", #line),
            ("https://cdn.example.com/t.HTML", "text/html", #line),
            ("https://cdn.example.com/t.Htm", "text/html", #line),
            // Plain, already-working baselines — must not regress.
            ("https://cdn.example.com/t.txt", "text/plain", #line),
            ("https://cdn.example.com/t.html", "text/html", #line),
        ]

        for c in cases {
            let transcript = TranscriptService.parseContentSync(timestamped, url: c.url, type: nil)
            XCTAssertEqual(transcript.type, c.expected, "url=\(c.url)", line: c.line)
            XCTAssertFalse(transcript.items.isEmpty, "url=\(c.url) must yield items", line: c.line)
        }
    }

    // MARK: - Declared feed type is authoritative

    func test_EDGE_declaredTypeWithCharsetParameter_stillRoutes() {
        // `type="text/plain; charset=utf-8"` is valid in a feed. The exact-match switch
        // misses it and falls through to parseSRT — zero items, no button.
        let transcript = TranscriptService.parseContentSync(
            timestamped, url: "https://cdn.example.com/opaque", type: "text/plain; charset=utf-8"
        )
        XCTAssertEqual(transcript.type, "text/plain")
        XCTAssertEqual(transcript.items.count, 2)
    }

    func test_declaredFeedType_winsOverConflictingUrlSuffix() {
        let html = "<p>[00:00:00] Host: hi there</p>"
        let transcript = TranscriptService.parseContentSync(
            html, url: "https://cdn.example.com/mislabeled.txt", type: "text/html"
        )
        XCTAssertEqual(transcript.type, "text/html", "The feed's declared type is the source of truth")
        XCTAssertFalse(transcript.items[0].text.contains("<p>"), "HTML parser should have run")
    }

    // MARK: - Universal zero-item backstop

    func test_fallsBackToPlainText_whenDetectedFormatYieldsNoItems() {
        // Extension-less REST URL + prose. Detection can't tell what this is; today it
        // guesses SRT, finds no "-->", returns zero items, and the button vanishes.
        let prose = "Host: Welcome to the show. Guest: Thanks for having me."
        let transcript = TranscriptService.parseContentSync(
            prose, url: "https://api.example.com/transcripts/12345", type: nil
        )

        XCTAssertFalse(transcript.items.isEmpty, "A zero-item parse must fall back to plain text")
        XCTAssertTrue(transcript.items[0].text.contains("Welcome to the show"))
    }

    func test_retriesMislabeledGrammarFormats_asPlainText() {
        // A feed labelling prose as SubRip/WebVTT/JSON is readable text behind a bad label.
        let prose = "Host: Welcome to the show.\n\nGuest: Thanks for having me."
        let cases: [(url: String, type: String, line: UInt)] = [
            ("https://cdn.example.com/t.srt", "application/x-subrip", #line),
            ("https://cdn.example.com/t.vtt", "text/vtt", #line),
            ("https://cdn.example.com/t.json", "application/json", #line),
        ]
        for c in cases {
            let transcript = TranscriptService.parseContentSync(prose, url: c.url, type: c.type)
            XCTAssertFalse(transcript.items.isEmpty, "type=\(c.type) mislabelled prose must stay readable", line: c.line)
            XCTAssertTrue(transcript.items[0].text.contains("Welcome to the show"), "type=\(c.type)", line: c.line)
        }
    }

    func test_EDGE_doesNotDumpRawMarkup_whenHTMLHasNoText() {
        // parseHTML already ends in parsePlainText, so zero items means there was no text.
        // Retrying the raw bytes would present the markup itself as the transcript.
        let markupOnly = "<html><body><div></div><p></p></body></html>"
        let transcript = TranscriptService.parseContentSync(markupOnly, url: "t.html", type: "text/html")

        XCTAssertTrue(transcript.items.isEmpty, "An HTML document with no text must yield nothing, not raw markup")
    }

    func test_EDGE_doesNotDumpControlWords_whenRTFFailsToDecode() {
        let corruptRTF = #"{\rtf1\ansi\deff0 {\fonttbl"#  // truncated mid-table
        let transcript = TranscriptService.parseContentSync(corruptRTF, url: "t.rtf", type: "application/rtf")

        for item in transcript.items {
            XCTAssertFalse(item.text.contains("fonttbl"), "A corrupt RTF must not spill control words into the transcript")
        }
    }

    func test_retriesRTF_asPlainText_whenBytesAreNotActuallyRTF() {
        // Mislabelled .rtf that is really prose — the bytes are readable, so show them.
        let prose = "Host: Welcome to the show.\n\nGuest: Thanks for having me."
        let transcript = TranscriptService.parseContentSync(prose, url: "t.rtf", type: "application/rtf")

        XCTAssertFalse(transcript.items.isEmpty, "Prose mislabelled as RTF must stay readable")
        XCTAssertTrue(transcript.items[0].text.contains("Welcome to the show"))
    }

    func test_doesNotFallBack_whenFormatParsesSuccessfully() {
        let srt = """
        1
        00:00:00,000 --> 00:00:04,000
        Host: Welcome to the show.
        """
        let transcript = TranscriptService.parseContentSync(srt, url: "https://cdn.example.com/t.srt", type: nil)

        XCTAssertEqual(transcript.type, "application/srt", "A successful parse must keep its own type")
        XCTAssertEqual(transcript.items.count, 1)
    }

    // MARK: - Markdown

    func test_parsesMarkdown_strippingSyntax() {
        let markdown = """
        # Episode Transcript

        **[00:00:00]** _Host:_ Welcome to the [show](https://example.com).

        **[00:00:05]** _Guest:_ Thanks for having me.
        """
        let transcript = TranscriptService.parseContentSync(
            markdown, url: "https://cdn.example.com/t.md", type: nil
        )

        XCTAssertEqual(transcript.type, "text/markdown")
        XCTAssertEqual(transcript.items.count, 2, "The untimestamped '# Episode Transcript' heading is dropped")
        XCTAssertEqual(transcript.items[0].start, 0)
        XCTAssertEqual(transcript.items[1].start, 5)
        XCTAssertTrue(transcript.items[0].text.contains("Host:"), "Speaker label survives emphasis stripping")
        XCTAssertTrue(transcript.items[0].text.contains("show"), "Link text is kept")
        XCTAssertFalse(transcript.items[0].text.contains("**"), "Emphasis markers stripped")
        XCTAssertFalse(transcript.items[0].text.contains("https://example.com"), "Link target dropped")
    }

    func test_detectsMarkdown_fromExtensionAndMimeType() {
        let cases: [(url: String, type: String?, line: UInt)] = [
            ("https://cdn.example.com/t.md", nil, #line),
            ("https://cdn.example.com/t.markdown", nil, #line),
            ("https://cdn.example.com/t.md?v=2", nil, #line),
            ("https://cdn.example.com/opaque", "text/markdown", #line),
        ]
        for c in cases {
            let transcript = TranscriptService.parseContentSync(timestamped, url: c.url, type: c.type)
            XCTAssertEqual(transcript.type, "text/markdown", "url=\(c.url) type=\(c.type ?? "nil")", line: c.line)
            XCTAssertEqual(transcript.items.count, 2, "url=\(c.url)", line: c.line)
        }
    }

    // MARK: - RTF

    func test_parsesRTF_decodingControlWords() {
        let rtf = #"""
        {\rtf1\ansi\ansicpg1252\cocoartf2639
        {\fonttbl\f0\fswiss\fcharset0 Helvetica;}
        \f0\fs24 \cf0 [00:00:00] Host: Welcome to the show.\par
        \par
        [00:00:05] Guest: Thanks for having me.\par
        }
        """#
        let transcript = TranscriptService.parseContentSync(rtf, url: "https://cdn.example.com/t.rtf", type: nil)

        XCTAssertEqual(transcript.type, "application/rtf")
        XCTAssertFalse(transcript.items.isEmpty, "RTF must decode to readable text")
        let joined = transcript.items.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("Host:"), "Speaker label survives RTF decode")
        XCTAssertTrue(joined.contains("Welcome to the show"), "Body text survives RTF decode")
        XCTAssertFalse(joined.contains("rtf1"), "RTF control words must not leak into the transcript")
        XCTAssertFalse(joined.contains("fonttbl"), "RTF font table must not leak into the transcript")
    }

    func test_detectsRTF_fromExtensionAndMimeType() {
        let cases: [(url: String, type: String?, line: UInt)] = [
            ("https://cdn.example.com/t.rtf", nil, #line),
            ("https://cdn.example.com/t.RTF?x=1", nil, #line),
            ("https://cdn.example.com/opaque", "application/rtf", #line),
            ("https://cdn.example.com/opaque", "text/rtf", #line),
        ]
        for c in cases {
            let transcript = TranscriptService.parseContentSync(
                #"{\rtf1\ansi \f0 [00:00:00] Host: hello there\par}"#, url: c.url, type: c.type
            )
            XCTAssertEqual(transcript.type, "application/rtf", "url=\(c.url) type=\(c.type ?? "nil")", line: c.line)
        }
    }

    // MARK: - parseHTML hygiene

    func test_parseHTML_dropsHeadTitleScriptAndStyleContent() {
        // parseHTML strips TAGS but keeps their text. Without timestamps the whole body
        // becomes one item, so <title>/<style>/<script> text leaks into the transcript.
        let html = """
        <!DOCTYPE html>
        <html><head><title>Why AI Data Centers Aren't The Real Problem</title>
        <style>body { color: red; font-size: 12px; }</style>
        <script>var tracker = 1;</script>
        </head>
        <body><p>Host: the actual transcript body text.</p></body></html>
        """
        let transcript = TranscriptService.parseContentSync(html, url: "t.html", type: "text/html")

        let text = transcript.items.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("actual transcript body"), "Real body text is kept")
        XCTAssertFalse(text.contains("Why AI Data Centers"), "<title> text must not leak in")
        XCTAssertFalse(text.contains("color: red"), "<style> contents must not leak in")
        XCTAssertFalse(text.contains("var tracker"), "<script> contents must not leak in")
    }

    func test_parseHTML_decodesNumericEntities() {
        let html = """
        <p>[00:00:00] Host: It&#8217;s a good question&#8230;</p>

        <p>[00:00:05] Guest: Right&#x2014;exactly.</p>
        """
        let transcript = TranscriptService.parseContentSync(html, url: "t.html", type: "text/html")

        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertTrue(transcript.items[0].text.contains("It\u{2019}s"), "Decimal entity &#8217; -> ’")
        XCTAssertTrue(transcript.items[0].text.contains("\u{2026}"), "Decimal entity &#8230; -> …")
        XCTAssertTrue(transcript.items[1].text.contains("\u{2014}"), "Hex entity &#x2014; -> —")
        XCTAssertFalse(transcript.items[0].text.contains("&#"), "No raw entities may survive")
    }

    // MARK: - Real-world feed shape

    func test_Scenario_parsesCastosHtmlTranscript_endToEnd() {
        // The exact shape Seriously Simple Podcasting / Castos publishes: a full HTML
        // document whose <title> duplicates the <h1>, per-line <span>/<strong> styling,
        // and numeric entities. Modelled on a real 3reate episode transcript.
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8" />
        <title>Why AI Data Centers Aren't The Real Problem</title>
        </head>
        <body>
        <h1>Why AI Data Centers Aren't The Real Problem</h1>
        <p><span style="color:#808080">[00:00:00]</span> <strong style="color:#489872">Host:</strong> Welcome to</p>
        <p><span style="color:#808080">[00:00:01]</span> <strong style="color:#9C5DE1">Guest:</strong> the show. Thanks for having me.</p>
        <p><span style="color:#808080">[00:00:02]</span> <strong style="color:#9C5DE1">Guest:</strong> That&#8217;s a good question.</p>
        </body>
        </html>
        """
        let transcript = TranscriptService.parseContentSync(
            html,
            url: "https://cdn.3reate.com/uploads/20260716160602/Why-AI-Data-Centers-Arent-The-Real-Problem.html",
            type: "text/html"
        )

        XCTAssertEqual(transcript.type, "text/html")
        XCTAssertEqual(transcript.items.count, 3,
                       "One item per timestamped <p> — the <title> and <h1> carry no timestamp and are dropped")
        XCTAssertEqual(transcript.items[0].start, 0)
        XCTAssertEqual(transcript.items[1].start, 1)
        XCTAssertEqual(transcript.items[2].start, 2)
        XCTAssertTrue(transcript.items[0].text.contains("Host:"), "Speaker labels survive tag stripping")
        XCTAssertTrue(transcript.items[2].text.contains("That\u{2019}s a good question."), "&#8217; decodes to a real apostrophe")

        let joined = transcript.items.map(\.text).joined(separator: " ")
        XCTAssertFalse(joined.contains("Why AI Data Centers"), "The <title>/<h1> must not read as transcript text")
        XCTAssertFalse(joined.contains("color:"), "Inline style attributes must not leak")
    }

    func test_EDGE_parseHTML_doesNotDoubleDecodeAmpersandEntities() {
        // &amp; is decoded first today, so &amp;lt; becomes &lt; and then <.
        let html = "<p>[00:00:00] Host: use &amp;lt;br&amp;gt; to break a line</p>"
        let transcript = TranscriptService.parseContentSync(html, url: "t.html", type: "text/html")

        XCTAssertEqual(transcript.items.count, 1)
        XCTAssertTrue(transcript.items[0].text.contains("&lt;br&gt;"), "&amp;lt; must decode to &lt;, not <")
    }
}
