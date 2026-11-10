//  HDRUltraHDR.swift — Adobe's `hdrgm` declaration of a JPEG's one gain map (Ultra HDR 1.0), written into the
//  file ImageIO has finished (HDR port, 2026-11-06, `PRD/HDR-PORT-PLAN-2026-11-06.md` D8).
//
//  ImageIO writes the camera's layout (`HDRContainer`: one map, declared as ISO 21496-1's and Apple's) and
//  **never writes hdrgm or Google's container directory** (measured, `PRD/hdr-port-maps/standards.md` §3). An
//  older Android, Chrome before 137, and every Ultra HDR reader find the map by them. So a JPEG's map is said a
//  third time, here, after `CGImageDestinationFinalize`:
//
//  - **The primary** gets `hdrgm:Version="1.0"` and the GContainer `Container:Directory` (Primary; GainMap with
//    its `Item:Length`) — the map is the MPF secondary image ImageIO already wrote.
//  - **The map image** gets every hdrgm field, **explicitly** (a reader's default for an absent offset is 1/64:
//    it would lift a film's blacks): GainMapMin 0, GainMapMax log2 H, Gamma the ISO declaration's own (the
//    camera layout's fitted Gamma), OffsetSDR 0, OffsetHDR 0, HDRCapacityMin 0, HDRCapacityMax log2 H,
//    BaseRenditionIsHDR False — each written as the very string the ISO declaration was given
//    (`HDRGainMap.metadata`), so the two can never say two gains (both D8 readers follow ISO where they differ).
//  - **One XMP packet an image**: the fields are a new `rdf:Description` merged into the packet the image already
//    has (ImageIO writes one in each: the primary's, the map's HDRGainMap); a packet is added only where there
//    is none, after the leading APP0/APP1 segments.
//  - **MPF patched**: the primary's size, the map's size and its offset (from the MPF header), which the
//    inserted bytes move.
//  - **The primary's picture is the HDR-off file's** (D3, `write(base:)`, the 2026-11-06 review): its tables,
//    frame and scan are taken from the same picture encoded without a map, since ImageIO encodes a JPEG with a
//    map with another encoder. Measured: the coded bytes then match to the byte, libjpeg decodes the two files to
//    the same pixels, and ImageIO's own decode of a JPEG with a map (another decoder, chosen by the JFIF `AMPF`,
//    MPF or ISO segment alone) stays within 2 codes.
//
//  The reference is the D8 compatibility pass (`scratchpad/compat/src/mkhdrgm.py`, its layout C: ImageIO's
//  DecodeToHDR and Adobe Camera Raw 18.6 read it, peak 2.00 stops at H 4, every bin within 0.05 stop).
//
//  **Streaming, and failing loud.** The source is read mapped and never held: only the segments before each
//  image's scan are parsed and rebuilt (a few kilobytes — Exif, XMP, ICC, the tables), and the entropy-coded
//  data is copied from the mapped file in slices. Anything the parse did not expect — not a JPEG, a marker
//  without a length before the scan, no MPF, an MPF that is not exactly the primary and one map, offsets that
//  do not meet, an extended-XMP packet, an hdrgm already there, a packet past 64 KB — throws, and the writer keeps
//  ImageIO's own file without hdrgm and says why (`ExportWriter.write`): a broken file is never written.
//
//  No third-party code: the JPEG, MPF (CIPA DC-007) and XMP arithmetic is written here. No UIKit, no Metal:
//  the macOS checks compile it.

import Foundation

enum HDRUltraHDR {
    enum Failure: Error, CustomStringConvertible {
        case parse(String)
        case write(String)
        var description: String {
            switch self {
            case .parse(let s): "the JPEG was not as ImageIO writes it: \(s)"
            case .write(let s): "hdrgm could not be written: \(s)"
            }
        }
    }

    /// The hdrgm fields of the map image, as strings (each the ISO declaration's own).
    struct Declaration: Equatable, Sendable {
        var gainMapMin: String
        var gainMapMax: String
        var gamma: String
        var offsetSDR: String
        var offsetHDR: String
        var capacityMin: String
        var capacityMax: String

        /// The fields for a stored map: what `HDRGainMap.metadata(headroom:gamma:)` gives ISO for it, to the digit.
        static func of(_ map: StoredMap) -> Declaration {
            let top = String(format: "%.6f", log2(max(map.headroom, 1))), zero = "0.000000"
            return Declaration(gainMapMin: zero, gainMapMax: top, gamma: String(format: "%.6f", map.isoGamma),
                               offsetSDR: zero, offsetHDR: zero, capacityMin: zero, capacityMax: top)
        }

