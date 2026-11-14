//  DoubleKeeping.swift — a double exposure, as the library keeps it (RFC-047 §5).
//
//  `PairKeeping.swift` mirrored, function for function, for the pair's sibling (`DoubleExposure`): a
//  library item (`LibraryFrame.double`) that is one frame of film with two of the library's photographs
//  exposed on it, whose `edit` is the whole's look. It sits after its bottom photograph, is kept the moment
//  it is made, and is worked on in its own darkroom (RFC-050), every edit through `changeDouble` — as a
//  pair's is through `changePair`.
//
//  **It references its photographs and does not own them** (PRD 2 §5): removing a double exposure
//  leaves both photographs; **removing a photograph empties its layer** in every double exposure holding
//  it, and a double exposure left with no exposure goes with it (`AppServices.remove`, `emptyDoubles`).
//
//  **It is kept where an older build does not look** (`LibraryShelf`, `doubles.json` beside `library.json`):
//  what such a build may have done meanwhile — removed a photograph, swept the guide — is mended at launch
//  (`holdDoublesToTheLibrary`).
//
//  **On the Mac it is also a row of its library**, as a pair is (`Mac/Library/MacDoubleRows.swift`,
//  `MAC-LIBRARY-DATA.md` §2k): its recipe `Doubles/<name>.spektradouble` beside `library.json`, written on
//  every keep and every change that moves the piece (`doubleKept`), the row added by reference into the
//  library holding its bottom photograph, and both gone with it.
//
//  **Until the engine has developed it, it shows a guide** (`DoubleGuide`, RFC-047 §5.1): the two
//  photographs' own previews, laid as their exposures lie and added in linear light at their own stops.
//  A file of the double exposure's own under `Previews`, which goes with it; in a library that keeps
//  nothing on disk — the drawings' own, the snapshot harness — a temporary file.
//
//  **What this file does not do yet, and who does** (RFC-050 §9's lanes):
//
//  - the develop itself is the darkroom's (`EngineRouter.prepare`, `stamp`, `sourceKey`, `exportSource`,
//    RFC-048); this file hands a double to the one queue (`queueDouble`) as `PairKeeping` hands a pair;
//  - undo of the piece: `DevelopRevision.double` carries it, with its photographs' decodes, and
//    `AppServices`'s `onRestoreRevision` puts it back through `changeDouble` (RFC-050 §3);
//  - the pages' own calls of the records `Log.doubleLayer`, `doubleBalance` (on release) and `doublePlace`
//    (the darkroom's, lane D). `double.made` and `double.swap` are written here.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

extension EngineRouter {
    /// The photographs a double exposure's layers hold, as the library has them now: a layer whose
    /// photograph has gone from the library is an empty one, as a pair's hole is (`held(by:)`). A piece
    /// made of photographs is never an exposure of another (PRD 2 §9: no double inside a pair's hole).
    func held(by double: DoubleExposure) -> DoubleExposure.Frames {
        var held: DoubleExposure.Frames = [:]
        for position in DoubleExposure.Position.allCases {
            if let id = double[position]?.frame, let frame = frames(id), !frame.isComposite { held[position] = frame }
        }
        return held
    }
}

extension DoubleExposure {
    /// The photographs a double exposure's layers hold, by position. No entry: an empty layer, or a
    /// photograph the library no longer has.
    typealias Frames = [Position: LibraryFrame]

    /// The double exposure with each exposure's decode and cut read again from its photograph: the shot
    /// stays the photograph's (`mirror`, as a pair's `mirrored`).
    func mirrored(_ frames: Frames) -> DoubleExposure {
        var double = self
        for position in Position.allCases {
            if let frame = frames[position] { double.mirror(position, decode: frame.edit.decode, cut: frame.pictureGeometry) }
        }
        return double
    }

    /// Each exposure's picture as its photograph cuts it, at the size of the file it is developed from:
    /// what the frame's shape and size are read from (`frameAspect`, `frameSize`).
    func framed(_ frames: Frames) -> Framed {
        var sizes: Framed = [:]
        for position in Position.allCases {
            guard let e = self[position], let frame = frames[position] else { continue }
            let own = frame.developSize
            sizes[position] = e.cut.outputSize(for: CGSize(width: own.width, height: own.height))
        }
        return sizes
    }

