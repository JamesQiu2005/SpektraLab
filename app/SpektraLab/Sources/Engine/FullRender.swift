//  FullRender.swift — the engine's render at full size, kept on disk in tiles: the page's zoom, and an export's.
//
//  The owner, 2026-10-20: the RAW's preview "when zoomed in can really show the
//  original resolution", and once a full-resolution render has been made "during
//  export we don't need to go through the whole engine process again" — with
//  the whole of it "extremely ram-awared".
//
//  - **What is kept is the engine's own result**: its working space (ProPhoto,
//    encoded), 16 bits a channel, before the output transform, Edit's layer,
//    the host's turn and Edit's crop — exactly what an export's job hands its
//    delivery (`EngineHost.deliver`). So an export whose engine side is this
//    render's — the same file, decode, cut, wire and engine, which is what the
//    name says (`fileName`, the stamp) — is delivered from it in any colour
//    space and container, and the engine is not run (`EngineHost.cached`).
//  - **In tiles, at two sizes**: 256 × 256 pixels, row after row of tiles, the
//    full size and then half of it. A part of the picture is read by the tiles
//    it touches alone (`Reader.region`), and a part shown smaller than half
//    size is read from the half (`FullDetail`): what the page holds for a zoom
//    is about the screen's pixels, never the picture's. 8 bytes a pixel, a
//    quarter more for the half size: 48 MP is 480 MB on disk.
//  - **Made by its own job** (`JobKind.fullView`), planned and priced as an
//    export at Full, through the one scheduler, when the page is zoomed past
//    what its preview holds; written on the engine's queue as the render is
//    delivered, a band of tile rows at a time (one band beside the result:
//    17 MB at 8,256 px across). Kept beside the proxies (`WorkingCopies`), **under a limit of
//    their own** (`fullLimit`, Settings' cache size; 2026-10-24, one at a time until then): the
//    renders used longest ago go first, by their bytes, never the one shown or being made. Asked
//    for through `FullRenderJobs`: the page's zoom, the Light Table, the Mac's prefetch.
//
//  The file: "SPKFULL1", the header's length (UInt32, little-endian), the
//  header (JSON), zeros to 4,096 bytes, then the tiles: RGBA, UInt16, the
//  render's own values, each tile whole (an edge tile padded with zeros).

import Accelerate
import Foundation

enum FullRender {
    /// Where a frame's full render is or would be, and what it is of.
    struct Ask: Sendable, Equatable {
        var url: URL
        /// What the render is made from (`DevelopStamp.of` of the export's own request).
        var stamp: String
    }

    struct Header: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var tile: Int
        var stamp: String
        /// The host's quarter turns, clockwise, after the render: the finished
        /// picture is this render turned (`EngineHost.turned`).
        var turnsAfter: Int

        func size(level: Int) -> (width: Int, height: Int) {
            level == 0 ? (width, height) : ((width + 1) / 2, (height + 1) / 2)
        }
        func across(level: Int) -> Int { (size(level: level).width + tile - 1) / tile }
        func down(level: Int) -> Int { (size(level: level).height + tile - 1) / tile }
        var tileBytes: Int { tile * tile * 8 }
        /// Where a tile begins, after the header.
        func offset(level: Int, tx: Int, ty: Int) -> Int {
            let base = level == 0 ? 0 : across(level: 0) * down(level: 0) * tileBytes
            return FullRender.dataStart + base + (ty * across(level: level) + tx) * tileBytes
        }
        var fileBytes: Int { offset(level: 1, tx: 0, ty: down(level: 1)) }

