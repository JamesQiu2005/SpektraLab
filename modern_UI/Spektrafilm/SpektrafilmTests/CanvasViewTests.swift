//  The real MTKView, constructed and drawn into.
//
//  These exist because of a defect the rest of the suite could not see: the
//  canvas was configured with `colorPixelFormat = .rgba16Unorm`, which is a
//  valid *texture* format and not a valid *drawable* format, so `CAMetalLayer`
//  raised `invalid pixel format 110` and the app died on launch. Every other
//  test passed, and the snapshot harness passed too, because snapshot mode
//  substitutes an offscreen render and never builds an `MTKView`.
//
//  So: build the view the app builds, put it in a window, and draw.

import MetalKit
import QuartzCore
import SwiftUI
import XCTest

@MainActor
final class CanvasViewTests: XCTestCase {

    /// The formats `CAMetalLayer` accepts. Anything else raises an ObjC
    /// exception on assignment, which is a crash, not an error.
    static let drawableFormats: Set<MTLPixelFormat> = [
        .bgra8Unorm, .bgra8Unorm_srgb, .rgba16Float, .rgb10a2Unorm, .bgr10a2Unorm,
        .bgra10_xr, .bgra10_xr_srgb, .bgr10_xr, .bgr10_xr_srgb,
    ]

    func testDrawableFormatIsOneCAMetalLayerAccepts() {
        XCTAssertTrue(Self.drawableFormats.contains(Renderer.drawableFormat),
                      "\(Renderer.drawableFormat) is not a drawable format; CAMetalLayer will throw")
        // The offscreen format is the other half of the split: 16-bit unorm so
        // `makeCGImage()` needs no conversion. It is deliberately NOT a
        // drawable format, so the two must differ.
        XCTAssertEqual(Renderer.offscreenFormat, .rgba16Unorm)
    }

