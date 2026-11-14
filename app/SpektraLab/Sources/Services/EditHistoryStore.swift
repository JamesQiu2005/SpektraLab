//  EditHistoryStore.swift — where a frame's edit history is kept between its pages and between launches (PRD-F §2).
//
//  A history lives where its edit lives, or the two can disagree with nobody to settle it. Every frame the Mac
//  shows is a `LibraryFrame` of the app's library, so the store is the app's own, keyed by `LibraryFrame.ID`:
//  `SQLiteEditHistoryStore` at `<Application Support>/<bundle id>/EditHistory/history.sqlite`, and for a test or
//  a library that keeps nothing on disk, `InMemoryEditHistoryStore`. The session never knows which it has
//  (`EditHistoryLine` is its one way to either). Phase 2 (§2.1, a catalog that carries its edits) swaps the store
//  and changes nothing else.
//
//  **What is kept.** Per frame: `count + 1` states numbered from the base's (`baseSeq`), each with a time, an
//  origin and a label, and a cursor. A state is the whole `DevelopRevision` (after `keepingReports`) as JSON,
//  zlib-compressed: full snapshots (the owner, §8.2), ~1.2 KB a photograph's. The base is "Original", or *Earlier
//  edits* once a step past 256 has dropped the oldest (`baseIsEarlier`); its own origin and label are those of the
//  step that made it, or `elsewhere` / *Original* for the state a history began from.
//
//  **The rules, the same in both stores and the same as `EditHistory`'s** (the session keeps a window of the
//  states and must agree with the store op for op, so the arithmetic is one):
//  - `append` drops the states ahead of the cursor, adds the step after it, moves the cursor onto it and drops
//    the oldest past `limit` — one transaction. `before` takes the cursor's place (`HistoryAppend.Before`).
//  - `open` is the reconciliation guard (§3.2): the library's edit is the cursor's state as a person's edit goes
//    (`DevelopRevision.isSameEdit`), or the cursor moves to the nearest state that is (a step behind after a
//    crash, `library.json` being debounced), or one `elsewhere` step is added. It never writes the edit itself.
//  - `move` is Undo, Redo and Go to This Step: the cursor alone, no step.
//  - `clear` keeps the edit as it stands as the new base, *Original*. `remove` forgets a frame.
//
//  A store written by a newer build (its schema number) is neither read nor written: every call throws
//  `EditHistoryError.newerSchema`, and the session keeps that frame's history in memory (§3.5).

import Foundation

// MARK: - what is read and written

/// One step's metadata, without its state: what the history page lists (256 rows at most).
struct HistoryStepInfo: Equatable, Sendable {
    var seq: Int
    var at: Date
    var origin: HistoryOrigin
    /// The origin as kept, for a newer build's that this one reads as `elsewhere`.
    var originText: String
    var label: HistoryLabel
    /// The compressed state's size.
    var bytes: Int
}

/// A frame's history in metadata: the base, the steps after it (oldest first), the cursor.
struct HistoryListing: Equatable, Sendable {
    var frame: UUID
    var base: HistoryStepInfo
    var steps: [HistoryStepInfo]
    var cursorSeq: Int
    /// The base is no longer the frame's first state: *Earlier edits*, not *Original*.
    var baseIsEarlier: Bool
    /// The states' bytes, base included.
    var bytes: Int { base.bytes + steps.reduce(0) { $0 + $1.bytes } }
}

/// What a session opens on: the history's shape and the states within `radius` of its cursor, after the
/// reconciliation guard has held it to the library's edit.
struct HistoryWindow: Sendable {
    enum Reconciled: Equatable, Sendable {
        /// The frame has no history.
        case empty
        /// The cursor's state is the library's edit.
        case agreed
        /// The library's edit was another state of the history: the cursor moved there from `from`.
        case movedCursor(from: Int)
        /// The edit changed where no step was recorded: one `elsewhere` step added.
        case addedElsewhere
    }
    var baseSeq = 0
    var lastSeq = 0
    var cursorSeq = 0
    var baseIsEarlier = false
    var states: [Int: DevelopRevision] = [:]
    var reconciled = Reconciled.empty
    var isEmpty: Bool { reconciled == .empty }

