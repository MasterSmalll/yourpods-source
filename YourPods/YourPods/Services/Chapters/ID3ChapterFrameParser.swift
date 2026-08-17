import Foundation

/// One parsed ID3 `CHAP` frame. Value type, no image decoding — `imageData`
/// carries raw APIC bytes that the caller downsamples and discards.
struct ParsedChapterFrame: Equatable {
    let elementID: String
    let startTimeMs: UInt32
    let endTimeMs: UInt32
    var title: String?
    var link: String?
    var imageData: Data?
}

/// Pure parser for ID3v2 `CHAP` frame payloads. No AVFoundation, no network,
/// no UIKit — every branch is unit-testable from synthesized bytes.
///
/// AVFoundation hands us the payload with the outer frame header already
/// stripped, but does NOT parse the embedded sub-frames, so we do that here.
enum ID3ChapterFrameParser {

    static func parse(payload: Data) -> ParsedChapterFrame? {
        // Index into `payload` by offset from startIndex — a Data slice does not
        // necessarily start at 0, and indexing it as if it did is a classic trap.
        let bytes = [UInt8](payload)

        guard let nul = bytes.firstIndex(of: 0x00) else { return nil }
        guard let elementID = String(bytes: bytes[0..<nul], encoding: .isoLatin1) else { return nil }

        let timesStart = nul + 1
        guard bytes.count >= timesStart + 16 else { return nil }

        let start = be32(bytes, at: timesStart)
        let end = be32(bytes, at: timesStart + 4)
        // Bytes at +8 and +12 are start/end byte offsets — 0xFFFFFFFF ("ignore")
        // in every real file examined. We always use the ms times.

        var frame = ParsedChapterFrame(elementID: elementID,
                                       startTimeMs: start,
                                       endTimeMs: end,
                                       title: nil,
                                       link: nil,
                                       imageData: nil)

        for sub in subFrames(in: payload, startingAt: timesStart + 16) {
            switch sub.id {
            case "TIT2":
                frame.title = decodeText(sub.body)
            case "APIC":
                frame.imageData = decodeAPIC(sub.body)
            case "WXXX":
                frame.link = decodeWXXX(sub.body)
            default:
                break
            }
        }

        return frame
    }

    // MARK: - Text decoding

    /// Decode an ID3 text-frame body: one encoding byte, then the string.
    /// Real files use UTF-16-with-BOM (0x01) for titles; assuming Latin-1
    /// yields mojibake.
    static func decodeText(_ body: Data) -> String? {
        let bytes = [UInt8](body)
        guard let encodingByte = bytes.first else { return nil }
        let payload = Data(bytes.dropFirst())

        let decoded: String?
        switch encodingByte {
        case 0x00:
            decoded = String(data: payload, encoding: .isoLatin1)
        case 0x01:
            // BOM decides endianness. String(encoding: .utf16) honours it,
            // and assumes big-endian when the BOM is absent (Foundation's
            // documented behavior) — so the LE fallback below only matters
            // for the rare non-compliant file whose BOM-less bytes are
            // invalid as big-endian but valid as little-endian.
            decoded = String(data: payload, encoding: .utf16)
                ?? String(data: payload, encoding: .utf16LittleEndian)
        case 0x02:
            decoded = String(data: payload, encoding: .utf16BigEndian)
        case 0x03:
            decoded = String(data: payload, encoding: .utf8)
        default:
            decoded = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1)
        }

        // Text frames are commonly NUL-terminated; drop terminators left by
        // the encoder. No separate BOM-residue strip is needed here: both
        // String(data:encoding:.utf16) and .utf8 already consume a real
        // leading byte-order mark while decoding, so a real BOM never
        // survives into `decoded`. Blanket-stripping U+FEFF from the whole
        // string (as opposed to just trimming NULs at the edges) would
        // instead risk deleting a legitimate U+FEFF character if one ever
        // appeared in the middle of a title.
        return decoded?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    // MARK: - APIC / WXXX

    /// Extract raw image bytes from an APIC body. The caller downsamples these
    /// immediately and discards them — we never hold decoded images. The MIME
    /// type is parsed only to locate its terminator and is otherwise discarded:
    /// `imageData` is untyped `Data`, and this task's scope doesn't add a MIME
    /// field to `ParsedChapterFrame`.
    ///
    /// Layout: encoding byte · NUL-terminated MIME · picture-type byte ·
    /// description (NUL- or double-NUL-terminated by encoding) · image data.
    /// This header is present only on the raw-metadata-items path (MP3); on the
    /// MP4 groups path AVFoundation strips it for us.
    ///
    /// Byte-offset note: `bytes` is a plain `[UInt8]`, so slicing it (e.g.
    /// `bytes[1...]`) yields an `ArraySlice` whose indices stay in `bytes`'s own
    /// coordinate space — `firstIndex(of:)` on that slice already returns an
    /// absolute index into `bytes`, so `mimeEnd + 1` below is correct as an
    /// absolute index with no rebasing needed. `Data` slices behave the same
    /// way for `firstIndex(of:)`; the real `Data`-slice trap is *positional*
    /// subscripting (`slice[0]` traps unless the slice happens to start at 0)
    /// — which is exactly why `parse(payload:)` converts to `[UInt8]` before
    /// indexing at all.
    static func decodeAPIC(_ body: Data) -> Data? {
        let bytes = [UInt8](body)
        guard let encoding = bytes.first else { return nil }

        // MIME: always single-byte, always NUL-terminated.
        guard let mimeEnd = bytes[1...].firstIndex(of: 0x00) else { return nil }

        let pictureTypeIndex = mimeEnd + 1
        guard pictureTypeIndex < bytes.count else { return nil }

        guard let cursor = descriptionEnd(bytes, from: pictureTypeIndex + 1, encoding: encoding) else { return nil }

        guard cursor < bytes.count else { return nil }
        return Data(bytes[cursor...])
    }

