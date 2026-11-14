//  MaskFinding.swift — 主体 · 背景 · 人 on the page (design/masks/MASKS-SPEC.md §4.3, §6.4, §6.5, §7; drawings 02, 08, 10,
//  14, 16; PRD-E §4 flow 1, §5.3; RFC-052 §5, §8.2): what the selection row, 人's menu, 组合蒙版's found entries and the
//  geometry mark's 重新查找 ask of `SubjectFinder`, and what the page keeps of it while it is open.
//
//  **Where a find lands.** The selection row's buttons make a new layer, picked, named 主体 n / 背景 n / 人物 n
//  (全部人物 for all), in the stage of the mode in front (`OpenFrameSession.makeLayer`); 组合蒙版's entries join the
//  picked layer with the join chosen there (`addPart`). Either is one step of Undo, and the step holds the part that
//  names the file: Undo takes the layer away, Redo brings it and its file's name back (the file stays: it is the
//  edit's, swept only when no edit, history state or `layers.json` names it, `FoundMaskKeeping`). Then the overlay
//  shows the found mask for 0.6 s (`MaskTools.flash`) and the picture comes back.
//
//  **While it looks** the button reads 正在查找 with a spinner, at its own width; a second click on any of the three
//  waits for the first (one find at a time: they share the decode). **Nothing found** says so in one line at the
//  panel's foot (`OpenFrameSession.maskNote`) and leaves no layer. **Not on this Mac** (`SubjectFinder.Failure
//  .unavailable`): the request's buttons stand down with "not available on this Mac" as their reason, for the launch
//  — 主体 and 背景 are one request, 人 the other. A result that lands after the page moved on is dropped silently
//  (`.dropped`).
//
//  **The page's calls** (the finder's author's list): `pageOpened` (focus, adopt a clone's files, the missing marks),
//  `refocus` (the lens correction switched), `pageClosed` (focus nil, adopt and sweep). The library's
//  (`framesRemoved`, `launchTidy`) are `AppServices`'.
//
//  Page state, `@Observable` and `@MainActor`; the finder is an actor of its own, so the main actor never waits on a
//  decode or a model.

import CoreGraphics
import Foundation
import ImageIO
import Observation
import UIKit

@MainActor @Observable
final class MaskFinding {
    static let shared = MaskFinding()

    /// The three buttons (MASKS-SPEC §4.3).
    enum What: String, CaseIterable, Sendable {
        case subject, background, people
        /// The request behind it: 主体 and 背景 are one.
        var request: Request { self == .people ? .people : .subject }
    }
    enum Request: Sendable { case subject, people }

    /// The button reading 正在查找 (drawing 16), nil when none looks.
    private(set) var finding: What?
    /// Why a request cannot run on this Mac (`Failure.unavailable`), by request: its buttons stand down.
    private(set) var unavailable: [Request: String] = [:]
    /// 人's menu, open under its button (or within 组合蒙版's popover).
    var peopleOpen = false
    /// The people of the open frame, once looked for (the second click opens the menu at once).
    private(set) var people: PeopleResult?
    /// Each person's part (and 全部人物's, key 0), its file written as the menu opened, so a row lit by the pointer
    /// shows that person on the picture and a click makes the layer at once.
    private(set) var peopleParts: [Int: MaskPart] = [:]
    /// The menu's squares of each person, from the photograph (key: the person's number).
    private(set) var thumbnails: [Int: UIImage] = [:]
    /// The row under the pointer in 人's menu: 0 全部人物, n 人物 n; the picture shows it in the overlay.
    var hovered: Int?
    /// Layers whose found parts have no whole file, by layer (`FoundMaskKeeping.missing`): their rows are marked and
    /// their page says so.
    private(set) var missing: [UUID: Set<String>] = [:]
    /// The frame the page is open on.
    private(set) var frame: UUID?

    /// The finder: Vision; `UnavailableDetector` for a check (`useFinder`).
    @ObservationIgnored private(set) var finder = SubjectFinder()
    @ObservationIgnored private var missingTask: Task<Void, Never>?

