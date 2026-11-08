//  LightTableExport.swift — the table's Share pictures drawn and written to a file.
//
//  Two pictures (`LightTableExportPlan` has what each is and its arithmetic):
//
//  - **Poster**: `LightTableController.share()`, the website's layout as it was, written as a JPG.
//  - **Contact Sheet**: drawn here, in bands, straight into the file:
//
//        ImageIO's encoder ──asks for rows──▶ a sequential CGDataProvider (`BandWriter`)
//              ▲                                   │ the band those rows are in, when it is reached:
//              │                                   │   the films it touches read (`exportTexture`),
//              └──── the band's rows ◀── a shared  │   the films it no longer needs let go of,
//                                        buffer ◀──┘   each tile drawn (`encodeTile`) and blitted in
//
//    ImageIO reads a sequential provider a few rows at a time and does not keep the image whole
//    (measured on this Mac: a 6,000 × 8,000 PNG written with 27 MB held, where the image is 192 MB),
//    so what is held is one band — the file's width × 1,024 rows — its tiles' targets and the films
//    of that band, never the file. Each film is read once, at the size the file shows it
//    (`filmStep`, to the table's ceiling, `LightTableSizing.sourceCeiling`: 4,224 px, a 6 × 9 strip on
//    A6 at 5,000 px pixel for pixel; 4,096 until 2026-10-24), under a budget from `MemoryBudget`
//    (`planFilms`) — from its kept develop where that is as large, else its full-size render kept on
//    disk (`LightTableSteps.choose`). Where neither is, the render is made first and waited for
//    (`LightTableController.makesFullForExport`, the Mac).
//
//  - **Colour**: Display P3, as the table draws; the profile is embedded (ImageIO writes the image's
//    space). JPG at 0.92. The resolution is written too, so a Layout Only sheet prints at A4.
//  - **Pixels**: the renderer's BGRA, premultiplied for With Light Table (the area round the table is
//    transparent, the shadow's alpha falling to 0 at the file's edges), opaque for Layout Only.
//  - **Stoppable**: `Cancel` is read before each band; a stopped file is removed.
//
//  Nothing is sent anywhere: the file is handed to the system's share sheet by the page.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UIKit
import UniformTypeIdentifiers

/// A stop asked for from the sheet, read by the drawing on its own thread.
final class LightTableExportCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

/// What an export measured, for the log and the checks.
struct LightTableExportReport: Sendable {
    var width: Int
    var height: Int
    var format: LightTableExportFormat
    var seconds: Double
    var bands: Int
    var tiles: Int
    /// The app's footprint before the drawing and the most it reached while drawing and writing.
    var footprintBefore: UInt64
    var footprintPeak: UInt64
    /// The films' textures: the most held at once, and what they were allowed.
    var texturePeak: Int
    var textureBudget: Int
    /// Each film's long edge as read, pixels, bottom of the pile first.
    var filmEdges: [Int]
    /// Each film's picture as it came: its long edge in pixels, and where it was read from.
    var filmReads: [(edge: Int, from: String)] = []
    var fileBytes: Int

    var line: String {
        "light table export: \(width) × \(height) \(format.title), \(String(format: "%.2f", seconds)) s, \(bands) bands, \(tiles) tiles, "
            + "footprint \(footprintBefore >> 20) → peak \(footprintPeak >> 20) MB, textures \(texturePeak >> 20) of \(textureBudget >> 20) MB, "
            + "file \(fileBytes >> 10) KB"
    }
}

enum LightTableExportFailure: Error, Equatable {
    case noGPU
    /// Not enough memory now for the size asked: the most it could take, MB.
    case memory(Int)
    case cancelled
    case write
}

// MARK: - the contact sheet

final class LightTableExporter: @unchecked Sendable {
    struct Film: Sendable {
        var item: LightTableItem
        var source: LightTableSource
        /// Its full-size render kept on disk, its kept develop's long edge, and whether a render can be
        /// had (`LightTableSteps.choose`).
        var full: LightTableFullRef? = nil
        var keptEdge: Int? = nil
        var hasMore = false
    }

    private let renderer: LightTableRenderer
    private let films: [Film]
    private let half: CGSize
    private let style: LightTableExportStyle
    private let format: LightTableExportFormat
    let sheet: LightTableExportPlan.Sheet

    init(renderer: LightTableRenderer, films: [Film], half: CGSize, choice: LightTableExportChoice) {
        self.renderer = renderer
        self.films = films
        self.half = half
        style = choice.style
        format = choice.fileFormat
        sheet = LightTableExportPlan.sheet(half: half, style: choice.style, shortEdge: choice.shortEdge)
    }

