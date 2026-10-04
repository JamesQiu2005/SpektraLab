//  FrameOrderTests.swift — dragging a thumbnail along the filmstrip.
//
//  The defect these pin: a thumbnail dragged to a new place in the strip was
//  taken by the window's own file drop, which opened it as a file handed to
//  the app — and the folder was replaced by that one frame.

import XCTest

@MainActor
final class FrameOrderTests: XCTestCase {
    private func folder(_ names: [String]) throws -> (Session, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: FrameOrder.url(for: dir))
        }
        for n in names { try Data().write(to: dir.appending(path: n)) }
        let suite = "spk-order-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let session = Session(clipboardDefaults: defaults)
        session.open(urls: [dir])
        return (session, session.frames.map(\.id))
    }

    private func names(_ session: Session) -> [String] { session.frames.map(\.id.lastPathComponent) }

    func testAThumbnailLetGoOverTheWindowDoesNotReplaceTheFolder() throws {
        let (session, urls) = try folder(["a.png", "b.png", "c.png", "d.png"])
        XCTAssertEqual(session.frames.count, 4)
        // The strip's own drag, dropped on the window (the canvas, a rail).
        session.draggedFrame = urls[2]
        session.dropped(files: [urls[2]])
        XCTAssertEqual(session.frames.count, 4, "the folder is still open")
        XCTAssertNil(session.selection, "and nothing was put on the canvas by it")
        XCTAssertNil(session.draggedFrame)
        // The same file from Finder: on the canvas, the folder still around it.
        session.dropped(files: [urls[2]])
        XCTAssertEqual(session.frames.count, 4)
        XCTAssertEqual(session.selection, urls[2])
        // A file from somewhere else is opened, as it always was.
        let other = FileManager.default.temporaryDirectory.appending(path: "spk-order-\(UUID().uuidString).png")
        try Data().write(to: other)
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        session.dropped(files: [other])
        XCTAssertEqual(names(session), [other.lastPathComponent])
    }

    func testADragAlongTheStripMovesTheFrameAndTheFolderKeepsTheOrder() throws {
        let (session, urls) = try folder(["a.png", "b.png", "c.png", "d.png"])
        let dir = urls[0].deletingLastPathComponent()
        // Right: the dragged cell takes the place of the one it is over.
        session.moveFrame(urls[0], onto: urls[2])
        XCTAssertEqual(names(session), ["b.png", "c.png", "a.png", "d.png"])
        // Left.
        session.moveFrame(urls[3], onto: urls[1])
        XCTAssertEqual(names(session), ["d.png", "b.png", "c.png", "a.png"])
        session.frameOrderChanged()

        // Opened again — with a frame added to the folder since.
        try Data().write(to: dir.appending(path: "bb.png"))
        let suite = "spk-order-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let again = Session(clipboardDefaults: defaults)
        again.open(urls: [dir])
        // The new frame follows the frame it follows by name (b).
        XCTAssertEqual(names(again), ["d.png", "b.png", "bb.png", "c.png", "a.png"])
    }

    func testAnOrderNamesOnlyWhatItKnows() {
        func frames(_ n: [String]) -> [Frame] { n.map { Frame(id: URL(fileURLWithPath: "/tmp/x/\($0)")) } }
        let listed = frames(["a", "b", "c", "d"])
        XCTAssertEqual(FrameOrder.ordered(listed, by: ["c", "a"]).map(\.id.lastPathComponent), ["c", "d", "a", "b"])
        XCTAssertEqual(FrameOrder.ordered(listed, by: []).map(\.id.lastPathComponent), ["a", "b", "c", "d"])
        XCTAssertEqual(FrameOrder.ordered(listed, by: ["gone", "d", "d", "a"]).map(\.id.lastPathComponent),
                       ["d", "a", "b", "c"])
        // Frames from two folders have no one order.
        XCTAssertNil(FrameOrder.folder(of: [URL(fileURLWithPath: "/tmp/x/a"), URL(fileURLWithPath: "/tmp/y/b")]))
    }
}
