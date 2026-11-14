//  found_mask_selftest.swift — the found masks of M1c (PRD-E §5.3, §5.4; RFC-052 §5, §8.2, §8.3, §9): the files, their
//  sweep, the bake from them on every path, the finder's tag and its unavailable path, on this Mac.
//
//      tools/found_mask_selftest.sh [--self-test]
//
//  A. the files: a round trip, content addressing (主体 and 背景 one file; another picture or another system another
//     file), immutability (a second write leaves the file as it was), a damaged file refused, a name that is a path
//     refused;
//  B. the sweep: what an edit, another frame's edit (a clone), a history state, `layers.json`'s text (an entry this
//     build cannot read) names stays; what nothing names goes, but not while it is young; nothing goes when the
//     history cannot be read; adopt, a frame removed handing on, the launch's tidy;
//  C. Vision on a real photograph (copied first): 主体 and 背景 from one kept asset, baked from the file alone, sum to
//     65,535 at every texel within a count;
//  D. the same plane is the picture resampled by `mask_found`'s bilinear rule (written again here in double);
//  E. a missing file fails the bake naming the layer, and `FoundMaskKeeping.missing` names it too;
//  F. a late result for another frame, or for the frame after its decode's geometry changed, is dropped; the memo;
//  G. the unavailable path (forced) and Vision's errors mapped to it;
//  H. determinism: the same photograph twice → the same bytes, the same asset;
//  I. *Clear Working Copies*, the working copies' launch sweep and the previews' and cards' tidies leave `Masks/` whole;
//  J. 场景 (`SceneLayerWire.planes`) and 成片 (`FinishedLayers.planes`) bake a stored found part from the files.
//  K. a phantom person: an instance 全部人物 does not overlap is not a person (`SubjectFinder.overlap`, the rule and its
//     threshold there) — a stand-in detector's two instances, one under 全部人物 and one beside it at the matte's own
//     size; and Vision on `SampleSources/scene_raw_srgb.jpg`, a street with nobody in it, where the per-person request
//     answers one soft "person" over the cars: no person, and 全部人物 nil; the people of the given photograph kept.
//
//  `--self-test` is run by the .sh against mutants of the sources (each rule broken in turn); each must go red.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import Vision

enum DevelopStamp { static let decoder = "decode.1" }