        /// The finished picture's size: the render turned.
        var finished: (width: Int, height: Int) { turnsAfter % 2 == 0 ? (width, height) : (height, width) }
    }

    static let version = "full.1"
    private static let magic = Array("SPKFULL1".utf8)
    static let dataStart = 4096
    static let tile = 256
    static let suffix = ".spkfull"

    /// `<frame>-<16 hex>.spkfull`, the frame's id first (the book reads whose it is from the name).
    static func fileName(frame: UUID, stamp: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325           // FNV-1a: a name, not a secret
        for byte in (version + "|" + stamp).utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        return frame.uuidString + "-" + String(format: "%016llx", h) + suffix
    }

    // MARK: writing

    /// Writes the render — `pixels`, `rowStride` pixels a row — into a file of
    /// its own beside `url`, then moves it into place. A band of tile rows is
    /// held at a time. Returns the file's size.
    @discardableResult
    static func write(_ pixels: UnsafePointer<UInt16>, rowStride: Int, width: Int, height: Int, stamp: String,
                      turnsAfter: Int, to url: URL, cancelled: () -> Bool = { false }) throws -> Int64 {
        let header = Header(width: width, height: height, tile: tile, stamp: stamp, turnsAfter: turnsAfter)
        let json = try JSONEncoder().encode(header)
        var head = Data(magic)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { head.append(contentsOf: $0) }
        head.append(json)
        guard head.count <= dataStart else { throw EngineError.failed("the full render's header is too long") }
        head.append(Data(count: dataStart - head.count))

        // The half size, made once by vImage before the tiles are cut (the owner, 2026-10-21: the zoom "FUCKING
        // SLOW … even slower than the export path"): the per-pixel loop that made it took 6 s of a 45 MP render's
        // 11 on the window in a debug build, 5.2 s on this Mac unoptimised and 0.3 optimised; vImage is the same
        // speed in every build. Its Lanczos is not the 2 × 2 mean the loop made — the half size is the zoom's
        // between-tier, read only below 100 %.
        let (hw, hh) = header.size(level: 1)
        let half = UnsafeMutablePointer<UInt16>.allocate(capacity: hw * hh * 4)
        defer { half.deallocate() }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: rowStride * 8)
        var target = vImage_Buffer(data: half, height: vImagePixelCount(hh), width: vImagePixelCount(hw), rowBytes: hw * 8)
        let scaled = vImageScale_ARGB16U(&source, &target, nil, vImage_Flags(kvImageNoFlags))
        guard scaled == kvImageNoError else { throw EngineError.failed("vImage could not make the half size (\(scaled))") }
        if cancelled() { throw EngineError.cancelled }

        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".partial-" + UUID().uuidString)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try handle.write(contentsOf: head)
            let T = tile
            for level in 0...1 {
                let (lw, lh) = header.size(level: level)
                let across = header.across(level: level)
                var band = [UInt16](repeating: 0, count: across * T * T * 4)
                for ty in 0..<header.down(level: level) {
                    if cancelled() { throw EngineError.cancelled }
                    band.withUnsafeMutableBufferPointer { b in
                        b.update(repeating: 0)
                        for row in 0..<min(T, lh - ty * T) {
                            let y = ty * T + row
                            for tx in 0..<across {
                                let x0 = tx * T, n = min(T, lw - x0)
                                let to = b.baseAddress! + (tx * T * T + row * T) * 4
                                if level == 0 {
                                    (to).update(from: pixels + (y * rowStride + x0) * 4, count: n * 4)
                                } else {
                                    (to).update(from: half + (y * hw + x0) * 4, count: n * 4)
                                }
                            }
                        }
                    }
                    try band.withUnsafeBytes { try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!),
                                                                                  count: $0.count, deallocator: .none)) }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return Int64(header.fileBytes)
    }

    // MARK: reading

    /// One full render, open for reading parts of it.
    final class Reader: @unchecked Sendable {
        let header: Header
        let url: URL
        private let fd: Int32

        /// Nil where there is no whole file at `url`, or it is of another stamp.
        init?(_ url: URL, stamp: String? = nil) {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { return nil }
            var head = [UInt8](repeating: 0, count: FullRender.dataStart)
            guard pread(fd, &head, head.count, 0) == head.count, Array(head[0..<8]) == FullRender.magic else { close(fd); return nil }
            let length = Int(UInt32(head[8]) | UInt32(head[9]) << 8 | UInt32(head[10]) << 16 | UInt32(head[11]) << 24)
            var st = stat()
            guard length > 0, 12 + length <= FullRender.dataStart,
                  let header = try? JSONDecoder().decode(Header.self, from: Data(head[12..<(12 + length)])),
                  header.width > 0, header.height > 0, header.tile > 0, stamp.map({ $0 == header.stamp }) ?? true,
                  fstat(fd, &st) == 0, Int(st.st_size) == header.fileBytes else { close(fd); return nil }
            self.fd = fd
            self.header = header
            self.url = url
        }
        deinit { close(fd) }

        /// The pixels of `rect` (in `level`'s pixels, inside it) into `into`,
        /// `rowStride` pixels a row (the rect's width when nil), RGBA UInt16.
        /// Only the tiles it touches are read, one read a tile.
        func region(level: Int, x: Int, y: Int, width w: Int, height h: Int, into: UnsafeMutablePointer<UInt16>,
                    rowStride: Int? = nil) throws {
            let T = header.tile
            let pitch = rowStride ?? w
            var rows = [UInt16](repeating: 0, count: T * T * 4)
            for ty in (y / T)...((y + h - 1) / T) {
                for tx in (x / T)...((x + w - 1) / T) {
                    let tileX = tx * T, tileY = ty * T
                    let c0 = max(x, tileX), c1 = min(x + w, tileX + T)
                    let r0 = max(y, tileY), r1 = min(y + h, tileY + T)
                    // One read a tile: the rows of it this region takes, whole.
                    let from = header.offset(level: level, tx: tx, ty: ty) + (r0 - tileY) * T * 8
                    let count = (r1 - r0) * T * 8
                    let got = rows.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, count, off_t(from)) }
                    guard got == count else { throw EngineError.failed("the full render could not be read") }
                    rows.withUnsafeBufferPointer { b in
                        for r in r0..<r1 {
                            (into + ((r - y) * pitch + (c0 - x)) * 4)
                                .update(from: b.baseAddress! + ((r - r0) * T + (c0 - tileX)) * 4, count: (c1 - c0) * 4)
                        }
                    }
                }
            }
        }
    }
}

