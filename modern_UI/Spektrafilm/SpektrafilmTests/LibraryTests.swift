//  LibraryTests.swift — the 2.0 library helper, driven from Swift exactly as
//  the app drives it: the vendored `spklib-host` as a child process, a store
//  in a temporary folder, and `Session` handed a library's frames.
//
//  What these hold, in the order it matters:
//
//  * **The 1.x path is untouched.** A folder still reads and writes sidecar
//    files, and leaving a library puts them back. A library frame's edit never
//    lands in a sidecar file, and a folder frame's never lands in a library.
//  * **A new catalog and a new session can be made**, with the folders a
//    session promises, and refused when one is already there.
//  * **An edit survives the pipe bit for bit**, including a Double that
//    `JSONSerialization` would re-print.
//  * **The store never saves over what it has not read**, never stores an
//    edit for a photo merely looked at, adopts a 1.x sidecar without moving
//    it from beside the photograph, and stops on `conflict` instead of
//    retrying blindly.
//
//  No fixture from `tests/` is needed: the images are made here, so the suite
//  runs in a worktree without the fixtures link.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class LibraryTests: XCTestCase {

    // MARK: - fixtures

    private static var helper: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "vendor/spklib/macos/spklib-host")
    }

    private var hosts: [LibraryHost] = []

    private func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-library-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func host(in dir: URL) throws -> LibraryClient {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.helper.path),
                          "vendor/spklib/macos/spklib-host is not in this checkout")
        let h = LibraryHost(launch: .init(executable: Self.helper, store: dir.appending(path: "store")))
        hosts.append(h)
        return LibraryClient(host: h)
    }

    override func tearDown() async throws {
        for h in hosts { await h.shutdown() }
        hosts = []
        try await super.tearDown()
    }

    /// A small real JPEG, so a frame can decode if a test opens it.
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
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A catalog with `photos` in it, by reference, and its handle.
    private func catalog(with photos: [URL], client: LibraryClient, in dir: URL) async throws
        -> (handle: String, path: URL, images: [LibraryImage]) {
        let made = try await client.create(at: dir.appending(path: "Test.spkcatalog"), kind: .catalog, name: "Test")
        let added = try await client.add(made.library, photos.map { LibraryClient.AddItem(url: $0) }, copy: false)
        XCTAssertEqual(added.added, photos.count)
        let page = try await client.images(made.library, LibraryQuery(sort: .name), offset: 0, limit: 100)
        return (made.library, URL(fileURLWithPath: made.info.path), page.images)
    }

    private func edited() -> Sidecar {
        var s = Sidecar()
        s.params.filmStock = "kodak_ektar_100"
        s.params.exposureCompensationEV = 0.1 + 0.2   // 0.30000000000000004
        s.geometry.flipH = true
        s.state = .processed
        return s
    }

    // MARK: - the helper

    func testTheHelperStartsOnFirstCallAndSpeaksABI1() async throws {
        let dir = try scratch("version")
        let client = try host(in: dir)
        let before = await client.host.launches
        XCTAssertEqual(before, 0, "nothing starts until a call")
        let v = try await client.version()
        XCTAssertEqual(v.abi, LibraryHost.abi)
        let after = await client.host.launches
        XCTAssertEqual(after, 1)
    }

    func testANewCatalogAndANewSessionCanBeMade() async throws {
        let dir = try scratch("create")
        let client = try host(in: dir)

        let cat = try await client.create(at: dir.appending(path: "Portfolio.spkcatalog"), kind: .catalog, name: "Portfolio")
        XCTAssertEqual(cat.info.kind, .catalog)
        XCTAssertEqual(cat.info.name, "Portfolio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appending(path: "Portfolio.spkcatalog/Library.spkdb").path))

        let shoot = dir.appending(path: "Shoot")
        let ses = try await client.create(at: shoot, kind: .session, name: "Shoot")
        XCTAssertEqual(ses.info.kind, .session)
        for folder in ["Capture", "Selects", "Output", "Trash"] {
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: shoot.appending(path: folder).path, isDirectory: &isDir)
                          && isDir.boolValue, "a session has \(folder)/")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: shoot.appending(path: "Shoot.spksession").path))
        let roles = try await client.sessionFolders(ses.library).folders.compactMap(\.role)
        XCTAssertEqual(Set(roles), ["capture", "selects", "output", "trash"])

        do {
            _ = try await client.create(at: dir.appending(path: "Portfolio.spkcatalog"), kind: .catalog)
            XCTFail("a second catalog at the same path must be refused")
        } catch let e as LibraryError {
            XCTAssertEqual(e.code, .exists)
        }

        // Reopened by path, as the app does after a restart.
        let again = try await client.open(shoot)
        XCTAssertEqual(again.info.uuid, ses.info.uuid)
    }

    func testASessionScanFindsANewCapture() async throws {
        let dir = try scratch("scan")
        let client = try host(in: dir)
        let shoot = dir.appending(path: "Shoot")
        let ses = try await client.create(at: shoot, kind: .session)
        _ = try photo("A.jpg", in: shoot.appending(path: "Capture"))
        let scan = try await client.sessionScan(ses.library)
        XCTAssertEqual(scan.added, 1)
        let page = try await client.images(ses.library, LibraryQuery(), offset: 0, limit: 10)
        XCTAssertEqual(page.images.map(\.fileName), ["A.jpg"])
    }

    func testAnEditCrossesThePipeBitForBit() async throws {
        let dir = try scratch("edit")
        let client = try host(in: dir)
        let lib = try await catalog(with: [try photo("a.jpg", in: dir)], client: client, in: dir)
        let variant = lib.images[0].variants[0].uuid
        XCTAssertFalse(lib.images[0].variants[0].hasEdit, "the helper answers null for no edit")

        let mine = edited()
        let rev = try await client.putEdit(lib.handle, variant: variant, edit: LibrarySettingsStore.encode(mine), baseRevision: 0)
        XCTAssertEqual(rev, 1)
        let back = try await client.edit(lib.handle, variant: variant)
        XCTAssertEqual(back.revision, 1)
        XCTAssertEqual(back.edit, mine, "the Sidecar comes back identical")
        XCTAssertEqual(back.edit?.params.filmStock, "kodak_ektar_100")
        XCTAssertEqual(back.edit?.params.exposureCompensationEV, 0.1 + 0.2, "a Double is not re-printed")

        do {
            _ = try await client.putEdit(lib.handle, variant: variant, edit: LibrarySettingsStore.encode(Sidecar()), baseRevision: 0)
            XCTFail("an edit on an old revision must be refused")
        } catch let e as LibraryError {
            XCTAssertEqual(e.code, .conflict)
            XCTAssertEqual(e.revision, 1)
        }
    }

    func testAReplyIsRoutedByItsLeadingID() {
        XCTAssertEqual(LibraryJSON.leadingID(Data(#"{"id":7,"result":{}}"#.utf8)), 7)
        XCTAssertEqual(LibraryJSON.leadingID(Data(#"{"id":12345,"error":{}}"#.utf8)), 12345)
        XCTAssertNil(LibraryJSON.leadingID(Data(#"{"event":"ready"}"#.utf8)))
        XCTAssertNil(LibraryJSON.leadingID(Data(#"{"id":"x"}"#.utf8)))
    }

    func testLinesAreSplitAcrossChunks() {
        let s = LineSplitter()
        XCTAssertEqual(s.feed(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"a":1}"#])
        XCTAssertEqual(s.feed(Data(":2}\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"b":2}"#])
    }

    // MARK: - the store

    private func store(for lib: (handle: String, path: URL, images: [LibraryImage]), client: LibraryClient,
                       capacity: Int = 256) async -> (LibrarySettingsStore, [URL]) {
        let conn = LibraryConnection(client: client, path: lib.path, handle: lib.handle, launch: await client.host.launches)
        var refs: [URL: LibrarySettingsStore.Ref] = [:]
        var revisions: [String: Int] = [:]
        for row in lib.images {
            refs[row.url] = .init(image: row.uuid, variant: row.variants[0].uuid)
            revisions[row.variants[0].uuid] = row.variants[0].editRevision ?? 0
        }
        return (LibrarySettingsStore(connection: conn, refs: refs, revisions: revisions, capacity: capacity),
                lib.images.map(\.url))
    }

    func testTheStoreNeverSavesOverWhatItHasNotRead() async throws {
        let dir = try scratch("unread")
        let client = try host(in: dir)
        let lib = try await catalog(with: [try photo("a.jpg", in: dir)], client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client)

        XCTAssertFalse(store.isReady(urls[0]))
        XCTAssertThrowsError(try store.save(edited(), for: urls[0]))
        await store.fetch(urls)
        XCTAssertTrue(store.isReady(urls[0]))
        XCTAssertNil(store.load(for: urls[0]))
    }

    func testAPhotoMerelyLookedAtGetsNoEdit() async throws {
        let dir = try scratch("untouched")
        let client = try host(in: dir)
        let lib = try await catalog(with: [try photo("a.jpg", in: dir)], client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client)
        await store.fetch(urls)

        // What `Session` saves on leaving a RAW it only opened: the as-shot
        // white balance filled in, nothing else.
        var looked = Sidecar()
        looked.decode.temperature = 5123
        looked.decode.tint = 7
        XCTAssertTrue(looked.isUntouched)
        try store.save(looked, for: urls[0])
        await store.flush()
        let none = try await client.edit(lib.handle, variant: lib.images[0].variants[0].uuid)
        XCTAssertEqual(none.revision, 0, "no edit for a photo nobody touched")

        try store.save(edited(), for: urls[0])
        await store.flush()
        let some = try await client.edit(lib.handle, variant: lib.images[0].variants[0].uuid)
        XCTAssertEqual(some.revision, 1)
        XCTAssertEqual(some.edit, edited())

        // The same settings again write nothing.
        try store.save(edited(), for: urls[0])
        await store.flush()
        let same = try await client.edit(lib.handle, variant: lib.images[0].variants[0].uuid)
        XCTAssertEqual(same.revision, 1)
    }

    func testA1xSidecarIsAdoptedWithoutBeingMovedFromBesideThePhoto() async throws {
        let dir = try scratch("adopt")
        let client = try host(in: dir)
        let image = try photo("old.jpg", in: dir)
        let neighbour = Sidecar.neighbourURL(for: image)
        try JSONEncoder().encode(edited()).write(to: neighbour)

        let lib = try await catalog(with: [image], client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client)
        await store.fetch(urls)

        XCTAssertEqual(store.load(for: urls[0]), edited())
        let stored = try await client.edit(lib.handle, variant: lib.images[0].variants[0].uuid)
        XCTAssertEqual(stored.revision, 1, "adopted into the library once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path),
                      "nothing is moved from beside an original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: image).path),
                       "and nothing is written into the 1.x store for it")
    }

    func testAConflictStopsTheWriterAndAsks() async throws {
        let dir = try scratch("conflict")
        let client = try host(in: dir)
        let lib = try await catalog(with: [try photo("a.jpg", in: dir)], client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client)
        var asked: [URL] = []
        store.onConflict = { asked.append($0) }
        await store.fetch(urls)

        // Someone else — another SpektraLab on the same catalog — saves first.
        var theirs = Sidecar()
        theirs.params.filmStock = "fuji_c200"
        _ = try await client.putEdit(lib.handle, variant: lib.images[0].variants[0].uuid,
                                     edit: LibrarySettingsStore.encode(theirs), baseRevision: 0)

        try store.save(edited(), for: urls[0])
        await store.flush()   // must return: a conflicted write waits on the person
        XCTAssertEqual(asked, [urls[0]])
        let kept = try await client.edit(lib.handle, variant: lib.images[0].variants[0].uuid)
        XCTAssertEqual(kept.edit?.params.filmStock, "fuji_c200", "theirs was not overwritten")

        await store.resolveTakingTheirs(urls[0])
        XCTAssertEqual(store.load(for: urls[0])?.params.filmStock, "fuji_c200")
    }

    func testTheCacheIsBoundedAndAnEvictedEditIsReadAgain() async throws {
        let dir = try scratch("bounded")
        let client = try host(in: dir)
        let photos = try (0..<12).map { try photo("p\($0).jpg", in: dir) }
        let lib = try await catalog(with: photos, client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client, capacity: 8)
        await store.fetch(urls)
        XCTAssertLessThanOrEqual(store.cachedCount, 8)
        XCTAssertFalse(store.isReady(urls[0]), "the oldest was evicted")
        await store.fetch([urls[0]])
        XCTAssertTrue(store.isReady(urls[0]))
    }

    // MARK: - Session

    func testSessionDevelopsALibraryFrameIntoTheLibraryAndAFolderIntoSidecars() async throws {
        let dir = try scratch("session")
        let client = try host(in: dir)
        let photos = try (0..<3).map { try photo("f\($0).jpg", in: dir) }
        let lib = try await catalog(with: photos, client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client)
        let session = Session()
        XCTAssertTrue(session.settingsStore === SidecarFileStore.shared, "a folder's store until a library is opened")

        session.open(library: urls, store: store,
                     source: .init(name: "Test", collection: "All Images", readOnly: false), selecting: urls[1])
        XCTAssertTrue(session.frameSource.isLibrary)
        XCTAssertEqual(session.frames.map(\.id), urls)
        try await waitUntil("the library frame to open once its edit is read") { session.selection == urls[1] }

        var g = session.geometry
        g.flipH.toggle()
        session.geometry = g
        await session.flushSettings()
        let stored = try await client.edit(lib.handle, variant: lib.images[1].variants[0].uuid)
        XCTAssertEqual(stored.revision, 1)
        XCTAssertEqual(stored.edit?.geometry.flipH, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: urls[1]).path),
                       "a library frame's edit never lands in a sidecar file")

        // No pairs and no reordering from a library's result.
        XCTAssertFalse(session.canMakePair)
        session.moveFrame(urls[0], onto: urls[2])
        XCTAssertEqual(session.frames.map(\.id), urls)

        // Back to a folder: the 1.x store, the 1.x behaviour.
        let folder = try scratch("session-folder")
        let loose = try photo("loose.jpg", in: folder)
        session.open(urls: [loose])
        XCTAssertTrue(session.settingsStore === SidecarFileStore.shared)
        XCTAssertEqual(session.frameSource, .folder)
        XCTAssertEqual(session.selection, loose)
        var h = session.geometry
        h.flipV.toggle()
        session.geometry = h
        session.flushSave()
        XCTAssertEqual(Sidecar.load(for: loose)?.geometry.flipV, true, "a folder frame's edit is a sidecar file")
        let untouched = try await client.edit(lib.handle, variant: lib.images[1].variants[0].uuid)
        XCTAssertEqual(untouched.revision, 1, "leaving the library wrote nothing more into it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: urls[1]).path),
                       "and the library frame was not flushed into a sidecar file on the way out")
    }

    /// Film ⋯ → Reset All Settings to the RAW Decode on a library frame
    /// clears its edit in the library — and at once: the reset reopens the
    /// frame immediately, and a clear that waited for the pipe reopened it on
    /// the edit it was about to replace. ⌘Z puts the edit back, into the
    /// library. And a history never crosses stores: the same file opened as
    /// a folder frame does not offer the library variant's steps.
    func testResetToDecodeClearsALibraryFrameAndUndoStaysWithItsStore() async throws {
        let dir = try scratch("reset")
        let client = try host(in: dir)
        let photos = try (0..<2).map { try photo("r\($0).jpg", in: dir) }
        let lib = try await catalog(with: photos, client: client, in: dir)
        let (store, urls) = await store(for: lib, client: client)
        let variant = lib.images[1].variants[0].uuid
        let session = Session()
        session.open(library: urls, store: store,
                     source: .init(name: "Test", collection: "All Images", readOnly: false), selecting: urls[1])
        try await waitUntil("the library frame to open") { session.selection == urls[1] }

        var g = session.geometry
        g.flipH = true
        session.geometry = g
        await session.flushSettings()
        let edited = try await client.edit(lib.handle, variant: variant)
        XCTAssertEqual(edited.edit?.geometry.flipH, true)

        session.resetToDecode()
        XCTAssertEqual(session.selection, urls[1])
        XCTAssertFalse(session.geometry.flipH, "the reset reopened the frame on the edit it replaced")
        await session.flushSettings()
        let cleared = try await client.edit(lib.handle, variant: variant)
        XCTAssertFalse(cleared.edit?.geometry.flipH ?? false, "the library still holds the reset frame's edit")
        XCTAssertEqual(cleared.edit?.state ?? .unprocessed, .unprocessed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Sidecar.url(for: urls[1]).path),
                       "a library frame's reset wrote a sidecar file")

        XCTAssertTrue(session.canUndo)
        session.undo()
        XCTAssertTrue(session.geometry.flipH, "⌘Z did not bring the edit back")
        await session.flushSettings()
        let restored = try await client.edit(lib.handle, variant: variant)
        XCTAssertEqual(restored.edit?.geometry.flipH, true, "the edit ⌘Z brought back did not reach the library")

        session.open(urls: [urls[1]])
        XCTAssertEqual(session.selection, urls[1])
        XCTAssertFalse(session.canUndo, "the folder frame offers to undo a library variant's steps")
    }

    /// A developed picture belongs to one set of settings. A file can be a
    /// folder frame with a sidecar and a library frame with an edit per
    /// variant, and the strip shows the picture of the settings the session
    /// is showing — never the sidecar's picture for a library frame because
    /// the sidecar file says "developed".
    func testADevelopedPictureBelongsToOneSettingsStore() throws {
        let dir = try scratch("pictures")
        let frame = try photo("p.jpg", in: dir)
        addTeardownBlock {
            DevelopedThumbnails.show([:])
            Sidecar.remove(for: frame)
            DevelopedThumbnails.remove(for: frame)
            DevelopedThumbnails.remove(for: frame, scope: "variant:A")
        }
        func solid(_ red: CGFloat) -> CGImage {
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            return ctx.makeImage()!
        }
        func red(_ image: CGImage?) -> Int? {
            guard let image else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Int(px[0])
        }
        var folder = Sidecar()
        folder.state = .processed
        try folder.save(for: frame)
        DevelopedThumbnails.store(solid(1), for: frame)                       // the folder frame's
        DevelopedThumbnails.store(solid(0.25), for: frame, scope: "variant:A") // a library variant's

        DevelopedThumbnails.show([:])
        XCTAssertGreaterThan(red(DevelopedThumbnails.image(for: frame)) ?? 0, 200,
                             "a frame the session does not show is answered from its sidecar file")
        DevelopedThumbnails.show([frame: .init(developed: true, scope: "variant:A")])
        XCTAssertLessThan(red(DevelopedThumbnails.image(for: frame)) ?? 255, 100,
                          "a library frame showed the folder frame's picture")
        DevelopedThumbnails.show([frame: .init(developed: false, scope: "variant:A")])
        XCTAssertNil(DevelopedThumbnails.image(for: frame),
                     "an undeveloped library frame showed a picture because its sidecar file says developed")

        DevelopedThumbnails.remove(for: frame, scope: "variant:A")
        DevelopedThumbnails.show([:])
        XCTAssertNotNil(DevelopedThumbnails.image(for: frame), "a variant's reset removed the folder frame's picture")
    }

    func testTheLibraryModelCreatesAddsAndHandsOver() async throws {
        let dir = try scratch("model")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.helper.path))
        let defaults = UserDefaults(suiteName: "spk-library-tests-\(UUID().uuidString)")!
        let session = Session()
        let model = LibraryModel(session: session, defaults: defaults,
                                 launch: .init(executable: Self.helper, store: dir.appending(path: "store")))
        addTeardownBlock { await model.close() }

        await model.create(.session, at: dir.appending(path: "Shoot"))
        XCTAssertTrue(model.isOpen)
        XCTAssertTrue(model.isSession)
        XCTAssertEqual(model.recents.first?.kind, .session)

        let a = try photo("a.jpg", in: dir), b = try photo("b.jpg", in: dir)
        await model.add([a, b], copy: true)
        try await waitUntil("the result to load") { model.rows.count == 2 && !model.loading }
        XCTAssertTrue(model.rows.allSatisfy { $0.path.contains("/Shoot/Capture/") }, "copied into Capture/")

        model.selection = model.rows[0].uuid
        let handed = await model.develop()
        XCTAssertTrue(handed)
        XCTAssertTrue(session.frameSource.isLibrary)
        XCTAssertEqual(session.frames.count, 2)
        try await waitUntil("the frame to open") { session.selection == model.rows[0].url }
    }
}