@main struct FoundMaskSelftest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1; print("ok    \(what)") } else { failed += 1; print("FAIL  \(what)") }
    }

    static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("found-mask-selftest-\(getpid())", isDirectory: true)

    static func picture(_ w: Int, _ h: Int, seed: Int) -> FoundPicture {
        FoundPicture(width: w, height: h, bytes: (0..<(w * h)).map { UInt8(truncatingIfNeeded: ($0 * 7 + seed * 13) % 256) })
    }

    static func mask(_ p: FoundPicture, what: FoundMask.What = .subject, system: String = "Version 27.0.1 (Build 26A434)") -> FoundMask {
        FoundMask(what: what, instance: 0, invert: false, width: p.width, height: p.height, detector: SubjectFinder.subjectDetector,
                  revision: 1, system: system, fingerprint: "f", decodeGeometry: "image")
    }

    static func edit(_ assets: [String]) -> FrameEdit {
        var e = FrameEdit()
        let parts = assets.map { a in MaskPart.found(FoundMask(what: .subject, width: 8, height: 8), asset: a) }
        e.layers = LocalLayers(items: [LocalLayer(name: "主体 1", stage: .scene, parts: parts)])
        return e
    }

    /// The file's modification date and inode, read afresh (a URL caches its resource values).
    static func mtime(_ u: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return nil }
        return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(a[.systemFileNumber] ?? 0)"
    }

    /// A picture file of a person-free gradient, for the finder's tag checks (not for Vision's answer).
    static func gradientPNG(_ url: URL) {
        let w = 96, h = 64
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<w { ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(w), green: 0.4, blue: 0.6, alpha: 1)); ctx.fill(CGRect(x: x, y: 0, width: 1, height: h)) }
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(d)
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let args = CommandLine.arguments
        guard let photo = args.dropFirst().first(where: { !$0.hasPrefix("--") }) else { print("usage: found_mask_selftest <photograph with a person>"); exit(2) }

        try await files()
        try await sweep()
        try await finderTag()
        await unavailable()
        await tidies()
        try await phantom(street: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                            .appendingPathComponent("../../SampleSources/scene_raw_srgb.jpg").standardizedFileURL,
                          people: URL(fileURLWithPath: photo))
        try await vision(URL(fileURLWithPath: photo))

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: A

    static func files() async throws {
        let root = scratch.appendingPathComponent("A/Masks", isDirectory: true)
        let store = FoundMaskFiles(folder: root)
        let frame = UUID()
        let p = picture(40, 30, seed: 1), m = mask(p)
        let a = try await store.write(p, m, frame: frame)
        expect(FoundMaskFiles.isAsset(a), "an asset is 32 hex digits (\(a))")
        let file = root.appendingPathComponent(frame.uuidString).appendingPathComponent(a + ".spkmask")
        expect(FileManager.default.fileExists(atPath: file.path), "it is Masks/<frame>/<asset>.spkmask")
        let back = try await store.read(a, in: frame)
        expect(back?.bytes == p.bytes && back?.width == 40 && back?.height == 30, "read back: the same bytes and size")
        var inverted = m; inverted.invert = true
        expect(FoundMaskFiles.asset(p, inverted) == a, "主体 and 背景 are one file: the part's invert is not in the name")
        let other = FoundMaskFiles.asset(picture(40, 30, seed: 2), m)
        var later = m; later.system = "Version 28.0 (Build 27A1)"
        expect(other != a && FoundMaskFiles.asset(p, later) != a, "another picture, or the same from another system, is another asset")
        let before = mtime(file)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let again = try await store.write(p, m, frame: frame)
        expect(again == a && mtime(file) == before, "a second write of the same is the same asset and leaves the file as it was (immutable)")
        // 重新查找 with another answer: a new file; the old stays.
        let b = try await store.write(picture(40, 30, seed: 3), m, frame: frame)
        expect(b != a && FileManager.default.fileExists(atPath: file.path), "a new find is a new file; the old one stays")
        // Damaged, twice: a byte of the packed picture changed (zlib's own check refuses it), and a whole, valid file
        // of another picture put under this one's name (only the name's hash can tell).
        let good = try Data(contentsOf: file)
        var bytes = good
        bytes[bytes.count - 3] ^= 0x5a
        try bytes.write(to: file)
        var damaged = false
        do { _ = try await store.read(a, in: frame) } catch FoundMaskFiles.Failure.damaged { damaged = true }
        expect(damaged, "a file whose packed bytes are broken is refused as damaged")
        let swapped = FoundMaskFiles.encode(picture(40, 30, seed: 4), m)!
        var forged = swapped.data
        let at = forged.range(of: Data(swapped.asset.utf8))!
        forged.replaceSubrange(at, with: Data(a.utf8))
        try forged.write(to: file)
        damaged = false
        do { _ = try await store.read(a, in: frame) } catch FoundMaskFiles.Failure.damaged { damaged = true }
        expect(damaged, "a whole file of another picture under this one's name is refused: its bytes do not hash to the name")
        try good.write(to: file)
        expect(await store.url("../../\(a)") == nil && !FoundMaskFiles.isAsset("../x"), "a name that is a path names no file")
        // No folder: nothing written, said.
        var noFolder = false
        do { _ = try await FoundMaskFiles(folder: nil).write(p, m, frame: frame) } catch FoundMaskFiles.Failure.noFolder { noFolder = true }
        expect(noFolder, "a library with no folder writes nothing and says so")
    }

    // MARK: B

    static func sweep() async throws {
        let root = scratch.appendingPathComponent("B/Masks", isDirectory: true)
        let store = FoundMaskFiles(folder: root)
        let f = UUID(), g = UUID(), gone = UUID(), shelfOnly = UUID()
        var name: [String: String] = [:]
        for (i, k) in ["edit", "history", "clone", "shelf", "nothing", "young"].enumerated() {
            let p = picture(16, 12, seed: 10 + i)
            name[k] = try await store.write(p, mask(p), frame: f)
        }
        // The history: a state with the layer made from `history`, then the edit moved on (the layer deleted).
        let history = InMemoryEditHistoryStore()
        let before = DevelopRevision(edit: edit([name["history"]!]), pair: nil, sourceDecodes: [:])
        let now = DevelopRevision(edit: edit([name["edit"]!]), pair: nil, sourceDecodes: [:])
        try await history.append(f, HistoryAppend(before: before, after: now, origin: .develop, label: HistoryLabel(key: "Mask"), at: Date(), mode: .amends))
        // layers.json with an entry this build does not read (a later build's shape), naming `shelf`.
        let shelf = scratch.appendingPathComponent("B/layers.json")
        try Data("{\"version\":1,\"frames\":{\"\(f.uuidString)\":{\"version\":9,\"futureItems\":[{\"parts\":[{\"asset\" : \"\(name["shelf"]!)\"}]}]}}}".utf8).write(to: shelf)
        let edits: [UUID: FrameEdit] = [f: edit([name["edit"]!]), g: edit([name["clone"]!])]
        let later = Date().addingTimeInterval(FoundMaskFiles.sweepAge + 5)
        // Young: written just now, swept at `now` → kept.
        let young = await FoundMaskKeeping.pageClosed(frame: f, edits: edits, layersFile: shelf, history: history, files: store, now: Date())
        expect(young.swept.isEmpty, "nothing younger than \(Int(FoundMaskFiles.sweepAge)) s goes (a find kept as the page closed)")
        // A history that cannot be read: nothing goes.
        let refused = await FoundMaskKeeping.pageClosed(frame: f, edits: edits, layersFile: shelf, history: RefusingHistory(), files: store, now: later)
        expect(refused.swept.isEmpty, "a history that cannot be read sweeps nothing")
        let swept = await FoundMaskKeeping.pageClosed(frame: f, edits: edits, layersFile: shelf, history: history,
                                                      extra: [name["young"]!], files: store, now: later)
        expect(Set(swept.swept) == [name["nothing"]!], "the sweep takes what nothing names, only that (\(swept.swept.count) went)")
        for k in ["edit", "history", "clone", "shelf", "young"] {
            let kept = try await store.read(name[k]!, in: f)
            expect(kept != nil, "kept: the file named by \(k == "edit" ? "the edit" : k == "history" ? "a history state only" : k == "clone" ? "another frame's edit (a clone)" : k == "shelf" ? "layers.json's unread entry" : "the session's unsent state")")
        }
        // The clone's page opens: its asset is adopted into its own folder.
        let opened = await FoundMaskKeeping.pageOpened(frame: g, edit: edits[g]!, files: store)
        let gFile = root.appendingPathComponent(g.uuidString).appendingPathComponent(name["clone"]! + ".spkmask")
        expect(opened.adopted == 1 && FileManager.default.fileExists(atPath: gFile.path) && opened.missing.isEmpty,
               "a clone's page adopts the file its edit names into its own folder")
        // F removed while a third frame H, never opened, names `edit`'s file: it is handed to H, the rest go.
        let h = UUID()
        await FoundMaskKeeping.framesRemoved([f], remaining: [g: edits[g]!, h: edit([name["edit"]!])], files: store)
        let hFile = root.appendingPathComponent(h.uuidString).appendingPathComponent(name["edit"]! + ".spkmask")
        let cloneKept = try await store.read(name["clone"]!, in: g)
        expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(f.uuidString).path) && FileManager.default.fileExists(atPath: hFile.path)
               && cloneKept != nil,
               "a frame removed takes its folder, handing a file another frame names to it first")
        // The launch's tidy: a folder of a frame the library no longer has goes; one layers.json still lists stays.
        let p = picture(8, 8, seed: 99)
        _ = try await store.write(p, mask(p), frame: gone)
        _ = try await store.write(p, mask(p), frame: shelfOnly)
        try Data("{\"version\":1,\"frames\":{\"\(shelfOnly.uuidString)\":{\"later\":true}}}".utf8).write(to: shelf)
        let tidy = await FoundMaskKeeping.launchTidy(edits: [g: edits[g]!, h: edit([name["edit"]!])], layersFile: shelf, files: store)
        expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(gone.uuidString).path)
               && FileManager.default.fileExists(atPath: root.appendingPathComponent(shelfOnly.uuidString).path)
               && FileManager.default.fileExists(atPath: hFile.path) && tidy.removed >= 1,
               "the launch's tidy takes the folder of a frame that is gone, never one layers.json still lists or one in the library")
    }

    /// A history store that cannot be read (a newer build's).
    actor RefusingHistory: EditHistoryStore {
        nonisolated var limit: Int { 256 }
        func open(_ frame: UUID, current: DevelopRevision, radius: Int, at: Date) throws -> HistoryWindow { throw EditHistoryError.newerSchema(found: 9, known: 2) }
        func listing(_ frame: UUID) throws -> HistoryListing? { throw EditHistoryError.newerSchema(found: 9, known: 2) }
        func state(_ frame: UUID, seq: Int) throws -> DevelopRevision? { throw EditHistoryError.newerSchema(found: 9, known: 2) }
        func states(_ frame: UUID, seqs: ClosedRange<Int>) throws -> [Int: DevelopRevision] { throw EditHistoryError.newerSchema(found: 9, known: 2) }
        func append(_ frame: UUID, _ step: HistoryAppend) throws -> Int? { throw EditHistoryError.newerSchema(found: 9, known: 2) }
        func move(_ frame: UUID, to seq: Int) throws {}
        func amend(_ frame: UUID, current: DevelopRevision) throws {}
        func clear(_ frame: UUID, keeping current: DevelopRevision) throws {}
        func remove(_ frames: Set<UUID>) throws {}
        func bytesOnDisk() throws -> Int64 { 0 }
        func clearAll(except: Set<UUID>) throws {}
    }

    // MARK: F

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Answers after `delay`, a 12 × 8 square, counting its calls.
    struct SlowDetector: MaskDetector {
        var delay: UInt64 = 300_000_000
        let calls = Calls()
        func answer() -> FoundPicture { FoundPicture(width: 12, height: 8, bytes: (0..<96).map { $0 % 12 >= 3 && $0 % 12 < 9 ? 255 : 0 }) }
        func subject(_ image: CGImage) async throws -> FoundPicture? { calls.add(); try await Task.sleep(nanoseconds: delay); return answer() }
        func persons(_ image: CGImage) async throws -> [FoundPicture] { calls.add(); try await Task.sleep(nanoseconds: delay); return [answer()] }
        func people(_ image: CGImage) async throws -> FoundPicture? { answer() }
    }

    static func finderTag() async throws {
        let png = scratch.appendingPathComponent("F-gradient.png")
        gradientPNG(png)
        let detector = SlowDetector()
        let finder = SubjectFinder(detector: detector, files: FoundMaskFiles(folder: scratch.appendingPathComponent("F/Masks")))
        let a = FindSource(frame: UUID(), url: png, isRAW: false, decode: DecodeSettings())
        let b = FindSource(frame: UUID(), url: png, isRAW: false, decode: DecodeSettings())
        await finder.focus(a.tag)
        func late(_ change: @escaping () async -> Void) async -> SubjectFinder.Failure? {
            let job = Task { try await finder.subject(a, again: true) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            await change()
            do { _ = try await job.value; return nil } catch let f as SubjectFinder.Failure { return f } catch { return .failed("\(error)") }
        }
        expect(await late({}) == nil, "a result for the frame still open is taken")
        expect(await late({ await finder.focus(b.tag) }) == .dropped, "a result that lands after the page moved to another frame is dropped")
        var lens = a; lens.isRAW = true; lens.decode.lensCorrection = true
        var plain = a; plain.isRAW = true
        expect(plain.tag != lens.tag && lens.madeOn.lensCorrection && !plain.madeOn.lensCorrection, "a RAW's tag and madeOn carry its lens correction")
        expect(await late({ await finder.focus(FindTag(frame: a.frame, geometry: "raw|lens=1")) }) == .dropped,
               "a result that lands after the frame's decode geometry changed (镜头校正) is dropped")
        // The memo: 人 a second time answers at once, without asking the detector.
        await finder.focus(a.tag)
        let n0 = detector.calls.count
        let first = try await finder.people(a)
        let n1 = detector.calls.count
        let second = try await finder.people(a)
        expect(n1 == n0 + 1 && detector.calls.count == n1 && second.count == first.count && first.count == 1,
               "人's second ask is the memo's (the detector asked once), \(first.count) person")
        let again = try await finder.people(a, again: true)
        expect(detector.calls.count == n1 + 1 && again.count == 1, "重新查找 asks the detector again")
        expect(first.people[0].thumbnail.width > 0 && abs(first.people[0].thumbnail.width * 96 - first.people[0].thumbnail.height * 64) < 1e-6,
               "a person's thumbnail is a square of the photograph's pixels")
    }

    // MARK: K

    /// Two instances at the rendition's size (96 × 64): one inside the left half, one in the right; 全部人物 at its
    /// model's own size (24 × 16) covering the left half only.
    struct PhantomDetector: MaskDetector {
        func half(_ w: Int, _ h: Int, left: Bool) -> FoundPicture {
            FoundPicture(width: w, height: h, bytes: (0..<(w * h)).map { i in
                let x = i % w, y = i / w
                let inside = (left ? x >= w / 8 && x < w * 3 / 8 : x >= w * 5 / 8 && x < w * 7 / 8) && y >= h / 4 && y < h * 3 / 4
                return inside ? 255 : 0
            })
        }
        func subject(_ image: CGImage) async throws -> FoundPicture? { nil }
        func persons(_ image: CGImage) async throws -> [FoundPicture] { [half(96, 64, left: true), half(96, 64, left: false)] }
        func people(_ image: CGImage) async throws -> FoundPicture? {
            FoundPicture(width: 24, height: 16, bytes: (0..<(24 * 16)).map { $0 % 24 < 12 ? 255 : 0 })
        }
    }

    static func phantom(street: URL, people: URL) async throws {
        let png = scratch.appendingPathComponent("K-gradient.png")
        gradientPNG(png)
        let stand = SubjectFinder(detector: PhantomDetector(), files: FoundMaskFiles(folder: nil))
        let r = try await stand.people(FindSource(frame: UUID(), url: png, isRAW: false, decode: DecodeSettings()))
        expect(r.count == 1 && r.people.first?.number == 1 && (r.people.first?.found.box?.x ?? 1) < 0.5 && r.all != nil,
               "an instance 全部人物 does not overlap is dropped, the one it covers kept as 人物 1 (\(r.count) kept of 2)")
        let copy = scratch.appendingPathComponent("K-" + street.lastPathComponent)
        try FileManager.default.copyItem(at: street, to: copy)
        let finder = SubjectFinder(files: FoundMaskFiles(folder: nil))
        let s = try await finder.people(FindSource(frame: UUID(), url: copy, isRAW: false, decode: DecodeSettings()))
        expect(s.count == 0 && s.all == nil, "a street with nobody in it (\(street.lastPathComponent)): no person and no 全部人物 (\(s.count) people)")
        let copy2 = scratch.appendingPathComponent("K-" + people.lastPathComponent)
        try FileManager.default.copyItem(at: people, to: copy2)
        let p = try await finder.people(FindSource(frame: UUID(), url: copy2, isRAW: false, decode: DecodeSettings()))
        expect(p.count >= 1 && p.all != nil, "a photograph with people (\(people.lastPathComponent)): \(p.count) kept")
        // The shares the threshold is set between, printed for the record (`SubjectFinder.personOverlap`).
        for url in [copy, copy2] {
            let (image, _) = try await finder.rendition(FindSource(frame: UUID(), url: url, isRAW: false, decode: DecodeSettings()))
            let persons = try await VisionDetector().persons(image), all = try await VisionDetector().people(image)
            let shares = persons.map { p in all.map { SubjectFinder.overlap(p, under: $0) } ?? 0 }
            print("note  \(url.lastPathComponent): \(persons.count) instance(s), share under 全部人物 " + shares.map { String(format: "%.3f", $0) }.joined(separator: ", "))
        }
        // `--shares FILE…`: the same for more photographs (how the threshold was measured).
        if CommandLine.arguments.contains("--shares") {
            for path in CommandLine.arguments.dropFirst().filter({ !$0.hasPrefix("--") }).dropFirst() {
                let u = scratch.appendingPathComponent("K-share-" + URL(fileURLWithPath: path).lastPathComponent)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: u)
                let raw = !["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains(u.pathExtension.lowercased())
                guard let (image, _) = try? await finder.rendition(FindSource(frame: UUID(), url: u, isRAW: raw, decode: DecodeSettings())) else { continue }
                let persons = try await VisionDetector().persons(image), all = try await VisionDetector().people(image)
                let shares = persons.map { p in all.map { SubjectFinder.overlap(p, under: $0) } ?? 0 }
                print("note  \(u.lastPathComponent): \(persons.count) instance(s), share " + shares.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            }
        }
    }

    // MARK: G

    static func unavailable() async {
        let finder = SubjectFinder(detector: UnavailableDetector(), files: FoundMaskFiles(folder: nil))
        let png = scratch.appendingPathComponent("G-gradient.png")
        gradientPNG(png)
        let source = FindSource(frame: UUID(), url: png, isRAW: false, decode: DecodeSettings())
        var said = "", f: SubjectFinder.Failure?, g: SubjectFinder.Failure?
        do { _ = try await finder.subject(source); said = "none" } catch let e as SubjectFinder.Failure { said = "\(e)"; f = e } catch { said = "\(error)" }
        do { _ = try await finder.people(source) } catch let e as SubjectFinder.Failure { g = e } catch {}
        if case .unavailable = f, case .unavailable = g {
            expect(true, "a detector that is not there: 主体 and 人 say \"\(said)\"")
        } else { expect(false, "a detector that is not there: \(said)") }
        if #available(macOS 15.0, *) {
            let other = VisionError.operationFailed("x")
            expect(SubjectFinder.failure(VisionError.unsupportedComputeDevice("no device")) == .unavailable("no device")
                   && SubjectFinder.failure(other) == .failed("\(other)"),
                   "Vision's unsupported-device error is unavailable; another error is a failure")
        }
    }


    // MARK: I

    @MainActor static func tidiesOnMain() -> Bool {
        let root = scratch.appendingPathComponent("I", isDirectory: true)
        let masks = FoundMaskFiles.folder(in: root).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        let file = masks.appendingPathComponent(String(repeating: "a", count: 32) + ".spkmask")
        try? Data("x".utf8).write(to: file)
        let wc = WorkingCopies(folder: root.appendingPathComponent("WorkingCopies"), limit: 1000)
        wc.clear()
        wc.sweep(known: [])
        let previews = root.appendingPathComponent("Previews")
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        StorageTidy.sweep(previews, keeping: [], now: Date().addingTimeInterval(1e6), age: 0)
        StorageTidy.sweepCards(StorageTidy.cardsFolder(in: previews), keepingFrames: [])
        return FileManager.default.fileExists(atPath: file.path)
    }

    static func tidies() async {
        let kept = await MainActor.run { tidiesOnMain() }
        expect(kept, "Clear Working Copies, the working copies' sweep and the previews' and cards' tidies leave Masks/ whole")
    }

    // MARK: C, D, E, H, J

    static func vision(_ original: URL) async throws {
        let copy = scratch.appendingPathComponent("photo-" + original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)
        let root = scratch.appendingPathComponent("C/Masks", isDirectory: true)
        let store = FoundMaskFiles(folder: root)
        let frame = UUID()
        let source = FindSource(frame: frame, url: copy, isRAW: false, decode: DecodeSettings())
        let finder = SubjectFinder(files: store)
        await finder.focus(source.tag)
        guard let subject = try await finder.subject(source) else { expect(false, "Vision finds the subject of \(original.lastPathComponent)"); return }
        expect(subject.mask.detector == SubjectFinder.subjectDetector && subject.mask.revision == 1 && !subject.mask.system.isEmpty
               && subject.mask.fingerprint.count == 32 && subject.mask.decodeGeometry == "image",
               "the provenance: \(subject.mask.detector) rev \(subject.mask.revision), \(subject.mask.system), \(subject.picture.width) x \(subject.picture.height)")
        // 人 on the same photograph: each person, the menu's squares, and 全部人物 at the model's size.
        do {
            let people = try await finder.people(source)
            let inside = people.people.allSatisfy { p in let t = p.thumbnail; return t.x >= 0 && t.y >= 0 && t.x + t.width <= 1 + 1e-9 && t.y + t.height <= 1 + 1e-9 }
            expect(people.count >= 1 && people.all != nil && inside && people.people.map(\.number) == Array(1...people.count)
                   && people.people.allSatisfy { $0.found.mask.what == .person && $0.found.mask.instance == $0.number }
                   && people.all?.mask.what == .people,
                   "人: \(people.count) people, each a mask and a square inside the picture, and 全部人物 at \(people.all.map { "\($0.picture.width) x \($0.picture.height)" } ?? "none")")
        } catch { expect(false, "人 on \(original.lastPathComponent): \(error)") }
        let fg = try await finder.part(subject)
        let bg = try await finder.part(subject, background: true)
        expect(fg.asset == bg.asset && bg.found?.invert == true && fg.found?.invert == false, "主体 and 背景 name one asset, 背景 with the part's invert")
        // H: the same photograph again, by a finder of its own (a model loaded again).
        let other = SubjectFinder(files: store)
        let twice = try await other.subject(source, again: true)
        let same = twice?.picture.bytes == subject.picture.bytes
        var asset2: String? = nil
        if let twice { asset2 = try await other.part(twice).asset }
        print("note  determinism: the same photograph twice -> \(same ? "the same bytes" : "OTHER bytes"), asset \(asset2 == fg.asset ? "the same" : "another")")
        expect(same && asset2 == fg.asset, "the same photograph twice gives the same mask, to the byte, and the same asset (this Mac, this system)")

        // C: bake from the files alone (nothing handed): the baker's store reads them.
        guard let device = MTLCreateSystemDefaultDevice() else { expect(false, "a Metal device"); return }
        let baker = try MaskBaker(device: device, store: MaskStore(files: store))
        let src = PixelSize(width: 3000, height: 2000)
        let layer = { (p: MaskPart) in LocalLayer(name: "主体 1", stage: .scene, parts: [p]) }
        let a: MaskPlane, b: MaskPlane
        do {
            a = try await baker.bake(layer(fg), source: src)
            b = try await baker.bake(layer(bg), source: src)
        } catch { expect(false, "主体 and 背景 bake from the kept file alone: \(error)"); return }
        let sums = zip(a.values, b.values).map { Int($0) + Int($1) }
        let exact = sums.filter { $0 == 65535 }.count
        expect(sums.allSatisfy { abs($0 - 65535) <= 1 },
               String(format: "背景 + 主体 = 65,535 at every texel within a count, from one file (%d…%d; exact at %.2f %% of %d)",
                      sums.min()!, sums.max()!, 100 * Double(exact) / Double(sums.count), sums.count))
        // D: the plane is the picture resampled by mask_found's rule — bilinear between texel centres, clamped at the
        // edge, × 1/255, quantised by rint — written again here in float32 as the kernel's statements are (the bar: a
        // count, for a GPU's fused multiply-add), and in double (reported: float32's own coordinate rounding at a hard
        // edge of the mask is what separates them).
        let pic = subject.picture
        let av = a.values
        var worst = 0, worstDouble = 0, exactly = 0
        let pw = Float(pic.width), ph = Float(pic.height)
        for j in 0..<a.height {
            for i in 0..<a.width {
                let s = (Float(i) + 0.5) / Float(a.width), t = (Float(j) + 0.5) / Float(a.height)
                let x = min(max(s * pw - 0.5, 0), pw - 1), y = min(max(t * ph - 0.5, 0), ph - 1)
                let x0f = x.rounded(.down), y0f = y.rounded(.down), tx = x - x0f, ty = y - y0f
                let x0 = Int(x0f), y0 = Int(y0f), x1 = min(x0 + 1, pic.width - 1), y1 = min(y0 + 1, pic.height - 1)
                func v(_ xx: Int, _ yy: Int) -> Float { Float(pic.bytes[yy * pic.width + xx]) }
                let top = v(x0, y0) + (v(x1, y0) - v(x0, y0)) * tx, bot = v(x0, y1) + (v(x1, y1) - v(x0, y1)) * tx
                let f = min(max((top + (bot - top) * ty) * (1 / Float(255)), 0), 1)
                let ref = Int((f * 65535).rounded(.toNearestOrEven))
                let got = Int(av[j * a.width + i])
                worst = max(worst, abs(ref - got))
                if ref == got { exactly += 1 }
                // Double, for the record.
                let sd = (Double(i) + 0.5) / Double(a.width), td = (Double(j) + 0.5) / Double(a.height)
                let xd = min(max(sd * Double(pw) - 0.5, 0), Double(pw) - 1), yd = min(max(td * Double(ph) - 0.5, 0), Double(ph) - 1)
                let x0d = Int(xd), y0d = Int(yd), x1d = min(x0d + 1, pic.width - 1), y1d = min(y0d + 1, pic.height - 1)
                func w(_ xx: Int, _ yy: Int) -> Double { Double(pic.bytes[yy * pic.width + xx]) }
                let txd = xd - Double(x0d), tyd = yd - Double(y0d)
                let topd = w(x0d, y0d) + (w(x1d, y0d) - w(x0d, y0d)) * txd, botd = w(x0d, y1d) + (w(x1d, y1d) - w(x0d, y1d)) * txd
                worstDouble = max(worstDouble, abs(Int(((topd + (botd - topd) * tyd) / 255 * 65535).rounded()) - got))
            }
        }
        expect(worst <= 1, String(format: "the baked plane is the found picture resampled by the kernel's bilinear rule: worst %d count of 65,535 against its float32 statements, equal at %.3f %% (%d x %d from %d x %d; against double, worst %d)",
                                  worst, 100 * Double(exactly) / Double(av.count), a.width, a.height, pic.width, pic.height, worstDouble))

        // E: a part whose file is gone fails the bake naming its layer; `missing` names it too.
        let missingPart = MaskPart.found(subject.mask, asset: String(repeating: "0", count: 32))
        let gone = LocalLayer(name: "主体 2", stage: .finished, parts: [missingPart])
        var named: UUID? = nil
        do { _ = try await baker.bake(gone, source: src) } catch MaskBaker.Failure.missingFound(_, let id, _) { named = id }
        expect(named == gone.id, "a found part with no file fails the bake, naming its layer (never baked empty or full)")
        let marks = await FoundMaskKeeping.missing(LocalLayers(items: [layer(fg), gone]), files: store)
        expect(marks.keys.sorted { $0.uuidString < $1.uuidString } == [gone.id], "FoundMaskKeeping.missing names the layer whose file is gone, only it")

        // J: the 场景 and 成片 paths, through the shared files (the app's), nothing handed.
        FoundMaskFiles.shared.use(root)
        var scene = layer(fg); scene.scene = SceneDeltas(exposure: 1)
        guard let ask = SceneLayerWire.ask(LocalLayers(items: [scene]), source: src, hostCut: nil, decode: src) else { expect(false, "a 场景 ask"); return }
        let planes = (try? SceneLayerWire.planes(for: ask, device: device)) ?? []
        expect(planes.first?.values == av, "场景: SceneLayerWire.planes bakes a stored found part from its file, the same plane")
        var fin = LocalLayer(name: "背景 1", stage: .finished, parts: [bg]); fin.finished?.exposure = 1
        guard let fl = FinishedLayers.of(LocalLayers(items: [fin]), adjustments: Adjustments(), source: src, toSource: .identity) else {
            expect(false, "a 成片 ask"); return
        }
        let fp = (try? await fl.planes(device: device)) ?? []
        expect(fp.first?.values == b.values, "成片: FinishedLayers.planes bakes it too (the page, zoom, tiles, histogram, export read these)")
        FoundMaskFiles.shared.use(nil)
    }
}
