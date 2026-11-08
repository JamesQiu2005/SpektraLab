//  FullDetail.swift — the develop page zoomed past its preview: the full render, the part of it on screen.
//
//  The page's picture is the engine's render at the preview's size (2,400 px).
//  Zoomed past one of its pixels to one of the screen's, it was drawn larger
//  than it was made: a 45 MP RAW looked like a 4 MP one. Now, from that zoom
//  on (`DevelopCanvas`), the frame's render at full size is asked for once
//  (`FullView.want`) — an export's at Full, through the one scheduler, kept on
//  disk (`FullRender`) — and the part of it on screen is laid over the preview.
//
//  **What the page holds for it is the screen's pixels, not the picture's.**
//  The part on screen is read from disk by the tiles it touches — from the
//  half size when it is shown at half or less — and made the screen's size in
//  one pass on the GPU (`spkFullDetail`): averaged over each screen pixel's
//  footprint, out of the engine's working space into Display P3 by the
//  engine's own output transform, and Edit's Light, Curve and Colour laid on as
//  the export lays them (`Layer2Export`: the same functions, the vignette over
//  the whole picture before the host's turn). At 1,180 × 1,250 screen pixels
//  that is a read of at most four times them (the half size's own rounding)
//  and a picture of them: 25-50 MB for a moment, 12 MB kept while shown.
//
//  - **Edited, it is let go at once**: any change the render is of (film,
//    paper, exposure, crop of the picture, film edge, decode) cancels the job
//    and takes the detail off (`editChanged`); a change of Edit's layer or of
//    Edit's crop does not — the render is the same, and the detail is drawn
//    again with the new layer.
//  - **Kept with the last ones looked at** (2026-10-24; until then one at a time): the renders have a
//    limit of their own, the one used longest ago going first, never the one this page shows or is
//    making (`WorkingCopies.fullLimit`, `pinnedName`).
//  - **Made once, whoever asks** (`FullRenderJobs`): a render the Light Table or the Mac's prefetch is
//    already making is the page's when its zoom asks for it — taken over where it is under way, asked
//    again at the page's standing where it has not started.
//
//  Not measured on a host yet: a simulator's times are this Mac's.

#if SPK_ENGINE
import CoreGraphics
import Foundation
import Metal
import Observation
import os

@MainActor
@Observable
final class FullView {
    enum State: Equatable {
        /// Not asked for, or not to be had (a pair, a frame no larger than its preview).
        case off
        /// The render is on its way: 0…1.
        case rendering(Double)
        /// It waits its turn: why, in English (shown through `L(shown:)`).
        case waiting(String)
        case ready
        case failed
    }

    /// The part of the finished picture on screen, at its own pixels.
    struct Detail {
        let image: CGImage
        /// Where it is on the finished picture: normalised, top-left origin.
        let rect: CGRect
        let adjustments: Adjustments
    }

    /// What the canvas asks to see.
    struct Ask: Equatable {
        /// On the finished picture: normalised, top-left origin.
        var rect: CGRect
        /// The screen's pixels it covers.
        var pixels: PixelSize
        var adjustments: Adjustments
    }

    let frameID: LibraryFrame.ID
    private(set) var state: State = .off {
        didSet { if state != oldValue { Self.onState?(frameID, state) } }
    }
    /// Every page's render changing state: the Mac's prefetch starts when the page's own is here.
    @ObservationIgnored static var onState: (@MainActor (LibraryFrame.ID, State) -> Void)?
    private(set) var detail: Detail?

