//  ExportPanelTests.swift — the export page's two side cards, and the tab that
//  hangs off one of them.
//
//  The user settled the tab's open question the other way: it is "non-fixed",
//  with "one narrowest and widest for both the collapse tabs". So the thing
//  worth pinning is not where the tab is but that it *follows the edge* — that
//  nothing positions it off a width constant, which is the defect that would
//  leave it sitting where the card used to end.
//
//  Its position cannot be checked by a capture: `HoverEdgeTab` is invisible
//  until the pointer is on it, so every snapshot of this page shows a tab that
//  is not there. Hosting the window and measuring the band is the check that
//  can see it, and it is the same one `CanvasViewTests` makes of the editor's
//  three bands.

import AppKit
import Metal
import SwiftUI
import XCTest

@MainActor
final class ExportPanelTests: XCTestCase {

    private let leftKey = "ui.panelWidth.export.left"
    private let foldKey = Session.uiKey + "exportSettingsCollapsed"
    private var savedLeft: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedLeft = UserDefaults.standard.object(forKey: leftKey)
        UserDefaults.standard.removeObject(forKey: foldKey)
    }

    /// Trap 24: a test that depends on a persisted setting sets it and puts
    /// back what it found. These keys are the page's own, and a run that left
    /// a width behind would move the next person's window.
    override func tearDown() async throws {
        if let savedLeft { UserDefaults.standard.set(savedLeft, forKey: leftKey) }
        else { UserDefaults.standard.removeObject(forKey: leftKey) }
        UserDefaults.standard.removeObject(forKey: foldKey)
        try await super.tearDown()
    }

    /// Host the page in a window and hand back the **pill's** leading edge, in
    /// window coordinates so two hosts can be compared.
    ///
    /// The pill, not the band: the band is deliberately offset seven points
    /// outward so it can be reached from the panel side as well as the canvas
    /// side (`HoverEdgeTab.bandShift`), which puts its own leading edge off the
    /// window when the card is folded. The pill is the thing that is
    /// positioned, and the pill is what has to be on the edge.
    private func pillX(width: CGFloat, folded: Bool = false,
                       mode: ExportPage.Mode = .viewer) throws -> CGFloat {
        UserDefaults.standard.set(Double(width), forKey: leftKey)
        UserDefaults.standard.set(folded, forKey: foldKey)

        let host = NSHostingView(rootView: ExportWindow(session: Session(), startIn: mode))
        let frame = CGRect(x: 0, y: 0, width: Theme.Metric.Export.width,
                           height: Theme.Metric.Export.height)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        // The page reads its widths in `onAppear`; one layout pass is not
        // always enough for SwiftUI to have put the subviews up.
        host.layoutSubtreeIfNeeded()

        func bands(in view: NSView) -> [HoverBand.Band] {
            (view as? HoverBand.Band).map { [$0] } ?? view.subviews.flatMap(bands(in:))
        }
        let found = bands(in: host)
        XCTAssertEqual(found.count, 1, "one band — only the settings card folds")
        let band = try XCTUnwrap(found.first)
        XCTAssertGreaterThan(band.bounds.height, 0)
        return band.convert(band.pillRect, to: nil).minX
    }

    /// The tab is on the settings card's trailing edge, so moving that edge
    /// moves the tab by the same amount. A tab positioned off `leftWidth`
    /// would not move at all, and this is the assertion that says so.
    func testTheCollapseTabFollowsTheSettingsCardEdge() throws {
        let standard = try pillX(width: Theme.Metric.Export.leftWidth)
        let wide = try pillX(width: Theme.Metric.Export.leftWidth + 120)
        XCTAssertEqual(wide - standard, 120, accuracy: 1,
                       "the tab should track the card's trailing edge, not a constant")
    }

    /// And it holds at both bounds, which is where a wrong constant would be
    /// most visible — the tab left standing where the drawing used to end.
    func testTheTabIsOnTheEdgeAtBothBounds() throws {
        let range = Theme.Metric.Export.leftRange
        let narrow = try pillX(width: range.narrowest)
        let wide = try pillX(width: range.widest)
        XCTAssertEqual(wide - narrow, range.widest - range.narrowest, accuracy: 1)
        // The narrowest tab is the drawing's own minus what the card gave up.
        let standard = try pillX(width: range.standard)
        XCTAssertEqual(narrow, standard - (range.standard - range.narrowest), accuracy: 1)
    }

    /// Folded, the card is out of the layout entirely, so the canvas — and the
    /// tab hung off it — is at the window's leading edge. This is the case the
    /// editor got wrong once, when the band belonged to a row that could fold.
    func testTheTabIsAtTheWindowEdgeWhenTheCardIsFolded() throws {
        let x = try pillX(width: Theme.Metric.Export.leftWidth, folded: true)
        XCTAssertEqual(x, 0, accuracy: 1,
                       "a folded card leaves the canvas — and the tab — at the window's edge")
    }

    /// **Grid mode is the second drawing's arrangement**: the centre pane and
    /// the filmstrip are one card, so what the tab hangs off is a different
    /// card than in Viewer — reached by the grid's own gap rather than by the
    /// resize handle. It still follows that edge, which is the whole point of
    /// the tab being non-fixed.
    /// The strip is the export batch, not the library: render the actual strip
    /// view with three picked frames out of four and count its three white cell
    /// outlines. This deliberately renders `stripPanel`, the smallest existing
    /// view containing the production `ForEach`, rather than reproducing the
    /// loop in a test-only view.
    func testTheExportStripRendersExactlySelectedFramesCountCells() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-export-strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<4 {
            try Data().write(to: dir.appending(path: String(format: "frame-%02d.png", i)))
        }

        let session = Session()
        session.open(urls: [dir])
        XCTAssertEqual(session.frames.count, 4)
        let urls = session.frames.map(\.id)
        session.click(urls[0])
        session.click(urls[1], command: true)
        session.click(urls[2], command: true)
        XCTAssertEqual(session.selectedFrames.count, 3)

        let page = ExportPage(session: session)
        let host = NSHostingView(rootView: page.stripPanel
            .frame(width: 180, height: 800))
        host.frame = CGRect(x: 0, y: 0, width: 180, height: 800)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Hosting view produced no bitmap; the cell count cannot run")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let image = rep.cgImage else {
            XCTFail("Hosting view bitmap produced no CGImage; the cell count cannot run")
            return
        }

        // Every chosen strip cell has a long near-white top and bottom outline;
        // labels and rounded corners are much shorter and do not pass this
        // horizontal-run threshold. Pair those six outline bands into cells.
        let bytes = rgbaBytes(of: image)
        let bands = (0..<image.height).filter { y in
            var bright = 0
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                if bytes[i] >= 225 && bytes[i + 1] >= 220 && bytes[i + 2] >= 210 { bright += 1 }
            }
            return bright >= image.width / 2
        }
        var runs = 0
        for (index, y) in bands.enumerated() where index == 0 || y > bands[index - 1] + 1 {
            _ = y
            runs += 1
        }
        let maximum = stride(from: 0, to: bytes.count, by: 4).map { max(bytes[$0], max(bytes[$0 + 1], bytes[$0 + 2])) }.max() ?? 0
        XCTAssertEqual(runs, 6, "three cells should produce six long outline bands, got \(runs), image \(image.width)x\(image.height), max=\(maximum)")
    }

    /// Read the renderer into a stable RGBA buffer, independent of its source
    /// pixel format.
    private func rgbaBytes(of image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    func testTheTabFollowsTheGridCardsEdgeInGridMode() throws {
        let width = Theme.Metric.Export.leftWidth
        // The edge itself does not move between modes — what changes is which
        // card is behind the pill, and that is not something a band's frame
        // can see. What this can see is that the rule holds in Grid too.
        let grid = try pillX(width: width, mode: .grid)

        let wide = try pillX(width: width + 120, mode: .grid)
        XCTAssertEqual(wide - grid, 120, accuracy: 1,
                       "the tab tracks the grid card's leading edge like any other")

        let folded = try pillX(width: width, folded: true, mode: .grid)
        XCTAssertEqual(folded, 0, accuracy: 1,
                       "folded, the grid card takes the whole window and the tab is on its edge")
    }

    /// The page's proof is rendered at full file size, but what it holds is the
    /// one display downsample: no image in the `SoftProof` may exceed the
    /// pane-derived bound. The file metadata and the statistics still describe
    /// the full-size render, so the caption cannot inherit the pane size.
    func testTheDisplayProofIsBoundedByThePaneWhileFileMetadataStaysFullSize() throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(Renderer(device: gpu))
        let fileSize = (w: 2048, h: 1536)
        let texture = try XCTUnwrap(renderer.store.makeWritable(width: fileSize.w,
                                                                 height: fileSize.h))
        let target = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let stats = OutputTransformStats(movedFraction: 0.75,
                                         clippedFraction: 0.125,
                                         outsideFraction: 0.25)
        let rendered = Exporter.Rendered(texture: texture, stats: stats, target: target,
                                         pixels: (fileSize.w, fileSize.h), appliedEV: nil)
        let pane = CGSize(width: 500, height: 320)
        let maxEdge = SoftProof.displayMaxEdge(for: pane)
        XCTAssertEqual(maxEdge, 1000)

        let proof = try XCTUnwrap(SoftProof.make(from: rendered, renderer: renderer,
                                                 targetName: "sRGB",
                                                 displayMaxEdge: maxEdge))
        let bound = 2 * Int(max(pane.width, pane.height))
        XCTAssertLessThanOrEqual(max(proof.displayImage.width, proof.displayImage.height), bound)
        XCTAssertEqual(proof.displayImage.width, 1000)
        XCTAssertEqual(proof.displayImage.height, 750)

        // These are measurements of the file, not of the image on screen.
        XCTAssertEqual(Int(proof.filePixelSize.width), fileSize.w)
        XCTAssertEqual(Int(proof.filePixelSize.height), fileSize.h)
        XCTAssertEqual(proof.compressedFraction, stats.outsideFraction)
        XCTAssertEqual(proof.clippedFraction, stats.clippedFraction)
        XCTAssertEqual(proof.movedFraction, stats.movedFraction)
    }
}
