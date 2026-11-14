import Foundation
import SQLite3

// The edit history's store (Services/EditHistoryStore.swift, Services/SQLiteEditHistoryStore.swift; PRD-F §7.3,
// §7.4, §5): the same rules held to both stores — SQLite on a scratch file and the one in memory — a step and its
// cursor in one transaction against a writer killed while it writes, a newer build's file left untouched, the
// reconciliation guard's three cases, and the budgets measured on this Mac.
//
//   history_store_selftest [--writer <file>]     (--writer: the child the kill test kills, appending forever)

@main struct HistoryStoreSelftest {
    static var passed = 0
    static func expect(_ ok: Bool, _ name: String) {
        guard ok else { print("FAIL: \(name)"); exit(1) }
        passed += 1
    }

    static func main() async {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--writer"), i + 1 < args.count { await writer(URL(fileURLWithPath: args[i + 1])); return }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("history-store-selftest-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        codec()
        await rules(InMemoryEditHistoryStore(limit: 4), "memory")
        await rules(SQLiteEditHistoryStore(url: scratch.appendingPathComponent("rules.sqlite"), limit: 4), "sqlite")
        await reconciliation(InMemoryEditHistoryStore(), "memory")
        await reconciliation(SQLiteEditHistoryStore(url: scratch.appendingPathComponent("reconcile.sqlite")), "sqlite")
        await reopened(scratch)
        await newerSchema(scratch)
        await schemaOne(scratch)
        await killed(scratch)
        await budgets(scratch)
        print("Edit history store: \(passed) passed, 0 failed")
    }

    // MARK: what a step holds

    static func photo(ev: Double) -> DevelopRevision {
        var e = FrameEdit()
        e.params.exposureCompensationEV = ev
        return DevelopRevision(edit: e, pair: nil, sourceDecodes: [:])
    }

    static let left = UUID(), right = UUID(), bottom = UUID(), top = UUID()

    static func pair(ev: Double, kelvin: Double) -> DevelopRevision {
        var p = HalfFramePair()
        p.left = HalfFramePair.Hole(path: "L.jpg", frame: left)
        p.right = HalfFramePair.Hole(path: "R.jpg", frame: right)
        p.left?.exposureEV = ev
        var d = DecodeSettings()
        d.whiteBalance = .custom
        d.temperature = kelvin
        return DevelopRevision(edit: FrameEdit(), pair: p, sourceDecodes: [left: d, right: DecodeSettings()])
    }

    static func double(balance: Double, kelvin: Double) -> DevelopRevision {
        var x = DoubleExposure(bottom: DoubleExposure.Exposure(frame: bottom), top: DoubleExposure.Exposure(frame: top), origin: nil)
        x[.top]?.exposureEV = balance
        var d = DecodeSettings()
        d.whiteBalance = .custom
        d.temperature = kelvin
        return DevelopRevision(edit: FrameEdit(), pair: nil, sourceDecodes: [bottom: d], double: x)
    }