    /// A check's stand-in (`--masks-check`: the unavailable path).
    func useFinder(_ f: SubjectFinder) {
        finder = f
        unavailable = [:]
    }

    // MARK: the page

    /// The page opened on `session`'s frame, or switched to it: the finder's focus, a clone's files adopted, the
    /// missing marks.
    func pageOpened(_ session: OpenFrameSession) {
        guard LayerRules.takesMasks(session.layerPiece) else { return }
        let id = session.frameID
        if frame != id { reset() }
        frame = id
        // With no file to find in, the tag is the frame's all the same: a find cannot start, and nothing lands.
        let tag = session.findSource?.tag ?? FindTag(frame: id, geometry: "none")
        let finder = finder, edit = session.edit
        Task {
            await finder.focus(tag)
            let missing = Self.broken("adopt") ? await FoundMaskKeeping.missing(edit.layers)
                : await FoundMaskKeeping.pageOpened(frame: id, edit: edit).missing
            guard self.frame == id else { return }
            self.missing = missing
        }
    }

    /// 镜头校正 switched (or the decode's geometry otherwise): a find under way is dropped, the memo goes, the people's
    /// menu looks again.
    func refocus(_ session: OpenFrameSession) {
        guard let source = session.findSource, source.frame == frame else { return }
        people = nil; peopleParts = [:]; thumbnails = [:]; hovered = nil
        let finder = finder
        Task { await finder.focus(source.tag) }
    }

    /// The page closed on `session`'s frame: focus nil, then the frame's folder adopts and sweeps (`pageClosed`).
    func pageClosed(_ session: OpenFrameSession, model: AppServices) {
        let id = session.frameID
        let extra = session.historyFoundAssets
        let edits = Dictionary(model.library.frames.map { ($0.id, $0.edit) }, uniquingKeysWith: { a, _ in a })
        let shelf = model.library.persistence?.layersURL
        let store = model.history.store
        let finder = finder
        if frame == id {
            reset()
            frame = nil
            Task { await finder.focus(nil) }
        }
        Task.detached(priority: .utility) {
            await FoundMaskKeeping.pageClosed(frame: id, edits: edits, layersFile: shelf, history: store, extra: extra)
        }
    }

    private func reset() {
        finding = nil; peopleOpen = false; people = nil; peopleParts = [:]; thumbnails = [:]; hovered = nil; missing = [:]
    }

    /// The edit's layers changed (an act, an Undo): the marks again.
    func layersChanged(_ session: OpenFrameSession) {
        guard session.frameID == frame else { return }
        let layers = session.edit.layers, id = session.frameID
        missingTask?.cancel()
        missingTask = Task {
            let m = await FoundMaskKeeping.missing(layers)
            guard !Task.isCancelled, self.frame == id else { return }
            if m != self.missing { self.missing = m }
        }
    }

    // MARK: finding

    /// Whether `what`'s button takes a click: not while another find runs, not where its request is not on this Mac.
    func takes(_ what: What) -> Bool { finding == nil && unavailable[what.request] == nil }

    /// 主体 or 背景: a new layer with that mask, or (`join`, from 组合蒙版) a part of the picked layer.
    func find(_ what: What, session: OpenFrameSession, join: MaskPart.Join? = nil) {
        guard what != .people else { return openPeople(session) }
        guard takes(what), let source = session.findSource else {
            if session.findSource == nil { session.maskNote = L("The photograph’s original is not here to find in.") }
            return
        }
        finding = what
        let finder = finder
        Task {
            defer { if self.finding == what { self.finding = nil } }
            do {
                guard let result = try await finder.subject(source) else {
                    session.maskNote = L("No subject was found in this photograph.")
                    return
                }
                let part = try await finder.part(result, background: what == .background && !Self.broken("invert"), join: join ?? .add)
                self.land(part, made: what == .background ? .background : .subject, source: source, session: session, join: join)
            } catch {
                self.failed(error, request: .subject, session: session)
            }
        }
    }

