//  SelectionModelTests.swift — the picked set, and the two gestures that move
//  frames in and out of it.
//
//  The set is what an export's batch is (`ExportPage.batch` is
//  `session.selectedFrames`), so every rule here is a rule about which
//  photographs get written. Four of them:
//
//  * a plain click picks exactly one frame, collapsing whatever set there was;
//  * ⌘-click toggles one frame, in both directions;
//  * the frame on the canvas cannot be removed from the set;
//  * the filmstrip and the Browse grid draw the same marks, from the one
//    function that decides them.
//
//  No decode is needed for any of this — the set is URLs — so the fixtures are
//  empty files with openable extensions, in a temporary folder. That also
//  keeps the suite away from `tests/Test_image/`, which the checkout's copy
//  shares with every other suite (`develop-writes-a-sidecar-copy-the-fixture`).

import AppKit
import XCTest

@MainActor
final class SelectionModelTests: XCTestCase {

    /// A folder of four frames, opened as a session. Opening a folder lands in
    /// Browse with nothing picked, which is the state the first rule starts
    /// from.
    private func openedSession(frameCount: Int = 4) throws -> (Session, [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-pick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<frameCount {
            // Named so `Library` sorts them, and with an extension it opens.
            try Data().write(to: dir.appending(path: String(format: "frame-%02d.png", i)))
        }
        let session = Session()
        session.open(urls: [dir])
        // The URLs come back **out of** the session rather than being the ones
        // written above: `temporaryDirectory` hands out `/var/…` and the
        // directory listing hands back `/private/var/…`, so the same file has
        // two spellings and `Set<URL>` is a string comparison. Taking them from
        // `frames` is what the app itself does — every click in the UI is on a
        // `Frame.id` — so this is the closer test, not the looser one.
        XCTAssertEqual(session.frames.count, frameCount,
                       "the fixture is not the session this test assumes")
        return (session, session.frames.map(\.id))
    }

    /// A plain click: exactly one frame, and it opens.
    ///
    /// The collapse is the whole point — a click that merely *added* would
    /// leave the previous picks in the batch, and the export would write
    /// photographs the person had already moved on from.
    func testAPlainClickPicksOneFrameAndOpensIt() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])
        session.click(urls[1], command: true)
        session.click(urls[2], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0], urls[1], urls[2]])

        session.click(urls[3])
        XCTAssertEqual(session.selectedFrames, [urls[3]], "a plain click did not collapse the set")
        XCTAssertEqual(session.selection, urls[3], "a plain click did not open the frame")
    }

    /// The export-page gesture opens a picked frame without changing the batch.
    func testOpeningAnExportCellMovesSelectionAndLeavesPickedUnchanged() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])
        session.click(urls[1], command: true)
        let picked = session.selectedFrames

        session.open(urls[1])
        XCTAssertEqual(session.selection, urls[1])
        XCTAssertEqual(session.selectedFrames, picked,
                       "opening an export cell changed the picked set")
    }

    /// The export-page gesture refuses a frame outside the batch (§2.3: the
    /// proof is of a frame in the batch, so the guard is the rule).
    func testOpeningAnUnpickedCellIsANoOp() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])
        session.click(urls[1], command: true)

        session.open(urls[3])
        XCTAssertEqual(session.selection, urls[0],
                       "opening an unpicked cell moved the canvas")
    }

    /// While a batch export runs, no gesture moves the open frame or the set.
    ///
    /// The exporter writes whatever frame is open, so a click that landed
    /// between the run's `select` and its write put one frame's render under
    /// another's file name. Seen red by removing the `batchExporting` guards.
    func testABatchExportHoldsTheFrameAndTheSet() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])
        session.click(urls[1], command: true)
        let picked = session.selectedFrames

        session.batchExporting = true
        session.click(urls[2])
        session.click(urls[3], command: true)
        session.click(urls[1], command: true)
        session.open(urls[1])
        session.stepFrame(1)
        XCTAssertEqual(session.selection, urls[0], "a gesture moved the open frame mid-batch")
        XCTAssertEqual(session.selectedFrames, picked, "a gesture changed the batch mid-batch")

        // The run's own door stays open.
        session.select(urls[1])
        XCTAssertEqual(session.selection, urls[1])

        session.batchExporting = false
        session.click(urls[2])
        XCTAssertEqual(session.selection, urls[2], "the lock outlived the batch")
    }

    /// ⌘-click toggles, both directions, and never moves the canvas.
    func testCommandClickTogglesAndLeavesTheCanvasAlone() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])

        session.click(urls[2], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0], urls[2]])
        XCTAssertEqual(session.selection, urls[0],
                       "⌘-click moved the canvas — notes.md says the viewed image stays put")

        session.click(urls[2], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0]], "⌘-click did not remove")
        XCTAssertEqual(session.selection, urls[0])

        // And it toggles *the set*, not "everything after the open frame":
        // ⌘-clicking a frame that was never picked, twice, is a round trip.
        session.click(urls[3], command: true)
        session.click(urls[3], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0]])
    }

    /// The open frame can never leave the set, however it is clicked.
    ///
    /// A batch that excludes the photograph on the canvas is a state with
    /// nothing to read off it: the export page proves the frame it is about to
    /// write, so the alternative is a proof of a picture the run will not
    /// produce. It is also one ⌘-click away, which is how a person loses a
    /// selection they did not mean to lose.
    func testTheOpenFrameCannotBePickedOff() throws {
        let (session, urls) = try openedSession()
        session.click(urls[1])
        session.click(urls[0], command: true)
        session.click(urls[2], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0], urls[1], urls[2]])

        session.click(urls[1], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0], urls[1], urls[2]],
                       "⌘-clicking the open frame removed it from the batch")
        XCTAssertEqual(session.selection, urls[1], "…and it moved the canvas doing it")

        // The way to drop it is to open another frame, which is a plain click
        // — and that collapses the set, so the frame it left is gone too. Both
        // are the same rule: the set is never short of the open frame.
        session.click(urls[2])
        XCTAssertEqual(session.selectedFrames, [urls[2]])
        XCTAssertTrue(session.selectedFrames.contains(try XCTUnwrap(session.selection)))
    }

    /// The set is dropped with the library, and with a frame that goes.
    ///
    /// `selectedFrames` maps over `frames`, so a url left behind is invisible
    /// — the batch would be short by one with nothing on screen to say which.
    func testTheSetFollowsTheLibrary() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])
        session.click(urls[3], command: true)
        XCTAssertEqual(session.selectedFrames, [urls[0], urls[3]])

        session.remove(urls[3])
        XCTAssertEqual(session.selectedFrames, [urls[0]],
                       "a removed frame is still in the batch")
        // …and the set itself, not only the batch it projects to. The two are
        // not the same assertion: `selectedFrames` maps over `frames` and
        // filters, so a url left behind in `picked` is *invisible* through it
        // — which is the whole reason the invariant is `picked ⊆ frames` and
        // not "whatever the batch comes back as".
        XCTAssertFalse(session.picked.contains(urls[3]),
                       "the set kept a frame that is no longer in the library")

        // A new folder is a new set: the old picks are not photographs of this
        // one, and there is no frame here they could still name.
        let (other, _) = try openedSession(frameCount: 2)
        other.open(urls: [urls[0]])
        XCTAssertEqual(other.selectedFrames, [urls[0]])
        other.open(urls: [urls[0].deletingLastPathComponent()])
        XCTAssertEqual(other.selectedFrames, [],
                       "opening a folder carried a set over from the last one")
        XCTAssertTrue(other.picked.isEmpty,
                      "…and the set kept a frame from the last library, which the batch "
                      + "hides because it is no longer in `frames`")
    }

    /// The two surfaces agree, and they agree **by construction**.
    ///
    /// Both ask `Session.framing(of:)`, spelled the same way, and neither
    /// compares `selection` itself. The last assertion is a source scan, which
    /// this suite does once and only here: what it protects is that there is
    /// *one* expression deciding a cell's mark, and that is not a thing a
    /// rendered strip can tell you — an offscreen render of two views that
    /// each decided correctly would look identical to one where they did not.
    func testBothSurfacesAskTheOneFunction() throws {
        let (session, urls) = try openedSession()
        session.click(urls[0])
        session.click(urls[2], command: true)

        // The marks, exhaustively: open, picked, neither.
        XCTAssertEqual(session.framing(of: urls[0]), .open)
        XCTAssertEqual(session.framing(of: urls[2]), .picked)
        XCTAssertEqual(session.framing(of: urls[1]), .none)

        // The open frame is the strongest mark; a picked frame is framed
        // more weakly, which is what makes the two readable apart on a
        // thumbnail that can be any colour.
        XCTAssertGreaterThan(FrameFraming.open.lineWidth, FrameFraming.picked.lineWidth)
        XCTAssertGreaterThan(FrameFraming.open.opacity, FrameFraming.picked.opacity)
        XCTAssertGreaterThan(FrameFraming.picked.opacity, FrameFraming.none.opacity)
        XCTAssertFalse(FrameFraming.none.isFramed)

        // One rule, and every call site spells it the same way. `BrowseView`
        // was the second site until the Browse grid was removed (2026-09-17);
        // the filmstrip is the only list of frames now, so this guards the
        // one that is left rather than pretending there are still two.
        for file in ["Panels/Filmstrip.swift"] {
            XCTAssertTrue(try source(file).contains("framing: session.framing(of: frame.id)"),
                          "\(file) does not ask Session how to mark a cell")
        }
    }

    // MARK: - helpers

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SpektrafilmTests
            .deletingLastPathComponent()   // Spektrafilm
            .appending(path: "Spektrafilm/\(relative)")
        return try String(contentsOf: root, encoding: .utf8)
    }
}