    /// The frame's own size, as a library item keeps it (`originalSize`): RFC-048 §5's, at the full tier.
    /// With no picture known, the first photograph's own size, so an item is never 0 × 0.
    ///
    /// **Not cut to a film edge's gate**: a whole that wears one is a photograph's frame with a film edge —
    /// the item's size is the picture's, and the gate's cut is made where a photograph's is
    /// (`FrameEdit.canvas` for the price, `DoubleExposure.pieceFrame` for the job, RFC-048 §5 as built). So
    /// `frameAspect(_:gateAspect:)` is not used for sizing, and no job is opened larger than it is priced.
    func ownSize(_ frames: Frames) -> PixelSize {
        if let size = frameSize(framed(frames)) { return size }
        return (frames[.bottom] ?? frames[.top])?.developSize ?? PixelSize(width: 1, height: 1)
    }
}

extension AppServices {
    /// **Make a double exposure of two of the library's photographs, and keep it** (RFC-047 §5): the way
    /// in from the viewer's 合成 and from Select (RFC-049 §3). Each exposure's decode and cut are read
    /// from its own photograph, each is laid in the middle at −1 EV and metered alone (Balance 50 %, PRD 2
    /// §4.2), and the look is the bottom's (`DoubleExposure.look(from:)`). Returns the item's id, or nil
    /// where either is not a photograph of the library — a pair or a double exposure is refused, it is not
    /// a photograph.
    ///
    /// `beginsWithFirst`: the double exposure began with `bottom` alone, and the second was asked for (the
    /// viewer's disc: "the frame you were on is the bottom", PRD 2 §3.2) — `bottom` is what it is of, and
    /// stays in it (`DoubleExposure.origin`, `mayChange`). False: two picked together in Select, **the
    /// earlier in the library is the bottom**, and neither is held.
    ///
    /// The same photograph twice is allowed, as a pair allows one frame under both holes.
    @discardableResult
    ///
    /// `keepsOrder` (the Mac's 合成, the UX review's R6): the two were picked in this order, and it is kept —
    /// the first picked is the bottom — with neither held.
    func makeDouble(_ bottom: LibraryFrame.ID, _ top: LibraryFrame.ID, beginsWithFirst: Bool = false,
                    keepsOrder: Bool = false) -> LibraryFrame.ID? {
        guard let a = library.frame(bottom), let b = library.frame(top), !a.isComposite, !b.isComposite else { return nil }
        var order = [a, b]
        if !beginsWithFirst, !keepsOrder {
            // The library's order, not the order they were picked in (the pair's `PairStart.make(.new…)`).
            let grid = library.grid().flatMap(\.frames).map(\.id)
            order.sort { (grid.firstIndex(of: $0.id) ?? .max) < (grid.firstIndex(of: $1.id) ?? .max) }
        }
        let laid = DoubleExposure(
            bottom: DoubleExposure.Exposure(frame: order[0].id, sourceEdit: order[0].edit, sourceGeometry: order[0].pictureGeometry),
            top: DoubleExposure.Exposure(frame: order[1].id, sourceEdit: order[1].edit, sourceGeometry: order[1].pictureGeometry),
            origin: beginsWithFirst ? order[0].id : nil)
        var made = laid
        // The same photograph twice starts with its top flipped: laid as it is, the double would be the
        // photograph itself (LAYERS-SPEC gap G8).
        if order[0].id == order[1].id { made[.top]?.placement.flipped = true }
        guard let id = keepDouble(made, look: DoubleExposure.look(from: order[0].edit)) else { return nil }
        library.selectedID = id
        Log.doubleMade(id, way: beginsWithFirst ? "one, then another" : "two picked", bottom: order[0], top: order[1])
        return id
    }