    /// 人: the first click looks, then opens the menu; later clicks open it at once (the finder's memo, and this).
    func openPeople(_ session: OpenFrameSession, opensMenu: Bool = true) {
        if people != nil { if opensMenu { peopleOpen = true }; return }
        guard takes(.people), let source = session.findSource else {
            if session.findSource == nil { session.maskNote = L("The photograph’s original is not here to find in.") }
            return
        }
        finding = .people
        let finder = finder
        Task {
            defer { if self.finding == .people { self.finding = nil } }
            do {
                let found = try await finder.people(source)
                var parts: [Int: MaskPart] = [:]
                if let all = found.all { parts[0] = try await finder.part(all) }
                for p in found.people { parts[p.number] = try await finder.part(p.found) }
                guard self.frame == source.frame else { return }
                self.people = found
                self.peopleParts = parts
                if opensMenu { self.peopleOpen = true }
                self.makeThumbnails(found, source: source)
            } catch {
                self.failed(error, request: .people, session: session)
            }
        }
    }

    /// A row of 人's menu: `number` 0 is 全部人物. A new layer 人物 n / 全部人物, or a part of the picked one.
    func choosePerson(_ number: Int, session: OpenFrameSession, join: MaskPart.Join? = nil) {
        peopleOpen = false
        hovered = nil
        guard var part = peopleParts[number], let source = session.findSource else { return }
        part.id = UUID()
        part.join = join ?? .add
        land(part, made: number == 0 ? .allPeople : .person, source: source, session: session, join: join,
             name: number == 0 ? nil : MaskRules.personName(number, among: session.edit.layers))
    }

    /// The found part on the edit: one step.
    private func land(_ part: MaskPart, made: MaskRules.Made, source: FindSource, session: OpenFrameSession, join: MaskPart.Join?,
                      name: String? = nil) {
        guard session.frameID == source.frame else { return }
        if let join, !Self.broken("join"), let picked = session.pickedMaskLayer {
            var p = part; p.join = join
            guard session.addPart(p, to: picked.id) else { return }
        } else {
            var p = part; p.join = .add
            guard session.makeLayer(made, parts: [p], name: name) != nil else { return }
        }
        MaskTools.shared.flash()
    }

    private func failed(_ error: Error, request: Request, session: OpenFrameSession) {
        let f = (error as? SubjectFinder.Failure) ?? SubjectFinder.failure(error)
        switch f {
        case .dropped: return
        case .unavailable(let why):
            if !Self.broken("unavailable") { unavailable[request] = why }
            session.maskNote = L("Finding subjects and people is not available on this Mac.")
        case .noSource:
            session.maskNote = L("The photograph’s original is not here to find in.")
        case .failed:
            session.maskNote = L("Finding did not work on this photograph.")
        }
        NSLog("[masks] find: %@", "\(f)")
    }

    // MARK: the geometry mark (MASKS-SPEC §6.5, drawing 14)

