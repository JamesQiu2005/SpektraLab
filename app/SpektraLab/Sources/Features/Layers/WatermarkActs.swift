//  WatermarkActs.swift — what a watermark layer can be asked to do, as the session does it (PRD-8 on the Mac: a
//  watermark is a layer of 图层). Every act is one step of Undo with a label the history reads (`HistoryFields`'s
//  watermark table): placed, removed, moved, sized, turned, faded, its stage, its eye, its mark, its order. A gesture on
//  the canvas is one step from the pointer's press to its lift (`beganWatermark` … `endedWatermark`): the marks follow
//  the pointer in the canvas's overlay meanwhile (`movingMarks`), nothing developed and nothing written until the lift.
//  Single photographs only (`WatermarkRules`, W5): on a pair or a double every act is refused, as the mask layers' are.

import CoreGraphics
import Foundation

extension OpenFrameSession {
    /// The marks as the canvas shows them: the ones under a gesture, else the edit's.
    var shownMarks: [WatermarkPlacement] { movingMarks ?? edit.watermarks }

    /// The picked watermark, as it stands on the page; nil where none is picked (or it has gone, undone away).
    var pickedMark: WatermarkPlacement? { watermarkPick.flatMap { id in shownMarks.first { $0.id == id } } }

    /// Whether the open piece takes watermarks: a single photograph (W5).
    var takesWatermarks: Bool { layerPiece.isSingle }

    /// Refused while an export reads the frame (trap 34), as a mask layer's act is.
    private func markActRefused() -> Bool {
        guard takesWatermarks else { return true }
        guard exportHolds() else { return false }
        maskNote = L("This picture is being exported. Its layers wait until the export is done.")
        return true
    }

    /// **水印 › a mark**: a new placement of `mark`, centred, 0.3 of the short side wide, upright, opaque, on 成片
    /// (N10), on top of the others, picked. Refused at four (W2), with the reason at the panel's foot. `canvas`: the
    /// finished picture's shape, in any unit (the canvas's points: `watermarkCanvas`).
    @discardableResult
    func addWatermark(_ mark: WatermarkMark) -> UUID? {
        guard !markActRefused() else { return nil }
        guard WatermarkGeometry.canAdd(to: edit.watermarks) else { maskNote = L("A photo holds at most 4 watermarks."); return nil }
        maskNote = nil
        let canvas = watermarkCanvas.width > 0 ? watermarkCanvas : CGSize(width: max(1, frame?.originalSize.width ?? 3), height: max(1, frame?.originalSize.height ?? 2))
        let p = WatermarkGeometry.newPlacement(mark: mark.id, canvas: canvas, aspect: Double(mark.w) / Double(max(mark.h, 1)))
        change { $0.watermarks.append(p) }
        watermarkPick = p.id
        maskPick = nil
        return p.id
    }

    /// ⌫, the row's 删除, the page's 删除: the placement goes, asking nothing (Undo brings it back). The pick moves to the
    /// row that took its place, or none.
    func removeWatermark(_ id: UUID) {
        guard !markActRefused(), let i = edit.watermarks.firstIndex(where: { $0.id == id }) else { return }
        let list = edit.watermarks
        change { $0.watermarks.removeAll { $0.id == id } }
        if watermarkPick == id {
            // The rows are topmost first: the one drawn under it is the next row down; else the one above.
            watermarkPick = i > 0 ? list[i - 1].id : list.count > 1 ? list[i + 1].id : nil
        }
    }

    /// A field of a placement changed by a click, a typed number, a card: one step.
    func changeWatermark(_ id: UUID, _ mutate: (inout WatermarkPlacement) -> Void) {
        guard !markActRefused(), let i = edit.watermarks.firstIndex(where: { $0.id == id }) else { return }
        var p = edit.watermarks[i]
        let was = p
        mutate(&p)
        guard p != was else { return }
        let made = p
        change { e in if let j = e.watermarks.firstIndex(where: { $0.id == id }) { e.watermarks[j] = made } }
    }

    /// Up (+1, drawn later: the row higher) or down (−1) the z-order: one step.
    func reorderWatermark(_ id: UUID, by delta: Int) {
        guard !markActRefused() else { return }
        let next = WatermarkGeometry.reordered(edit.watermarks, moving: id, by: delta)
        guard next != edit.watermarks else { return }
        change { $0.watermarks = next }
    }