    /// Keep what was made: a new library item **after its bottom photograph** — or, with `existing`, over
    /// the double exposure it was opened from. Each exposure's decode and cut are read again from its
    /// photograph; the look is held to its film and wears no cut of its own (`FrameEdit.asDoubleLook`).
    /// Returns the item's id, or nil for one with no photograph the library has: an empty piece is not
    /// kept. The pair's `keepPair`, line for line, but for the pair's strip and film-edge switch.
    @discardableResult
    func keepDouble(_ made: DoubleExposure, look: FrameEdit, as existing: LibraryFrame.ID? = nil) -> LibraryFrame.ID? {
        let look = look.heldToItsFilm().asDoubleLook
        let frames = darkroom.held(by: made)
        let double = made.mirrored(frames)
        // The bottom sets the frame: its date, its camera (PRD 2 §8.4, one date: the bottom's).
        guard let first = frames[.bottom] ?? frames[.top] else { return nil }
        let own = double.ownSize(frames)
        let preview = own.scaled(toLongEdge: settings.previewLongEdge)
        let folder = doubleGuideFolder

        if let existing, let was = library.frame(existing), was.isDouble {
            let session = openSession(existing)
            let before = session?.historySnapshot()
            // With no page open, the frame's state before, for its history's step (the door, PRD-F §3.3).
            let door = session == nil ? historyRevision(existing) : nil
            let guide = DoubleGuide.write(double, frames: frames, id: existing, in: folder)
            library.update(existing) { f in
                f.double = double
                f.originalSize = own
                f.previewSize = preview
                f.captureDate = first.captureDate
                f.camera = first.camera
                f.exposure = first.exposure
                if let guide { f.picture = .file(guide) }
            }
            if guide != nil { Task.detached(priority: .utility) { DoubleGuide.discard(was.picture) } }
            if let session {
                session.pieceChanged(look: look)
                if let before { session.recordHistory(from: before) }
            } else {
                library.update(existing) { $0.edit = look }
                queueDouble(existing)
                if let door { recordStep(existing, before: door, origin: .flow, label: nil) }
            }
            // On the Mac a double exposure is a row of the library, pointing at its recipe (`MacDoubleRows.swift`).
            macLibrary.doubleKept(existing)
            return existing
        }

        let fresh = double.startingLook(look)
        let id = UUID()
        // Never another frame's own file: a double exposure's picture goes with it (`ImportService.discard`).
        guard let guide = DoubleGuide.write(double, frames: frames, id: id, in: folder) else { return nil }
        var n = 1
        while library.frames.contains(where: { $0.isDouble && $0.fileName == DoubleExposure.name(n) }) { n += 1 }
        let item = LibraryFrame(id: id, fileName: DoubleExposure.name(n), captureDate: first.captureDate, camera: first.camera,
                                exposure: first.exposure, originalSize: own, previewSize: preview, isRAW: false, source: .copiedIn,
                                picture: .file(guide), edit: fresh,
                                // After its bottom photograph, in the grid's own order (PRD 2 §5; the pair's B8).
                                importedAt: first.importedAt.addingTimeInterval(0.001), double: double)
        library.add([item])
        queueDouble(id)
        macLibrary.doubleKept(id)
        return id
    }