        /// In hdrgm's names, as a reader finds them (`read`).
        var fields: [String: String] {
            ["GainMapMin": gainMapMin, "GainMapMax": gainMapMax, "Gamma": gamma, "OffsetSDR": offsetSDR,
             "OffsetHDR": offsetHDR, "HDRCapacityMin": capacityMin, "HDRCapacityMax": capacityMax]
        }
    }

    static let xmpID = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let extendedXMPID = Array("http://ns.adobe.com/xmp/extension/\0".utf8)
    static let mpfID = Array("MPF\0".utf8)
    static let hdrgmNS = "http://ns.adobe.com/hdr-gain-map/1.0/"

    // MARK: the file's shape

    /// A marker segment before an image's scan: its marker byte and where it is (FF, marker, length, body).
    struct Segment {
        var marker: UInt8
        /// Where its FF is, from the image's start.
        var at: Int
        /// FF + marker + its length's 2 bytes + its body.
        var count: Int
    }

    /// One image of the file: its segments up to the scan, and where its scan begins (the SOS marker),
    /// offsets from the image's own start.
    struct Image {
        var segments: [Segment]
        var scan: Int
    }

    /// The segments of the JPEG image at `start` in `b`, as far as its first scan. Throws on anything else.
    static func image(_ b: UnsafeRawBufferPointer, at start: Int, end: Int) throws -> Image {
        guard end - start > 4, b[start] == 0xFF, b[start + 1] == 0xD8 else { throw Failure.parse("no SOI at \(start)") }
        var i = start + 2, segments: [Segment] = []
        while true {
            guard i + 4 <= end, b[i] == 0xFF else { throw Failure.parse("no marker at \(i)") }
            let m = b[i + 1]
            if m == 0xDA { return Image(segments: segments, scan: i - start) }
            // Markers without a length (SOI, EOI, RSTn, TEM) and fill bytes have no place before a scan here.
            guard m != 0xFF, m != 0xD8, m != 0xD9, m != 0x01, !(0xD0...0xD7).contains(m) else {
                throw Failure.parse(String(format: "marker %02X at %d before the scan", m, i))
            }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= end else { throw Failure.parse("a segment of \(length) bytes at \(i) runs past the image") }
            segments.append(Segment(marker: m, at: i - start, count: 2 + length))
            i += 2 + length
        }
    }

    /// A JPEG's coded picture: its tables, frame and restart interval (every segment before the scan but APPn and
    /// COM) and its scan to `end` (the primary's end; nil: the file's). Two files with the same are the same picture
    /// to any one decoder (D3's check: `tools/hdr_gainmap_selftest.swift`, `MacExportHDRCheck`).
    static func codedPicture(_ data: Data, end: Int? = nil) -> [UInt8]? {
        data.withUnsafeBytes { b -> [UInt8]? in
            guard let i = try? image(b, at: 0, end: b.count), (end ?? b.count) <= b.count, i.scan < (end ?? b.count) else { return nil }
            var out: [UInt8] = []
            for s in i.segments where !((0xE0...0xEF).contains(s.marker) || s.marker == 0xFE) { out += b[s.at..<(s.at + s.count)] }
            return out + b[i.scan..<(end ?? b.count)]
        }
    }

    static func starts(_ b: UnsafeRawBufferPointer, _ at: Int, with id: [UInt8]) -> Bool {
        guard at + id.count <= b.count else { return false }
        for k in 0..<id.count where b[at + k] != id[k] { return false }
        return true
    }

    /// The MPF index of the primary: the TIFF header's place in the file, its byte order, and its two entries
    /// (attribute, size, offset from the TIFF header), and where in the file the entries' bytes are.
    struct MPF {
        var tiff: Int
        var bigEndian: Bool
        var entries: [(attribute: UInt32, size: UInt32, offset: UInt32)]
        /// Where entry k's 16 bytes are in the file.
        var entryAt: [Int]
    }

