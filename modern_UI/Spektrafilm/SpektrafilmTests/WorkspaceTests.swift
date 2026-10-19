//  WorkspaceTests.swift — Library | Edit, the switch between the window's two
//  surfaces (2.0).
//
//  The owner could find no way between the Library and the frame being edited:
//  the Library was a window reached only from the menus. These hold what the
//  switch promises — it is where they asked for it, in both surfaces at the
//  same place; Develop goes back to Edit on the frame; and in the Library the
//  editor's single keys leave the grid alone.

import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@MainActor
final class WorkspaceTests: XCTestCase {
    /// The app opens on the editor, as 1.x did, and the switch reads in the
    /// order a frame travels: from the Library to Edit.
    func testTheWindowOpensOnEditAndTheSwitchStartsWithTheLibrary() {
        XCTAssertEqual(Session().workspace, .edit)
        XCTAssertEqual(Workspace.allCases, [.library, .edit])
    }

    /// Under the left rail's name and above its first section, at the same
    /// place in both surfaces — so the pointer that used it is still on it —
    /// and on the same row as the right rail's Pre-Dev | Post-Dev switch.
    func testTheSwitchIsAtOnePlaceInBothSurfaces() throws {
        let session = Session()
        let library = LibraryModel(session: session,
                                   defaults: UserDefaults(suiteName: "spk-workspace-\(UUID().uuidString)")!)
        let window = host(EditorWindow(session: session, library: library), size: CGSize(width: 1920, height: 1080))

        let inEdit = try XCTUnwrap(workspaceSwitch, "no Library | Edit switch in the editor")
        let parameters = try XCTUnwrap(parametersSwitch, "no Pre-Dev | Post-Dev switch to line up with")
        XCTAssertLessThan(inEdit.maxX, 1920 / 2, "the switch is not in the left rail")
        XCTAssertEqual(inEdit.midY, parameters.midY, accuracy: 0.5, "the two rails' switches are not on one row")
        XCTAssertGreaterThanOrEqual(inEdit.minY, Theme.Metric.panelHeaderHeight - 0.5,
                                    "the switch is not under the rail's name")

        session.workspace = .library
        settle(window)
        let inLibrary = try XCTUnwrap(workspaceSwitch, "no switch in the Library")
        XCTAssertEqual(inLibrary, inEdit, "the switch moved when it was used")
        XCTAssertNil(parametersSwitch, "the editor's rails are still on screen behind the Library")

        session.workspace = .edit
        settle(window)
        XCTAssertEqual(workspaceSwitch, inEdit, "the way back put the switch somewhere else")
        XCTAssertNotNil(parametersSwitch, "the editor did not come back")
    }

    /// Without a Library (a window made in a test), the switch's Library side
    /// cannot be chosen, and the window stays on the editor.
    func testWithoutALibraryTheWindowStaysOnTheEditor() {
        let session = Session()
        session.workspace = .library
        let window = host(EditorWindow(session: session), size: CGSize(width: 1512, height: 982))
        XCTAssertNotNil(parametersSwitch, "a window with no Library showed no editor")
        _ = window
    }

    /// In the Library the editor's single-key shortcuts are off: the menu
    /// takes a key before the grid that has focus, so an enabled ← would
    /// step a frame no one can see instead of the grid's selection.
    func testTheLibraryLeavesTheEditorsKeysAlone() {
        let session = Session()
        XCTAssertTrue(session.editing)
        session.workspace = .library
        XCTAssertFalse(session.editing)
    }

    /// Develop goes back to Edit on the photo; a photo that cannot be
    /// developed leaves the Library on screen, where its reason is shown.
    func testDevelopGoesToEditOnThePhoto() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "vendor/spklib/macos/spklib-host")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path),
                          "vendor/spklib/macos/spklib-host is not in this checkout")
        let session = Session()
        let library = LibraryModel(session: session,
                                   defaults: UserDefaults(suiteName: "spk-workspace-\(UUID().uuidString)")!,
                                   launch: .init(executable: helper, store: dir.appending(path: "store")))
        addTeardownBlock { await library.close() }
        await library.create(.catalog, at: dir.appending(path: "Test.spkcatalog"))
        await library.add([try photo("a.jpg", in: dir)], copy: false)
        try await waitUntil("the catalog's rows") { library.rows.count == 1 && !library.loading }
        session.workspace = .library

        library.developInEditor("no-such-photo")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.workspace, .library, "a photo that was not developed left the Library")

        library.developInEditor(library.rows[0].uuid)
        try await waitUntil("Edit") { session.workspace == .edit }
        try await waitUntil("the photo on the canvas") { session.selection == library.rows[0].url }
    }

    // MARK: - helpers

    /// The window in a real `NSWindow`, laid out, with the switches' places
    /// from any earlier window forgotten.
    private func host<V: View>(_ view: V, size: CGSize) -> NSWindow {
        SwitchPlacement.frames = [:]
        let hosting = NSHostingView(rootView: view.environment(\.snapshotMode, true))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // A window made in code releases itself on close, and ARC releases
        // it again: the test process crashed in teardown.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrame(CGRect(origin: .zero, size: size), display: true)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        addTeardownBlock { window.close() }
        return window
    }

    private var workspaceSwitch: CGRect? { SwitchPlacement.frames[WorkspaceSwitch.accessibilityName] }
    private var parametersSwitch: CGRect? { SwitchPlacement.frames[L(.railParameters)] }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func photo(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ what: String, timeout: Double = 20, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