    /// **An edit of a kept double exposure**, from its darkroom: Balance, an exposure's own stops and
    /// meter, a placement (位置), a swap (交換上下), a photograph replaced or removed. `mutate` is handed the
    /// piece and the whole's look together, as `changePair`'s is, because ↺ is of both (PRD 2 §4.2).
    ///
    /// The one place the library's piece is written between its making and its removal. Each exposure's
    /// decode and cut are read again from its photograph, the frame's size is RFC-048 §5's, and its guide
    /// is drawn again when what a guide shows has moved (`DoubleExposure.guideKey`: the photographs, their
    /// cuts and placements, each exposure's own stops — never a decode alone). The develop is the open
    /// page's (`OpenFrameSession.pieceChanged`: asked for when the finger rests, as for any control) or the
    /// queue's. On the open page one call is one undo step of the piece and the look together
    /// (`historySnapshot` / `recordHistory`, the pair's way; `DevelopRevision.double`, RFC-050 §3).
    /// `origin`: what the history's step is, where no page is open (PRD-F §3.3) — a person's edit from the grid,
    /// or `elsewhere` for what the app mends by itself (a photograph removed under the double, a launch's hold).
    func changeDouble(_ id: LibraryFrame.ID, as origin: HistoryOrigin = .develop, _ mutate: (inout DoubleExposure, inout FrameEdit) -> Void) {
        guard let item = library.frame(id), let was = item.double else { return }
        let session = openSession(id)
        let historyBefore = session?.historySnapshot()
        // With no page open (a photograph removed under it, a swap from the grid), the state before (PRD-F §3.3).
        let door = session == nil ? historyRevision(id) : nil
        var double = was
        var look = session?.edit ?? item.edit
        mutate(&double, &look)
        let frames = darkroom.held(by: double)
        double = double.mirrored(frames)
        look = look.heldToItsFilm().asDoubleLook
        guard double != was || look != (session?.edit ?? item.edit) else { return }
        let own = double.ownSize(frames)
        // Not while a finger is on the page's control (an exposure's own EV dial lands a value every tenth of
        // a stop, and the guide is two photographs read, added and written as a JPEG on the main thread — the
        // pair's v0.1 watchdog kill): owed, and drawn once when it lifts (`drawOwedDoubleGuide`). The open page
        // shows the engine's develop meanwhile.
        let moved = double.guideKey != was.guideKey || DoubleGuideOwed.ids.contains(id)
        let redraw = moved && !(session?.isDragging ?? false)
        if moved, !redraw { DoubleGuideOwed.ids.insert(id) } else if redraw { DoubleGuideOwed.ids.remove(id) }
        let guide = redraw ? DoubleGuide.write(double, frames: frames, id: id, in: doubleGuideFolder) : nil
        let first = frames[.bottom] ?? frames[.top]
        library.update(id) { f in
            f.double = double
            f.originalSize = own
            f.previewSize = own.scaled(toLongEdge: settings.previewLongEdge)
            if let first {
                f.captureDate = first.captureDate
                f.camera = first.camera
                f.exposure = first.exposure
            }
            if let guide { f.picture = .file(guide) }
        }
        if guide != nil { Task.detached(priority: .utility) { DoubleGuide.discard(item.picture) } }
        if let session {
            session.pieceChanged(look: look)
            if let historyBefore { session.recordHistory(from: historyBefore) }
        } else {
            library.update(id) { $0.edit = look }
            queueDouble(id)
            if let door { recordStep(id, before: door, origin: origin, label: origin == .develop ? nil : .changedElsewhere) }
        }
        if double != was { macLibrary.doubleKept(id) }
    }

    /// **The guide owed** since a finger moved a control of the open page (`changeDouble` draws none while it
    /// is down), drawn once now: the finger has lifted, or the page has closed. Nothing when none is owed.
    func drawOwedDoubleGuide(_ id: LibraryFrame.ID) {
        guard DoubleGuideOwed.ids.remove(id) != nil, let item = library.frame(id), let double = item.double,
              let guide = DoubleGuide.write(double, frames: darkroom.held(by: double), id: id, in: doubleGuideFolder) else { return }
        library.update(id) { $0.picture = .file(guide) }
        Task.detached(priority: .utility) { DoubleGuide.discard(item.picture) }
    }

    /// **Swap top and bottom** (交換上下), as one edit and one undo step: `DoubleExposure.swap` with each
    /// exposure's picture as its photograph frames it, so that a new bottom of another shape lays both
    /// again (RFC-047 §3). Written to the log as `double.swap` (RFC-047 §8).
    func swapDouble(_ id: LibraryFrame.ID) {
        // Both layers filled: K3's row is dimmed otherwise, and nothing reaching it (VoiceOver included) swaps one
        // exposure into the top and leaves the bottom empty (the phase-2 review).
        guard let was = library.frame(id)?.double, was.isFilled else { return }
        let framed = was.framed(darkroom.held(by: was))
        let refits = !DoubleExposure.sameShape(was.frameAspect(framed),
                                               was.frameAspect([.bottom: framed[.top], .top: framed[.bottom]].compactMapValues { $0 }))
        changeDouble(id) { double, _ in double.swap(framed: framed) }
        guard let now = library.frame(id)?.double, now != was else { return }
        Log.doubleSwap(id, refit: refits, balance: now.balance)
    }

