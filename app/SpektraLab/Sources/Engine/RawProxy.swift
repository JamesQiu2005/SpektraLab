//  RawProxy.swift — a RAW's decode at preview size, kept, so it is decoded once.
//
//  The owner, 2026-10-20: "create one proxy for each RAW (set to the side as
//  the preview resolution) whenever it is imported, and we maintain the cache
//  within the shared cache size, instead of render and drop everytime it is
//  asked" — and the cards are made from it too. Until then every open of a
//  RAW's page decoded the file again (a 45 MP NEF: 1.5 s, the app from 97 to
//  774 MB, the reference device), and its strip's cards waited on that decode.
//
//  - **What is kept is the decode, not a render**: Core Image's own picture of
//    the RAW (`RawExposure.prepare`, the file's decode settings) at the
//    frame's preview size, uncut and unturned, in the context's working space
//    — extended linear sRGB, half floats, which is what Core Image holds it in
//    (`FrameDecoder.readied`). A job then makes its frame of it exactly as it
//    made it of the RAW: the same scale, the same host cut, the same last
//    conversion into the engine's linear ProPhoto. The film, the paper and
//    every effect are the engine's and are never in it: nothing developed is
//    cached here, and an edit is recomputed as before.
//  - **Made by the first decode that would have made the same pixels**: an
//    import's develop, a shot's, a page's, a card's — whichever comes first.
//    That decode writes the proxy and the job reads its frame from it, so the
//    first job and every later one see the same pixels.
//  - **Named by what it is of** (`fileName`): the frame, the original's name,
//    the decode's settings that change a RAW's pixels, the size, the decoder
//    and the system's version (a new the operating system may decode a RAW differently). A
//    white balance moved is another proxy; the old one stays until the
//    shared limit takes it.
//  - **Kept with the working copies, under their limit** (`WorkingCopies`,
//    `.proxies` inside their folder): one book, the one read longest ago goes
//    first, never one of a frame being read. Anything here can be made again
//    from the original, so nothing here is backed up.
//  - **A job larger than the proxy decodes the RAW** — an export, a full-size
//    develop: the proxy is never enlarged.
//
//  The file: "SPKRAWP1", the header's length (UInt32, little-endian), the
//  header (JSON), zeros to a multiple of 16, then the pixels — RGBA, half
//  floats, the picture's top row first, 8 bytes a pixel: 31 MB for 2,400 ×
//  1,600. Written whole to a file of its own and moved into place, so a proxy
//  the app was ended in the middle of writing is never read.

import CoreImage
import Foundation

enum RawProxy {
    /// What a job asks of a proxy: where it is, and the long edge it is made at
    /// (the frame's preview size). A job that decodes larger than that does not use it.
    struct Ask: Sendable, Equatable {
        var url: URL
        var longEdge: Int
    }

    /// What a decode did with its proxy, for the book (`WorkingCopies.noteProxy`).
    struct Event: Sendable {
        var url: URL
        var bytes: Int64
        /// Written by this decode; false: read.
        var made: Bool
    }

    struct Header: Codable, Equatable {
        var width: Int
        var height: Int
        /// The RAW decoder's own word ("RAW 8 [...]"), as `DecodeReport.how` says it.
        var how: String
        var asShotTemperature: Double?
        var asShotTint: Double?
        var facts: RawExposureFacts?
    }

    /// Moved whenever the file's layout or what it holds changes.
    static let version = "proxy.1"
    private static let magic = Array("SPKRAWP1".utf8)
    static let bytesPerPixel = 8

    /// The proxy of `source` decoded with `decode` at `longEdge`, for `frame`:
    /// `<frame>-<16 hex>.spkraw`. The frame's id first, so the book knows
    /// whose it is from the name alone (`WorkingCopies`).
    static func fileName(frame: UUID, source: URL, decode: DecodeSettings, longEdge: Int,
                         system: String = ProcessInfo.processInfo.operatingSystemVersionString) -> String {
        let words = [version, DevelopStamp.decoder, system, source.lastPathComponent, decode.pixelsKey, "\(longEdge)"]
        var h: UInt64 = 0xcbf29ce484222325           // FNV-1a: a name, not a secret
        for byte in words.joined(separator: "|").utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return frame.uuidString + "-" + String(format: "%016llx", h) + ".spkraw"
    }

    // MARK: the file

    /// The proxy at `url`, or nil where there is none or it is not whole.
    /// The pixels are mapped, not read: what a render touches is paged in.
    static func read(_ url: URL) -> (header: Header, pixels: Data)? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 12,
              Array(data.prefix(8)) == magic else { return nil }
        let length = data.subdata(in: 8..<12).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let start = padded(12 + length)
        guard length > 0, data.count >= start,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length))),
              header.width > 0, header.height > 0,
              data.count == start + header.width * header.height * bytesPerPixel else { return nil }
        return (header, data.subdata(in: start..<data.count))
    }

    /// Writes the proxy: whole into a file of its own beside `url`, then moved
    /// into place. Returns the file's size.
    @discardableResult
    static func write(_ header: Header, pixels: UnsafeRawPointer, to url: URL) throws -> Int64 {
        let json = try JSONEncoder().encode(header)
        var head = Data(magic)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { head.append(contentsOf: $0) }
        head.append(json)
        head.append(Data(count: padded(head.count) - head.count))
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".partial-" + UUID().uuidString)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try handle.write(contentsOf: head)
            try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pixels),
                                              count: header.width * header.height * bytesPerPixel, deallocator: .none))
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return Int64(head.count + header.width * header.height * bytesPerPixel)
    }

    /// The proxy's pixels as Core Image's picture: in the working space they
    /// were written from, the top row first, at the origin.
    static func image(_ header: Header, pixels: Data) -> CIImage {
        CIImage(bitmapData: pixels, bytesPerRow: header.width * bytesPerPixel,
                size: CGSize(width: header.width, height: header.height), format: .RGBAh,
                colorSpace: workingSpace)
    }

    /// Core Image's working space in `FrameDecoder`: what a proxy is written in.
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func padded(_ n: Int) -> Int { (n + 15) / 16 * 16 }
}