    /// The contact sheet drawn and written to `url`. Blocks for as long as it takes: call it off
    /// the main thread. `progress` is told the share of bands done, on the drawing's thread.
    func write(to url: URL, cancel: LightTableExportCancel, progress: @escaping @Sendable (Double) -> Void) throws -> LightTableExportReport {
        let start = Date()
        let before = MemoryProbe.footprint()
        let budget = MemoryBudget.compute(MemoryProbe.read(), frontend: FrontendState())
        let fixed = LightTableExportPlan.fixedBytes(sheet)
        let textureBudget = min(512 << 20, Int(budget.bytes) - fixed)
        guard textureBudget >= 24 << 20 else { throw LightTableExportFailure.memory(Int(budget.bytes >> 20)) }

        let writer = try BandWriter(renderer: renderer, films: films, half: half, style: style, sheet: sheet,
                                    textureBudget: textureBudget, cancel: cancel, progress: progress)
        writer.footprintPeak = before
        try? FileManager.default.removeItem(at: url)
        let rowBytes = sheet.width * 4
        var callbacks = CGDataProviderSequentialCallbacks(
            version: 0,
            getBytes: { info, buffer, count in
                Unmanaged<BandWriter>.fromOpaque(info!).takeUnretainedValue().bytes(into: buffer, count: count)
            },
            skipForward: { info, count in
                Unmanaged<BandWriter>.fromOpaque(info!).takeUnretainedValue().skip(Int(count))
            },
            rewind: { info in
                Unmanaged<BandWriter>.fromOpaque(info!).takeUnretainedValue().rewind()
            },
            releaseInfo: { info in
                Unmanaged<BandWriter>.fromOpaque(info!).release()
            })
        guard let provider = CGDataProvider(sequentialInfo: Unmanaged.passRetained(writer).toOpaque(), callbacks: &callbacks)
        else { throw LightTableExportFailure.write }
        let alpha = style == .withTable
        let info = CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.premultipliedFirst : CGImageAlphaInfo.noneSkipFirst).rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: sheet.width, height: sheet.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, (format == .png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
        else { throw LightTableExportFailure.write }
        let dpi = sheet.k * 25.4
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format == .jpg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        let ok = CGImageDestinationFinalize(dest)
        writer.finish()
        writer.footprintPeak = max(writer.footprintPeak, MemoryProbe.footprint())
        if cancel.isCancelled || writer.failed || !ok {
            try? FileManager.default.removeItem(at: url)
            throw cancel.isCancelled ? LightTableExportFailure.cancelled : LightTableExportFailure.write
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let report = LightTableExportReport(width: sheet.width, height: sheet.height, format: format,
                                            seconds: Date().timeIntervalSince(start), bands: writer.bands.count,
                                            tiles: writer.tiles.reduce(0) { $0 + $1.count }, footprintBefore: before,
                                            footprintPeak: writer.footprintPeak, texturePeak: writer.texturePeak,
                                            textureBudget: textureBudget, filmEdges: films.map { writer.steps[$0.item.id] ?? 0 },
                                            filmReads: films.map { writer.reads[$0.item.id] ?? (0, "nothing") },
                                            fileBytes: size)
        NSLog("%@", report.line)
        return report
    }
}

/// The file's rows, drawn a band at a time as ImageIO asks for them.
private final class BandWriter {
    let renderer: LightTableRenderer
    let sheet: LightTableExportPlan.Sheet
    let style: LightTableExportStyle
    let bands: [Range<Int>]
    let tiles: [[LightTableExportPlan.Tile]]
    let films: [LightTableExporter.Film]
    /// Each film's bands, first to last; a film outside the file has none.
    let spans: [UUID: ClosedRange<Int>]
    let steps: [UUID: Int]
    let scene: LightTableRenderer.Scene
    let cancel: LightTableExportCancel
    let progress: @Sendable (Double) -> Void
    let rowBytes: Int
    let buffer: MTLBuffer
    var targets: [Int: MTLTexture] = [:]
    var textures: [UUID: (texture: MTLTexture, bytes: Int)] = [:]
    /// Films whose picture could not be read: drawn as nothing, as the table draws them.
    var unreadable: Set<UUID> = []
    /// Each film's picture as it came: its long edge, and where it was read from.
    var reads: [UUID: (edge: Int, from: String)] = [:]
    var band = -1
    var offset = 0
    var failed = false
    var texturePeak = 0
    var footprintPeak: UInt64 = 0