    /// **An exposure's white balance or lens correction**, set in the double exposure's darkroom
    /// (pro-control's Scene tab, PRD 2 §4) — the pair's `changeDecode(of:in:_:)`, the desktop's
    /// `Session.setFocusDecode`: **written to the photograph itself** ("the shot stays the frame's — it is
    /// the same shot in every piece and by itself"). An exposure's decode is read from its photograph every
    /// time the piece is written (`DoubleExposure.mirrored`), so the double exposure takes it from there —
    /// through `changeDouble`, which composes it again when the finger rests and does not draw the guide
    /// again (a decode is not in `guideKey`). The photograph's own kept picture is made again by
    /// `keepDecode(of:inDouble:)` when the finger lifts. One undo step of the page for the gesture.
    func changeDecode(of position: DoubleExposure.Position, inDouble doubleID: LibraryFrame.ID, _ mutate: (inout DecodeSettings) -> Void) {
        guard let exposure = library.frame(doubleID)?.double?[position], let held = library.frame(exposure.frame),
              !held.isComposite else { return }
        var decode = held.edit.decode
        mutate(&decode)
        guard decode != held.edit.decode else { return }
        let session = openSession(doubleID)
        let ownsHistory = session?.beginHistoryTransaction() ?? false
        defer { if ownsHistory { session?.endHistoryTransaction() } }
        library.update(held.id) { $0.edit.decode = decode }
        changeDouble(doubleID) { _, _ in }
    }

    /// The finger has left a control of `changeDecode(of:inDouble:)`: the photograph's own kept develop —
    /// what the library shows of it by itself — is made again, in the one queue (the pair's `keepDecode`).
    func keepDecode(of position: DoubleExposure.Position, inDouble doubleID: LibraryFrame.ID) {
        guard let exposure = library.frame(doubleID)?.double?[position], let held = library.frame(exposure.frame),
              !held.isComposite else { return }
        if !isSnapshot { develop(held.id) }
    }

    // MARK: the removal cascade (RFC-047 §5)

    /// The double exposures **left with no exposure** once `removed` leave the library: each layer empty,
    /// holding one of them, or holding a photograph the library no longer has (`isLeftEmpty`). They go
    /// with them (`AppServices.remove`). A double exposure among `removed` is not one of these: it is going
    /// already, and its photographs stay.
    func doublesLeftEmpty(by removed: Set<LibraryFrame.ID>) -> Set<LibraryFrame.ID> {
        Set(library.frames.filter { item in
            guard let double = item.double, !removed.contains(item.id) else { return false }
            return double.isLeftEmpty(removing: removed) { [library] id in library.frame(id).map { !$0.isComposite } ?? false }
        }.map(\.id))
    }

    /// **Photographs have left the library**: every double exposure holding one has that layer emptied
    /// (`DoubleExposure.empty(holding:)`, the pair's "hole left empty", whatever `mayChange` says — the
    /// photograph is gone), its frame laid again when its shape moved, its guide drawn again of what is
    /// left. One left with no exposure is removed (`remove`, which leaves its photographs). Called by
    /// `AppServices.remove` once the photographs are out of the library, before it is written, and at launch.
    ///
    /// Through `changeDouble`, so a darkroom open on one (beside the library) sees its layer go
    /// as an edit of the page.
    func emptyDoubles(holding removed: Set<LibraryFrame.ID>) {
        guard !removed.isEmpty else { return }
        var leftEmpty: Set<LibraryFrame.ID> = []
        for item in library.frames {
            guard let double = item.double, !removed.contains(item.id),
                  double.frameIDs.contains(where: removed.contains) else { continue }
            if double.isLeftEmpty(removing: removed, has: { [library] id in library.frame(id).map { !$0.isComposite } ?? false }) {
                leftEmpty.insert(item.id)
                continue
            }
            // The frame's shape before is the item's own (`originalSize`, the frame at its shape): the
            // photographs that went are out of the library by now — at launch, long since — so their sizes
            // cannot be read again. After, each picture left as its photograph frames it, in its place.
            let shape = CGSize(width: item.originalSize.width, height: item.originalSize.height)
            let before: DoubleExposure.Framed = [.bottom: shape, .top: shape]
            let after = double.framed(darkroom.held(by: double).filter { !removed.contains($0.value.id) })
            changeDouble(item.id, as: .elsewhere) { piece, _ in piece.empty(holding: removed, before: before, after: after) }
        }
        if !leftEmpty.isEmpty { remove(leftEmpty) }
    }

