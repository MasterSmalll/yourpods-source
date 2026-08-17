import XCTest
@testable import YourPods

final class ID3ChapterFrameParserTests: XCTestCase {

    // MARK: - Builders

    /// Big-endian UInt32.
    static func be32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
              UInt8(truncatingIfNeeded: v >> 8),  UInt8(truncatingIfNeeded: v)])
    }

    /// A CHAP payload header: element ID + 4 big-endian UInt32s.
    static func chapHeader(id: String, start: UInt32, end: UInt32) -> Data {
        var d = Data(id.utf8)
        d.append(0x00)
        d.append(be32(start))
        d.append(be32(end))
        d.append(be32(0xFFFF_FFFF))
        d.append(be32(0xFFFF_FFFF))
        return d
    }

    // MARK: - Header

    func test_parsesElementIdAndTimes() {
        let payload = Self.chapHeader(id: "chp6", start: 76_000, end: 94_000)

        let frame = ID3ChapterFrameParser.parse(payload: payload)

        XCTAssertEqual(frame?.elementID, "chp6")
        XCTAssertEqual(frame?.startTimeMs, 76_000)
        XCTAssertEqual(frame?.endTimeMs, 94_000)
    }

    func test_parsesZeroStartTime() {
        let payload = Self.chapHeader(id: "chp0", start: 0, end: 5_000)

        let frame = ID3ChapterFrameParser.parse(payload: payload)

        XCTAssertEqual(frame?.startTimeMs, 0)
    }

    // MARK: - Malformed input (must return nil, never crash or trap)

    func test_returnsNil_whenPayloadEmpty() {
        XCTAssertNil(ID3ChapterFrameParser.parse(payload: Data()))
    }

    func test_returnsNil_whenNoNulTerminator() {
        XCTAssertNil(ID3ChapterFrameParser.parse(payload: Data("chp0".utf8)))
    }

    /// EDGE: NUL present but the four UInt32s are truncated.
    func test_returnsNil_whenTimesTruncated() {
        var d = Data("chp0".utf8)
        d.append(0x00)
        d.append(Self.be32(0))
        d.append(Data([0x00, 0x01]))  // 2 of the remaining 12 bytes

        XCTAssertNil(ID3ChapterFrameParser.parse(payload: d))
    }

    // MARK: - Sub-frame builders

    /// A 10-byte ID3 frame header with a plain big-endian size (v2.3).
    static func subFramePlain(id: String, body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(be32(UInt32(body.count)))
        d.append(Data([0x00, 0x00]))
        d.append(body)
        return d
    }

    /// A 10-byte ID3 frame header with a synchsafe size (v2.4).
    static func subFrameSynchsafe(id: String, body: Data) -> Data {
        let n = UInt32(body.count)
        var d = Data(id.utf8)
        d.append(Data([UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F),
                       UInt8((n >> 7) & 0x7F),  UInt8(n & 0x7F)]))
        d.append(Data([0x00, 0x00]))
        d.append(body)
        return d
    }

    /// A body large enough that plain-BE and synchsafe sizes diverge (>= 128 in
    /// any size byte). 200 bytes: plain = 0x000000C8, synchsafe = 0x00000148.
    static func largeBody(_ n: Int = 200) -> Data {
        Data(repeating: 0xAB, count: n)
    }

    // MARK: - Sub-frame walk

    func test_walksSingleSmallSubFrame_v23() {
        var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(Self.subFramePlain(id: "TIT2", body: Data(repeating: 0x41, count: 20)))

        let subs = ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21)

        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].id, "TIT2")
        XCTAssertEqual(subs[0].body.count, 20)
    }

    /// The core regression: a large sub-frame sized as plain big-endian (v2.3).
    /// Reading it as synchsafe truncates the body — the chapter-image bug.
    func test_walksLargeSubFrame_v23_plainBigEndianSize() {
        let body = Self.largeBody()
        var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(Self.subFramePlain(id: "APIC", body: body))

        let subs = ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21)

        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].id, "APIC")
        XCTAssertEqual(subs[0].body.count, 200, "v2.3 plain-BE size misread as synchsafe truncates the image")
    }

    /// The mirror case: the same body sized synchsafe (v2.4), followed by a second
    /// sub-frame. A plain-BE-only reading of APIC's size bytes (00 00 01 48 = 328)
    /// clamps to a wrong-length body but still overruns the payload — so without a
    /// second frame to reach, that misreading is invisible to the assertions. The
    /// second frame is what actually discriminates: a plain-only walk's declared
    /// 328 bytes swallow the rest of the payload and TIT2 is never seen.
    func test_walksLargeSubFrame_v24_synchsafeSize() {
        let body = Self.largeBody()
        var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(Self.subFrameSynchsafe(id: "APIC", body: body))
        payload.append(Self.subFrameSynchsafe(id: "TIT2", body: Data(repeating: 0x42, count: 41)))

        let subs = ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21)

        XCTAssertEqual(subs.map(\.id), ["APIC", "TIT2"],
                        "v2.4 synchsafe sizes misread as plain-BE overrun and never reach TIT2")
        XCTAssertEqual(subs.map(\.body.count), [200, 41])
    }

    /// Real-world shape from auphonic.mp3: APIC, TIT2, WXXX in one payload.
    func test_walksMultipleSubFrames_largeFirst() {
        var payload = Self.chapHeader(id: "chp6", start: 76_000, end: 94_000)
        payload.append(Self.subFramePlain(id: "APIC", body: Self.largeBody(300)))
        payload.append(Self.subFramePlain(id: "TIT2", body: Data(repeating: 0x42, count: 41)))
        payload.append(Self.subFramePlain(id: "WXXX", body: Data(repeating: 0x43, count: 40)))

        let subs = ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21)

        XCTAssertEqual(subs.map(\.id), ["APIC", "TIT2", "WXXX"])
        XCTAssertEqual(subs.map(\.body.count), [300, 41, 40])
    }

    func test_returnsEmpty_whenNoSubFrames() {
        let payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)

        XCTAssertTrue(ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21).isEmpty)
    }

    /// EDGE: a declared size that runs past the end of the payload must be
    /// clamped, not trusted — a truncated download must not trap.
    func test_clampsSubFrame_whenDeclaredSizeOverrunsPayload() {
        var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(Data("APIC".utf8))
        payload.append(Self.be32(99_999))
        payload.append(Data([0x00, 0x00]))
        payload.append(Data(repeating: 0xAB, count: 50))  // only 50 bytes actually present

        let subs = ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21)

        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].id, "APIC")
        XCTAssertEqual(subs[0].body.count, 50, "must clamp to available bytes")
    }

    /// EDGE: bytes that decode via ISO-8859-1 to "letter-like" or "number-like"
    /// characters (Latin-1 uppercase diacritics, superscript/fraction digits) are
    /// not legal ID3 frame IDs — only ASCII 'A'-'Z'/'0'-'9' are. A validity check
    /// based on Character.isUppercase/isNumber would wrongly accept these; the
    /// walk must reject them and stop, the same way it stops on any other garbage.
    func test_stopsWalk_onNonAsciiLatin1FrameID() {
        let casesByFirstIDByte: [(byte: UInt8, label: String)] = [
            (0xC0, "À — Latin-1 uppercase, not ASCII"),
            (0xDE, "Þ — Latin-1 uppercase, not ASCII"),
            (0xB2, "² — Unicode numeric, not ASCII digit"),
            (0xBC, "¼ — Unicode numeric, not ASCII digit"),
        ]

        for testCase in casesByFirstIDByte {
            var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
            var idBytes = Data("PIC".utf8)   // 3 legal bytes + 1 illegal, still isoLatin1-decodable
            idBytes.insert(testCase.byte, at: 0)
            payload.append(idBytes)
            payload.append(Self.be32(20))
            payload.append(Data([0x00, 0x00]))
            payload.append(Data(repeating: 0xAB, count: 20))

            let subs = ID3ChapterFrameParser.subFrames(in: payload, startingAt: 21)

            XCTAssertTrue(subs.isEmpty, "\(testCase.label) must not be accepted as a frame ID")
        }
    }

    // MARK: - Text decoding

    func test_decodesText_acrossAllEncodings() {
        let utf16LE: Data = {
            var d = Data([0x01, 0xFF, 0xFE])                       // BOM: little-endian
            d.append("Output".data(using: .utf16LittleEndian)!)
            return d
        }()
        let utf16BE_BOM: Data = {
            var d = Data([0x01, 0xFE, 0xFF])                       // BOM: big-endian
            d.append("Output".data(using: .utf16BigEndian)!)
            return d
        }()
        let utf16BE_noBOM: Data = {
            var d = Data([0x02])
            d.append("Output".data(using: .utf16BigEndian)!)
            return d
        }()

        let cases: [(name: String, body: Data, expected: String?)] = [
            ("latin1",         Data([0x00]) + Data("Output".utf8),  "Output"),
            ("utf16 LE BOM",   utf16LE,                             "Output"),
            ("utf16 BE BOM",   utf16BE_BOM,                         "Output"),
            ("utf16 BE noBOM", utf16BE_noBOM,                       "Output"),
            ("utf8",           Data([0x03]) + Data("Output".utf8),  "Output"),
            ("utf8 non-ascii", Data([0x03]) + Data("Café ☕".utf8), "Café ☕"),
            ("empty body",     Data(),                              nil),
            ("encoding only",  Data([0x03]),                        ""),
        ]

        for c in cases {
            XCTAssertEqual(ID3ChapterFrameParser.decodeText(c.body), c.expected, "case: \(c.name)")
        }
    }

    /// EDGE: ID3 text frames are often NUL-terminated; the terminator must not
    /// survive into the title.
    func test_decodesText_strippingTrailingNul() {
        let body = Data([0x03]) + Data("Intro".utf8) + Data([0x00])

        XCTAssertEqual(ID3ChapterFrameParser.decodeText(body), "Intro")
    }

    /// EDGE: invalid UTF-8 bytes under the 0x03 encoding byte must degrade to
    /// nil, never trap — the same "log and continue, never crash" rule this
    /// parser already applies to malformed headers and sub-frame sizes.
    func test_decodesText_returnsNil_forInvalidUtf8Bytes() {
        let body = Data([0x03, 0xFF, 0xFE, 0xFD])

        XCTAssertNil(ID3ChapterFrameParser.decodeText(body))
    }

    /// EDGE: U+FEFF appearing mid-string is legitimate content, not BOM
    /// residue — Foundation's utf8/utf16 decoders already consume a real
    /// leading byte-order mark, so a naive "strip every U+FEFF" pass would
    /// corrupt a title that happens to contain this character instead of
    /// removing decoder residue (there is none left to remove).
    func test_decodesText_preservesLegitimateMidStringFeff() {
        let title = "Before\u{FEFF}After"
        let body = Data([0x03]) + Data(title.utf8)

        XCTAssertEqual(ID3ChapterFrameParser.decodeText(body), title)
    }

    // MARK: - Title integration

    func test_parse_populatesTitleFromTIT2() {
        var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(Self.subFramePlain(id: "TIT2", body: Data([0x03]) + Data("Introduction".utf8)))

        let frame = ID3ChapterFrameParser.parse(payload: payload)

        XCTAssertEqual(frame?.title, "Introduction")
    }

    func test_parse_leavesTitleNil_whenNoTIT2() {
        let payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)

        XCTAssertNil(ID3ChapterFrameParser.parse(payload: payload)?.title)
    }

    /// EDGE: a sub-frame present but not TIT2 must not populate title. This
    /// exercises the `switch`'s `default: break` branch (APIC/WXXX handling
    /// has its own sections below) so the no-TIT2 case above isn't only ever tested by
    /// the absence of any sub-frame at all.
    func test_parse_leavesTitleNil_whenOnlySubFrameIsNotTIT2() {
        var payload = Self.chapHeader(id: "chp0", start: 0, end: 1000)
        payload.append(Self.subFramePlain(id: "TALB", body: Data([0x03]) + Data("Some Album".utf8)))

        XCTAssertNil(ID3ChapterFrameParser.parse(payload: payload)?.title)
    }

    // MARK: - APIC builders

    static func apicBody(mime: String = "image/jpeg",
                         encoding: UInt8 = 0x00,
                         description: String = "",
                         image: Data) -> Data {
        var d = Data([encoding])
        d.append(Data(mime.utf8)); d.append(0x00)
        d.append(0x03)                                   // picture type: front cover
        if encoding == 0x01 || encoding == 0x02 {
            d.append(description.data(using: .utf16LittleEndian) ?? Data())
            d.append(Data([0x00, 0x00]))                 // UTF-16 terminator
        } else {
            d.append(Data(description.utf8)); d.append(0x00)
        }
        d.append(image)
        return d
    }

    // MARK: - APIC

    func test_decodesAPIC_extractingImageBytes() {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(0x11), count: 96))

        let extracted = ID3ChapterFrameParser.decodeAPIC(Self.apicBody(image: image))

        XCTAssertEqual(extracted, image)
    }

    func test_decodesAPIC_withNonEmptyDescription() {
        let image = Data(repeating: 0x22, count: 64)

        let extracted = ID3ChapterFrameParser.decodeAPIC(
            Self.apicBody(description: "cover art", image: image))

        XCTAssertEqual(extracted, image)
    }

    /// EDGE: UTF-16 descriptions terminate with a DOUBLE NUL. Treating it as a
    /// single NUL leaves a stray byte at the head of the image data.
    func test_decodesAPIC_withUtf16Description() {
        let image = Data(repeating: 0x33, count: 64)

        let extracted = ID3ChapterFrameParser.decodeAPIC(
            Self.apicBody(encoding: 0x01, description: "art", image: image))

        XCTAssertEqual(extracted, image)
    }

    /// EDGE: an empty UTF-16 description is just the double-NUL terminator
    /// with nothing before it — the scan must match it on its very first
    /// iteration and land the cursor exactly on the first image byte, not
    /// one before or after.
    func test_decodesAPIC_withEmptyUtf16Description() {
        let image = Data(repeating: 0x44, count: 64)

        let extracted = ID3ChapterFrameParser.decodeAPIC(
            Self.apicBody(encoding: 0x01, description: "", image: image))

        XCTAssertEqual(extracted, image)
    }

    func test_decodesAPIC_pngMime() {
        let image = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0x44), count: 60))

        let extracted = ID3ChapterFrameParser.decodeAPIC(
            Self.apicBody(mime: "image/png", image: image))

        XCTAssertEqual(extracted, image)
    }

    func test_decodesAPIC_returnsNil_whenNoImageBytes() {
        XCTAssertNil(ID3ChapterFrameParser.decodeAPIC(Self.apicBody(image: Data())))
    }

    func test_decodesAPIC_returnsNil_whenTruncatedBeforeMimeTerminator() {
        let body = Data([0x00]) + Data("image/jpe".utf8)   // no NUL

        XCTAssertNil(ID3ChapterFrameParser.decodeAPIC(body))
    }

    /// EDGE: a 1-byte-encoding description with no NUL terminator anywhere
    /// before the end of the body. Coverage for the `else` branch's nil
    /// guard, which was already correct but previously unexercised directly.
    func test_decodesAPIC_returnsNil_whenDescriptionUnterminated() {
        var body = Data([0x00])
        body.append(Data("image/jpeg".utf8)); body.append(0x00)
        body.append(0x03)
        body.append(Data("no terminator here".utf8))   // no trailing NUL at all

        XCTAssertNil(ID3ChapterFrameParser.decodeAPIC(body))
    }

    /// EDGE (regression): a UTF-16 description with no double-NUL terminator
    /// anywhere before the end of the body is malformed input. Before this
    /// fix the scan fell through the `while` loop with no `else`, so the
    /// outcome was parity-dependent — sometimes nil, sometimes a stray tail
    /// byte returned as "image data". It must degrade to nil symmetrically
    /// with the 1-byte-encoding branch above, never return garbage.
    func test_decodesAPIC_returnsNil_whenUtf16DescriptionUnterminated() {
        var body = Data([0x01])
        body.append(Data("image/jpeg".utf8)); body.append(0x00)
        body.append(0x03)
        body.append(Data([0x41, 0x00]))   // one UTF-16 code unit, no terminator
        body.append(Data([0x01]))         // stray trailing byte — still no 00 00 pair

        XCTAssertNil(ID3ChapterFrameParser.decodeAPIC(body))
    }

    // MARK: - WXXX

    func test_decodesWXXX_link() {
        // WXXX: encoding byte, NUL-terminated description, then the URL (Latin-1).
        var body = Data([0x00])
        body.append(Data("chapter url".utf8)); body.append(0x00)
        body.append(Data("https://example.com/ch1".utf8))

        XCTAssertEqual(ID3ChapterFrameParser.decodeWXXX(body), "https://example.com/ch1")
    }

    /// EDGE (regression): WXXX's description terminator width depends on the
    /// encoding byte exactly like APIC's — the URL itself always stays
    /// Latin-1, but the description before it does not. A single-NUL scan
    /// stops at the first zero *byte* of the first UTF-16 code unit and
    /// returns a corrupted link (embedded description bytes prepended to the
    /// URL) instead of the clean URL.
    func test_decodesWXXX_withUtf16Description() {
        var body = Data([0x01])                             // encoding: UTF-16LE, no BOM
        body.append("link".data(using: .utf16LittleEndian)!)
        body.append(Data([0x00, 0x00]))                     // UTF-16 terminator
        body.append(Data("https://example.com/ch1".utf8))

        XCTAssertEqual(ID3ChapterFrameParser.decodeWXXX(body), "https://example.com/ch1")
    }

    /// EDGE: an empty (single-byte, encoding-only) body has no description
    /// terminator to find at all — must degrade to nil, never trap on the
    /// slice arithmetic.
    func test_decodesWXXX_returnsNil_whenBodyEmpty() {
        XCTAssertNil(ID3ChapterFrameParser.decodeWXXX(Data()))
    }

    // MARK: - Full integration

    func test_parse_populatesAllFields_realWorldShape() {
        // Mirrors auphonic.mp3 chp6: APIC first, then TIT2, then WXXX.
        let image = Data(repeating: 0x55, count: 300)
        var payload = Self.chapHeader(id: "chp6", start: 76_000, end: 94_000)
        payload.append(Self.subFramePlain(id: "APIC", body: Self.apicBody(image: image)))
        payload.append(Self.subFramePlain(id: "TIT2",
                                          body: Data([0x01, 0xFF, 0xFE]) + "Output".data(using: .utf16LittleEndian)!))
        var wxxx = Data([0x00]); wxxx.append(0x00); wxxx.append(Data("https://e.g/6".utf8))
        payload.append(Self.subFramePlain(id: "WXXX", body: wxxx))

        let frame = ID3ChapterFrameParser.parse(payload: payload)

        XCTAssertEqual(frame?.elementID, "chp6")
        XCTAssertEqual(frame?.startTimeMs, 76_000)
        XCTAssertEqual(frame?.title, "Output")
        XCTAssertEqual(frame?.imageData?.count, 300)
        XCTAssertEqual(frame?.link, "https://e.g/6")
    }
}