    init(renderer: LightTableRenderer, films: [LightTableExporter.Film], half: CGSize, style: LightTableExportStyle,
         sheet: LightTableExportPlan.Sheet, textureBudget: Int, cancel: LightTableExportCancel,
         progress: @escaping @Sendable (Double) -> Void) throws {
        self.renderer = renderer
        self.sheet = sheet
        self.style = style
        self.films = films
        self.cancel = cancel
        self.progress = progress
        bands = LightTableExportPlan.bands(height: sheet.height)
        tiles = LightTableExportPlan.tiles(width: sheet.width, height: sheet.height)
        rowBytes = sheet.width * 4
        // A tile's last row is written `rowBytes` × (rows − 1) plus its own width past its start.
        guard let b = renderer.device.makeBuffer(length: rowBytes * LightTableExportPlan.bandRows + 16, options: .storageModeShared)
        else { throw LightTableExportFailure.memory(rowBytes * LightTableExportPlan.bandRows >> 20) }
        b.label = "export band"
        buffer = b

        let flat = style == .layoutOnly
        var needs: [LightTableExportPlan.FilmNeed] = []
        var drawn: [LightTableRenderer.Film] = []
        for f in films {
            let it = f.item
            var shadow = LightTableShown.atRest(it, ready: true).shadow
            // On flat paper a film casts no shadow; its 0.35 mm contact line stays, as a print's edge.
            if flat { shadow.alpha = 0 }
            if f.source != .none,
               let n = LightTableExportPlan.need(id: it.id, centre: it.centre, angle: it.rot, size: it.size,
                                                 reach: LightTableExportPlan.shadowReach(shadow), sheet: sheet) {
                needs.append(n)
            }
            drawn.append(LightTableRenderer.Film(centre: it.centre, angle: it.rot, size: it.size, presence: f.source == .none ? 0 : 1,
                                                 shadow: shadow, texture: nil))
        }
        var spans: [UUID: ClosedRange<Int>] = [:]
        for n in needs { spans[n.id] = LightTableExportPlan.bandSpan(n.rows, bands: bands) }
        self.spans = spans
        steps = LightTableExportPlan.planFilms(needs, bands: bands, budget: textureBudget)
        let a = LightTableExportPlan.ambient
        scene = LightTableRenderer.Scene(
            half: half, films: drawn,
            sheen: SIMD3(Float(-0.3 * half.width), Float(0.45 * half.height), flat ? 0 : 0.075),
            darkDesk: false,
            look: flat ? SIMD4(2, 0, 0, 0) : SIMD4(1, Float(a.sigma), Float(a.drop), Float(a.alpha)))
    }

    // MARK: ImageIO's side

    func bytes(into out: UnsafeMutableRawPointer, count: Int) -> Int {
        let total = rowBytes * sheet.height
        var done = 0
        while done < count && offset < total {
            let b = (offset / rowBytes) / LightTableExportPlan.bandRows
            if b != band {
                guard draw(b) else { return done }
                band = b
            }
            let start = bands[b].lowerBound * rowBytes
            let n = min(count - done, bands[b].upperBound * rowBytes - offset)
            memcpy(out + done, buffer.contents() + (offset - start), n)
            done += n
            offset += n
        }
        return done
    }

    func skip(_ count: Int) -> off_t {
        let n = min(count, rowBytes * sheet.height - offset)
        offset += n
        return off_t(n)
    }

    func rewind() {
        offset = 0
        band = -1
    }

    /// Everything let go of once the file is written.
    func finish() {
        textures.removeAll()
        targets.removeAll()
    }

    // MARK: a band

    private func draw(_ b: Int) -> Bool {
        guard !failed else { return false }
        if cancel.isCancelled { failed = true; return false }
        // the films this band touches, read; the ones it does not, let go of
        for (id, span) in spans where !span.contains(b) { textures[id] = nil }
        for f in films {
            let id = f.item.id
            guard let span = spans[id], span.contains(b), textures[id] == nil, !unreadable.contains(id), let edge = steps[id] else { continue }
            let want = LightTableTextures.Want(id: id, source: f.source, pixels: Double(edge), visible: true, aspect: 1,
                                               full: f.full, keptEdge: f.keptEdge, hasMore: f.hasMore)
            let source = LightTableTextures.effective(want, edge: edge).0
            if let made = LightTableTextures.exportTexture(source, edge: edge, renderer: renderer) {
                textures[id] = (made.0, LightTableSteps.bytes(width: made.1, height: made.2, mipmapped: true))
                reads[id] = (max(made.1, made.2), LightTableTextures.origin(source))
            } else {
                unreadable.insert(id)
            }
        }
        texturePeak = max(texturePeak, textures.values.reduce(0) { $0 + $1.bytes })

        var scene = self.scene
        for i in scene.films.indices {
            let id = films[i].item.id
            scene.films[i].texture = textures[id]?.texture
            if unreadable.contains(id) { scene.films[i].presence = 0 }
        }
        guard let cb = renderer.queue.makeCommandBuffer(), let target0 = target(LightTableExportPlan.tileSide, bands[b].count) else {
            failed = true
            return false
        }
        cb.label = "export band \(b)"
        let clear = style == .withTable ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0) : MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        for t in tiles[b] {
            guard let target = t.width == target0.width ? target0 : self.target(t.width, t.height) else { failed = true; return false }
            let camera = LightTableRenderer.Camera(
                centre: CGPoint(x: sheet.worldX(column: Double(t.x) + Double(t.width) / 2), y: sheet.worldY(row: Double(t.y) + Double(t.height) / 2)),
                spanMM: CGSize(width: Double(t.width) / sheet.k, height: Double(t.height) / sheet.k), bias: -0.35)
            renderer.encodeTile(scene, camera, into: target, clear: clear, commandBuffer: cb)
            guard let blit = cb.makeBlitCommandEncoder() else { failed = true; return false }
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: buffer,
                      destinationOffset: t.x * 4, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * t.height)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { failed = true; return false }
        footprintPeak = max(footprintPeak, MemoryProbe.footprint())
        progress(Double(b + 1) / Double(bands.count))
        return true
    }