#if SPK_ENGINE
import Metal

extension FullRender.Reader {
    /// The whole render at full size, as the engine would have handed it to
    /// its host: a texture over a shared buffer of its rows, at the device's
    /// linear-texture pitch — one picture's memory, read a tile at a time
    /// (the the operating system simulator, which makes no texture over a buffer, a copy more).
    func pixels(device: MTLDevice) throws -> RenderedPixels {
        let w = header.width, h = header.height
        let align = max(device.minimumLinearTextureAlignment(for: .rgba16Unorm), 8)
        let rowBytes = (w * 8 + align - 1) / align * align
        guard let buffer = device.makeBuffer(length: rowBytes * h, options: .storageModeShared) else {
            throw EngineError.resource("no \((rowBytes * h) >> 20) MB for the full render")
        }
        let base = buffer.contents().assumingMemoryBound(to: UInt16.self)
        try region(level: 0, x: 0, y: 0, width: w, height: h, into: base, rowStride: rowBytes / 8)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        #if targetEnvironment(simulator)
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d), let queue = device.makeCommandQueue(),
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw EngineError.resource("no texture for the full render")
        }
        blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #else
        d.storageMode = .shared
        guard let texture = buffer.makeTexture(descriptor: d, offset: 0, bytesPerRow: rowBytes) else {
            throw EngineError.resource("no texture for the full render")
        }
        #endif
        return RenderedPixels(texture: texture, rgba16: UnsafePointer(base), size: PixelSize(width: w, height: h),
                              rowStridePixels: rowBytes / 8, keep: buffer)
    }
}
#endif
