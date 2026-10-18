//  EditHistoryTests.swift — Undo and Redo for the grade: one step a gesture,
//  in one timeline with the sidecar's own stack, per frame.

import XCTest

final class EditHistoryTests: XCTestCase {

    // MARK: - the value history

    func testAStepIsItsBeforeAndAfterAndANewStepEndsRedo() {
        var h = EditHistory<Int>(limit: 3)
        h.record(from: 0, to: 0, stamp: 1)
        XCTAssertFalse(h.canUndo, "a gesture that changed nothing records nothing")
        h.record(from: 0, to: 1, stamp: 2)
        h.record(from: 1, to: 2, stamp: 3)
        XCTAssertEqual(h.undo()?.before, 1)
        XCTAssertEqual(h.redo()?.after, 2)
        XCTAssertEqual(h.undo()?.before, 1)
        h.record(from: 1, to: 5, stamp: 4)
        XCTAssertFalse(h.canRedo, "a new step is not followed by what was undone")
        h.record(from: 5, to: 6, stamp: 5); h.record(from: 6, to: 7, stamp: 6)
        XCTAssertEqual(h.past.count, 3, "held to its limit, oldest first out")
        XCTAssertEqual(h.lastStamp, 6)
    }
}

@MainActor
final class Layer2HistorySessionTests: XCTestCase {
    private func session(_ name: String = "a.tif") -> Session {
        let s = Session()
        s.selection = URL(fileURLWithPath: "/nonexistent/layer2-history/\(name)")
        return s
    }

    /// **One gesture, one step**, however many values it set. 1.3's stack
    /// took a snapshot at most every half second, so a two-second drag was
    /// four steps and Undo walked back through the middle of it.
    ///
    /// **Seen red** with the gesture's begin and end left out of the setter's
    /// guard: every one of the 40 values was a step.
    func testADragIsOneStep() {
        let s = session()
        s.beginLayer2Gesture()
        for i in 1...40 { var a = s.adjustments; a.exposure = Double(i) / 20; s.adjustments = a }
        s.endLayer2Gesture()
        XCTAssertEqual(s.layer2History?.past.count, 1)
        XCTAssertEqual(s.undoMenuTitle, L("Undo Adjustment", zh: "撤销调整"))
        s.undoLatest()
        XCTAssertEqual(s.adjustments.exposure, 0)
        XCTAssertTrue(s.canRedoAdjustment)
        s.redoAdjustment()
        XCTAssertEqual(s.adjustments.exposure, 2)
        XCTAssertFalse(s.canRedoAdjustment)
    }

    /// A change with no gesture open — a double-click, a typed value, a
    /// Reset — is a step of its own, and a gesture that ends where it began
    /// is none.
    func testADiscreteChangeIsAStepAndANoOpGestureIsNone() {
        let s = session()
        var a = s.adjustments; a.contrast = 10; s.adjustments = a
        a.contrast = 0; s.adjustments = a
        XCTAssertEqual(s.layer2History?.past.count, 2)
        s.beginLayer2Gesture()
        a.contrast = 5; s.adjustments = a
        a.contrast = 0; s.adjustments = a
        s.endLayer2Gesture()
        XCTAssertEqual(s.layer2History?.past.count, 2, "a gesture that came back to where it began")
    }

    /// The grade's steps and the sidecar's are one timeline: ⌘Z takes the
    /// newer, and its title says which. A change outside the grade ends the
    /// grade's redo.
    func testUndoFollowsTheOrderThingsWereDoneIn() {
        let s = session()
        var p = s.params; p.exposureCompensationEV = 0.5; s.params = p        // the sidecar's stack
        var a = s.adjustments; a.saturation = 20; s.adjustments = a           // the grade's
        XCTAssertEqual(s.nextUndo, .grade)
        s.undoLatest()
        XCTAssertEqual(s.adjustments.saturation, 0)
        XCTAssertEqual(s.params.exposureCompensationEV, 0.5, "the older Pre-Dev change is still there")
        XCTAssertEqual(s.nextUndo, .settings)
        XCTAssertEqual(s.undoMenuTitle, L("Undo", zh: "撤销"))
        s.undoLatest()
        XCTAssertEqual(s.params.exposureCompensationEV, 0)
        // Redo of the grade survives the sidecar's undo of an older step …
        XCTAssertTrue(s.canRedoAdjustment)
        // … but not a new change elsewhere.
        p = s.params; p.exposureCompensationEV = -0.3; s.params = p
        XCTAssertFalse(s.canRedoAdjustment)
    }

    /// A frame's history is that frame's: another frame's steps are never
    /// undone onto it.
    func testEachFrameHasItsOwnHistory() {
        let s = session("one.tif")
        let one = s.selection!
        var a = s.adjustments; a.tint = 12; s.adjustments = a
        s.selection = URL(fileURLWithPath: "/nonexistent/layer2-history/two.tif")
        XCTAssertNil(s.layer2History, "the second frame has no grade history")
        XCTAssertEqual(s.nextUndo, .nothing)
        s.selection = one
        XCTAssertEqual(s.layer2History?.past.count, 1)
    }

    /// Nothing moves the open frame's grade during a batch export (AGENTS
    /// trap 34), undo included.
    func testUndoAndRedoWaitForABatchExport() {
        let s = session()
        var a = s.adjustments; a.shadows = 30; s.adjustments = a
        s.batchExporting = true
        defer { s.batchExporting = false }
        XCTAssertFalse(s.canUndoLatest)
        s.undoLatest()
        XCTAssertEqual(s.adjustments.shadows, 30)
    }
}
