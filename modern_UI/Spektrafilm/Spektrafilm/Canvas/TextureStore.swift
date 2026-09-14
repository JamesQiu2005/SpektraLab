//  TextureStore.swift — the buffer system behind a snappy canvas.
//
//  What is resident, and why:
//
//  | texture             | source                      | lifetime            |
//  |---------------------|-----------------------------|---------------------|
//  | source preview      | Core Image decode, P3       | per frame, LRU 8    |
//  | print (preview res) | service reprint, rgba16 raw | per frame, LRU 8    |
//  | full render         | service reprint, `full`     | one frame only      |
//  | stock LUT preview   | service preview_stock_lut   | transient           |
//  | adjusted            | Layer 2 kernel output       | one, re-run on edit |
//  | curve table         | CPU, 256×5 r32Float         | one                 |
//
//  Frame switches are instant because the last eight frames' preview-resolution
//  prints stay resident (a 2560 px rgba16 texture is ~35 MB; eight of each kind
//  is well under 400 MB). Returning to a frame shows its last print immediately,
//  flagged `soft` until the service's session catches up.
//
//  The full render is deliberately *not* kept per frame: at 45 MP one is
//  360 MB, so eight would be 2.9 GB. There is one slot, for the frame on
//  screen, and it is what the canvas settles on once an edit stops moving.
//
//  The slot is **stamped** with the parameters the service rendered it from,
//  so validity is data rather than timing. An undo, or a slider dragged back
//  to where it was, makes the resident render correct again and it is shown
//  instead of re-rendered. The rank the slot used to carry went with the zoom
//  ladder (2026-09-12): there is one full-resolution state now, not three
//  rungs to order.

import Foundation
import Metal

/// One resident native-resolution render: which frame it belongs to, which
/// parameters made it, and the texture.
struct FullRenderEntry: @unchecked Sendable {
    let url: URL
    let stamp: String
    let texture: MTLTexture
    let costMs: Double
    let cacheKey: CacheKey?
    let sourceWidth: Int
    let sourceHeight: Int
}

private struct PrintRenderEntry: @unchecked Sendable {
    let texture: MTLTexture
    let stamp: String
    let costMs: Double
    let cacheKey: CacheKey?
    let sourceWidth: Int
    let sourceHeight: Int
}

final class TextureStore: @unchecked Sendable {
    final class Scratch: @unchecked Sendable {
        let texture: MTLTexture
        private let lock = NSLock()
        private var returned = false
        private let onReturn: @Sendable (MTLTexture) -> Void

        fileprivate init(texture: MTLTexture, onReturn: @escaping @Sendable (MTLTexture) -> Void) {
            self.texture = texture
            self.onReturn = onReturn
        }

        /// Return this destination now that every command buffer that writes
        /// it has completed. `deinit` is the fallback, not the contract.
        func giveBack() {
            lock.lock()
            guard !returned else { lock.unlock(); return }
            returned = true
            lock.unlock()
            onReturn(texture)
        }

        deinit { giveBack() }
    }

    private struct ScratchKey: Hashable {
        let width: Int
        let height: Int
        let format: MTLPixelFormat
    }

    private struct IdleScratch {
        let texture: MTLTexture
        let handle: MemoryArena.Handle
        let slot: HandleSlot
    }

    let device: MTLDevice
    private var sources: [URL: MTLTexture] = [:]
    private var prints: [URL: PrintRenderEntry] = [:]
    /// The frame's print at its **own** resolution — what the canvas settles
    /// on once an edit stops moving. One slot, current frame only: a 45 MP
    /// rgba16 texture is 360 MB, so eight of them is not an option the way
    /// eight preview-resolution prints is. `stamp` is the Layer 1 parameters
    /// it was rendered from, which is what makes a lookup a cache hit rather
    /// than a coincidence.
    private var full: FullRenderEntry?
    private var order: [URL] = []
    private let capacity = 8
    // Admission can synchronously call an eviction closure below. That
    // closure re-enters this store to drop the dictionary entry, so the lock
    // must be recursive rather than deadlocking the admission path.
    private let lock = NSRecursiveLock()
    let arena: MemoryArena
    private var sourceHandles: [URL: MemoryArena.Handle] = [:]
    private var printHandles: [URL: MemoryArena.Handle] = [:]
    private var fullHandle: MemoryArena.Handle?
    private var idleScratch: [ScratchKey: [IdleScratch]] = [:]
    private var borrowedScratch: [ObjectIdentifier: MemoryArena.Handle] = [:]