    /// The session's history from it.
    func history(limit: Int) -> EditHistory<DevelopRevision> {
        isEmpty ? EditHistory(limit: limit)
                : EditHistory(limit: limit, baseSeq: baseSeq, steps: lastSeq - baseSeq, cursorSeq: cursorSeq,
                              baseIsEarlier: baseIsEarlier, loaded: states)
    }
}

/// A step to add.
struct HistoryAppend: Sendable {
    /// How the state the step begins from is taken.
    enum Before: Sendable {
        /// A page's session, which holds the history and has reconciled it: `before` takes the cursor's place
        /// (what was read since — a meter, a placement solved — folded into the state it began from).
        case amends
        /// A change made with no page open (Paste Settings on the grid, Crop's Done, a composite's member):
        /// `before` is the library's edit, and where it is not the cursor's state as a person's edit goes, the
        /// history is reconciled to it first, as a page's opening does.
        case reconciles
    }
    var before: DevelopRevision
    var after: DevelopRevision
    var origin: HistoryOrigin
    var label: HistoryLabel
    var at: Date
    var mode: Before
}

enum EditHistoryError: Error, Equatable, CustomStringConvertible {
    /// The file was written by a newer build: not read, not written.
    case newerSchema(found: Int, known: Int)
    /// SQLite said no.
    case sqlite(String)
    /// A kept state could not be read.
    case unreadable(String)

    var description: String {
        switch self {
        case .newerSchema(let found, let known): "edit history schema \(found) is newer than this build's \(known)"
        case .sqlite(let message): "edit history: \(message)"
        case .unreadable(let message): "edit history state unreadable: \(message)"
        }
    }
}

/// The store, wherever it is. An actor: the session hands it values and never waits on it on the main actor.
protocol EditHistoryStore: Actor {
    /// The steps a frame keeps (256, PRD-F §8.5).
    nonisolated var limit: Int { get }
    /// The reconciliation guard, then the states within `radius` of the cursor (PRD-F §3.2).
    func open(_ frame: UUID, current: DevelopRevision, radius: Int, at: Date) throws -> HistoryWindow
    /// A frame's steps without their states; nil for a frame with no history.
    func listing(_ frame: UUID) throws -> HistoryListing?
    /// The state numbered `seq`, if the frame holds it.
    func state(_ frame: UUID, seq: Int) throws -> DevelopRevision?
    /// The states numbered within `seqs` that the frame holds.
    func states(_ frame: UUID, seqs: ClosedRange<Int>) throws -> [Int: DevelopRevision]
    /// One step and its cursor, in one transaction. The new cursor's number; nil where `before == after`.
    @discardableResult func append(_ frame: UUID, _ step: HistoryAppend) throws -> Int?
    /// The cursor onto `seq` (clamped to the states held); no step.
    func move(_ frame: UUID, to seq: Int) throws
    /// The cursor's state as it is now (read, not set, since: a pair's shown placement, a solved one); no step.
    func amend(_ frame: UUID, current: DevelopRevision) throws
    /// Clear History: `current` is the base, *Original*, and nothing else is kept.
    func clear(_ frame: UUID, keeping current: DevelopRevision) throws
    /// The frames' histories, gone (the frame left the library).
    func remove(_ frames: Set<UUID>) throws
    /// What the store takes on disk (the file, its write-ahead log and its index); in memory, the states' bytes.
    func bytesOnDisk() throws -> Int64
    /// Every frame's history, gone, but those of `except` (frames a page has open, cleared through their sessions).
    func clearAll(except: Set<UUID>) throws
}

extension EditHistoryStore {
    /// Every frame's history, gone.
    func clearAll() throws { try clearAll(except: []) }
}