    /// 重新查找: each found part of the layer found again on the photograph as it is decoded now — a new file, the
    /// part's join, invert and eye kept, the old file named by the history for Undo — and the mark cleared. One step.
    /// Also what a missing file's line offers.
    func findAgain(_ layerID: UUID, session: OpenFrameSession) {
        guard finding == nil, let layer = session.edit.layers?[layerID], let source = session.findSource else { return }
        let found = layer.parts.filter { $0.kind == .found }
        guard !found.isEmpty else { return keepAsIs(layerID, session: session) }
        finding = found.contains { $0.found?.what != .subject } ? .people : .subject
        let finder = finder
        Task {
            defer { self.finding = nil }
            do {
                var subject: FoundResult?, people: PeopleResult?
                var replaced: [UUID: MaskPart] = [:]
                for part in found {
                    guard let f = part.found else { continue }
                    let result: FoundResult?
                    switch f.what {
                    case .subject:
                        if subject == nil { subject = try await finder.subject(source, again: true) }
                        result = subject
                    case .people:
                        if people == nil { people = try await finder.people(source, again: true) }
                        result = people?.all
                    case .person:
                        if people == nil { people = try await finder.people(source, again: true) }
                        result = people?.people.first { $0.number == f.instance }?.found
                    }
                    guard let result else { continue }
                    var new = try await finder.part(result, background: f.invert, join: part.join)
                    new.id = part.id
                    new.on = part.on
                    replaced[part.id] = new
                }
                guard session.frameID == source.frame else { return }
                if replaced.isEmpty { session.maskNote = L("No subject was found in this photograph.") }
                session.changeLayer(layerID) { l in
                    for i in l.parts.indices { if let n = replaced[l.parts[i].id] { l.parts[i] = n } }
                    l.madeOn = source.madeOn
                }
                self.people = nil; self.peopleParts = [:]
                MaskTools.shared.flash()
                self.layersChanged(session)
            } catch {
                self.failed(error, request: found.contains { $0.found?.what != .subject } ? .people : .subject, session: session)
            }
        }
    }

    /// 保持现状: the mask as it is, now on the decode as it is; the mark cleared. One step.
    func keepAsIs(_ layerID: UUID, session: OpenFrameSession) {
        let made = MaskMadeOn(lensCorrection: session.edit.decode.lensCorrection, lensWord: session.lensWord)
        guard !Self.broken("keep") else { return }
        session.changeLayer(layerID) { $0.madeOn = made }
    }

    // MARK: the menu's squares

    /// Each person's 28-point square, cut from the photograph (ImageIO's picture, its orientation applied), off the main
    /// actor. A RAW's is cut from the camera's own preview in the file (`…FromImageIfAbsent`): no second decode of the
    /// RAW beside the engine's and the finder's for a square of 28 points (the preview is the frame uncorrected, which
    /// a 28-point square of a person does not show).
    private func makeThumbnails(_ found: PeopleResult, source: FindSource) {
        let url = source.url, squares = found.people.map { ($0.number, $0.thumbnail) }, raw = source.isRAW
        Task.detached(priority: .userInitiated) {
            let options: [CFString: Any] = [raw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(s, 0, options as CFDictionary) else { return }
            var out: [Int: UIImage] = [:]
            for (n, r) in squares {
                let rect = CGRect(x: r.x * Double(image.width), y: r.y * Double(image.height),
                                  width: r.width * Double(image.width), height: r.height * Double(image.height)).integral
                if let cut = image.cropping(to: rect) { out[n] = UIImage(cgImage: cut) }
            }
            let made = out
            await MainActor.run { if self.frame == source.frame { self.thumbnails = made } }
        }
    }

    // MARK: the overlay of a row under the pointer

    /// The person under the pointer in 人's menu as a layer of one part, for the overlay (`MaskStage`); nil otherwise.
    var preview: LocalLayer? {
        guard let n = hovered, let part = peopleParts[n] else { return nil }
        var l = LocalLayer(name: "", stage: .finished, parts: [part])
        l.id = Self.previewID
        return l
    }
    static let previewID = UUID(uuidString: "5E1EC7ED-0000-4000-8000-000000000000")!
}

#if DEBUG
/// The rules `--masks-check-break find-<rule>` breaks (`MacMaskFindCheck`): "join": 组合蒙版's join ignored (a new
/// layer); "invert": 背景 not inverted; "keep": 保持现状 leaves the mark; "adopt": a page opened adopts nothing;
/// "unavailable": an unavailable request does not stand its buttons down.
@MainActor enum MaskFindingProbe {
    static var broken: String?
    static func breaks(_ rule: String) -> Bool { broken == rule }
}
#endif

extension MaskFinding {
    /// Whether a debug check broke `rule` (always false in a release build).
    static func broken(_ rule: String) -> Bool {
        #if DEBUG
        return MaskFindingProbe.breaks(rule)
        #else
        return false
        #endif
    }
}