    func testCanvasViewBuildsAndDrawsInAWindow() throws {
        let session = Session()
        let view = CanvasNSView.configured(host: session)
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        XCTAssertEqual(layer.pixelFormat, Renderer.drawableFormat)
        // The layer is tagged with **the space the texture is in**, which is the
        // working space — ProPhoto RGB. ColorSync converts for the display.
        //
        // It was Display P3, and the assertion read the same way either time:
        // tag what the pixels are. RFC-018 §2.4 had the canvas convert into P3
        // first; the user reversed that half ("all displayed image in the main
        // app page would be in ProPhoto RGB and macOS should be handling the
        // color space management"), so the tag moved and the conversion went
        // with it. A mismatch here is the quietest failure in the app — ProPhoto
        // values wearing a P3 tag is a washed-out canvas and no error anywhere.
        XCTAssertEqual(layer.colorspace?.name, ImageDecoder.workingSpace?.name,
                       "the layer must be tagged with the space the canvas holds")
        XCTAssertTrue(view.isFlipped, "mouse points must share the shader's top-left origin")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()

        // Empty canvas: the ground only.
        session.renderer.draw(in: view)

        // With an image: exercises the drawable render pipeline, which is the
        // state whose pixel format must match the drawable's.
        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: 4, height: 2))
        session.renderer.setLive(tex)
        session.renderer.viewport.resize(viewport: view.bounds.size, image: CGSize(width: 4, height: 2))
        session.renderer.draw(in: view)
        XCTAssertEqual(view.colorPixelFormat, Renderer.drawableFormat)
    }

    /// A redraw request must produce a draw. This asserts the wiring —
    /// delegate installed, closure connected, view able to dispatch — and it
    /// caught a real defect: `configured(host:)` at one point installed no
    /// `MTKViewDelegate`, so nothing drew however the redraw was requested.
    ///
    /// **What it does not catch, stated so nobody trusts it too far.** The
    /// shipped bug was `needsDisplay = true` failing to fire the delegate in
    /// the running app. In this test process it fires — with the view bare in
    /// a window *and* hosted in `NSHostingView` — so this test passes against
    /// the broken code. Whatever AppKit is doing differently in the real app
    /// does not reproduce in-process. The guard that actually catches it is
    /// `Tools/capture-live.sh`, which photographs the real window through the
    /// window server.
    func testRedrawRequestReachesTheViewWhenHostedBySwiftUI() async throws {
        let session = Session()
        let hosting = NSHostingView(rootView: MetalCanvasView(host: session).frame(width: 400, height: 300))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()

        func canvas(in view: NSView) -> CanvasNSView? {
            (view as? CanvasNSView) ?? view.subviews.lazy.compactMap(canvas(in:)).first
        }
        let view = try XCTUnwrap(canvas(in: hosting), "the representable must produce a CanvasNSView")
        XCTAssertNotNil(view.delegate, "no delegate means no draw, however the redraw is requested")

        // Let the hosting view's own first draws happen, then confirm idle:
        // otherwise the measurement counts those and passes regardless.
        try await Task.sleep(for: .milliseconds(500))
        let settled = session.renderer.drawCount
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(session.renderer.drawCount, settled, "the view must be idle before the measurement")

        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: 4, height: 2))
        session.renderer.setLive(tex)          // fires needsDraw, exactly as a landed render does
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertGreaterThan(session.renderer.drawCount, settled,
                             "a redraw request must produce a draw, or the canvas stays blank")
    }

    /// The canvas is resized the way the interface actually resizes it: a
    /// stream of small changes, each one its own layout pass, which is what a
    /// panel animation and a window drag both are.
    ///
    /// What this pins is the thing that was *checked and found correct* when
    /// "the picture twitches when the panels move" was investigated — with a
    /// per-draw log across a 40-step resize, a 76-draw live drag and a
    /// frame-by-frame capture of a collapse animation. The three sizes agree
    /// at every step: the viewport the fit was computed against, the view's
    /// bounds, and the drawable the picture is actually drawn into. A drawable
    /// left behind by one layout pass is a picture drawn to the wrong
    /// rectangle — the visible failure everyone expects this bug to be — and
    /// this is the assertion that would catch it.
    ///
    /// **It passes on the code the twitch was reported against.** The defect
    /// that investigation found is in *when* frames are presented, not where
    /// the picture is (see the note in `scheduleDraw`), and no assertion in
    /// this process can see the difference: the canvas draws in a real window
    /// on a real display link and an offscreen test has neither. It earns its
    /// place as a guard on the arithmetic, not as a reproduction.
    func testViewportBoundsAndDrawableAgreeAtEveryResizeStep() throws {
        let session = Session()
        let view = CanvasNSView.configured(host: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1448, height: 878),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 1448, height: 878)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()

        // A square frame: the fit is height-limited, so the scale must not
        // change at all as the canvas widens — the picture only re-centres.
        let side: CGFloat = 2084
        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: Int(side), height: Int(side)))
        session.renderer.viewport.backingScale = 2
        session.renderer.viewport.resize(viewport: view.bounds.size, image: CGSize(width: side, height: side))
        session.renderer.setLive(tex, logical: CGSize(width: side, height: side))

        var widths: [CGFloat] = []
        for step in 0...40 {
            let w = 1448 - CGFloat(step) * 10          // the collapse, in 10 pt steps
            widths.append(w)
            view.frame = CGRect(x: 0, y: 0, width: w, height: 878)
            view.layoutSubtreeIfNeeded()

            let vp = session.renderer.viewport
            let bs = view.window?.backingScaleFactor ?? 2
            let what = "at width \(w)"
            XCTAssertEqual(vp.viewport.width, w, accuracy: 0.5, "the viewport is not the canvas \(what)")
            XCTAssertEqual(view.drawableSize.width, w * bs, accuracy: 1.0,
                           "the drawable is a layout pass behind the canvas \(what)")
            // …and the picture is centred in whatever the canvas now is.
            let imageWidth = vp.image.width * vp.scale
            XCTAssertEqual(vp.offset.x, (vp.viewport.width - imageWidth) / 2, accuracy: 0.01,
                           "the picture is not centred \(what)")
            XCTAssertEqual(vp.scale, 878 / side, accuracy: 1e-9,
                           "a height-limited fit must not rescale when the canvas only widens \(what)")
        }
        // A resize that never happened would pass every assertion above.
        XCTAssertEqual(widths.first! - widths.last!, 400, accuracy: 0.001)
    }

    /// The hover band must be **centred on the pill it reveals**.
    ///
    /// They are hung off the same canvas edge but by different rules — the
    /// band is 28 pt against the edge, the pill is 14 pt and inset — so
    /// whichever way the arithmetic goes, one of them ends up off to a side.
    /// Measured in a hosted window on the code this was written against:
    ///
    ///     leading   band x 343…371   pill x 343…357    centres 357 vs 350
    ///     trailing  band x 1591…1619 pill x 1605…1619  centres 1605 vs 1612
    ///     bottom    band y 914…942   pill y 918…932    centres 928 vs 925
    ///
    /// Seven points on the two vertical edges and three on the bottom, all of
    /// the slack on the far side from where a person reaches: coming *from*
    /// the panel or the filmstrip, the band was not there at all. The user's
    /// words were that the bottom trigger sits above the bar it belongs to.
    ///
    /// The invariant is stated as "the pill is centred in the band" rather
    /// than as three numbers, so it holds however the tokens move and does not
    /// repeat the arithmetic it is checking.
    func testTheHoverBandIsCentredOnThePillItReveals() throws {
        let session = Session()
        let host = NSHostingView(rootView: EditorWindow(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        func bands(in view: NSView) -> [HoverBand.Band] {
            (view as? HoverBand.Band).map { [$0] } ?? view.subviews.flatMap(bands(in:))
        }
        let found = bands(in: host)
        XCTAssertEqual(found.count, 3, "one band per collapsible edge — the top bar does not fold")
        for band in found {
            XCTAssertGreaterThan(band.bounds.width, 0)
            XCTAssertGreaterThan(band.bounds.height, 0)
            // The pill's rect is in the band's own coordinates, so "centred"
            // is a statement about the band's bounds alone.
            XCTAssertEqual(band.pillRect.midX, band.bounds.midX, accuracy: 0.5,
                           "pill is \(band.pillRect.midX - band.bounds.midX) pt off centre across")
            XCTAssertEqual(band.pillRect.midY, band.bounds.midY, accuracy: 0.5,
                           "pill is \(band.pillRect.midY - band.bounds.midY) pt off centre down")
        }
    }

    /// The drawable must **cover** the layer it is drawn into.
    ///
    /// `MTKView.autoResizeDrawable` rounds the drawable down from the bounds
    /// while a `CAMetalLayer`'s own bounds are the bounds in pixels, unrounded
    /// — so at any fractional size the drawable is up to a pixel short, and on
    /// an opaque layer that sliver is black, on the **right and bottom**, which
    /// is the side a rounded-down number leaves a gap on. Measured live over
    /// one panel animation: 14 of 28 draws were short, the worst by 0.42 px
    /// (bounds 1762.2101 pt, drawable 3524 px where 3524.42 px of layer were
    /// there). This is the user's "very small black edge on the bottom and
    /// right side of the canvas".
    ///
    /// A *fractional* size is the whole point of the test: at integral points
    /// there is nothing to round, which is why the defect only showed up on a
    /// window someone had dragged to an arbitrary size.
    func testTheDrawableCoversTheViewAtFractionalSizes() throws {
        let session = Session()
        let view = CanvasNSView.configured(host: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for width in [999.0, 1000.37, 1276.21, 1438.63] {
            for height in [701.0, 888.42, 894.71] {
                view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                view.layoutSubtreeIfNeeded()
                let bs = view.window?.backingScaleFactor ?? 2
                let wantW = width * bs, wantH = height * bs
                XCTAssertGreaterThanOrEqual(view.drawableSize.width, wantW - 1e-9,
                                            "drawable \(view.drawableSize.width) px is short of \(wantW) at \(width)×\(height)")
                XCTAssertGreaterThanOrEqual(view.drawableSize.height, wantH - 1e-9,
                                            "drawable \(view.drawableSize.height) px is short of \(wantH) at \(width)×\(height)")
                // …and not absurdly over: one pixel of slack, not a whole point.
                XCTAssertLessThan(view.drawableSize.width, wantW + bs,
                                  "the drawable is more than a pixel wider than the layer")
                XCTAssertLessThan(view.drawableSize.height, wantH + bs,
                                  "the drawable is more than a pixel taller than the layer")
            }
        }
    }

    /// **The canvas twitch, measured in-process.**
    ///
    /// What "the picture twitches while the panels move" is: during the
    /// collapse the canvas is re-laid-out continuously, and the frames that
    /// reach the screen are the ones drawn — so the picture moves in steps
    /// whose size is decided by *when the draw happened*, not by the
    /// animation. Measured on the real app: a 113 ms interval with no draw at
    /// all, straddled by a 108 pt jump, against a total travel of 167 pt.
    ///
    /// This drives the same thing where a test can see it: the real
    /// `EditorWindow`, the real `MetalCanvasView`, in a real window, with the
    /// collapse run as an animation exactly as the tab runs it. Every
    /// millisecond it samples the draw count and where the picture is, and
    /// reports the longest interval with no draw and how far the picture
    /// moved across it. That is the number to compare when someone changes
    /// what animates — an A/B needs the same measurement on both arms.
    ///
    /// **The assertion is deliberately weak.** It fires if the collapse stops
    /// running at all (no resizes, no draws, or the canvas never moves),
    /// which is a real regression: this file is where the collapse, the fit
    /// and the draw path meet. It does **not** assert a bound on the hole,
    /// because the hole is wall-clock on whatever machine is running and a
    /// bound would be flaky rather than informative. The printed line is the
    /// point; the assertion is the tripwire under it.
    ///
    /// **One result, so it is not re-tested.** The obvious cheap fix — keep
    /// the panel at its fixed width and animate a clip window over it,
    /// instead of removing it and animating its width — was measured as an
    /// A/B on this harness, four runs per arm: baseline 37–41 canvas resizes
    /// and ~304–325 ms of CPU for a 180 ms animation; clip version 45–47
    /// resizes and ~298–321 ms of CPU. A wash. The canvas's width animates
    /// either way — that is what drives the fit — so the pass count is set by
    /// the canvas, not by whether the panel is laid out inside its own slot.
    /// The same reasoning applies to the right panel and the filmstrip.
    func testTheCollapseIsMeasuredAndTheCanvasKeepsUp() async throws {
        let session = Session()
        let size = CGSize(width: 1920, height: 1080)
        let host = NSHostingView(rootView: EditorWindow(session: session))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let canvas = try XCTUnwrap(find(CanvasNSView.self, in: host), "the representable must produce a CanvasNSView")

        // `Session` reads the collapse flags out of `UserDefaults` at init, and
        // this test does not own those: whether the panel starts open depends
        // on whatever wrote `ui2.leftCollapsed` last — the app itself, another
        // test class, or a person. Measured: with the flag left set, this test
        // measured a collapse that never happened and reported zero of
        // everything. So it sets its own input and puts it back (AGENTS 24).
        let savedLeft = session.leftCollapsed
        defer { session.leftCollapsed = savedLeft }
        session.leftCollapsed = false
        host.layoutSubtreeIfNeeded()

        try await Task.sleep(for: .milliseconds(700))     // let the window settle
        XCTAssertFalse(session.leftCollapsed, "the panel must be open before it is collapsed")

        let before = (resizes: canvas.resizeCount, draws: session.renderer.drawCount)
        func cpu() -> Double {
            var t = timespec()
            clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
            return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
        }
        let cpuBefore = cpu()
        withAnimation(.easeOut(duration: 0.18)) { session.leftCollapsed = true }

        // Sample until the animation is over and the surface is still.
        var samples: [(t: Double, draws: Int, left: CGFloat)] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            samples.append((ProcessInfo.processInfo.systemUptime, session.renderer.drawCount,
                            session.renderer.viewport.offset.x))
            try await Task.sleep(for: .milliseconds(1))
        }

        let after = (resizes: canvas.resizeCount, draws: session.renderer.drawCount)
        XCTAssertGreaterThan(after.resizes, before.resizes + 2,
                             "the collapse must resize the canvas repeatedly — it is an animation")
        XCTAssertGreaterThan(after.draws, before.draws,
                             "the canvas must draw while it is being resized")

        // Only the stretch where the picture is actually moving counts: the
        // pause before the animation starts is not the defect, and it is
        // longer than anything inside it.
        let moving = samples.indices.filter { i in
            i > 0 && abs(samples[i].left - samples[i - 1].left) > 0.01
        }
        let span = (moving.first ?? 0)...(moving.last ?? samples.count - 1)
        let inFlight = Array(samples[span])

        // The longest stretch with no draw, and how far the picture moved
        // across it: the twitch, as a pair of numbers.
        var hole = 0.0, jump: CGFloat = 0, at = 0.0
        var last = inFlight.first
        for s in inFlight.dropFirst() {
            guard let l = last else { break }
            if s.draws == l.draws {
                let dt = s.t - l.t
                if dt > hole { hole = dt; jump = abs(s.left - l.left); at = l.t - inFlight[0].t }
            }
            last = s
        }
        let moved = abs(inFlight.last!.left - inFlight.first!.left)
        // How long the animation actually took. A 0.18 s animation that takes
        // 0.4 s is one whose frames are not keeping up, and that is what this
        // process *can* see: there is no display link here, so the visible
        // stall of the real app — no draw at all for 113 ms — does not
        // reproduce. The pass count and the wall-clock cost do.
        let took = (inFlight.last!.t - inFlight.first!.t) * 1000
        // …and what it *cost*. The pass count is the same either way — the
        // canvas's width animates whatever the panel does — so the number that
        // separates "the panel is re-laid-out forty times" from "the panel is
        // laid out once and clipped" is the CPU burnt doing it.
        let cpuUsed = cpu() - cpuBefore
        print(String(format: "collapse: %d canvas resizes, %d draws, picture moved %.1f pt "
                     + "in %.0f ms (the animation asks for 180), %.0f ms of CPU; "
                     + "longest gap with no draw %.0f ms (at %.0f ms), across which it moved %.1f pt",
                     after.resizes - before.resizes, after.draws - before.draws, moved, took,
                     cpuUsed * 1000, hole * 1000, at * 1000, jump))
    }

    /// The zoom readout is computed from the viewport, and the viewport only
    /// means anything once there is an image in it. With none, the fit scale
    /// is against a 1×1 placeholder and the pill showed "Fit · 158,000 %".
    func testZoomReadoutFollowsTheImage() throws {
        let session = Session()
        session.viewportChanged()
        XCTAssertEqual(session.zoomPercent, 0, "no image, no zoom to report")

        let tex = try XCTUnwrap(session.renderer.store.makeWritable(width: 1000, height: 500))
        session.renderer.viewport.backingScale = 2
        session.renderer.viewport.resize(viewport: CGSize(width: 500, height: 500))
        session.renderer.setLive(tex)     // fits, and must refresh the readout itself
        XCTAssertEqual(session.zoomPercent, 100, "a 1000 pt image fitted to 500 pt at 2× is 100 %")
        XCTAssertTrue(session.isFit)
    }
}
