//  Session+EditHistory.swift — Undo and Redo for the grade (Layer 2).
//
//  The sidecar has had an undo stack since 1.0 (`Session.undo`): a snapshot of
//  every setting, taken at most once every half second. That made a slow drag
//  several steps and a fast double-click part of the step before it, and it
//  had no redo. The grade now keeps a history of its own, **one step a
//  gesture** (`EditHistory`):
//
//  - a Post-Dev control calls `beginLayer2Gesture` when the pointer goes down
//    and `endLayer2Gesture` when it comes up; every value set in between is
//    drawn and saved as before, and one step is recorded at the end;
//  - a change made with no gesture open — a double-click back to rest, a
//    typed value, a section's Reset, Bypass Adjustments, an agent's edit — is
//    a step by itself, recorded where it is set (`recordLayer2`).
//
//  **The two histories are one timeline.** Both take their stamps from one
//  clock, and ⌘Z undoes whichever has the newer step, so the order of undo is
//  the order things were done in, whichever rail they were done on. Redo is
//  the grade's alone (the sidecar stack never had one), and any change that is
//  not the grade's ends it.
//
//  Scope: the frame's own grade, which on a half-frame pair is the film's.
//  A picked frame's grade is written into the pair's file (`updatePair`) and
//  undoes with the sidecar stack, as it did.

import Foundation

extension Session {
    /// The open frame's grade history.
    var layer2History: EditHistory<Adjustments>? {
        selection.flatMap { layer2Histories[$0] }
    }

    func nextHistoryStamp() -> Int {
        historyClock += 1
        return historyClock
    }

    // MARK: recording

    /// A control's gesture begins: the grade as it is now is the step's
    /// "before". A second begin inside the first is the same gesture.
    func beginLayer2Gesture() {
        guard layer2GestureStart == nil, pickedHole == nil, let url = selection else { return }
        layer2GestureStart = (url, adjustments)
    }

    /// The gesture ends: one step, from the grade it began on to the grade
    /// it left, or nothing if the two are the same.
    func endLayer2Gesture() {
        guard let start = layer2GestureStart else { return }
        layer2GestureStart = nil
        // A gesture that outlived its frame (a click that opened another one)
        // is not a step of either.
        guard start.url == selection else { return }
        record(start.before, adjustments, for: start.url)
    }

    /// Called by `adjustments`' setter. Inside a gesture the gesture records;
    /// outside one, this change is a step of its own.
    func recordLayer2(from before: Adjustments, to after: Adjustments) {
        guard !replayingLayer2, layer2GestureStart == nil, let url = selection else { return }
        record(before, after, for: url)
    }

    private func record(_ before: Adjustments, _ after: Adjustments, for url: URL) {
        var history = layer2Histories[url] ?? EditHistory()
        history.record(from: before, to: after, stamp: nextHistoryStamp())
        layer2Histories[url] = history
    }

    /// See `pushUndo`: a change that is not the grade's ends its redo.
    func dropLayer2Redo() {
        guard let url = selection, layer2Histories[url]?.canRedo == true else { return }
        layer2Histories[url]?.dropRedo()
    }

    /// The open frame's grade history goes (`undo`, when a snapshot's grade is
    /// not the grade its steps describe).
    func dropLayer2History() {
        guard let url = selection else { return }
        layer2Histories[url] = nil
    }

    // MARK: undo and redo

    /// What ⌘Z would undo now.
    enum UndoTarget: Equatable { case grade, settings, nothing }

    var nextUndo: UndoTarget {
        guard !batchExporting, selection != nil else { return .nothing }
        let grade = layer2History?.lastStamp
        let settings = canUndo ? (lastSettingsUndoStamp ?? 0) : nil
        switch (grade, settings) {
        case (nil, nil): return .nothing
        case (.some, nil): return .grade
        case (nil, .some): return .settings
        case let (.some(g), .some(s)): return g > s ? .grade : .settings
        }
    }

    var canUndoLatest: Bool { nextUndo != .nothing }
    var canRedoAdjustment: Bool { !batchExporting && layer2History?.canRedo == true }

    /// The Edit menu's title says which history ⌘Z is about to use.
    var undoMenuTitle: String {
        nextUndo == .grade ? L("Undo Adjustment", zh: "撤销调整") : L("Undo", zh: "撤销")
    }
    var redoMenuTitle: String { L("Redo Adjustment", zh: "重做调整") }

    /// ⌘Z: the newest step of either history.
    func undoLatest() {
        endLayer2Gesture()
        switch nextUndo {
        case .grade: undoAdjustment()
        case .settings: undo()
        case .nothing: break
        }
    }

    func undoAdjustment() {
        guard !batchExporting, let url = selection, var history = layer2Histories[url],
              let step = history.undo() else { return }
        layer2Histories[url] = history
        replay(step.before)
    }

    /// ⇧⌘Z.
    func redoAdjustment() {
        endLayer2Gesture()
        guard !batchExporting, let url = selection, var history = layer2Histories[url],
              let step = history.redo() else { return }
        layer2Histories[url] = history
        replay(step.after)
    }

    private func replay(_ grade: Adjustments) {
        replayingLayer2 = true
        defer { replayingLayer2 = false }
        adjustments = grade
    }
}
