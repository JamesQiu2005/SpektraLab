//  MacHistoryCheck.swift — a debug build's proof, in the running app, that a frame's edit history outlives its
//  page and the app (PRD-F §7.1 and §7.5).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --library real --import <folder> --history-check <dir> [--history-check-exit]
//      CFFIXED_USER_HOME=<same>/home  SpektraLab --library real --history-check <dir2> --history-check-relaunch <dir> [--history-check-exit]
//
//  `tools/history_check.sh` runs both, with copies of the fixtures (a develop writes a sidecar). Writes
//  `<dir>/report.json`; the first run also writes `<dir>/recorded.json`, what the relaunch holds itself to.
//
//  The first run (`--history-check <dir>`):
//
//  S. **The frame switch** (PRD-F §1, the loss read from the code): Develop opened on A with a strip of A and
//     B, three edits on A's page, a step to B (the page is rebuilt per frame, `DevelopPane(…).id(id)`) and back:
//     ⌘Z must give A's second edit and ⇧⌘Z its third. B is given 20 edits on its page, for the relaunch's walk
//     past the states a session holds.
//  P. **A half-frame pair** of C and D, on its session: the look's exposure, C's white balance from the pair's
//     darkroom (`changeDecode`), the left hole's own exposure. C gets one `composite` step, named for the pair.
//  D. **A double exposure** of E and F: the print's brightness, E's white balance (`changeDecode(of:inDouble:)`),
//     the top exposure's stops.
//  V. **Paste Settings onto five frames with no page open** (G…K, `pasteOntoLibrary`): one `paste` step each,
//     named for L.
//  The library is flushed and the store's line drained, as a quit leaves them, and the app exits.
//
//  The relaunch (`--history-check-relaunch <dir>`, the first run's report folder):
//
//  R. A's page opens with no change to reconcile; ⌘Z ×3 gives each recorded edit back, ⇧⌘Z ×3 forward again.
//     B: ⌘Z ×20 to its first state, through reads past the window. The pair and the double the same way,
//     their members' decodes with them. The five pasted frames hold one step each. Clear Working Copies leaves
//     every history; removing a frame removes its own.
//
//  The page's run (`--history-check-page`, after the relaunch): `MacHistoryPageCheck`.
//
//  Refuses to run without `CFFIXED_USER_HOME`: the debug build keeps its library where the person's is.
//  Not in a release build.

#if DEBUG
import Foundation
import UIKit