    @ObservationIgnored private let library: FrameCatalog
    @ObservationIgnored private let scheduler: RenderQueue
    @ObservationIgnored private let darkroom: EngineRouter?
    @ObservationIgnored private var kept: (ask: FullRender.Ask, reader: FullRender.Reader)?
    @ObservationIgnored private var job: (id: UUID, stamp: String)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var bringing: Task<Void, Never>?
    @ObservationIgnored private var asked: Ask?
    @ObservationIgnored private var drawing = false
    @ObservationIgnored private var zoomed = false
    @ObservationIgnored private var again: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "fullview")

    init(frameID: LibraryFrame.ID, library: FrameCatalog, scheduler: RenderQueue, darkroom: EngineRouter?) {
        self.frameID = frameID
        self.library = library
        self.scheduler = scheduler
        self.darkroom = darkroom
    }

    /// Whether a frame has more to show than its preview: a photograph whose
    /// original is a quarter larger or more, that the engine develops.
    static func hasMore(_ frame: LibraryFrame) -> Bool {
        !frame.isPair && !frame.isDemo && frame.originalSize.longEdge * 4 > frame.previewSize.longEdge * 5
    }

    /// The render this page shows or is making, by its file's name: the one the renders' limit never
    /// takes (`WorkingCopies.fullInUse`).
    var pinnedName: String? { kept?.ask.url.lastPathComponent ?? jobName }
    @ObservationIgnored private var jobName: String?

    /// The canvas is zoomed past its preview: the full render is found, or
    /// asked for. Again and again as the canvas settles: asked once a render.
    func want() {
        zoomed = true
        guard let darkroom, let frame = library.frame(frameID), let made = FullRenderJobs.made(frame, darkroom: darkroom) else {
            state = .off
            return
        }
        let ask = made.ask
        if kept?.ask == ask { state = .ready; draw(); return }
        if let reader = FullRender.Reader(ask.url, stamp: ask.stamp) {
            take(ask, reader)
            return
        }
        if job?.stamp == ask.stamp || bringing != nil { return }       // on its way
        cancelJob()
        // An original that stays in Photos is brought first: a render at full size is of the file itself.
        if darkroom.isAway(frame) {
            state = .waiting("Reading the original from Photos")
            bringing = Task { [weak self] in
                let brought = await darkroom.bring(frame, asked: true)
                guard let self, !Task.isCancelled else { return }
                self.bringing = nil
                if brought == .here { self.want() } else { self.state = .failed }
            }
            return
        }
        submit(frame, made)
    }

    /// The canvas is back within its preview: nothing more is asked for. A
    /// render under way goes on — it is the zoom's next time — and is kept.
    func unwant() {
        zoomed = false
        asked = nil
        detail = nil
        again?.cancel()
    }

    /// The edit changed what the render is of: the job goes, the detail comes
    /// off, and — still zoomed — it is asked for again once the edit rests.
    func editChanged() {
        cancelJob()
        bringing?.cancel(); bringing = nil
        kept = nil
        detail = nil
        state = .off
        again?.cancel()
        guard zoomed else { return }
        again = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, self.zoomed else { return }
            self.want()
        }
    }

    /// The page closed: everything goes but the file.
    func close() {
        unwant()
        cancelJob()
        bringing?.cancel(); bringing = nil
        kept = nil
        state = .off
    }

    /// The part of the picture to show: drawn when the render is here, the
    /// latest asked for winning over any asked meanwhile.
    func show(_ ask: Ask) {
        guard ask != asked else { return }
        asked = ask
        draw()
    }

    // MARK: the render

    private func take(_ ask: FullRender.Ask, _ reader: FullRender.Reader) {
        kept = (ask, reader)
        state = .ready
        darkroom?.originals?.copies.noteProxy(ask.url, bytes: Int64(reader.header.fileBytes))
        draw()
    }

    private func submit(_ frame: LibraryFrame, _ made: FullRenderJobs.Made) {
        guard let darkroom else { return }
        let ask = made.ask, plan = made.plan
        // One the Light Table or a prefetch is making already is this page's (`FullRenderJobs.promote`).
        guard let id = FullRenderJobs.promote(frame, made, scheduler: scheduler, darkroom: darkroom) else {
            state = .failed
            return
        }
        self.job = (id, ask.stamp)
        jobName = ask.url.lastPathComponent
        state = .rendering(0)
        log.info("asked for the full render of a frame: \(plan.engineCanvas.width) x \(plan.engineCanvas.height)")
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let s = self.scheduler.snapshots.first(where: { $0.id == id }) {
                    switch s.state {
                    case .running(let p): self.state = .rendering(p.fraction)
                    case .waiting(let why): self.state = .waiting(why.text)
                    default: break
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.scheduler.outcome(of: id)
            guard self.job?.id == id else { return }
            self.job = nil
            self.jobName = nil
            self.watcher?.cancel(); self.watcher = nil
            switch outcome {
            case .finished:
                if let reader = FullRender.Reader(ask.url, stamp: ask.stamp) { self.take(ask, reader) } else { self.state = .failed }
            case .failed(let message):
                self.log.error("the full render failed: \(message, privacy: .public)")
                self.state = .failed
            case .cancelled:
                self.state = .off
            }
        }
    }

    private func cancelJob() {
        watcher?.cancel(); watcher = nil
        if let job { scheduler.cancel(job.id) }
        job = nil
        jobName = nil
    }

    /// A memory warning, the page not on screen: the part of the picture it holds goes (it is drawn
    /// again from the file when the page asks).
    func releaseDetail() {
        detail = nil
        asked = nil
    }

    /// What the page holds of its render in memory: its detail's pixels.
    var heldBytes: Int { detail.map { $0.image.bytesPerRow * $0.image.height } ?? 0 }

    // MARK: the detail

    private func draw() {
        guard !drawing, let ask = asked, let kept, let darkroom else { return }
        drawing = true
        let reader = kept.reader
        Task { [weak self] in
            let made: CGImage?
            do {
                let renderer = try await FullDetail.shared(darkroom)
                made = try await Task.detached(priority: .userInitiated) {
                    try renderer.render(reader, rect: ask.rect, pixels: ask.pixels, adjustments: ask.adjustments)
                }.value
            } catch {
                self?.log.error("the detail could not be made: \(String(describing: error), privacy: .public)")
                made = nil
            }
            guard let self else { return }
            self.drawing = false
            // Still the render, and still zoomed: shown. The canvas may have moved on meanwhile.
            if let made, self.kept?.ask == kept.ask, self.asked != nil {
                self.detail = Detail(image: made, rect: ask.rect, adjustments: ask.adjustments)
            }
            if self.asked != ask { self.draw() }
        }
    }
}