    // MARK: at launch, and when a photograph changes under one

    /// At launch: the double exposures held to the library as it was read. **What an older build may have
    /// done while the testers were on it** (`LibraryShelf`: it never opens `doubles.json`) is mended here,
    /// and nothing else is touched:
    ///
    /// - a photograph it removed: that layer is empty, and a double exposure left with none goes
    ///   (`emptyDoubles`);
    /// - the guide it swept from `Previews` (its tidy keeps only the files its frames name, an hour after
    ///   they are written): drawn again, as a guide is when the double exposure changes.
    ///
    /// Before `tidyStorage`, which keeps the files the library names as it is then.
    func holdDoublesToTheLibrary() {
        let gone = Set(library.frames.compactMap(\.double).flatMap(\.frameIDs)
            .filter { id in library.frame(id).map(\.isComposite) ?? true })
        emptyDoubles(holding: gone)
        for item in library.frames where item.isDouble {
            guard let double = item.double, let url = item.picture.fileURL,
                  !FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let guide = DoubleGuide.write(double, frames: darkroom.held(by: double), id: item.id, in: doubleGuideFolder) else { continue }
            library.update(item.id) { $0.picture = .file(guide) }
        }
    }

    /// Photographs' decodes changed from outside a double exposure's darkroom (a check's lens correction switched
    /// over the library, `MacMaskFindCheck.setLens`): every double exposure holding one
    /// reads it again (`changeDouble`, which mirrors each exposure from its photograph) and is developed
    /// again — on its page where one is open, in the queue otherwise. Not drawn again: a decode is not in
    /// the guide.
    func decodesChanged(_ changed: Set<LibraryFrame.ID>) {
        for item in library.frames where item.double?.frameIDs.contains(where: changed.contains) == true {
            changeDouble(item.id, as: .elsewhere) { _, _ in }
        }
    }

    /// A photograph's size was corrected from its file (`Originals.take`, `AppServices.resized`): a double
    /// exposure holding it was sized from the old one, and its frame is sized again (RFC-048 §5) — and
    /// developed again, where its develop is not already on its way and no page has it open.
    func resizedDoubles(holding id: LibraryFrame.ID) {
        for item in library.frames {
            guard let double = item.double, double.frameIDs.contains(id) else { continue }
            let own = double.ownSize(darkroom.held(by: double))
            guard own.width > 0, own.height > 0, own != item.originalSize else { continue }
            library.update(item.id) { f in
                f.originalSize = own
                f.previewSize = own.scaled(toLongEdge: settings.previewLongEdge)
            }
            if library.frame(item.id)?.develop.isBusy == false, openSession(item.id) == nil { queueDouble(item.id) }
        }
    }

    /// The engine's meter has read one exposure of a double exposure alone (`EngineHost.Delivery.metered`,
    /// `index` its position): the reading is kept in the piece, for the exposure it was read for
    /// (`DoubleExposure.keep(reading:of:for:)`), so that picture is read once — as a pair's frame's is. Not
    /// an edit: the develop that read it is already of it, so nothing is asked for. Lane B's metering
    /// render delivers it (RFC-048 §4).
    func meteredDouble(_ id: LibraryFrame.ID, _ index: Int, _ ev: Double, _ key: String) {
        guard let position = DoubleExposure.Position(rawValue: index), library.frame(id)?.double != nil else { return }
        library.update(id) { $0.double?.keep(reading: ev, of: position, for: key) }
    }

    /// Where a double exposure's guide is kept: beside the preview copies in a library kept on disk; the
    /// temporary files in one that keeps nothing (the drawings', the snapshot harness), as a pair's.
    private var doubleGuideFolder: URL {
        library.persistence != nil ? ImportService.previews
                                   : FileManager.default.temporaryDirectory.appendingPathComponent("DoubleGuides", isDirectory: true)
    }

