//  LightTableTextures.swift — the films' pictures on the GPU, at the size the table shows them.
//
//  RAM first (RFC-045, "RAM first"; RFC-036 §6.3's `r_app`). The light table is a reader of
//  pictures that already exist: it never starts a develop or a job of the scheduler's itself — where
//  nothing large enough of a film is kept it says so (`onAsks`), and whoever keeps the renders asks for
//  one (the Mac, `MacRenderCache`; `LightTableSteps.choose`). What it holds is one texture a film, and
//  only as large as the film is shown:
//
//  - **Read at the size it needs**, straight from the file through ImageIO
//    (`kCGImageSourceThumbnailMaxPixelSize`, the `ThumbnailStore` principle), or from the frame's
//    full-size render kept on disk by the tiles of it a band needs (`LightTableFullRead`): the full
//    bitmap is never held. The size is the film's long edge on the screen in pixels, rounded **up** to
//    a step — 256, 512, 1,024, 2,048, then the table's ceiling, 4,224 (`LightTableSizing.sourceCeiling`:
//    a 6 × 9 strip on A6 pixel for pixel in the largest export; 2,048, the website's `maxEdge` on a host,
//    until 2026-10-24) — so a pinch does not read a film again at every frame. Each texture is
//    mipmapped: the website's films are, and a film shown smaller than its step is drawn from its mips.
//  - **Larger only where it is seen**: a film in the view at the current zoom, or under the loupe
//    (three times its size there), is read at the step it needs; a film out of the view keeps the
//    step it needs at the fitted view, and is read again smaller when the view zooms out. A film's
//    old texture stays drawn until the new one lands.
//  - **One byte budget for all of it**, from `MemoryBudget`: the app's reserve for its own pages
//    (`BudgetTuning.appReserve`, 150 MB: "the library's thumbnails, the canvas's textures") less
//    the picture cache's own 64 MB (`ThumbnailStore`), and never more than a quarter of what a job
//    could be given this moment — at least 24 MB. Over budget, the largest steps are halved, the
//    films out of view first. The loupe's target is counted in it.
//  - **Emptied on leaving** the table (`empty`); a film then shows nothing until it is read again at
//    the size it needs. **On a memory warning only the films out of view go** (`releaseHidden`, 2026-10-24;
//    until then every texture went, the ones on screen too).
//
//  Decoding is off the main thread, one at a time, inside an autorelease pool (`ThumbnailStore`'s
//  reason: a burst of decodes piles up autoreleased buffers). The pixels are drawn by Core Graphics
//  into Display P3 — the library's space — straight into a shared Metal buffer, and blitted into a
//  private texture (`LightTableRenderer.texture(from:)`): the simulator's Metal has no shared
//  texture, and a buffer is what Core Graphics can draw into without a copy. The buffer goes when
//  the GPU has copied it.
//
//  A film edge not yet developed is drawn by `FilmCanvasView` (the film from its geometry round the
//  preview) through SwiftUI's `ImageRenderer`, on the main thread: what the library shows of it
//  until the library's own develop path has made the film.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class LightTableTextures {
    struct Entry {
        var texture: MTLTexture
        /// The step it was read at: its long edge, pixels.
        var edge: Int
        var bytes: Int
        var key: String
    }

    /// What the table wants of a film this moment.
    struct Want {
        var id: UUID
        var source: LightTableSource
        /// The long edge it is shown at, pixels (the loupe's magnification included).
        var pixels: Double
        /// It is in the view (or under the loupe).
        var visible: Bool
        /// Its width over its height, for the bytes a step will take.
        var aspect: Double
        /// Its full-size render kept on disk, where there is one to read (`LightTableSteps.choose`).
        var full: LightTableFullRef? = nil
        /// Its kept develop's long edge; nil where it has none.
        var keptEdge: Int? = nil
        /// A full-size render of it can be had (`FullView.hasMore`).
        var hasMore = false
    }

    static var steps: [Int] { LightTableSteps.steps }
    static func step(for px: Double) -> Int { LightTableSteps.step(for: px) }

    /// The table's budget this moment (see the header).
    static func budget(reading: MemoryReading = MemoryProbe.read(), tuning: BudgetTuning = BudgetTuning()) -> Int {
        let share = Int(tuning.appReserve) - (64 << 20)
        let now = MemoryBudget.compute(reading, frontend: FrontendState(), tuning: tuning)
        return max(24 << 20, min(share, Int(now.bytes / 4)))
    }

    private let renderer: LightTableRenderer
    private(set) var entries: [UUID: Entry] = [:]
    /// What is being read: the step and the picture, so a second ask for the same is not made.
    private var loading: [UUID: (edge: Int, key: String)] = [:]
    private var queued: [(Want, Int)] = []
    /// Bumped when everything is let go of: a read that lands after it is dropped.
    private var generation = 0
    private(set) var budget: Int
    private var budgetRead = Date.distantPast
    /// The most the table's textures have held at once since it opened, bytes.
    private(set) var peakBytes = 0
    /// A texture landed: the table is drawn again.
    var onLoaded: (() -> Void)?
    /// The films that have nothing kept as large as the size planned for them (`LightTableSteps.choose`):
    /// told at each update, for whoever can make one.
    var onAsks: ((Set<UUID>) -> Void)?
    /// The films in view at the last update: what a memory warning keeps.
    private(set) var visible: Set<UUID> = []
    /// Each film's picture as it was last read: a kept develop, a full render, the file.
    private(set) var readFrom: [UUID: String] = [:]

    private let decodes = DispatchQueue(label: "com.spektralab.lighttable.textures", qos: .userInitiated)

    init(renderer: LightTableRenderer) {
        self.renderer = renderer
        budget = Self.budget()
    }

    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } + renderer.loupeBytes }
    /// Nothing is being read, and nothing waits to be.
    var isIdle: Bool { loading.isEmpty && queued.isEmpty }
    func texture(_ id: UUID) -> MTLTexture? { entries[id]?.texture }

    private static func plan(_ wants: [Want], budget: Int) -> [UUID: Int] {
        LightTableSteps.plan(wants.map { .init(id: $0.id, pixels: $0.pixels, visible: $0.visible, aspect: $0.aspect) }, budget: budget)
    }

    /// The films the table has now, and what each needs: textures no film needs go, and each one
    /// whose step or picture is not what is needed is read again — those in view first, the ones
    /// with nothing to show before the ones being made larger.
    func update(_ wants: [Want]) {
        if Date().timeIntervalSince(budgetRead) > 1 { budget = Self.budget(); budgetRead = Date() }
        let ids = Set(wants.map(\.id))
        for id in entries.keys where !ids.contains(id) { entries[id] = nil }
        let plan = Self.plan(wants, budget: max(budget - renderer.loupeBytes, 0))
        visible = Set(wants.filter(\.visible).map(\.id))
        var asks: [(Want, Int)] = []
        var lacking: Set<UUID> = []
        for var w in wants {
            guard let edge = plan[w.id] else { continue }
            let (source, asked) = Self.effective(w, edge: edge)
            w.source = source
            if asked { lacking.insert(w.id) }
            if let e = entries[w.id], e.key == w.source.key, e.edge == edge { continue }
            if let l = loading[w.id], l.key == w.source.key, l.edge == edge { continue }
            asks.append((w, edge))
        }
        onAsks?(lacking)
        asks.sort { a, b in
            if a.0.visible != b.0.visible { return a.0.visible }
            let ea = entries[a.0.id] == nil, eb = entries[b.0.id] == nil
            if ea != eb { return ea }
            return a.1 < b.1
        }
        queued = asks
        pump()
    }

    /// What a film is read from at `edge`: its kept develop or file as the frame gives it, or its full
    /// render (`LightTableSteps.choose`); and whether something larger is to be asked for.
    nonisolated static func effective(_ w: Want, edge: Int) -> (LightTableSource, asks: Bool) {
        let choice = LightTableSteps.choose(step: edge, keptEdge: w.keptEdge, hasMore: w.hasMore, fullKept: w.full != nil)
        if choice.readsFull, let full = w.full { return (.full(full), false) }
        return (w.source, choice.asks)
    }

    /// Every film read now, on this thread, at the step it needs: a check's still picture.
    func updateNow(_ wants: [Want]) {
        let plan = Self.plan(wants, budget: max(budget - renderer.loupeBytes, 0))
        visible = Set(wants.filter(\.visible).map(\.id))
        for var w in wants {
            guard let edge = plan[w.id] else { continue }
            w.source = Self.effective(w, edge: edge).0
            if let e = entries[w.id], e.key == w.source.key, e.edge == edge { continue }
            let image: CGImage?
            switch w.source {
            case .film(let g, let p, let f, let src, let stock): image = Self.drawFilm(g, picture: p, framing: f, source: src, stock: stock, edge: edge)
            case .picture, .cut: image = Self.read(w.source, edge: edge)
            case .full(let ref): image = LightTableFullRead.image(ref, edge: edge)
            case .none: image = nil
            }
            guard let image, let made = Self.upload(image, edge: edge, renderer: renderer) else { continue }
            entries[w.id] = Entry(texture: made.0, edge: edge, bytes: LightTableSteps.bytes(width: made.1, height: made.2, mipmapped: true),
                                  key: w.source.key)
        }
        peakBytes = max(peakBytes, bytes)
    }

    /// A memory warning: the textures of the films out of view go, those in view stay (they are what is
    /// shown). The bytes let go of.
    @discardableResult
    func releaseHidden() -> Int {
        var freed = 0
        for (id, e) in entries where !visible.contains(id) {
            freed += e.bytes
            entries[id] = nil
        }
        queued.removeAll { !visible.contains($0.0.id) }
        return freed
    }

    /// Everything goes: the table closed.
    func empty() {
        generation += 1
        entries.removeAll()
        loading.removeAll()
        queued.removeAll()
        renderer.release()
    }

    // MARK: reading

    /// One read at a time: the next is started when the last lands.
    private func pump() {
        guard loading.isEmpty, !queued.isEmpty else { return }
        let (want, edge) = queued.removeFirst()
        loading[want.id] = (edge, want.source.key)
        readFrom[want.id] = Self.origin(want.source)
        let gen = generation, key = want.source.key, id = want.id, renderer = self.renderer
        let land: @Sendable (MTLTexture?, Int, Int) -> Void = { [weak self] texture, w, h in
            Task { @MainActor in self?.landed(id, texture, edge: edge, key: key, size: (w, h), generation: gen) }
        }
        switch want.source {
        case .none:
            loading[id] = nil
            pump()
        case .film(let g, let picture, let framing, let source, let stock):
            // SwiftUI's renderer runs on the main thread; it is only for a film not yet developed.
            let drawn = Self.drawFilm(g, picture: picture, framing: framing, source: source, stock: stock, edge: edge)
            decodes.async {
                autoreleasepool {
                    guard let drawn, let made = Self.upload(drawn, edge: edge, renderer: renderer) else { return land(nil, 0, 0) }
                    land(made.0, made.1, made.2)
                }
            }
        case .picture, .cut:
            let source = want.source
            decodes.async {
                autoreleasepool {
                    guard let image = Self.read(source, edge: edge), let made = Self.upload(image, edge: edge, renderer: renderer)
                    else { return land(nil, 0, 0) }
                    land(made.0, made.1, made.2)
                }
            }
        case .full(let ref):
            decodes.async {
                autoreleasepool {
                    guard let image = LightTableFullRead.image(ref, edge: edge), let made = Self.upload(image, edge: edge, renderer: renderer)
                    else { return land(nil, 0, 0) }
                    land(made.0, made.1, made.2)
                }
            }
        }
    }

    /// Where a picture is read from, in a word: for the log and the checks.
    nonisolated static func origin(_ source: LightTableSource) -> String {
        switch source {
        case .full: "full render"
        case .picture(let p), .cut(let p, _, _):
            if case .file(let url) = p, url.lastPathComponent.hasPrefix("dev-") { "kept develop" } else { "file" }
        case .film: "file, as its film"
        case .none: "nothing"
        }
    }

    private func landed(_ id: UUID, _ texture: MTLTexture?, edge: Int, key: String, size: (Int, Int), generation gen: Int) {
        defer { pump() }
        guard gen == generation else { return }
        loading[id] = nil
        guard let texture else { return }
        let bytes = LightTableSteps.bytes(width: size.0, height: size.1, mipmapped: true)
        // The old texture is let go of here: until now it was what was drawn.
        entries[id] = Entry(texture: texture, edge: edge, bytes: bytes, key: key)
        peakBytes = max(peakBytes, self.bytes)
        onLoaded?()
    }

    /// The picture's pixels drawn into a shared buffer in Display P3, RGBA 8 bits, its long edge at
    /// most `edge`, and blitted into a texture. The texture and its size.
    nonisolated private static func upload(_ image: CGImage, edge: Int, renderer: LightTableRenderer) -> (MTLTexture, Int, Int)? {
        let k = min(1, Double(edge) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        let rowBytes = w * 4
        guard let buffer = renderer.device.makeBuffer(length: rowBytes * h, options: .storageModeShared),
              let ctx = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let t = renderer.texture(from: buffer, width: w, height: h, bytesPerRow: rowBytes, debugName: "film") else { return nil }
        return (t, w, h)
    }

    /// A picture on disk at a long edge of `edge` (`ThumbnailStore.load`'s reading, without its
    /// cache: the table keeps the GPU's copy only); a preview through its crop at the crop's own
    /// size of that.
    nonisolated private static func read(_ source: LightTableSource, edge: Int) -> CGImage? {
        switch source {
        case .picture(let p):
            return thumbnail(p, maxPixel: edge)
        case .cut(let p, let g, let src):
            let size = CGSize(width: src.width, height: src.height)
            let zoom = min(1 / max(min(g.crop.width, g.crop.height), 0.1), 4)
            guard let image = thumbnail(p, maxPixel: Int((Double(edge) * zoom).rounded(.up))) else { return nil }
            let out = g.outputSize(for: size)
            let k = Double(edge) / Double(max(out.width, out.height, 1))
            let w = max(1, Int((out.width * k).rounded())), h = max(1, Int((out.height * k).rounded()))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            // y down, as the geometry's transform is written (`CroppedPicture`)
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: k, y: -k)
            ctx.concatenate(g.outputToSourceTransform(imageSize: size).inverted())
            // the picture upright in a y-down space
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: size))
            return ctx.makeImage()
        case .film, .full, .none:
            return nil
        }
    }

    nonisolated private static func thumbnail(_ picture: PictureRef, maxPixel: Int) -> CGImage? {
        guard let url = ThumbnailStore.url(for: picture),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // A RAW's embedded preview, as a tile reads it, unless it is too small to show.
        let isRAW = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }?.conforms(to: .rawImage) ?? false
        func make(fromImage: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                (fromImage ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        var made = make(fromImage: !isRAW)
        if isRAW, let preview = made {
            // A grey preview of a colour RAW: the RAW decoded (`RawPreviewColour`).
            if RawPreviewColour.lost(preview, in: source) { made = ImportService.rawDecoded(url, longEdge: maxPixel) ?? preview }
            else if max(preview.width, preview.height) < min(maxPixel, 512) / 2 { made = make(fromImage: true) ?? preview }
        }
        return made
    }

    /// One film's picture read at `edge` and put on the GPU outside the table's own set and budget:
    /// an export's (`LightTableExport`), which holds it only while the bands it lies in are drawn.
    /// Any thread but the main one; a film not yet developed is drawn on the main thread, which
    /// must not be waiting for the caller. The texture, its width and its height.
    nonisolated static func exportTexture(_ source: LightTableSource, edge: Int, renderer: LightTableRenderer) -> (MTLTexture, Int, Int)? {
        autoreleasepool {
            let image: CGImage?
            switch source {
            case .film(let g, let p, let f, let src, let stock):
                guard !Thread.isMainThread else { return nil }
                image = DispatchQueue.main.sync { MainActor.assumeIsolated { drawFilm(g, picture: p, framing: f, source: src, stock: stock, edge: edge) } }
            case .picture, .cut: image = read(source, edge: edge)
            case .full(let ref): image = LightTableFullRead.image(ref, edge: edge)
            case .none: image = nil
            }
            guard let image else { return nil }
            return upload(image, edge: edge, renderer: renderer)
        }
    }

    /// One film's picture as a bitmap, its long edge `edge` at most, read exactly as the table reads it for a
    /// texture: the Mac's rail draws its tiles with it (2026-10-24), so a tile and its film on the table are
    /// the same picture. Any thread but the main one, except a film edge not yet developed (`.film`), which
    /// SwiftUI draws on the main thread: `image(_:edge:)` on the main actor reads that one.
    nonisolated static func picture(_ source: LightTableSource, edge: Int) -> CGImage? {
        switch source {
        case .picture, .cut: read(source, edge: edge)
        case .full(let ref): LightTableFullRead.image(ref, edge: edge)
        case .film, .none: nil
        }
    }

    /// A film edge not yet developed, drawn round its preview as the table draws it: on the main actor.
    static func filmPicture(_ source: LightTableSource, edge: Int) -> CGImage? {
        guard case .film(let g, let p, let f, let src, let stock) = source else { return nil }
        return drawFilm(g, picture: p, framing: f, source: src, stock: stock, edge: edge)
    }

    /// The film drawn from its geometry round the preview, `edge` pixels on its long side.
    private static func drawFilm(_ g: FilmGeometry, picture: PictureRef, framing: Geometry, source: PixelSize, stock: String,
                                 edge: Int) -> CGImage? {
        let mm = g.canvasMM
        let k = Double(edge) / Double(max(mm.width, mm.height, 0.001))
        let w = max(1, (mm.width * k).rounded()), h = max(1, (mm.height * k).rounded())
        let view = FilmCanvasView(geometry: g, style: .developed, picture: picture,
                                  sourceSize: CGSize(width: source.width, height: source.height), framing: framing,
                                  pointSize: CGFloat(edge), handles: false, ink: EdgeLook.of(stock).ink(on: g.request.format))
            .frame(width: w, height: h)
            .environment(\.isSnapshot, true)
            .environment(\.displayScale, 1)
        let r = ImageRenderer(content: view)
        r.scale = 1
        return r.cgImage
    }
}