    private final class HandleSlot: @unchecked Sendable {
        var handle: MemoryArena.Handle?
    }

    init(device: MTLDevice, arena: MemoryArena = MemoryArena()) {
        self.device = device
        self.arena = arena
    }

    func source(for url: URL) -> MTLTexture? { lock.withLock { sources[url] } }
    func print(for url: URL) -> MTLTexture? { lock.withLock { prints[url]?.texture } }
    func printEntry(for url: URL) -> (texture: MTLTexture, stamp: String, costMs: Double,
                                      cacheKey: CacheKey?, sourceWidth: Int,
                                      sourceHeight: Int)? {
        lock.withLock {
            guard let entry = prints[url] else { return nil }
            return (entry.texture, entry.stamp, entry.costMs, entry.cacheKey,
                    entry.sourceWidth, entry.sourceHeight)
        }
    }
    func fullEntry(for url: URL) -> FullRenderEntry? {
        lock.withLock { full?.url == url ? full : nil }
    }

    /// The resident native-resolution render for `url`, if it was made from
    /// `stamp`.
    func fullRender(for url: URL, stamp: String) -> MTLTexture? {
        lock.withLock {
            guard let f = full, f.url == url, f.stamp == stamp else { return nil }
            return f.texture
        }
    }

    /// Cache references, not physical bytes. The current frame's preview is
    /// registered twice (this evictable source entry and `renderer.original`'s
    /// pinned entry), so dropping this reference can free nothing while the
    /// canvas still holds the texture. `evicted_mb` counts the dropped cache
    /// references; `MemorySampler`'s fresh free reading is what decides whether
    /// another batch is needed.
    func setSource(_ t: MTLTexture, for url: URL, costMs: Double = 0) {
        lock.withLock {
            if let h = sourceHandles.removeValue(forKey: url) { arena.release(h) }
            let slot = HandleSlot()
            let admitted = arena.admitCache(bytes: t.width * t.height * 8,
                                            kind: "sources", costMs: costMs,
                                            evict: { [weak self] in self?.dropSource(url, matching: slot) })
            if admitted == nil {
                sources[url] = nil
                sourceHandles[url] = nil
                if prints[url] == nil { order.removeAll { $0 == url } }
                return
            }
            slot.handle = admitted
            sources[url] = t
            sourceHandles[url] = admitted
            touch(url)
        }
    }

    func setPrint(_ t: MTLTexture?, stamp: String = "", for url: URL, costMs: Double = 0,
                  cacheKey: CacheKey? = nil, sourceWidth: Int? = nil,
                  sourceHeight: Int? = nil) {
        lock.withLock {
            if let h = printHandles.removeValue(forKey: url) { arena.release(h) }
            guard let t else {
                prints[url] = nil
                if sources[url] == nil { order.removeAll { $0 == url } }
                return
            }
            let slot = HandleSlot()
            let admitted = arena.admitCache(bytes: t.width * t.height * 8,
                                            kind: "prints", costMs: costMs,
                                            evict: { [weak self] in self?.dropPrint(url, matching: slot) })
            if admitted == nil {
                prints[url] = nil
                printHandles[url] = nil
                if sources[url] == nil { order.removeAll { $0 == url } }
                return
            }
            slot.handle = admitted
            prints[url] = PrintRenderEntry(
                texture: t, stamp: stamp, costMs: costMs, cacheKey: cacheKey,
                sourceWidth: sourceWidth ?? t.width,
                sourceHeight: sourceHeight ?? t.height
            )
            printHandles[url] = admitted
            touch(url)
        }
    }