@MainActor
enum MacHistoryCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--history-check"), i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let exits = arguments.contains("--history-check-exit")
        let relaunch = arguments.firstIndex(of: "--history-check-relaunch").flatMap { j in
            j + 1 < arguments.count ? URL(fileURLWithPath: arguments[j + 1]) : nil
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let r = Report()
            if let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty {
                r.note("start", ["home": NSHomeDirectory(), "store": SQLiteEditHistoryStore.file(in: ImportService.root).path])
                let fixed = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
                r.check(ImportService.root.resolvingSymlinksInPath().path.hasPrefix(fixed), "the library and its history are under the scratch home")
                if let previous = relaunch, arguments.contains("--history-check-newer") {
                    await newer(model, r, previous: previous)
                } else if let previous = relaunch, let q = arguments.firstIndex(of: "--history-check-quit"), q + 1 < arguments.count {
                    await quit(model, r, kind: arguments[q + 1], previous: previous, out: out)
                } else if let previous = relaunch, arguments.contains("--history-check-afterquit") {
                    await afterQuit(model, r, previous: previous)
                } else if let previous = relaunch, arguments.contains("--history-check-page") {
                    if let data = try? Data(contentsOf: previous.appending(path: "recorded.json")),
                       let kept = try? JSONDecoder().decode(Recorded.self, from: data) {
                        await MacHistoryPageCheck.run(model, r, kept: kept)
                    } else { r.check(false, "page: the first run's recorded.json is there to read") }
                } else if let previous = relaunch {
                    await relaunched(model, r, previous: previous)
                } else {
                    var kept = Recorded()
                    await frameSwitch(model, r, &kept)
                    await composites(model, r, &kept)
                    await pasted(model, r, &kept)
                    kept.recordMillis = OpenFrameSession.recordMillis
                    if let data = try? JSONEncoder().encode(kept) {
                        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                        try? data.write(to: out.appending(path: "recorded.json"))
                    }
                }
                let ms = OpenFrameSession.recordMillis.sorted()
                if !ms.isEmpty {
                    r.note("budget: a step recorded on the main actor (snapshot, diff, label, hand-off)",
                           ["steps": ms.count, "median_ms": ms[ms.count / 2], "max_ms": ms.last!])
                    r.check(ms[ms.count / 2] <= 1, "budget: recording a step on the main actor ≤ 1 ms (median \(ms[ms.count / 2]))")
                }
            } else {
                r.check(false, "CFFIXED_USER_HOME is set (the debug build keeps its library where the person's is): refused to run")
            }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": r.failures.isEmpty,
                                         "home": NSHomeDirectory()]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("history-check: wrote \(out.appending(path: "report.json").path), \(r.checks) checks, \(r.failures.count) failures")
            if exits {
                // As a quit leaves them: the library written, every step the line holds made.
                await model.history.drained()
                model.library.flush()
                await model.macLibrary.host.shutdown()
                exit(r.failures.isEmpty ? 0 : 1)
            }
        }
    }

    // MARK: - the report

    final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var checks = 0
        func note(_ name: String, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            steps.append(s)
            print("history-check: \(name) \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures.append(what); print("history-check: FAIL \(what)") } else { print("history-check: ok \(what)") }
        }
    }

    static func until(_ seconds: Double, every ms: Int = 50, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(ms))
        }
        return done()
    }

    /// The library's photographs, once the launch's import has made them.
    static func photographs(_ model: AppServices, atLeast n: Int) async -> [LibraryFrame] {
        _ = await until(60, every: 200) { model.library.frames.filter { !$0.isComposite && !$0.isDemo }.count >= n }
        return model.library.frames.filter { !$0.isComposite && !$0.isDemo }.sorted { $0.fileName < $1.fileName }
    }

    /// One gesture on a page's session, as a control does it: began, the change, the lift.
    static func gesture(_ session: OpenFrameSession, _ mutate: (inout FrameEdit) -> Void) {
        session.began(.shoot)
        session.change(mutate)
        session.ended()
    }

    // MARK: - S. the frame switch

    /// What the first run did, for the relaunch to hold itself to.
    struct Recorded: Codable {
        var photo: UUID?
        var photoEdits: [FrameEdit] = []
        var long: UUID?
        var longEdits: [FrameEdit] = []
        var pair: UUID?
        var pairMember: UUID?
        var pairStates: [DevelopRevision] = []
        var double: UUID?
        var doubleMember: UUID?
        var doubleStates: [DevelopRevision] = []
        var pasted: [UUID] = []
        var pasteSource = ""
        var recordMillis: [Double] = []
    }

    /// The store's listing of a frame, after every call sent before.
    static func listing(_ model: AppServices, _ id: UUID) async -> HistoryListing? {
        try? await model.history.ask("check") { try await $0.listing(id) }
    }

    /// The state numbered `seq` of a frame's history, after every call sent before.
    static func state(_ model: AppServices, _ id: UUID, _ seq: Int) async -> DevelopRevision? {
        let s = try? await model.history.ask("check") { try await $0.state(id, seq: seq) }
        return s ?? nil
    }

    /// A session of the frame's with its history landed, and how long that took.
    static func opened(_ model: AppServices, _ id: UUID) async -> (OpenFrameSession, Double) {
        let t0 = ContinuousClock.now
        let s = model.session(for: id)
        s.enter()
        _ = await until(5, every: 1) { !s.historyLoading }
        let d = ContinuousClock.now - t0
        return (s, Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
    }

    private static func frameSwitch(_ model: AppServices, _ r: Report, _ kept: inout Recorded) async {
        let photos = await photographs(model, atLeast: 12)
        guard photos.count >= 12 else { r.check(false, "S: twelve photographs imported (\(photos.count))"); return }
        let a = photos[0].id, b = photos[1].id
        MacDevelopCarry.shared.frames = [a, b]
        model.router.toLibrary()
        model.router.open(.develop(a))
        let opened = await until(30) { model.openSession(a) != nil }
        r.check(opened, "S: Develop opens on \(photos[0].fileName)")
        guard opened, let page = model.openSession(a) else { return }
        var edits: [FrameEdit] = [page.edit]
        for ev in [0.3, 0.7, 1.1] {
            gesture(page) { $0.params.exposureCompensationEV = ev }
            edits.append(page.edit)
        }
        // Edits made while the page's history is still being read are laid on it when it lands.
        let undoableBefore = await until(5) { page.canUndo }
        r.check(undoableBefore, "S: the page can take its edits back before the switch")
        NotificationCenter.default.post(name: .spkCheckStep, object: 1)
        let onB = await until(30) { model.openSession(b) != nil && model.openSession(a) == nil }
        r.check(onB, "S: a step along the strip leaves A's page for B's")
        NotificationCenter.default.post(name: .spkCheckStep, object: -1)
        let back = await until(30) { model.openSession(a) != nil && model.openSession(b) == nil }
        r.check(back, "S: and a step back opens A's page again")
        guard back, let again = model.openSession(a) else { return }
        r.note("S: back on A", ["same_session": again === page, "edit_ev": again.edit.params.exposureCompensationEV])
        // The history is read off the main actor; ⌘Z waits for it (PRD-F §5), so the check waits too.
        let undoable = await until(5) { again.canUndo }
        r.check(undoable, "S: after the switch, Undo is there (canUndo \(again.canUndo))")
        again.undo()
        r.check(again.edit == edits[2], "S: ⌘Z gives A's second edit (EV \(again.edit.params.exposureCompensationEV), want \(edits[2].params.exposureCompensationEV))")
        again.redo()
        r.check(again.edit == edits[3], "S: ⇧⌘Z gives its third again (EV \(again.edit.params.exposureCompensationEV), want \(edits[3].params.exposureCompensationEV))")
        kept.photo = a
        kept.photoEdits = edits
        // B: twenty edits on its page, for the relaunch's walk past the window.
        NotificationCenter.default.post(name: .spkCheckStep, object: 1)
        _ = await until(30) { model.openSession(b) != nil && model.openSession(a) == nil }
        if let pageB = model.openSession(b) {
            _ = await until(5) { !pageB.historyLoading }
            var long: [FrameEdit] = [pageB.edit]
            for i in 1...20 {
                gesture(pageB) { $0.params.printBrightnessStops = Double(i) / 40 }
                long.append(pageB.edit)
            }
            kept.long = b
            kept.longEdits = long
        }
        model.router.toLibrary()
        _ = await until(10) { model.openSession(a) == nil && model.openSession(b) == nil }
        let la = await listing(model, a)
        r.check(la?.steps.count == 3 && la?.cursorSeq == 3 && la?.steps.allSatisfy { $0.origin == .develop } == true,
                "S: A's store holds its three develop steps, the cursor on the third (\(la?.steps.count ?? -1), \(la?.cursorSeq ?? -1))")
        let lb = await listing(model, b)
        r.check(lb?.steps.count == 20, "S: B's holds its twenty (\(lb?.steps.count ?? -1))")
    }

    // MARK: - P, D. a pair and a double

    private static func composites(_ model: AppServices, _ r: Report, _ kept: inout Recorded) async {
        let photos = await photographs(model, atLeast: 12)
        let c = photos[2].id, d = photos[3].id, e = photos[4].id, f = photos[5].id
        // P. The pair.
        guard let pairID = model.makePair(c, d) else { r.check(false, "P: a pair of C and D is made"); return }
        var (s, ms) = await opened(model, pairID)
        r.note("P: the pair's session opened", ["ms": ms, "reconciled": "\(String(describing: s.historyReconciled))"])
        var states = [s.historySnapshot()]
        gesture(s) { $0.params.exposureCompensationEV = 0.5 }
        states.append(s.historySnapshot())
        let side: HalfFramePair.Side = model.library.frame(pairID)?.pair?.left?.frame == c ? .left : .right
        model.changeDecode(of: side, in: pairID) { $0.whiteBalance = .custom; $0.temperature = 4200; $0.tint = 3 }
        model.keepDecode(of: side, in: pairID)
        states.append(s.historySnapshot())
        r.check(states[2].sourceDecodes[c]?.temperature == 4200, "P: the member's decode is in the pair's state")
        model.changePair(pairID) { piece, look in piece.exposure(0.7, of: side, look: &look.params) }
        states.append(s.historySnapshot())
        r.check(s.canUndo && Set(states.map { try! HistoryCodec.encode($0) }).count == 4, "P: three steps, each another state")
        s.leave()
        kept.pair = pairID
        kept.pairMember = c
        kept.pairStates = states
        let lp = await listing(model, pairID)
        r.check(lp?.steps.count == 3, "P: the pair's store holds three steps (\(lp?.steps.count ?? -1))")
        let lc = await listing(model, c)
        r.check(lc?.steps.count == 1 && lc?.steps.first?.origin == .composite
                && lc?.steps.first?.label == .composite(model.library.frame(pairID)?.fileName ?? "?"),
                "P: C, whose decode the pair moved, has one composite step named for the pair (\(lc?.steps.map { "\($0.origin) \($0.label)" } ?? []))")

        // D. The double.
        guard let doubleID = model.makeDouble(e, f, beginsWithFirst: true) else { r.check(false, "D: a double of E and F is made"); return }
        (s, ms) = await opened(model, doubleID)
        r.note("D: the double's session opened", ["ms": ms])
        states = [s.historySnapshot()]
        gesture(s) { $0.params.printBrightnessStops = 0.3 }
        states.append(s.historySnapshot())
        let bottomIsE = model.library.frame(doubleID)?.double?[.bottom]?.frame == e
        let position: DoubleExposure.Position = bottomIsE ? .bottom : .top
        model.changeDecode(of: position, inDouble: doubleID) { $0.whiteBalance = .custom; $0.temperature = 6100; $0.tint = -4 }
        states.append(s.historySnapshot())
        r.check(states[2].sourceDecodes[e]?.temperature == 6100, "D: the photograph's decode is in the double's state")
        model.changeDouble(doubleID) { x, _ in x.exposure(0.6, of: position == .bottom ? .top : .bottom) }
        states.append(s.historySnapshot())
        r.check(Set(states.map { try! HistoryCodec.encode($0) }).count == 4, "D: three steps, each another state")
        s.leave()
        kept.double = doubleID
        kept.doubleMember = e
        kept.doubleStates = states
        let ld = await listing(model, doubleID)
        r.check(ld?.steps.count == 3, "D: the double's store holds three steps (\(ld?.steps.count ?? -1))")
        let le = await listing(model, e)
        r.check(le?.steps.count == 1 && le?.steps.first?.origin == .composite, "D: E has one composite step")
    }

    // MARK: - V. a paste onto frames with no page open

    private static func pasted(_ model: AppServices, _ r: Report, _ kept: inout Recorded) async {
        let photos = await photographs(model, atLeast: 12)
        let targets = Array(photos[6..<11]).map(\.id), source = photos[11]
        var settings = source.edit
        settings.params.exposureCompensationEV = 1.3
        let clip = SettingsClip(groups: [.filmExposure], settings: settings, sourceName: source.fileName)
        model.pasteOntoLibrary(clip, onto: Set(targets))
        var steps: [Int] = []
        for id in targets { steps.append(await listing(model, id)?.steps.filter { $0.origin == .paste && $0.label == .paste(from: source.fileName) }.count ?? 0) }
        r.check(steps == [1, 1, 1, 1, 1], "V: Paste Settings onto five frames with no page open gives one paste step each (\(steps))")
        kept.pasted = targets
        kept.pasteSource = source.fileName
    }



    // MARK: - Q. a quit

    /// `--history-check-quit <kind>`: the app quits as ⌘Q quits it (`NSApplication terminate:`), timed, writing
    /// `<dir>/quit.json` first:
    /// - `steps`: forty steps on A from the one door and the library's edit with them, sent in the quit's own turn of
    ///   the main thread — still in their lines when the quit begins (`--history-check-afterquit` must find them);
    /// - `clean`: nothing pending (the library written, the line run out) — the quit is not delayed;
    /// - `stuck`: the store held up for ten seconds by a call in the line, then a step — the quit waits half a second
    ///   at most (`EditHistoryLine.drainAtQuit`) and goes.
    private static func quit(_ model: AppServices, _ r: Report, kind: String, previous: URL, out: URL) async {
        let photos = await photographs(model, atLeast: 12)
        guard let a = photos.first?.id else { r.check(false, "Q: A is there"); return }
        model.library.flush()
        await model.history.drained()
        let before = await listing(model, a)?.steps.count ?? 0
        let ev0 = model.library.frame(a)?.edit.params.exposureCompensationEV ?? 0
        var want: [String: Any] = ["kind": kind, "frame": a.uuidString]
        switch kind {
        case "steps": want["steps"] = before + 40; want["ev"] = 4.0
        case "stuck": want["steps_at_most"] = before; want["ev"] = ev0 + 0.5
        default: want["steps"] = before; want["ev"] = ev0
        }
        if kind == "stuck" {
            model.history.send("check: a stuck store") { _ in try await Task.sleep(for: .seconds(10)) }
            guard let was = model.historyRevision(a) else { return }
            model.library.update(a) { $0.edit.params.exposureCompensationEV = ev0 + 0.5 }
            model.recordStep(a, before: was, origin: .develop, label: nil)
        } else if kind == "steps" {
            for i in 1...40 {
                guard let was = model.historyRevision(a) else { break }
                model.library.update(a) { $0.edit.params.exposureCompensationEV = Double(i) / 10 }
                model.recordStep(a, before: was, origin: .develop, label: nil)
            }
        }
        want["terminate_at"] = Date().timeIntervalSince1970
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: want).write(to: out.appending(path: "quit.json"))
        print("history-check: Q: quitting (\(kind))")
        // What the quit says on its way, every notification of any centre's, timed from here.
        let t0 = Date()
        NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { n in
            let name = n.name.rawValue
            if name.contains("Terminat") || name.contains("Disconnect") || name.contains("Background") || name.contains("Resign")
                || name.contains("Close") || name.contains("Quit") || name.contains("Destroy") || name.contains("WillEnd") {
                print("history-check: Q: +\(Int(Date().timeIntervalSince(t0) * 1000)) ms \(name) main=\(Thread.isMainThread)")
            }
        }
        // ⌘Q's own way out: the application's terminate:.
        let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
        app?.perform(NSSelectorFromString("terminate:"), with: nil)
        print("history-check: terminate: returned")
        exit(3)
    }

    /// `--history-check-afterquit`: the relaunch after that quit: what it kept.
    private static func afterQuit(_ model: AppServices, _ r: Report, previous: URL) async {
        _ = await photographs(model, atLeast: 12)
        guard let data = try? Data(contentsOf: previous.appending(path: "quit.json")),
              let want = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (want["frame"] as? String).flatMap(UUID.init(uuidString:)), let kind = want["kind"] as? String else {
            r.check(false, "Q: the quitting run's quit.json is there to read"); return
        }
        let ev = model.library.frame(id)?.edit.params.exposureCompensationEV
        let l = await listing(model, id)
        r.note("Q: after the quit (\(kind))", ["ev": ev ?? -9, "steps": l?.steps.count ?? -1, "want": want])
        r.check(ev == want["ev"] as? Double, "Q (\(kind)): the library holds the edit made before the quit (EV \(ev ?? -9), want \(want["ev"] ?? "?"))")
        if let steps = want["steps"] as? Int {
            r.check((l?.steps.count ?? 0) == steps && l?.cursorSeq == l?.steps.last?.seq,
                    "Q (\(kind)): the history holds its steps, the cursor on the last (\(l?.steps.count ?? -1) of \(steps))")
        }
    }

    // MARK: - N. a newer build's store

    /// `--history-check-newer`: the store's file was stamped by a newer build (`tools/history_check.sh` sets its
    /// schema number past this build's). The page still opens and undoes, in memory alone; the file is not touched.
    private static func newer(_ model: AppServices, _ r: Report, previous: URL) async {
        guard let data = try? Data(contentsOf: previous.appending(path: "recorded.json")),
              let kept = try? JSONDecoder().decode(Recorded.self, from: data), let a = kept.photo else {
            r.check(false, "N: the first run's recorded.json is there to read")
            return
        }
        _ = await photographs(model, atLeast: 12)
        let file = SQLiteEditHistoryStore.file(in: ImportService.root)
        let bytes = try? Data(contentsOf: file)
        // The page's own state for such a file (PRD-F §3.5), drawn: the library's offer to become a catalog put off first.
        _ = await until(5) { model.macLibrary.move.showsPage }
        if model.macLibrary.move.showsPage { model.macLibrary.move.notNow(); try? await Task.sleep(for: .seconds(1)) }
        if let p = await MacHistoryPageCheck.page(model, a) {
            r.check(p.phase == .newer, "N: the page says History from a newer version (\(p.phase))")
            await MacHistoryPageCheck.capture("page-en-newer")
            await MacHistoryPageCheck.closePage(model)
        } else { r.check(false, "N: A's page opens") }
        let (s, _) = await opened(model, a)
        r.check(s.historyReconciled == nil && !s.canUndo, "N: a newer build's history is not read: the page opens with none (\(String(describing: s.historyReconciled)))")
        let was = s.edit
        gesture(s) { $0.params.exposureCompensationEV = -0.4 }
        r.check(s.canUndo, "N: an edit is still undoable, in memory")
        s.undo()
        r.check(s.edit == was, "N: and ⌘Z gives it back")
        s.leave()
        await model.history.drained()
        r.check(bytes != nil && (try? Data(contentsOf: file)) == bytes, "N: the newer file's bytes are as they were")
    }

    // MARK: - R. the relaunch

    private static func relaunched(_ model: AppServices, _ r: Report, previous: URL) async {
        guard let data = try? Data(contentsOf: previous.appending(path: "recorded.json")),
              let kept = try? JSONDecoder().decode(Recorded.self, from: data) else {
            r.check(false, "R: the first run's recorded.json is there to read")
            return
        }
        _ = await photographs(model, atLeast: 12)
        // A: ⌘Z ×3, ⇧⌘Z ×3, each edit against the one recorded.
        if let a = kept.photo, kept.photoEdits.count == 4 {
            let (s, ms) = await opened(model, a)
            r.note("R: A's session opened after the relaunch", ["ms": ms, "reconciled": "\(String(describing: s.historyReconciled))"])
            r.check(s.historyReconciled == .agreed, "R: A's library and store agree: nothing to reconcile")
            walk(s, r, "A", kept.photoEdits.map { DevelopRevision(edit: $0, pair: nil, sourceDecodes: [:]) }, steps: 3)
            s.leave()
        } else { r.check(false, "R: A was recorded") }
        // B: ⌘Z ×20, past the states the session holds (cursor ± 8), read as it goes.
        if let b = kept.long, kept.longEdits.count == 21 {
            let (s, _) = await opened(model, b)
            var reached = 0
            for i in stride(from: 19, through: 0, by: -1) {
                _ = await until(2, every: 1) { s.canUndo }
                s.undo()
                _ = await until(2, every: 1) { !s.historyReading }
                if s.edit == kept.longEdits[i] { reached += 1 }
            }
            r.check(reached == 20 && !s.canUndo, "R: B walks back 20 steps to its first state, past the window (\(reached) of 20)")
            s.leave()
        }
        if let p = kept.pair {
            let (s, _) = await opened(model, p)
            r.check(s.historyReconciled == .agreed, "R: the pair's library and store agree (\(String(describing: s.historyReconciled)))")
            walk(s, r, "pair", kept.pairStates, steps: 3)
            if let c = kept.pairMember {
                s.undo(); s.undo()
                r.check(model.library.frame(c)?.edit.decode == kept.pairStates[1].sourceDecodes[c],
                        "R: undone past it, the pair puts C's own decode back (\(String(describing: model.library.frame(c)?.edit.decode.temperature)))")
                s.redo(); s.redo()
            }
            s.leave()
        }
        if let d = kept.double {
            let (s, _) = await opened(model, d)
            r.check(s.historyReconciled == .agreed, "R: the double's library and store agree (\(String(describing: s.historyReconciled)))")
            walk(s, r, "double", kept.doubleStates, steps: 3)
            s.leave()
        }
        var steps: [Int] = []
        for id in kept.pasted { steps.append(await listing(model, id)?.steps.filter { $0.origin == .paste }.count ?? 0) }
        r.check(steps == [1, 1, 1, 1, 1], "R: the five pasted frames still hold one paste step each (\(steps))")
        // The page's 256 rows are read from the store, metadata only: here, the longest history's.
        if let b = kept.long {
            let t0 = ContinuousClock.now
            let l = await listing(model, b)
            let d = ContinuousClock.now - t0
            r.note("budget: a listing read on the line", ["steps": l?.steps.count ?? -1, "ms": Double(d.components.attoseconds) / 1e15])
        }
        // Clear Working Copies is not history's; removing a frame is.
        model.clearWorkingCopies()
        let afterClear = await listing(model, kept.photo ?? UUID())
        r.check(afterClear?.steps.count == 3, "R: Clear Working Copies leaves the history (\(afterClear?.steps.count ?? -1))")
        if let gone = kept.pasted.first {
            model.remove([gone])
            let l = await listing(model, gone)
            r.check(l == nil, "R: a frame removed from the library takes its history with it")
        }
        let onDisk = (try? await model.history.ask("check") { try await $0.bytesOnDisk() }) ?? -1
        r.note("budget: the store on disk", ["bytes": onDisk])
    }

    /// ⌘Z `steps` times, then ⇧⌘Z as many, each state against the one recorded (`states`, oldest first).
    private static func walk(_ s: OpenFrameSession, _ r: Report, _ name: String, _ states: [DevelopRevision], steps: Int) {
        var ok = 0
        for i in stride(from: steps - 1, through: 0, by: -1) {
            s.undo()
            if s.historySnapshot().isSameEdit(as: states[i]) { ok += 1 }
            else { r.note("R: \(name) ⌘Z to \(i) differs", ["got": "\(s.historySnapshot())".prefix(600), "want": "\(states[i])".prefix(600)]) }
        }
        r.check(ok == steps, "R: \(name): ⌘Z ×\(steps) gives each recorded state back (\(ok) of \(steps))")
        ok = 0
        for i in 1...steps {
            s.redo()
            if s.historySnapshot().isSameEdit(as: states[i]) { ok += 1 }
        }
        r.check(ok == steps, "R: \(name): ⇧⌘Z ×\(steps) forward again (\(ok) of \(steps))")
    }
}
#endif