    /// A double exposure's own develop, in the one queue — the pair's `queue(_:)`: `develop(id)`, but in
    /// the snapshot harness, which develops nothing. The darkroom composes the piece (`EngineRouter.prepare`,
    /// RFC-048: both exposures `PieceAsk.Lay.add`, priced by the scheduler as a composed open); the item
    /// shows its guide until that develop lands.
    private func queueDouble(_ id: LibraryFrame.ID) {
        if !isSnapshot { develop(id) }
    }
}

/// The guide's file: read the previews, add them (`DoubleGuide.added`, `DoubleGuideLight.swift`), write.
/// The double exposures whose guide is owed: an edit moved what the guide shows while a finger was on the page's
/// control, and it is drawn once that finger lifts (`AppServices.changeDouble`, `drawOwedDoubleGuide`).
@MainActor
enum DoubleGuideOwed {
    static var ids: Set<LibraryFrame.ID> = []
}

extension DoubleGuide {
    /// Write the guide for `double` into `folder`, and say where: the frame at its own shape, `longEdge`
    /// long, each exposure's preview laid and added in linear light (RFC-047 §5.1). Nil when no exposure
    /// has a picture to read.
    ///
    /// **What it holds while it draws** — the pair's own: each preview read by ImageIO at twice the guide's
    /// long edge (a zoom of up to 4 still has a pixel for most of the guide's), so two 8-bit pictures of
    /// at most 2560 px — 2560 × 1920 × 4 bytes ≈ 19.7 MB each at 4:3 — and Core Image's tiles for a
    /// 1280 px frame. Arithmetic, not measured; outside the render scheduler, on the main thread, as
    /// `PairGuide.write` is (RFC-036's budget is the engine's; neither guide asks the engine anything).
    static func write(_ double: DoubleExposure, frames: DoubleExposure.Frames, id: UUID, in folder: URL, longEdge: Int = 1280) -> URL? {
        let framed = double.framed(frames)
        guard let size = double.frameSize(framed, longEdge: longEdge), size.width > 0, size.height > 0 else { return nil }
        var pictures: [DoubleExposure.Position: CIImage] = [:]
        for position in DoubleExposure.Position.allCases {
            // A photograph's own file, or — in the drawings' own library — its bundled picture.
            guard let frame = frames[position], let url = ThumbnailStore.url(for: frame.picture),
                  let shown = preview(url, maxPixel: longEdge * 2) else { continue }
            pictures[position] = shown
        }
        guard let added = added(double, framed: framed, pictures: pictures, size: CGSize(width: size.width, height: size.height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A new name each time: the pages' picture cache keys by path.
        let out = folder.appendingPathComponent("double-\(id.uuidString)-\(UUID().uuidString.prefix(8)).jpg")
        let context = context()
        defer { context.clearCaches() }
        do {
            try context.writeJPEGRepresentation(of: added, to: out, colorSpace: space, options: [:])
            return out
        } catch {
            return nil
        }
    }

    /// What the guide is drawn from, by position (`DoubleExposure.guideKey`, a line each).
    static func inputs(_ double: DoubleExposure) -> [String] {
        double.guideKey.components(separatedBy: ";")
    }

    /// A guide that has been replaced. Only a guide: a file of a double exposure's own, under `Previews`
    /// or the temporary files (the pair's `PairGuide.discard`, by its own prefix).
    nonisolated static func discard(_ picture: PictureRef?) {
        guard let url = picture?.fileURL, url.lastPathComponent.hasPrefix("double-") else { return }
        let path = url.standardizedFileURL.path
        let mine = [ImportService.previews, FileManager.default.temporaryDirectory].map { $0.standardizedFileURL.path }
        guard mine.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The file's own small picture, turned as the file says: a RAW's embedded preview, a HEIF or a JPEG
    /// reduced by ImageIO. Nothing is demosaiced (the pair's `PairGuide.preview`).
    private static func preview(_ url: URL, maxPixel: Int) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }
        return CIImage(cgImage: image)
    }
}