    /// Take a native-resolution render into the slot.
    func setFullRender(_ t: MTLTexture, stamp: String, costMs: Double = 0,
                       cacheKey: CacheKey? = nil, sourceWidth: Int? = nil,
                       sourceHeight: Int? = nil, for url: URL) {
        lock.withLock {
            if let h = fullHandle { arena.release(h) }
            full = FullRenderEntry(
                url: url, stamp: stamp, texture: t, costMs: costMs, cacheKey: cacheKey,
                sourceWidth: sourceWidth ?? t.width,
                sourceHeight: sourceHeight ?? t.height
            )
            fullHandle = arena.registerPinned(bytes: t.width * t.height * 8, kind: "full")
        }
    }
    /// Free the slot. Called when a print lands that the resident render was
    /// not made from — the same parameters are handled by the lookup, which
    /// keeps a resident render an undo landed back on rather than re-rendering
    /// it. (The `unless:`-shaped variant that used to sit here was only ever
    /// called from the branch that had just failed that identical lookup.)
    func dropFullRender() { lock.withLock { clearFullLocked() } }
    func invalidatePrint(for url: URL) { lock.withLock { if let h = printHandles.removeValue(forKey: url) { arena.release(h) }; prints[url] = nil } }
    func removeAll() {
        lock.withLock {
            sourceHandles.values.forEach { arena.release($0) }
            printHandles.values.forEach { arena.release($0) }
            if let h = fullHandle { arena.release(h) }
            sourceHandles.removeAll()
            printHandles.removeAll()
            fullHandle = nil
            sources.removeAll()
            prints.removeAll()
            full = nil
            order.removeAll()
            clearIdleScratchLocked()
        }
    }

    /// Drop only idle pool storage. Borrowed scratch remains owned by its
    /// in-flight render and is returned to a fresh pool when it completes.
    func dropIdleScratch() { lock.withLock { clearIdleScratchLocked() } }
    var idleScratchCount: Int {
        lock.withLock { idleScratch.values.reduce(0) { $0 + $1.count } }
    }

    /// Caller holds `lock`.
    private func clearFullLocked() {
        if let h = fullHandle { arena.release(h); fullHandle = nil }
        full = nil
    }

    /// The arena has already removed the accounting entry when this runs. Drop
    /// only the reference whose handle is still the one registered here; a
    /// stale closure must not evict a newer entry for the same URL.
    private func dropSource(_ url: URL, matching slot: HandleSlot) {
        lock.withLock {
            guard let handle = slot.handle, sourceHandles[url] == handle else { return }
            sourceHandles[url] = nil
            sources[url] = nil
            if prints[url] == nil { order.removeAll { $0 == url } }
        }
    }

    private func dropPrint(_ url: URL, matching slot: HandleSlot) {
        lock.withLock {
            guard let handle = slot.handle, printHandles[url] == handle else { return }
            printHandles[url] = nil
            prints[url] = nil
            if sources[url] == nil { order.removeAll { $0 == url } }
        }
    }

    private func touch(_ url: URL) {
        if let h = sourceHandles[url] { arena.touch(h) }
        if let h = printHandles[url] { arena.touch(h) }
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > capacity {
            let old = order.removeFirst()
            if let h = sourceHandles.removeValue(forKey: old) { arena.release(h) }
            if let h = printHandles.removeValue(forKey: old) { arena.release(h) }
            sources[old] = nil
            prints[old] = nil
            if full?.url == old { clearFullLocked() }
        }
    }

    // MARK: scratch textures

    /// Borrow a transient destination. The caller returns it after the GPU has
    /// completed every command buffer that writes it; until then the texture is
    /// registered as pinned, and while idle it is evictable by the arena.
    func borrowWritable(width: Int, height: Int,
                        format: MTLPixelFormat = .rgba16Unorm) -> Scratch? {
        guard width > 0, height > 0 else { return nil }
        let key = ScratchKey(width: width, height: height, format: format)
        let texture: MTLTexture
        lock.lock()
        if var list = idleScratch[key], let entry = list.popLast() {
            idleScratch[key] = list.isEmpty ? nil : list
            arena.release(entry.handle)
            texture = entry.texture
        } else if let made = makeWritable(width: width, height: height, format: format) {
            texture = made
        } else {
            lock.unlock()
            return nil
        }
        let handle = arena.registerPinned(bytes: scratchBytes(texture), kind: "scratch_in_use")
        borrowedScratch[ObjectIdentifier(texture)] = handle
        lock.unlock()
#if DEBUG
        garbageFill(texture)
#endif
        return Scratch(texture: texture) { [weak self] texture in
            self?.returnScratch(texture, key: key)
        }
    }