// MARK: - the state's form

/// A state as kept: `DevelopRevision`'s JSON, its keys sorted (one revision, one byte string — an amend that
/// changes nothing is seen as nothing), zlib-compressed.
enum HistoryCodec {
    static func encode(_ revision: DevelopRevision) throws -> Data {
        let json = JSONEncoder()
        json.outputFormatting = [.sortedKeys]
        let data = try json.encode(revision)
        return try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decode(_ data: Data) throws -> DevelopRevision {
        do {
            let json = try (data as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode(DevelopRevision.self, from: json)
        } catch {
            throw EditHistoryError.unreadable(String(describing: error))
        }
    }

    static func label(_ label: HistoryLabel) -> String {
        (try? String(decoding: JSONEncoder().encode(label), as: UTF8.self)) ?? #"{"key":"Adjustment"}"#
    }

    static func label(_ text: String) -> HistoryLabel {
        (try? JSONDecoder().decode(HistoryLabel.self, from: Data(text.utf8))) ?? .adjustment
    }

    /// The label a history's first base is kept with.
    static let original = HistoryLabel(key: "Original")
}

/// The order the guard looks for the library's edit in: nearest the cursor first, behind before ahead.
enum HistoryReconcile {
    static func searchOrder(cursor: Int, base: Int, last: Int) -> [Int] {
        var out: [Int] = []
        var d = 1
        while cursor - d >= base || cursor + d <= last {
            if cursor - d >= base { out.append(cursor - d) }
            if cursor + d <= last { out.append(cursor + d) }
            d += 1
        }
        return out
    }
}

// MARK: - in memory

/// The store for a test, and for a library that keeps nothing on disk (the drawings' own, the snapshot
/// harness): the same rules over dictionaries, its states kept in their stored form so a test reads through the
/// same codec. Lost with the process.
actor InMemoryEditHistoryStore: EditHistoryStore {
    private struct Row {
        var at: Date
        var origin: String
        var label: HistoryLabel
        var state: Data
    }
    private struct Kept {
        var cursor: Int
        var earlier: Bool
        var rows: [Int: Row]
        var base: Int { rows.keys.min() ?? 0 }
        var last: Int { rows.keys.max() ?? 0 }
    }
    private var frames: [UUID: Kept] = [:]
    nonisolated let limit: Int

    init(limit: Int = 256) { self.limit = max(1, limit) }

    func open(_ frame: UUID, current: DevelopRevision, radius: Int, at: Date) throws -> HistoryWindow {
        guard var kept = frames[frame], !kept.rows.isEmpty else { return HistoryWindow() }
        let reconciled = try reconcile(&kept, to: current, at: at)
        frames[frame] = kept
        var window = HistoryWindow(baseSeq: kept.base, lastSeq: kept.last, cursorSeq: kept.cursor, baseIsEarlier: kept.earlier,
                                   reconciled: reconciled)
        window.states = try states(frame, seqs: max(kept.base, kept.cursor - radius)...max(kept.base, min(kept.last, kept.cursor + radius)))
        return window
    }

    func listing(_ frame: UUID) throws -> HistoryListing? {
        guard let kept = frames[frame], let base = kept.rows[kept.base] else { return nil }
        func info(_ seq: Int, _ row: Row) -> HistoryStepInfo {
            HistoryStepInfo(seq: seq, at: row.at, origin: HistoryOrigin(stored: row.origin), originText: row.origin,
                            label: row.label, bytes: row.state.count)
        }
        let steps = kept.rows.keys.sorted().dropFirst().map { info($0, kept.rows[$0]!) }
        return HistoryListing(frame: frame, base: info(kept.base, base), steps: steps, cursorSeq: kept.cursor, baseIsEarlier: kept.earlier)
    }

    func state(_ frame: UUID, seq: Int) throws -> DevelopRevision? {
        guard let row = frames[frame]?.rows[seq] else { return nil }
        return try HistoryCodec.decode(row.state)
    }

    func states(_ frame: UUID, seqs: ClosedRange<Int>) throws -> [Int: DevelopRevision] {
        var out: [Int: DevelopRevision] = [:]
        for seq in seqs { if let s = try state(frame, seq: seq) { out[seq] = s } }
        return out
    }

    @discardableResult
    func append(_ frame: UUID, _ step: HistoryAppend) throws -> Int? {
        guard step.before != step.after else { return nil }
        let before = try HistoryCodec.encode(step.before), after = try HistoryCodec.encode(step.after)
        var kept: Kept
        if let was = frames[frame], !was.rows.isEmpty {
            kept = was
            if step.mode == .reconciles { _ = try reconcile(&kept, to: step.before, at: step.at) }
            kept.rows[kept.cursor]?.state = before
        } else {
            kept = Kept(cursor: 0, earlier: false,
                        rows: [0: Row(at: step.at, origin: HistoryOrigin.elsewhere.rawValue, label: HistoryCodec.original, state: before)])
        }
        add(&kept, Row(at: step.at, origin: step.origin.rawValue, label: step.label, state: after))
        frames[frame] = kept
        return kept.cursor
    }

    func move(_ frame: UUID, to seq: Int) throws {
        guard var kept = frames[frame], !kept.rows.isEmpty else { return }
        kept.cursor = min(max(seq, kept.base), kept.last)
        frames[frame] = kept
    }

    func amend(_ frame: UUID, current: DevelopRevision) throws {
        guard frames[frame]?.rows.isEmpty == false, let cursor = frames[frame]?.cursor else { return }
        frames[frame]?.rows[cursor]?.state = try HistoryCodec.encode(current)
    }

    func clear(_ frame: UUID, keeping current: DevelopRevision) throws {
        guard let kept = frames[frame], let row = kept.rows[kept.cursor] else { return }
        var base = row
        base.state = try HistoryCodec.encode(current)
        frames[frame] = Kept(cursor: kept.cursor, earlier: false, rows: [kept.cursor: base])
    }

    func remove(_ ids: Set<UUID>) throws { for id in ids { frames[id] = nil } }

    func bytesOnDisk() throws -> Int64 {
        Int64(frames.values.reduce(0) { $0 + $1.rows.values.reduce(0) { $0 + $1.state.count } })
    }

    func clearAll(except: Set<UUID>) throws { frames = frames.filter { except.contains($0.key) } }

    // MARK: the rules

    private func add(_ kept: inout Kept, _ row: Row) {
        for seq in kept.rows.keys where seq > kept.cursor { kept.rows[seq] = nil }
        kept.cursor += 1
        kept.rows[kept.cursor] = row
        let over = kept.cursor - kept.base - limit
        if over > 0 {
            let base = kept.base
            for seq in base..<(base + over) { kept.rows[seq] = nil }
            kept.earlier = true
        }
    }

    private func reconcile(_ kept: inout Kept, to current: DevelopRevision, at: Date) throws -> HistoryWindow.Reconciled {
        guard let row = kept.rows[kept.cursor] else { return .empty }
        let cursorState = try HistoryCodec.decode(row.state)
        if cursorState.isSameEdit(as: current) {
            if cursorState != current { kept.rows[kept.cursor]?.state = try HistoryCodec.encode(current) }
            return .agreed
        }
        for seq in HistoryReconcile.searchOrder(cursor: kept.cursor, base: kept.base, last: kept.last) {
            guard let r = kept.rows[seq], try HistoryCodec.decode(r.state).isSameEdit(as: current) else { continue }
            let from = kept.cursor
            kept.cursor = seq
            return .movedCursor(from: from)
        }
        add(&kept, Row(at: at, origin: HistoryOrigin.elsewhere.rawValue, label: .changedElsewhere, state: try HistoryCodec.encode(current)))
        return .addedElsewhere
    }
}