/// The pass that makes the part on screen of a full render (`spkFullDetail`). One for the app.
final class FullDetail: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let setup: OutputTransformer.Setup

    @MainActor private static var made: FullDetail?
    @MainActor private static var making: Task<FullDetail, Error>?

    /// The pass, made once: its kernel compiled with safe math, and the
    /// engine's numbers for Display P3 asked of the engine.
    @MainActor static func shared(_ darkroom: EngineRouter) async throws -> FullDetail {
        if let made { return made }
        if let making { return try await making.value }
        let task = Task { @MainActor () throws -> FullDetail in
            guard let device = darkroom.device, let data = try await darkroom.pageTransform() else {
                throw EngineError.failed("no engine for the full render's detail")
            }
            return try FullDetail(device: device, data: data)
        }
        making = task
        do {
            let pass = try await task.value
            made = pass
            making = nil
            return pass
        } catch {
            making = nil
            throw error
        }
    }

    init(device: MTLDevice, data: SpkEngine.OutputTransformData) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw EngineError.failed("no command queue for the detail") }
        self.queue = queue
        setup = try OutputTransformer(device: device).setup(data)
        let library = try device.makeLibrary(source: OutputTransformer.source + "\n" + Layer2Kernel.functions + "\n" + Self.kernel,
                                             options: Layer2Kernel.options())
        guard let function = library.makeFunction(name: "spkFullDetail") else { throw EngineError.failed("the detail's kernel is missing") }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// The part `rect` (normalised, of the finished picture) of the render
    /// `reader` holds, `pixels` large at most — never larger than the render
    /// has it — in Display P3, 16 bits a channel, with `adjustments` laid on.
    func render(_ reader: FullRender.Reader, rect: CGRect, pixels: PixelSize, adjustments: Adjustments) throws -> CGImage {
        let h = reader.header
        let (fw, fh) = h.finished
        // On the finished picture, in its pixels.
        let r = CGRect(x: rect.minX * CGFloat(fw), y: rect.minY * CGFloat(fh), width: rect.width * CGFloat(fw), height: rect.height * CGFloat(fh))
            .intersection(CGRect(x: 0, y: 0, width: fw, height: fh))
        guard r.width >= 1, r.height >= 1, pixels.width > 0, pixels.height > 0 else { throw EngineError.failed("nothing of the picture to show") }
        // The screen's pixels, or the render's where it has fewer.
        let step = max(r.width / CGFloat(pixels.width), r.height / CGFloat(pixels.height), 1)
        let ow = max(1, Int((r.width / step).rounded(.up))), oh = max(1, Int((r.height / step).rounded(.up)))
        let level = step >= 2 ? 1 : 0
        let scale = CGFloat(1 << level)
        // Where it is on the render, before the host's turn, and on the level read.
        let W = CGFloat(h.width), H = CGFloat(h.height)
        func onRender(_ p: CGPoint) -> CGPoint {
            switch h.turnsAfter % 4 {
            case 1: CGPoint(x: p.y, y: H - p.x)
            case 2: CGPoint(x: W - p.x, y: H - p.y)
            case 3: CGPoint(x: W - p.y, y: p.x)
            default: p
            }
        }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map(onRender)
        let (lw, lh) = h.size(level: level)
        let x0 = max(0, Int(floor(corners.map(\.x).min()! / scale)) - 2), y0 = max(0, Int(floor(corners.map(\.y).min()! / scale)) - 2)
        let x1 = min(lw, Int(ceil(corners.map(\.x).max()! / scale)) + 2), y1 = min(lh, Int(ceil(corners.map(\.y).max()! / scale)) + 2)
        let rw = x1 - x0, rh = y1 - y0
        guard rw > 0, rh > 0, let region = device.makeBuffer(length: rw * rh * 8, options: .storageModeShared),
              let out = device.makeBuffer(length: ow * oh * 8, options: .storageModeShared) else {
            throw EngineError.resource("no memory for the detail")
        }
        try reader.region(level: level, x: x0, y: y0, width: rw, height: rh, into: region.contents().assumingMemoryBound(to: UInt16.self))

        // The map, as the kernel's `FullDetailMap` lays it out: eight floats, then eight words.
        var map: [UInt8] = []
        for f in [Float(r.minX), Float(r.minY), Float(step), Float(W), Float(H), Float(x0), Float(y0), Float(scale)] {
            withUnsafeBytes(of: f) { map.append(contentsOf: $0) }
        }
        for u in [UInt32(rw), UInt32(rh), UInt32(ow), UInt32(oh), UInt32(h.turnsAfter % 4), adjustments.isActive ? 1 : 0, 0, 0] as [UInt32] {
            withUnsafeBytes(of: u) { map.append(contentsOf: $0) }
        }
        var u = adjustments.uniforms()
        let tables = adjustments.curves.tables()
        guard let curves = device.makeBuffer(bytes: tables, length: tables.count * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw EngineError.resource("no memory for the detail")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(region, offset: 0, index: 0)
        encoder.setBytes(setup.uniforms, length: setup.uniforms.count, index: 1)
        encoder.setBuffer(setup.cmax, offset: 0, index: 2)
        encoder.setBuffer(out, offset: 0, index: 3)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 4)
        encoder.setBuffer(curves, offset: 0, index: 5)
        encoder.setBytes(map, length: map.count, index: 6)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (ow + tw - 1) / tw, height: (oh + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw EngineError.failed("the detail's pass failed: \(error.localizedDescription)") }

        // The image holds the buffer for as long as it lives; nothing is copied.
        let held = Unmanaged.passRetained(out as AnyObject)
        guard let provider = CGDataProvider(dataInfo: held.toOpaque(), data: out.contents(), size: ow * oh * 8,
                                            releaseData: { info, _, _ in if let info { Unmanaged<AnyObject>.fromOpaque(info).release() } }) else {
            held.release()
            throw EngineError.failed("no data provider for the detail")
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let image = CGImage(width: ow, height: oh, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: ow * 8,
                                  space: OutputTransformer.Target.displayP3.colorSpace, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw EngineError.failed("the detail could not be made")
        }
        return image
    }

    /// One screen pixel: the render's pixels under its footprint, averaged
    /// (from the half size where the footprint is two or more), out of the
    /// working space by the output transform, held to 16 bits as the page's
    /// picture is, and Edit's layer laid on at the pixel's place in the whole
    /// render (`l2Exported`'s steps, from a buffer and not a texture).
    static let kernel = #"""
    struct FullDetailMap {
        float originX; float originY; float step; float renderW;
        float renderH; float regionX; float regionY; float levelScale;
        uint regionW; uint regionH; uint outW; uint outH;
        uint turns; uint layer2; uint spare0; uint spare1;
    };

    // A point of the finished picture on the render: the host's clockwise turns undone.
    static inline float2 fdOnRender(float2 f, uint k, float W, float H) {
        if (k == 1u) return float2(f.y, H - f.x);
        if (k == 2u) return float2(W - f.x, H - f.y);
        if (k == 3u) return float2(W - f.y, f.x);
        return f;
    }

    kernel void spkFullDetail(device const ushort *src [[buffer(0)]],
                              constant OutputTransformUniforms &toPage [[buffer(1)]],
                              device const float *cmax [[buffer(2)]],
                              device ushort *dst [[buffer(3)]],
                              constant Layer2Uniforms &u [[buffer(4)]],
                              device const float *curves [[buffer(5)]],
                              constant FullDetailMap &m [[buffer(6)]],
                              uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= m.outW || gid.y >= m.outH) return;
        float2 f = float2(m.originX, m.originY) + (float2(gid) + 0.5f) * m.step;
        float2 c = fdOnRender(f, m.turns, m.renderW, m.renderH);
        float2 l = c / m.levelScale - float2(m.regionX, m.regionY);
        float r = max(0.5f * m.step / m.levelScale, 0.5f);
        float x0 = l.x - r, x1 = l.x + r, y0 = l.y - r, y1 = l.y + r;
        int ix0 = max(int(floor(x0)), 0), ix1 = min(int(ceil(x1)) - 1, int(m.regionW) - 1);
        int iy0 = max(int(floor(y0)), 0), iy1 = min(int(ceil(y1)) - 1, int(m.regionH) - 1);
        ix1 = min(ix1, ix0 + 4); iy1 = min(iy1, iy0 + 4);
        float3 sum = float3(0.0f); float wsum = 0.0f;
        for (int y = iy0; y <= iy1; y++) {
            float wy = min(y1, float(y + 1)) - max(y0, float(y));
            if (wy <= 0.0f) continue;
            for (int x = ix0; x <= ix1; x++) {
                float wx = min(x1, float(x + 1)) - max(x0, float(x));
                if (wx <= 0.0f) continue;
                uint i = (uint(y) * m.regionW + uint(x)) * 4u;
                sum += float3(float(src[i]), float(src[i + 1u]), float(src[i + 2u])) / 65535.0f * (wx * wy);
                wsum += wx * wy;
            }
        }
        float3 working = wsum > 0.0f ? sum / wsum : float3(0.0f);
        float3 p = spkTransformed(working, toPage, cmax);
        p = select(p, float3(0.0f), isnan(p));
        p = floor(saturate(p) * 65535.0f + 0.5f) / 65535.0f;
        if (m.layer2 != 0u) p = l2Apply(p, c / float2(m.renderW, m.renderH), u, curves);
        uint o = (gid.y * m.outW + gid.x) * 4u;
        dst[o]      = to16(p.x);
        dst[o + 1u] = to16(p.y);
        dst[o + 2u] = to16(p.z);
        dst[o + 3u] = (ushort)65535;
    }
    """#
}
#endif