    /// Extract the URL from a WXXX body: encoding byte, then a description
    /// terminated per that same encoding (single NUL for 1-byte encodings,
    /// double NUL for UTF-16 — identical rule to APIC's description field,
    /// see `descriptionEnd`), then the URL itself, which is always Latin-1
    /// regardless of the description's encoding.
    static func decodeWXXX(_ body: Data) -> String? {
        let bytes = [UInt8](body)
        guard let encoding = bytes.first else { return nil }

        guard let urlStart = descriptionEnd(bytes, from: 1, encoding: encoding) else { return nil }
        guard urlStart < bytes.count else { return nil }

        return String(bytes: bytes[urlStart...], encoding: .isoLatin1)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Locate the end of an ID3 description field — the index of the first
    /// byte *after* its terminator — starting at `start`, shared by APIC's
    /// description-before-image-data and WXXX's description-before-URL.
    /// Terminator width depends on encoding: UTF-16 (`0x01`/`0x02`) uses a
    /// double NUL scanned two bytes at a time from `start` (the description's
    /// true first byte), so the pairing stays aligned to UTF-16 code-unit
    /// boundaries regardless of `start`'s parity within the overall body; any
    /// other encoding uses a single NUL. Returns nil — never a guessed
    /// offset — both when `start` is out of bounds and when no terminator is
    /// found before the end of `bytes` (a truncated/malformed body), so both
    /// branches degrade identically instead of one risking a stray partial
    /// read.
    private static func descriptionEnd(_ bytes: [UInt8], from start: Int, encoding: UInt8) -> Int? {
        guard start <= bytes.count else { return nil }

        if encoding == 0x01 || encoding == 0x02 {
            var cursor = start
            while cursor + 1 < bytes.count {
                if bytes[cursor] == 0x00 && bytes[cursor + 1] == 0x00 {
                    return cursor + 2
                }
                cursor += 2
            }
            return nil   // no double-NUL terminator found — don't guess
        } else {
            guard let descEnd = bytes[start...].firstIndex(of: 0x00) else { return nil }
            return descEnd + 1
        }
    }

    // MARK: - Byte helpers

    static func be32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    /// ID3v2.4 synchsafe integer: 7 significant bits per byte.
    static func synchsafe32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset] & 0x7F) << 21)
            | (UInt32(bytes[offset + 1] & 0x7F) << 14)
            | (UInt32(bytes[offset + 2] & 0x7F) << 7)
            | UInt32(bytes[offset + 3] & 0x7F)
    }

    // MARK: - Sub-frame walk

    /// Walk the embedded sub-frames of a CHAP payload.
    ///
    /// ID3v2.3 sizes are plain big-endian; v2.4 sizes are synchsafe. They agree
    /// below 128 per byte and diverge above, so short TIT2 frames parse either
    /// way while large APIC frames do not — which is why chapter titles have
    /// always worked and chapter images have not.
    ///
    /// Disambiguation is deterministic rather than a guess: walk with both
    /// interpretations and keep whichever lands exactly on the end of the
    /// payload. Falls back to the longer walk if neither is exact (truncated
    /// download), so we degrade to partial data instead of nothing.
    static func subFrames(in payload: Data, startingAt offset: Int) -> [(id: String, body: Data)] {
        let bytes = [UInt8](payload)
        guard offset >= 0, offset < bytes.count else { return [] }

        let plain = walk(bytes, from: offset, sizeReader: be32)
        if plain.consumedExactly { return plain.frames }

        let synchsafe = walk(bytes, from: offset, sizeReader: synchsafe32)
        if synchsafe.consumedExactly { return synchsafe.frames }

        return plain.frames.count >= synchsafe.frames.count ? plain.frames : synchsafe.frames
    }

    private static func walk(
        _ bytes: [UInt8],
        from offset: Int,
        sizeReader: ([UInt8], Int) -> UInt32
    ) -> (frames: [(id: String, body: Data)], consumedExactly: Bool) {
        var frames: [(id: String, body: Data)] = []
        var cursor = offset

        // 10-byte sub-frame header: 4-byte ID, 4-byte size, 2-byte flags.
        while cursor + 10 <= bytes.count {
            let idBytes = bytes[cursor..<(cursor + 4)]
            // Strict ASCII 'A'-'Z' / '0'-'9', per the ID3 spec — not
            // Character.isUppercase/isNumber, which also accepts Latin-1
            // extended letters (À, Þ, …) and numeric glyphs (², ¼, …) that
            // isoLatin1 happily decodes but are never valid frame IDs. A
            // wrong size interpretation can land the cursor on such bytes;
            // treating them as "valid" would let a bogus walk continue
            // instead of failing loudly enough to lose the exactness check.
            guard idBytes.allSatisfy({ (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }),
                  let id = String(bytes: idBytes, encoding: .isoLatin1) else {
                break
            }

            let declared = Int(sizeReader(bytes, cursor + 4))
            guard declared > 0 else { break }

            let bodyStart = cursor + 10
            let bodyEnd = min(bodyStart + declared, bytes.count)   // clamp: never trust a declared size
            frames.append((id: id, body: Data(bytes[bodyStart..<bodyEnd])))

            cursor = bodyStart + declared
            if cursor > bytes.count { return (frames, false) }     // overran
        }

        return (frames, cursor == bytes.count)
    }
}