    /// A private target `w` × `h`, kept for the next band of the same size.
    private func target(_ w: Int, _ h: Int) -> MTLTexture? {
        let w = min(w, sheet.width)
        let key = w << 16 | h
        if let t = targets[key] { return t }
        // a band's height differs only at the last: the earlier sizes go
        targets = targets.filter { $0.key & 0xFFFF == h }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: LightTableRenderer.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .private
        let t = renderer.device.makeTexture(descriptor: d)
        t?.label = "export tile"
        targets[key] = t
        return t
    }
}

// MARK: - the page's side

@MainActor
enum LightTableExport {
    /// The file's name: "SpektraLab Contact Sheet 2026-10-17.png".
    static func fileName(_ choice: LightTableExportChoice, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let kind = choice.kind == .poster ? L("SpektraLab Poster") : L("SpektraLab Contact Sheet")
        return "\(kind) \(f.string(from: date)).\(choice.fileFormat.fileExtension)"
    }

    /// A folder of the export's own in the temporary folder, so the file keeps its plain name.
    static func folder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LightTableExport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The choice drawn and written to a file of its own. The poster is drawn as the table always
    /// drew it; a contact sheet in bands on a thread of its own. `progress` is called on the main thread.
    static func run(_ choice: LightTableExportChoice, table: LightTableController, cancel: LightTableExportCancel,
                    progress: @escaping (Double) -> Void) async throws -> (url: URL, report: LightTableExportReport?) {
        let url = folder().appendingPathComponent(fileName(choice))
        switch choice.kind {
        case .poster:
            progress(0)
            guard let image = await table.share() else { throw LightTableExportFailure.noGPU }
            if cancel.isCancelled { throw LightTableExportFailure.cancelled }
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw LightTableExportFailure.write
            }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw LightTableExportFailure.write }
            progress(1)
            return (url, nil)
        case .contactSheet:
            guard let renderer = table.renderer else { throw LightTableExportFailure.noGPU }
            // The films the sheet shows larger than anything kept of them are made first (the Mac's
            // `MacRenderCache`), one job each, and waited for; elsewhere nobody is asked and each is read
            // from what there is.
            let sheet = LightTableExportPlan.sheet(half: table.model.half, style: choice.style, shortEdge: choice.shortEdge)
            let lacking = table.lackingForExport(pixelsPerMM: sheet.k)
            if !lacking.isEmpty, let make = table.makesFullForExport {
                progress(0)
                await make(lacking)
                if cancel.isCancelled { throw LightTableExportFailure.cancelled }
                table.rendersChanged()
            }
            let films = table.exportFilms()
            let exporter = LightTableExporter(renderer: renderer, films: films, half: table.model.half, choice: choice)
            let tell: @Sendable (Double) -> Void = { p in DispatchQueue.main.async { progress(p) } }
            let report = try await Task.detached(priority: .userInitiated) {
                try exporter.write(to: url, cancel: cancel, progress: tell)
            }.value
            return (url, report)
        }
    }

    /// The pixels the choice will make, for the sheet to say.
    static func pixels(_ choice: LightTableExportChoice, half: CGSize) -> (width: Int, height: Int) {
        switch choice.kind {
        case .poster: return LightTableExportPlan.posterPixels(half: half)
        case .contactSheet:
            let s = LightTableExportPlan.sheet(half: half, style: choice.style, shortEdge: choice.shortEdge)
            return (s.width, s.height)
        }
    }
}