    private func returnScratch(_ texture: MTLTexture, key: ScratchKey) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = borrowedScratch.removeValue(forKey: ObjectIdentifier(texture)) else { return }
        arena.release(handle)
        var list = idleScratch[key] ?? []
        guard list.count < 2 else { return }
        let slot = HandleSlot()
        let admitted = arena.admitCache(bytes: scratchBytes(texture), kind: "scratch_idle",
                                        costMs: 0,
                                        evict: { [weak self] in
                                            self?.dropIdleScratch(key, matching: slot)
                                        })
        guard let admitted else { return }
        slot.handle = admitted
        list.append(IdleScratch(texture: texture, handle: admitted, slot: slot))
        idleScratch[key] = list
    }

    private func dropIdleScratch(_ key: ScratchKey, matching slot: HandleSlot) {
        lock.withLock {
            guard var list = idleScratch[key],
                  let i = list.firstIndex(where: { $0.slot === slot }) else { return }
            list.remove(at: i)
            idleScratch[key] = list.isEmpty ? nil : list
        }
    }

    private func clearIdleScratchLocked() {
        for list in idleScratch.values {
            for entry in list { arena.release(entry.handle) }
        }
        idleScratch.removeAll()
    }

    private func scratchBytes(_ texture: MTLTexture) -> Int {
        texture.allocatedSize > 0 ? texture.allocatedSize : texture.width * texture.height * 8
    }

#if DEBUG
    /// Hand every pooled destination out with recognisable garbage. A kernel
    /// that omits a texel or reads its destination becomes visible in the
    /// existing pixel suites instead of silently reusing old pixels.
    private func garbageFill(_ texture: MTLTexture) {
        let bpp = max(1, texture.allocatedSize / max(1, texture.width * texture.height))
        let rowBytes = texture.width * bpp
        guard rowBytes > 0 else { return }
        let row = UnsafeMutableRawPointer.allocate(byteCount: rowBytes,
                                                   alignment: MemoryLayout<UInt64>.alignment)
        defer { row.deallocate() }
        for y in 0..<texture.height {
            let bytes = row.assumingMemoryBound(to: UInt8.self)
            for x in 0..<rowBytes {
                bytes[x] = UInt8(truncatingIfNeeded: (x &* 131) &+ (y &* 17) &+ 0x5d)
            }
            texture.replace(region: MTLRegionMake2D(0, y, texture.width, 1),
                            mipmapLevel: 0, withBytes: row, bytesPerRow: rowBytes)
        }
    }
#endif

    // MARK: uploads

    /// A raw 16-bit RGBA dump from the service (row 0 = top row), straight
    /// into an `rgba16Unorm` texture. No colour interpretation happens here:
    /// the values are already Display P3 encoded and the layer is P3.
    func uploadRGBA16(path: String, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              data.count >= width * height * 8 else { return nil }
        return uploadRGBA16(data: data, width: width, height: height)
    }

    /// The same upload from bytes already held by the disk cache.
    func uploadRGBA16(data: Data, width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0, data.count == width * height * 8 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        return tex
    }

    func makeWritable(width: Int, height: Int, format: MTLPixelFormat = .rgba16Unorm) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// 256 × 5 r32Float: rgb, luma, r, g, b tables.
    func makeCurveTable() -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: Curve.tableSize, height: 5, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    func upload(curves: CurveSet, into tex: MTLTexture) {
        var floats = curves.tables()
        floats.withUnsafeMutableBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, Curve.tableSize, 5), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: Curve.tableSize * 4)
        }
    }
}