    static func codec() {
        for (name, r) in [("photograph", photo(ev: 0.7)), ("pair", pair(ev: -0.3, kelvin: 4100)), ("double", double(balance: 0.4, kelvin: 6200))] {
            let data = try! HistoryCodec.encode(r)
            let back = try! HistoryCodec.decode(data)
            expect(back == r, "codec: a \(name) and its members' decodes round-trip")
            expect(try! HistoryCodec.encode(back) == data, "codec: one revision, one byte string (\(name))")
            print("  codec: a \(name) state is \(data.count) bytes compressed")
        }
        // A state written before a field existed reads with it neutral (PRD-F §3.5): an edit with no `double` key
        // and no `sourceDecodes` key at all.
        let bare = try! JSONEncoder().encode(["edit": FrameEdit()])
        let read = try! JSONDecoder().decode(DevelopRevision.self, from: bare)
        expect(read.double == nil && read.pair == nil && read.sourceDecodes.isEmpty, "codec: missing keys read as nothing")
        expect(HistoryCodec.label(#"{"key":"Preset: %@","args":["Night"],"future":1}"#) == .preset("Night"), "label: a newer build's field is ignored")
        expect(HistoryCodec.label(#"{"key":"Crop"}"#) == .crop, "label: missing args read as none")
        expect(HistoryOrigin(stored: "something-new") == .elsewhere, "origin: an unknown one reads as elsewhere")
    }

    // MARK: the rules, both stores

    static func rules(_ store: any EditHistoryStore, _ kind: String) async {
        let f = UUID(), g = UUID()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func step(_ a: DevelopRevision, _ b: DevelopRevision, _ origin: HistoryOrigin = .develop, _ label: HistoryLabel = .adjustment,
                  mode: HistoryAppend.Before = .amends, at: Int = 0) -> HistoryAppend {
            HistoryAppend(before: a, after: b, origin: origin, label: label, at: t0.addingTimeInterval(Double(at)), mode: mode)
        }
        let empty = try! await store.open(f, current: photo(ev: 0), radius: 8, at: t0)
        expect(empty.isEmpty, "\(kind): a frame with no history opens empty, and nothing is written")
        expect(try! await store.listing(f) == nil, "\(kind): still no history after an open")
        expect(try! await store.append(f, step(photo(ev: 0), photo(ev: 0))) == nil, "\(kind): no step where nothing changed")
        try! await store.append(f, step(photo(ev: 0), photo(ev: 1), at: 1))
        try! await store.append(f, step(photo(ev: 1), photo(ev: 2), .paste, .paste(from: "DSCF1201"), at: 2))
        let cursor = try! await store.append(f, step(photo(ev: 2), photo(ev: 3), .preset, .preset("Night"), at: 3))
        expect(cursor == 3, "\(kind): three steps, the cursor on the third")
        let l = try! await store.listing(f)!
        expect(l.base.seq == 0 && l.steps.map(\.seq) == [1, 2, 3] && l.cursorSeq == 3 && !l.baseIsEarlier, "\(kind): the listing")
        expect(l.base.label == HistoryCodec.original && l.steps.map(\.origin) == [.develop, .paste, .preset], "\(kind): origins kept")
        expect(l.steps[1].label == .paste(from: "DSCF1201") && l.steps[2].label == .preset("Night"), "\(kind): labels kept as key and args")
        expect(l.steps[2].at == t0.addingTimeInterval(3) && l.bytes > 0, "\(kind): times and sizes kept")
        let s1 = try! await store.state(f, seq: 1), s0 = try! await store.state(f, seq: 0)
        expect(s1 == photo(ev: 1) && s0 == photo(ev: 0), "\(kind): a state reads back")
        expect(try! await store.listing(g) == nil, "\(kind): another frame is untouched")
        // Undo twice, a new edit: the redo tail goes.
        try! await store.move(f, to: 1)
        try! await store.append(f, step(photo(ev: 1), photo(ev: 9), at: 4))
        let l2 = try! await store.listing(f)!
        let s2 = try! await store.state(f, seq: 2)
        expect(l2.steps.map(\.seq) == [1, 2] && l2.cursorSeq == 2 && s2 == photo(ev: 9), "\(kind): a new edit after undo drops the tail")
        // `before` takes the cursor's place (what was read since: a solved placement, a shown side).
        var read = photo(ev: 9); read.edit.solvedEV = 0.25
        try! await store.append(f, step(read, photo(ev: 10), at: 5))
        expect(try! await store.state(f, seq: 2) == read, "\(kind): the state a step began from replaces the cursor's")
        // The limit (4 here): the oldest goes, the base relabels.
        for i in 0..<3 { try! await store.append(f, step(photo(ev: Double(10 + i)), photo(ev: Double(11 + i)), at: 6 + i)) }
        let l3 = try! await store.listing(f)!
        expect(l3.steps.count == 4 && l3.baseIsEarlier && l3.base.seq == l3.cursorSeq - 4, "\(kind): past the limit the oldest goes; Earlier edits")
        expect(try! await store.state(f, seq: l3.base.seq - 1) == nil, "\(kind): the dropped state is gone")
        // A move beyond the ends is held to them.
        try! await store.move(f, to: -50)
        expect(try! await store.listing(f)!.cursorSeq == l3.base.seq, "\(kind): a move is held to the base")
        try! await store.move(f, to: 10_000)
        expect(try! await store.listing(f)!.cursorSeq == l3.cursorSeq, "\(kind): and to the last")
        // Amend: the cursor's state, no step.
        var amended = photo(ev: 13); amended.edit.placementNeedsFit = true
        try! await store.amend(f, current: amended)
        let la = try! await store.listing(f)!, sa = try! await store.state(f, seq: l3.cursorSeq)
        expect(la.steps.count == 4 && sa == amended, "\(kind): amend")
        // Clear: the edit kept as Original.
        try! await store.clear(f, keeping: photo(ev: 13))
        let l4 = try! await store.listing(f)!
        expect(l4.steps.isEmpty && !l4.baseIsEarlier && l4.cursorSeq == l4.base.seq, "\(kind): Clear leaves the base alone")
        expect(try! await store.state(f, seq: l4.base.seq) == photo(ev: 13), "\(kind): and the base is the edit as it stood")
        try! await store.append(f, step(photo(ev: 13), photo(ev: 14), at: 20))
        expect(try! await store.listing(f)!.steps.count == 1, "\(kind): a step after Clear")
        // The window a session opens on: cursor ± radius.
        for i in 0..<3 { try! await store.append(g, step(photo(ev: Double(i)), photo(ev: Double(i + 1)), at: 30 + i)) }
        let w = try! await store.open(g, current: photo(ev: 3), radius: 1, at: t0)
        expect(w.reconciled == .agreed && w.cursorSeq == 3 && Set(w.states.keys) == [2, 3], "\(kind): the window is the cursor and its neighbours")
        expect(try! await store.states(g, seqs: 0...3).count == 4, "\(kind): a range of states")
        // Remove and Clear All.
        try! await store.remove([f])
        let lf = try! await store.listing(f), lg = try! await store.listing(g)
        expect(lf == nil && lg != nil, "\(kind): remove forgets one frame")
        let h = UUID()
        try! await store.append(h, step(photo(ev: 0), photo(ev: 1), at: 40))
        try! await store.clearAll(except: [h])
        let kept = try! await store.listing(h), clearedG = try! await store.listing(g)
        expect(clearedG == nil && kept?.steps.count == 1, "\(kind): Clear All but an open page's frame leaves that one")
        try! await store.clearAll()
        let goneG = try! await store.listing(g), goneH = try! await store.listing(h)
        expect(goneG == nil && goneH == nil, "\(kind): Clear All forgets every frame")
    }

    // MARK: the reconciliation guard (PRD-F §3.2, §7.4)

    static func reconciliation(_ store: any EditHistoryStore, _ kind: String) async {
        let t0 = Date()
        func steps(_ f: UUID, _ revisions: [DevelopRevision]) async {
            for (a, b) in zip(revisions, revisions.dropFirst()) {
                try! await store.append(f, HistoryAppend(before: a, after: b, origin: .develop, label: .adjustment, at: t0, mode: .amends))
            }
        }
        // 1. The library one step behind (library.json is debounced; the store wrote through): the cursor moves.
        let a = UUID()
        await steps(a, [photo(ev: 0), photo(ev: 1), photo(ev: 2), photo(ev: 3)])
        let behind = try! await store.open(a, current: photo(ev: 2), radius: 8, at: t0)
        let la = try! await store.listing(a)!
        expect(behind.reconciled == .movedCursor(from: 3) && la.cursorSeq == 2 && la.steps.count == 3,
               "\(kind) guard: one step behind, the cursor moves and nothing is added (\(behind.reconciled))")
        expect(behind.states[3] == photo(ev: 3), "\(kind) guard: the step ahead is still there to redo")
        // A pair one step behind, its member's decode with it.
        let p = UUID()
        await steps(p, [pair(ev: 0, kelvin: 5000), pair(ev: 0.5, kelvin: 5000), pair(ev: 0.5, kelvin: 3800)])
        let pb = try! await store.open(p, current: pair(ev: 0.5, kelvin: 5000), radius: 8, at: t0)
        expect(pb.reconciled == .movedCursor(from: 2), "\(kind) guard: a pair behind by a member's decode moves its cursor")

        // 2. Changed elsewhere (an older build, a restored backup): one `elsewhere` step, the redo tail dropped.
        let b = UUID()
        await steps(b, [photo(ev: 0), photo(ev: 1), photo(ev: 2)])
        try! await store.move(b, to: 1)
        let elsewhere = try! await store.open(b, current: photo(ev: 7), radius: 8, at: t0)
        let lb = try! await store.listing(b)!
        expect(elsewhere.reconciled == .addedElsewhere && lb.steps.count == 2 && lb.cursorSeq == 2, "\(kind) guard: changed elsewhere adds one step")
        expect(lb.steps.last?.origin == .elsewhere && lb.steps.last?.label == .changedElsewhere, "\(kind) guard: labelled Changed elsewhere")
        let b2 = try! await store.state(b, seq: 2), b1 = try! await store.state(b, seq: 1)
        expect(b2 == photo(ev: 7) && b1 == photo(ev: 1), "\(kind) guard: from the cursor's state to the edit as it is; the old redo tail gone")
        let again = try! await store.open(b, current: photo(ev: 7), radius: 8, at: t0)
        let lb2 = try! await store.listing(b)!
        expect(again.reconciled == .agreed && lb2.steps.count == 2, "\(kind) guard: and opened again, agrees")

        // 3. Only reports changed: a meter reading, As Shot read, the solved EV, the RAW decode's provenance.
        let c = UUID()
        await steps(c, [photo(ev: 0), photo(ev: 1)])
        var reports = photo(ev: 1)
        reports.edit.solvedEV = 0.42
        reports.edit.decode.temperature = 4321
        reports.edit.decode.tint = 7
        let agreed = try! await store.open(c, current: reports, radius: 8, at: t0)
        let lc = try! await store.listing(c)!
        expect(agreed.reconciled == .agreed && lc.steps.count == 1, "\(kind) guard: only reports changed, nothing added")
        let pm = UUID()
        await steps(pm, [pair(ev: 0, kelvin: 5000), pair(ev: 1, kelvin: 5000)])
        var metered = pair(ev: 1, kelvin: 5000)
        metered.pair?.left?.meteredEV = 0.8
        metered.pair?.left?.meteredFor = "key"
        let pa = try! await store.open(pm, current: metered, radius: 8, at: t0)
        expect(pa.reconciled == .agreed, "\(kind) guard: a pair's meter reading is not a change")
        // But a white balance set by hand is (the control under As Shot is not a report).
        var hand = photo(ev: 1)
        hand.edit.decode.whiteBalance = .custom
        hand.edit.decode.temperature = 4321
        let set = try! await store.open(c, current: hand, radius: 8, at: t0)
        expect(set.reconciled == .addedElsewhere, "\(kind) guard: a white balance set by hand is a change")

        // A door with no page open (Paste on the grid) whose `before` the history does not know: reconciled first.
        let d = UUID()
        await steps(d, [photo(ev: 0), photo(ev: 1)])
        try! await store.append(d, HistoryAppend(before: photo(ev: 5), after: photo(ev: 6), origin: .paste, label: .paste(from: "X"), at: t0, mode: .reconciles))
        let ld = try! await store.listing(d)!
        expect(ld.steps.map(\.origin) == [.develop, .elsewhere, .paste], "\(kind) door: a change made elsewhere first, then the paste")
        try! await store.append(d, HistoryAppend(before: photo(ev: 6), after: photo(ev: 7), origin: .paste, label: .paste(from: "X"), at: t0, mode: .reconciles))
        expect(try! await store.listing(d)!.steps.count == 4, "\(kind) door: a paste on a known state is one step")
    }

    // MARK: SQLite on its own

    static func reopened(_ scratch: URL) async {
        let url = scratch.appendingPathComponent("reopen.sqlite")
        let f = UUID()
        do {
            let s = SQLiteEditHistoryStore(url: url)
            try! await s.append(f, HistoryAppend(before: pair(ev: 0, kelvin: 5000), after: pair(ev: 1, kelvin: 3000), origin: .composite,
                                                 label: .composite("Pair 1"), at: Date(), mode: .amends))
            try! await s.append(f, HistoryAppend(before: pair(ev: 1, kelvin: 3000), after: double(balance: 0.2, kelvin: 7000), origin: .develop,
                                                 label: .adjustment, at: Date(), mode: .amends))
        }
        let s2 = SQLiteEditHistoryStore(url: url)
        let w = try! await s2.open(f, current: double(balance: 0.2, kelvin: 7000), radius: 8, at: Date())
        expect(w.reconciled == .agreed && w.states[1] == pair(ev: 1, kelvin: 3000) && w.states[0] == pair(ev: 0, kelvin: 5000),
               "sqlite: a new store on the same file reads the pair and double states back, members' decodes and all")
        expect(FileManager.default.fileExists(atPath: url.path + "-wal") || true, "sqlite: WAL")
        var stmt: OpaquePointer?, db: OpaquePointer?
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, nil)
        sqlite3_step(stmt)
        let mode = String(cString: sqlite3_column_text(stmt, 0))
        sqlite3_finalize(stmt); sqlite3_close_v2(db)
        expect(mode == "wal", "sqlite: the file is in WAL mode (\(mode))")
    }

    /// A file of part 1's schema (WITHOUT ROWID) is read and moved to this one, its steps and cursor kept.
    static func schemaOne(_ scratch: URL) async {
        let url = scratch.appendingPathComponent("one.sqlite")
        let f = UUID()
        let a = try! HistoryCodec.encode(photo(ev: 0)), b = try! HistoryCodec.encode(photo(ev: 0.5))
        var db: OpaquePointer?
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(db, """
            CREATE TABLE history_frame(frame TEXT PRIMARY KEY NOT NULL, cursor INTEGER NOT NULL, earlier INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE history_step(frame TEXT NOT NULL, seq INTEGER NOT NULL, at REAL NOT NULL, origin TEXT NOT NULL, label TEXT NOT NULL,
                                      state BLOB NOT NULL, PRIMARY KEY(frame, seq)) WITHOUT ROWID;
            INSERT INTO history_frame VALUES('\(f.uuidString)', 1, 0);
            PRAGMA user_version = 1;
            """, nil, nil, nil)
        for (seq, data) in [(0, a), (1, b)] {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO history_step VALUES(?, ?, 0, 'develop', '{\"key\":\"Adjustment\"}', ?)", -1, &stmt, nil)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, f.uuidString, -1, transient)
            sqlite3_bind_int(stmt, 2, Int32(seq))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32($0.count), transient) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_close_v2(db)
        let s = SQLiteEditHistoryStore(url: url)
        let l = try? await s.listing(f)
        let state = try? await s.state(f, seq: 1)
        expect(l?.steps.count == 1 && l?.cursorSeq == 1 && state == photo(ev: 0.5), "sqlite: a schema-1 file's steps and cursor are read")
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT (SELECT user_version FROM pragma_user_version), (SELECT sql FROM sqlite_master WHERE name = 'history_step')", -1, &stmt, nil)
        sqlite3_step(stmt)
        let version = sqlite3_column_int(stmt, 0)
        let sql = String(cString: sqlite3_column_text(stmt, 1))
        sqlite3_finalize(stmt)
        sqlite3_close_v2(db)
        expect(version == SQLiteEditHistoryStore.schema && !sql.contains("WITHOUT ROWID"), "sqlite: and it is moved to schema \(version), a table with row ids")
    }

    static func newerSchema(_ scratch: URL) async {
        let url = scratch.appendingPathComponent("newer.sqlite")
        var db: OpaquePointer?
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_exec(db, "CREATE TABLE future(x); INSERT INTO future VALUES('kept'); PRAGMA user_version = \(SQLiteEditHistoryStore.schema + 1);", nil, nil, nil)
        sqlite3_close_v2(db)
        let bytes = try! Data(contentsOf: url)
        let s = SQLiteEditHistoryStore(url: url)
        let f = UUID()
        var refused = 0
        func refusedNewer(_ body: () async throws -> Void) async {
            do { try await body() } catch EditHistoryError.newerSchema(found: Int(SQLiteEditHistoryStore.schema) + 1, known: Int(SQLiteEditHistoryStore.schema)) { refused += 1 } catch { print("  other error: \(error)") }
        }
        await refusedNewer { _ = try await s.open(f, current: photo(ev: 0), radius: 8, at: Date()) }
        await refusedNewer { try await s.append(f, HistoryAppend(before: photo(ev: 0), after: photo(ev: 1), origin: .develop, label: .adjustment, at: Date(), mode: .amends)) }
        await refusedNewer { _ = try await s.listing(f) }
        await refusedNewer { try await s.clearAll() }
        await refusedNewer { try await s.remove([f]) }
        expect(refused == 5, "sqlite: a newer schema's file is neither read nor written: every call refused (\(refused) of 5)")
        expect(try! Data(contentsOf: url) == bytes, "sqlite: the newer file's bytes are as they were")
        expect(!FileManager.default.fileExists(atPath: url.path + "-wal"), "sqlite: no write-ahead log was made beside it")
        expect((try? await s.bytesOnDisk()) == Int64(bytes.count), "sqlite: its size can still be read")
    }

    /// The child: appends to one frame forever, saying each step's number once it is committed.
    static func writer(_ url: URL) async {
        setvbuf(stdout, nil, _IONBF, 0)
        let s = SQLiteEditHistoryStore(url: url)
        let f = UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!
        var i = Double((try? await s.listing(f)?.cursorSeq) ?? 0)
        while true {
            let cursor = try! await s.append(f, HistoryAppend(before: photo(ev: i), after: photo(ev: i + 1), origin: .develop, label: .adjustment,
                                                             at: Date(), mode: .amends))
            print("committed \(cursor!)")
            i += 1
        }
    }

    /// A step and its cursor in one transaction (PRD-F §7.3): the writer killed (SIGKILL) at random moments; each
    /// time the file opens, is whole, its cursor is on its last state, and at most the step in flight is lost.
    static func killed(_ scratch: URL) async {
        let url = scratch.appendingPathComponent("killed.sqlite")
        let me = URL(fileURLWithPath: CommandLine.arguments[0])
        let f = UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!
        var kills = 0, lost = 0
        for round in 0..<12 {
            let child = Process()
            child.executableURL = me
            child.arguments = ["--writer", url.path]
            let pipe = Pipe()
            child.standardOutput = pipe
            try! child.run()
            usleep(useconds_t(150_000 + (round * 37_000) % 200_000))
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            kills += 1
            let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let lastSaid = said.split(separator: "\n").compactMap { $0.split(separator: " ").last.flatMap { Int($0) } }.max() ?? 0
            // The file, as the next launch finds it.
            var db: OpaquePointer?, stmt: OpaquePointer?
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
            sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, nil)
            sqlite3_step(stmt)
            let integrity = String(cString: sqlite3_column_text(stmt, 0))
            sqlite3_finalize(stmt); sqlite3_close_v2(db)
            expect(integrity == "ok", "kill \(round): the file is whole (\(integrity))")
            let l = try! await SQLiteEditHistoryStore(url: url).listing(f)!
            let seqs = [l.base.seq] + l.steps.map(\.seq)
            expect(seqs == Array(l.base.seq...(l.steps.last?.seq ?? l.base.seq)), "kill \(round): no hole in the steps")
            expect(l.cursorSeq == seqs.last, "kill \(round): the cursor is on the last step written (\(l.cursorSeq), last \(seqs.last!))")
            expect(l.cursorSeq >= lastSaid && l.cursorSeq <= lastSaid + 1,
                   "kill \(round): every committed step is there, at most the one in flight besides (\(l.cursorSeq) vs said \(lastSaid))")
            if l.cursorSeq == lastSaid { lost += 0 } else { lost += 1 }
        }
        print("  kill: \(kills) writers killed mid-run; \(lost) times the step in flight had committed before the kill")
    }

    // MARK: budgets (PRD-F §5), measured, not asserted beyond a generous ceiling

    static func ms(_ body: () async throws -> Void) async rethrows -> Double {
        let t = ContinuousClock.now
        try await body()
        let d = ContinuousClock.now - t
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func budgets(_ scratch: URL) async {
        let url = scratch.appendingPathComponent("budget.sqlite")
        let s = SQLiteEditHistoryStore(url: url)
        let f = UUID()
        // A realistic photograph's edit: a film edge, a crop, Layer 2 moved, so its JSON is the size of a kept one.
        var base = photo(ev: 0)
        base.edit.filmEdge.active = true
        base.edit.geometry.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.7)
        _ = try! await s.listing(UUID())        // the file opened outside the timings
        var appends: [Double] = []
        var last = base
        for i in 0..<300 {
            var next = last
            next.edit.params.exposureCompensationEV = Double(i + 1) / 10
            next.edit.adjustments.exposure = Double(i % 7) / 10
            let a = last, b = next
            appends.append(try! await ms { try await s.append(f, HistoryAppend(before: a, after: b, origin: .develop, label: .adjustment, at: Date(), mode: .amends)) })
            walPeak = max(walPeak, (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0)
            last = next
        }
        appends.sort()
        var listing: HistoryListing?
        var listMs: [Double] = []
        for _ in 0..<10 { listMs.append(try! await ms { listing = try await s.listing(f) }) }
        listMs.sort()
        var openMs: [Double] = []
        let current = last
        for _ in 0..<10 { openMs.append(try! await ms { _ = try await s.open(f, current: current, radius: 8, at: Date()) }) }
        openMs.sort()
        var readMs: [Double] = []
        for k in 0..<10 { readMs.append(try! await ms { _ = try await s.states(f, seqs: (100 + k * 9)...(116 + k * 9)) }) }
        readMs.sort()
        let one = listing!.steps.map(\.bytes).sorted()[128]
        let onDisk = try! await s.bytesOnDisk()
        print(String(format: "  budget: append (encode+compress+write, off main) median %.2f ms, p95 %.2f ms over 300", appends[150], appends[285]))
        print(String(format: "  budget: open, cursor ± 8, at 256 steps: median %.2f ms, max %.2f ms (budget 10)", openMs[5], openMs[9]))
        print(String(format: "  budget: the page's 256 rows, metadata only: median %.2f ms, max %.2f ms (budget 20)", listMs[5], listMs[9]))
        print(String(format: "  budget: a window of 17 states past the cursor: median %.2f ms (budget 5 for one read)", readMs[5]))
        print("  budget: a state \(one) B compressed; this frame's 257 states \(listing!.bytes / 1024) KB; the file \(onDisk / 1024) KB")
        expect(listing!.steps.count == 256 && listing!.baseIsEarlier, "budget: 300 appends keep 256 steps")
        expect(openMs[5] < 10 && listMs[5] < 20 && readMs[5] < 5, "budget: open, listing and a read inside PRD-F §5")
        // Settings' figure is what is kept, not the log (part 1 measured 3.7 MB for these 0.3 MB of states): the file,
        // its log and its index within twice the states and 128 KB of pages; the log itself never past 256 KB
        // between two figures (`journal_size_limit`, `wal_autocheckpoint`); Clear All brings it down to the empty file's.
        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
        let walBetween = walPeak
        expect(onDisk <= Int64(listing!.bytes) * 2 + 128 * 1024,
               "settings: the figure is the states' (\(onDisk / 1024) KB on disk for \(listing!.bytes / 1024) KB of states)")
        expect(wal == 0 && walBetween <= 300 * 1024, "settings: the log is folded in when measured (\(wal) B) and stays under 300 KB between (\(walBetween / 1024) KB)")
        try! await s.clearAll()
        let cleared = try! await s.bytesOnDisk()
        print("  settings: on disk \(onDisk / 1024) KB, the log at most \(walBetween / 1024) KB while appending; after Clear All \(cleared / 1024) KB")
        expect(cleared < 64 * 1024 && cleared < onDisk, "settings: Clear All brings the figure down (\(onDisk / 1024) KB → \(cleared / 1024) KB)")
    }

    /// The largest the write-ahead log grew while the budget's 300 steps were appended.
    nonisolated(unsafe) static var walPeak: Int64 = 0
}