    /// The canvas `p` is measured on, as the page's canvas shows it (`WatermarkCanvases`): the 成片 one in the canvas's
    /// points, or — a 底片 mark with the film on — the 底片 one in its own units.
    func markCanvas(_ p: WatermarkPlacement) -> CGSize {
        if !WatermarkRules.drawnAsFull(p, appliesFilm: edit.appliesFilm), let c = watermarkCanvases, c.base.width > 0 { return c.base }
        return watermarkCanvas.width > 0 ? watermarkCanvas : CGSize(width: 3, height: 2)
    }

    /// The picked mark moved by `points` of the canvas as shown (an arrow key: Keynote's nudge), kept on its own canvas and
    /// measured from its nearest corner: one step. A 底片 mark's canvas is the 底片 one, the points taken through its place.
    func nudgeWatermark(_ id: UUID, points: CGSize) {
        guard let p = edit.watermarks.first(where: { $0.id == id }) else { return }
        let aspect = WatermarkComposite.library?.info(p.mark).map { Double($0.w) / Double(max($0.h, 1)) } ?? 1
        var by = points
        if !WatermarkRules.drawnAsFull(p, appliesFilm: edit.appliesFilm), let c = watermarkCanvases, c.base.width > 0,
           watermarkCanvas.width > 0 {
            let back = c.baseToShown(watermarkCanvas).inverted()
            by = CGSize(width: points.width * back.a + points.height * back.c, height: points.width * back.b + points.height * back.d)
        }
        let canvas = markCanvas(p)
        let next = WatermarkGeometry.settled(WatermarkGeometry.moved(p, by: by, canvas: canvas), canvas: canvas, aspect: aspect)
        changeWatermark(id) { $0 = next }
    }

    /// **叠加于 成片 · 底片**: one step, the numbers converted between the two canvases so the mark keeps its place and size
    /// on screen where both cover it, and is held in where they do not (`WatermarkGeometry.switched`). With the film off
    /// a 底片 mark is drawn on the 成片 canvas anyway (N9): the stage changes and the numbers stay.
    func switchWatermarkStage(_ id: UUID, to stage: WatermarkStage) {
        guard let p = edit.watermarks.first(where: { $0.id == id }), p.stage != stage else { return }
        let aspect = WatermarkComposite.library?.info(p.mark).map { Double($0.w) / Double(max($0.h, 1)) } ?? 1
        guard edit.appliesFilm, let c = watermarkCanvases, c.full.width > 0, c.base.width > 0 else {
            changeWatermark(id) { $0.stage = stage }
            return
        }
        // A placement's numbers are shares of its canvas's short side: any unit of a canvas measures them alike.
        let next = WatermarkGeometry.switched(p, to: stage, canvases: c, aspect: aspect)
        changeWatermark(id) { $0 = next }
    }

    // MARK: a gesture, one step

    /// The pointer landed on a mark, a handle, or a slider of the page: one step until it lifts.
    func beganWatermark() {
        guard !markActRefused(), movingMarks == nil else { return }
        beginHistoryTransaction()
        movingMarks = edit.watermarks
        Layer2Copies.shared.hold(frameID)
    }

    /// The marks on the move: the overlay follows them; nothing is written until `endedWatermark`.
    func moveWatermark(_ id: UUID, _ mutate: (inout WatermarkPlacement) -> Void) {
        guard var list = movingMarks, let i = list.firstIndex(where: { $0.id == id }) else { changeWatermark(id, mutate); return }
        var p = list[i]
        mutate(&p)
        guard p != list[i] else { return }
        list[i] = p
        movingMarks = list
        // With the overlay off (a slider of the page while the row's handles are put away), the pass shows it.
        if !watermarkOverlayLive { var shown = edit; shown.watermarks = list; layer2.show(marks: WatermarkComposite.Laid(shown, isComposite: false)) }
        // A 底片 mark is in the developed picture: under the gesture the page shows the frame developed without its 底片
        // marks, and the overlay draws them where the pointer has them (`developTarget`). Asked once; a repeat is a no-op.
        if cleanUnderGesture { requestUnderGesture() }
    }

    /// The pointer lifted: the marks are the edit's, the gesture one step.
    func endedWatermark() {
        guard let list = movingMarks else { return }
        movingMarks = nil
        if list != edit.watermarks { change { $0.watermarks = list } }
        // A gesture that came back to where it began writes nothing; the picture under it (developed without the 底片
        // marks) is owed the edit again.
        requestUnderGesture()
        Layer2Copies.shared.release(frameID)
        endHistoryTransaction()
    }
}