    static func mpf(_ b: UnsafeRawBufferPointer, primary: Image) throws -> MPF {
        let found = primary.segments.filter { $0.marker == 0xE2 && starts(b, $0.at + 4, with: mpfID) }
        guard found.count == 1, let seg = found.first else { throw Failure.parse("\(found.count) MPF segments in the primary") }
        let tiff = seg.at + 8, end = seg.at + seg.count
        guard tiff + 8 <= end else { throw Failure.parse("an MPF segment too short") }
        let big: Bool
        if b[tiff] == 0x4D, b[tiff + 1] == 0x4D { big = true } else if b[tiff] == 0x49, b[tiff + 1] == 0x49 { big = false }
        else { throw Failure.parse("an MPF of no byte order") }
        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= end else { throw Failure.parse("MPF read past its segment") }
            return big ? Int(b[o]) << 8 | Int(b[o + 1]) : Int(b[o + 1]) << 8 | Int(b[o])
        }
        func u32(_ o: Int) throws -> UInt32 {
            guard o + 4 <= end else { throw Failure.parse("MPF read past its segment") }
            let v = (0..<4).map { UInt32(b[o + $0]) }
            return big ? v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3] : v[3] << 24 | v[2] << 16 | v[1] << 8 | v[0]
        }
        guard try u16(tiff + 2) == 42 else { throw Failure.parse("an MPF TIFF header without 42") }
        let ifd = tiff + Int(try u32(tiff + 4))
        let n = try u16(ifd)
        var images = -1, list: (count: Int, at: Int)?
        for k in 0..<n {
            let e = ifd + 2 + 12 * k
            let tag = try u16(e), count = Int(try u32(e + 4)), value = try u32(e + 8)
            if tag == 0xB001 { images = Int(value) }       // NumberOfImages, LONG ×1
            if tag == 0xB002 { list = (count, tiff + Int(value)) }   // MPEntry, UNDEFINED ×16N, at an offset
        }
        guard images == 2, let list, list.count == 32 else {
            throw Failure.parse("an MPF of \(images) images (\(list?.count ?? 0) entry bytes), not the primary and one map")
        }
        var entries: [(UInt32, UInt32, UInt32)] = [], at: [Int] = []
        for k in 0..<2 {
            let e = list.at + 16 * k
            entries.append((try u32(e), try u32(e + 4), try u32(e + 8)))
            at.append(e)
        }
        return MPF(tiff: tiff, bigEndian: big, entries: entries, entryAt: at)
    }

    // MARK: XMP

    /// The image's one XMP packet's segment, nil without one. Two, or an extended packet, throw.
    static func xmp(_ b: UnsafeRawBufferPointer, _ image: Image, base: Int) throws -> Segment? {
        let app1 = image.segments.filter { $0.marker == 0xE1 }
        guard !app1.contains(where: { starts(b, base + $0.at + 4, with: extendedXMPID) }) else { throw Failure.parse("an extended XMP packet") }
        let packets = app1.filter { starts(b, base + $0.at + 4, with: xmpID) }
        guard packets.count <= 1 else { throw Failure.parse("\(packets.count) XMP packets in one image") }
        return packets.first
    }

    /// An APP1 XMP segment of `packet`.
    static func app1(_ packet: [UInt8]) throws -> [UInt8] {
        let length = 2 + xmpID.count + packet.count
        guard length <= 0xFFFF else { throw Failure.write("an XMP packet of \(packet.count) bytes is past one segment") }
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + xmpID + packet
    }

    /// `description` merged into the image's packet (before its last `</rdf:RDF>`), or a packet of its own:
    /// the new segment, and the one it replaces (nil: it is inserted).
    static func merged(_ b: UnsafeRawBufferPointer, _ image: Image, base: Int, _ description: String) throws -> (segment: [UInt8], replaces: Segment?) {
        guard let seg = try xmp(b, image, base: base) else {
            let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + description + "</rdf:RDF></x:xmpmeta>"
            return (try app1(Array(packet.utf8)), nil)
        }
        let from = base + seg.at + 4 + xmpID.count, to = base + seg.at + seg.count
        let packet = Array(b[from..<to])
        guard let text = String(bytes: packet, encoding: .utf8) else { throw Failure.parse("an XMP packet that is not UTF-8") }
        guard !text.contains(hdrgmNS) else { throw Failure.parse("hdrgm is declared already") }
        guard let close = text.range(of: "</rdf:RDF>", options: .backwards) else { throw Failure.parse("an XMP packet without </rdf:RDF>") }
        var out = text
        out.insert(contentsOf: description + "\n", at: close.lowerBound)
        return (try app1(Array(out.utf8)), seg)
    }

    static func mapDescription(_ d: Declaration) -> String {
        "<rdf:Description rdf:about=\"\" xmlns:hdrgm=\"\(hdrgmNS)\" hdrgm:Version=\"1.0\" "
            + "hdrgm:GainMapMin=\"\(d.gainMapMin)\" hdrgm:GainMapMax=\"\(d.gainMapMax)\" hdrgm:Gamma=\"\(d.gamma)\" "
            + "hdrgm:OffsetSDR=\"\(d.offsetSDR)\" hdrgm:OffsetHDR=\"\(d.offsetHDR)\" hdrgm:HDRCapacityMin=\"\(d.capacityMin)\" "
            + "hdrgm:HDRCapacityMax=\"\(d.capacityMax)\" hdrgm:BaseRenditionIsHDR=\"False\"/>"
    }

    static func primaryDescription(mapLength: Int) -> String {
        "<rdf:Description rdf:about=\"\" xmlns:Container=\"http://ns.google.com/photos/1.0/container/\" "
            + "xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\" xmlns:hdrgm=\"\(hdrgmNS)\" hdrgm:Version=\"1.0\">"
            + "<Container:Directory><rdf:Seq>"
            + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Semantic=\"Primary\" Item:Mime=\"image/jpeg\"/></rdf:li>"
            + "<rdf:li rdf:parseType=\"Resource\"><Container:Item Item:Semantic=\"GainMap\" Item:Mime=\"image/jpeg\" Item:Length=\"\(mapLength)\"/></rdf:li>"
            + "</rdf:Seq></Container:Directory></rdf:Description>"
    }

    /// The image's head rebuilt: SOI, its segments up to the scan with `new` in place of `replaces` (or inserted
    /// after the leading APP0/APP1 run); and where each old segment went (`moved`: its offset in the new head).
    static func head(_ b: UnsafeRawBufferPointer, _ image: Image, base: Int, new: [UInt8], replaces: Segment?) -> (bytes: [UInt8], moved: (Int) -> Int) {
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(image.scan + new.count)
        let insertAfter = replaces == nil ? (image.segments.firstIndex { $0.marker != 0xE0 && $0.marker != 0xE1 } ?? image.segments.count) : -1
        var newAt = [Int: Int]()          // an old segment's offset → its new one
        for (k, s) in image.segments.enumerated() {
            if k == insertAfter { out += new }
            newAt[s.at] = out.count
            if let r = replaces, r.at == s.at { out += new } else { out += b[(base + s.at)..<(base + s.at + s.count)] }
        }
        if insertAfter == image.segments.count { out += new }
        return (out, { newAt[$0] ?? -1 })
    }

    // MARK: writing

    #if DEBUG
    /// A check's way to make the step fail as a surprise in a file would (`tools/hdr_gainmap_selftest.swift`: the
    /// writer must then keep ImageIO's file, its ISO and Apple maps, and say why). Never set by the app.
    nonisolated(unsafe) static var refuseForCheck: String?
    #endif

    /// `source` (a JPEG ImageIO finished with one gain map, the camera's layout) written to `destination` with
    /// hdrgm (the header). Throws, leaving nothing at `destination`, on any surprise.
    ///
    /// `base`: the same picture as ImageIO writes it **without** a map (`ExportWriter`), whose coding and scan the
    /// primary takes in place of `source`'s (D3, to the bit; the 2026-11-06 review). With a map attached ImageIO
    /// encodes a JPEG's primary with another encoder — the same quantisation, one DHT, no restart interval, Apple's
    /// `AROT` restart table — and 34 % of a grained picture's samples decoded differently, up to 39 codes, so turning
    /// Enable HDR on changed the file's SDR picture. The primary keeps `source`'s metadata segments (APPn, COM: Exif
    /// with MakerApple 33/48, the XMP, MPF, ISO's APP2, the ICC profile) but its `AROT` (an index into the scan it no
    /// longer has), and takes `base`'s tables, frame, restart interval and scan, as they are; the two frames (SOF)
    /// must be the same bytes. HEIF needs none of this: its primary is the no-map file's to the bit already.
    static func write(from source: URL, to destination: URL, declaration d: Declaration, base: URL? = nil) throws {
        #if DEBUG
        if let why = refuseForCheck { throw Failure.parse(why) }
        #endif
        let data: Data, plain: Data
        do {
            data = try Data(contentsOf: source, options: .alwaysMapped)
            plain = try base.map { try Data(contentsOf: $0, options: .alwaysMapped) } ?? Data()
        } catch { throw Failure.parse("\(error.localizedDescription)") }
        try? FileManager.default.removeItem(at: destination)
        do {
            try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in try plain.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                let total = b.count
                var primary = try image(b, at: 0, end: total)
                let index = try mpf(b, primary: primary)
                let mapStart = index.tiff + Int(index.entries[1].offset)
                guard index.entries[0].offset == 0, Int(index.entries[0].size) == mapStart,
                      mapStart + Int(index.entries[1].size) == total else {
                    throw Failure.parse("the MPF says a primary of \(index.entries[0].size) and a map of \(index.entries[1].size) at \(mapStart), in a file of \(total)")
                }
                let map = try image(b, at: mapStart, end: total)
                guard !map.segments.contains(where: { $0.marker == 0xE2 && starts(b, mapStart + $0.at + 4, with: mpfID) }) else {
                    throw Failure.parse("the map has an MPF index of its own")
                }
                // The primary's coding: `base`'s (D3), else its own.
                var coding: [UInt8] = []
                var scan: (buffer: UnsafeRawBufferPointer, from: Int, to: Int) = (b, primary.scan, mapStart)
                if base != nil {
                    let own = try image(p, at: 0, end: p.count)
                    func isMetadata(_ s: Segment) -> Bool { (0xE0...0xEF).contains(s.marker) || s.marker == 0xFE }
                    func bytes(_ x: UnsafeRawBufferPointer, _ s: Segment) -> [UInt8] { Array(x[s.at..<(s.at + s.count)]) }
                    func frames(_ x: UnsafeRawBufferPointer, _ i: Image) -> [[UInt8]] {
                        i.segments.filter { (0xC0...0xCF).contains($0.marker) && ![0xC4, 0xC8, 0xCC].contains($0.marker) }.map { bytes(x, $0) }
                    }
                    let mine = frames(b, primary), theirs = frames(p, own)
                    guard mine.count == 1, mine == theirs else { throw Failure.parse("the picture without a map has another frame (SOF) than the one with it") }
                    guard !own.segments.isEmpty, own.scan < p.count else { throw Failure.parse("the picture without a map has no scan") }
                    for s in own.segments where !isMetadata(s) { coding += bytes(p, s) }
                    // The metadata stays the file's own, its `AROT` (restart offsets into the old scan) left out.
                    let arot = Array("AROT".utf8)
                    primary.segments = primary.segments.filter { isMetadata($0) && !($0.marker == 0xEA && starts(b, $0.at + 4, with: arot)) }
                    scan = (p, own.scan, p.count)
                }
                // The map: its packet with every hdrgm field.
                let m = try merged(b, map, base: mapStart, mapDescription(d))
                let mapHead = head(b, map, base: mapStart, new: m.segment, replaces: m.replaces).bytes
                let mapLength = mapHead.count + (total - (mapStart + map.scan))
                // The primary: its packet with the directory; then MPF's sizes and offset, whose segment keeps its length.
                let pd = try merged(b, primary, base: 0, primaryDescription(mapLength: mapLength))
                let rebuilt = head(b, primary, base: 0, new: pd.segment, replaces: pd.replaces)
                var primaryHead = rebuilt.bytes + coding
                let primaryLength = primaryHead.count + (scan.to - scan.from)
                let mpfSegment = primary.segments.first { $0.marker == 0xE2 && starts(b, $0.at + 4, with: mpfID) }!
                let newMPF = rebuilt.moved(mpfSegment.at)
                guard newMPF >= 0 else { throw Failure.write("the MPF segment was lost") }
                let newTIFF = newMPF + 8
                func put(_ v: UInt32, at o: Int) {
                    let bytes: [UInt8] = index.bigEndian ? [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
                                                         : [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
                    for k in 0..<4 { primaryHead[o + k] = bytes[k] }
                }
                // The entries are inside the MPF segment, which moved whole: the same place from its TIFF header.
                let e0 = newTIFF + (index.entryAt[0] - index.tiff), e1 = newTIFF + (index.entryAt[1] - index.tiff)
                guard e1 + 12 <= primaryHead.count, primaryLength - newTIFF > 0 else { throw Failure.write("the MPF entries are not in the head") }
                put(UInt32(primaryLength), at: e0 + 4)
                put(UInt32(mapLength), at: e1 + 4)
                put(UInt32(primaryLength - newTIFF), at: e1 + 8)

                guard FileManager.default.createFile(atPath: destination.path, contents: nil),
                      let out = FileHandle(forWritingAtPath: destination.path) else { throw Failure.write("the file could not be made") }
                defer { try? out.close() }
                // The scans, from the mapped files, in slices: never a copy of the picture.
                func copy(_ x: UnsafeRawBufferPointer, _ from: Int, _ to: Int) throws {
                    var at = from
                    while at < to {
                        let n = min(4 << 20, to - at)
                        try out.write(contentsOf: UnsafeRawBufferPointer(rebasing: x[at..<(at + n)]))
                        at += n
                    }
                }
                try out.write(contentsOf: primaryHead)
                try copy(scan.buffer, scan.from, scan.to)
                try out.write(contentsOf: mapHead)
                try copy(b, mapStart + map.scan, total)
                try out.synchronize()
            } }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: reading (the writer's own check, and the selftests')

    /// What a JPEG's hdrgm says: the primary's version and directory, the MPF's two entries, and the map's fields.
    struct Read: Equatable {
        var primaryVersion: String?
        /// The directory's items: (semantic, length).
        var directory: [String]
        var mapLengthSaid: Int?
        var mpfPrimarySize: Int
        var mpfMapSize: Int
        var mpfMapStart: Int
        var fileBytes: Int
        var mapVersion: String?
        var mapFields: [String: String]
        var baseRenditionIsHDR: String?
        /// The primary's and the map's scans as they are in the file (start, length), to compare with ImageIO's.
        var primaryScan: Range<Int>
        var mapScan: Range<Int>

        /// The file's index meets itself: the directory's length is the map's, the MPF's sizes the file's.
        var consistent: Bool {
            directory == ["Primary", "GainMap"] && mapLengthSaid == mpfMapSize && mpfPrimarySize == mpfMapStart
                && mpfMapStart + mpfMapSize == fileBytes
        }
    }

    /// The hdrgm of `url`, as a reader finds it. Nil fields where absent; throws where the file is not one JPEG
    /// with an MPF map.
    static func read(_ url: URL) throws -> Read {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Read in
            let primary = try image(b, at: 0, end: b.count)
            let index = try mpf(b, primary: primary)
            let mapStart = index.tiff + Int(index.entries[1].offset)
            let map = try image(b, at: mapStart, end: b.count)
            func text(_ img: Image, _ base: Int) throws -> String {
                guard let s = try xmp(b, img, base: base) else { return "" }
                return String(decoding: b[(base + s.at + 4 + xmpID.count)..<(base + s.at + s.count)], as: UTF8.self)
            }
            let pt = try text(primary, 0), mt = try text(map, mapStart)
            var fields: [String: String] = [:]
            for k in Declaration.of(StoredMap(width: 0, height: 0, codes: Data(), headroom: 1, isoGamma: 1)).fields.keys {
                if let v = value(mt, "hdrgm:" + k) { fields[k] = v }
            }
            let items = matches(pt, "Item:Semantic=\"([A-Za-z]+)\"")
            let length = matches(pt, "Item:Semantic=\"GainMap\"[^>]*?Item:Length=\"([0-9]+)\"").first
                ?? matches(pt, "Item:Length=\"([0-9]+)\"[^>]*?Item:Semantic=\"GainMap\"").first
            return Read(primaryVersion: value(pt, "hdrgm:Version"), directory: items, mapLengthSaid: length.flatMap { Int($0) },
                        mpfPrimarySize: Int(index.entries[0].size), mpfMapSize: Int(index.entries[1].size), mpfMapStart: mapStart,
                        fileBytes: b.count, mapVersion: value(mt, "hdrgm:Version"), mapFields: fields,
                        baseRenditionIsHDR: value(mt, "hdrgm:BaseRenditionIsHDR"),
                        primaryScan: primary.scan..<mapStart, mapScan: (mapStart + map.scan)..<b.count)
        }
    }

    /// An XMP property's value, as an attribute (`name="v"`) or an element (`<name>v</name>`).
    static func value(_ xmp: String, _ name: String) -> String? {
        let n = NSRegularExpression.escapedPattern(for: name)
        return matches(xmp, n + "=\"([^\"]*)\"").first ?? matches(xmp, "<" + n + ">([^<]*)</" + n + ">").first
    }

    static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    /// Whether `url` says `d` as hdrgm, its index consistent: the writer's check of its own file.
    static func says(_ url: URL, _ d: Declaration) throws -> Bool {
        let r = try read(url)
        return r.consistent && r.primaryVersion == "1.0" && r.mapVersion == "1.0" && r.mapFields == d.fields && r.baseRenditionIsHDR == "False"
    }
}
