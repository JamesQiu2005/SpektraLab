//  LightTableFrames.swift — a library frame as the light table reads it: its size, and its picture.
//
//  The two questions the table asks of the library, answered from the frame alone and never from
//  its picture's shape:
//
//  - **How big is it?** `LightTableSizing`, from the frame's edit: its film's canvas while Film
//    Edge is on (the film resolved as every page resolves it, `FilmEdgeResolver`, with the same
//    body), a pair's piece, or the bare picture at its film's size.
//  - **What is drawn?** What the library tile draws (`FrameView`, `DevelopedFrameView`): the
//    frame's kept develop, already cut and with Edit's layer where it carries one; until there is
//    one, the camera's preview through the frame's crop; and for a film edge not yet developed, the
//    film drawn from its geometry round that preview (`FilmCanvasView`'s developed face) — the
//    same silhouette the develop will have. A frame waiting for a develop shows what the tile shows,
//    and is read again when it has been made (`LightTableSource.key` changes with the develop's stamp).
//  - **Larger than its kept develop, or with none** (2026-10-24; the Mac makes its frames on demand and
//    develops none as they arrive): its full-size render kept on disk, read at the size asked
//    (`full`, `LightTableFullRead`); where none is kept, one is asked for once — the table's only job —
//    and the film shows what there is meanwhile (`LightTableSteps.choose`, `LightTableController.wantsFull`).

import CoreGraphics
import Foundation

/// Where a film's picture is read from. `key` names the picture exactly: a new develop, a new
/// crop or a new film is a new key, and the texture is read again.
enum LightTableSource: Equatable, Sendable {
    /// A picture on disk drawn as it is: a kept develop (already cut), or an uncut preview.
    case picture(PictureRef)
    /// A preview drawn through the frame's crop, straighten, turns and flips; `source` is the
    /// size the geometry was made in (the original's pixels).
    case cut(PictureRef, Geometry, source: PixelSize)
    /// A film edge not yet developed: the film drawn from its geometry round the preview.
    case film(FilmGeometry, picture: PictureRef, framing: Geometry, source: PixelSize, stock: String)
    /// The frame's full-size render kept on disk, read at the size asked (`LightTableFullRead`).
    case full(LightTableFullRef)
    /// Nothing to read (a develop still in memory only, or a frame with no picture).
    case none

    var key: String {
        switch self {
        case .picture(let p): "p|\(p)"
        case .cut(let p, let g, let s): "c|\(p)|\(g.cutKey)|q\(g.quarterTurns)|\(g.flipH)\(g.flipV)|\(s.width)x\(s.height)"
        case .film(let g, let p, let f, let s, let stock):
            "f|\(p)|\(f.cutKey)|\(g.out.width)x\(g.out.height)|\(g.request.format.rawValue)|\(g.request.mode.rawValue)|\(g.request.turn)|\(g.request.cameraSeed)|\(g.request.frameSeed)|\(stock)|\(s.width)x\(s.height)"
        case .full(let r): "F|\(r.key)"
        case .none: "-"
        }
    }
}

@MainActor
enum LightTableFrames {
    /// The frame's size on the table, mm, as its picture lies unturned.
    static func size(of frame: LibraryFrame, bodySeed: Int) -> CGSize {
        let e = frame.edit
        if let pair = frame.pair {
            return LightTableSizing.pair(pair, filmEdge: FeatureFlags.filmEdge && pair.onStrip, view: e.filmEdge.mode)
        }
        if let film = film(of: frame, bodySeed: bodySeed) { return LightTableSizing.film(film.geometry) }
        return LightTableSizing.plain(display: frame.displaySize, original: frame.originalSize, filmFormatMM: e.params.filmFormatMM)
    }

    /// The frame's film, resolved as the pages resolve it, at the frame's own size: no film budget,
    /// because the table wants millimetres and the budget scales pixels only (`FilmEdgeResolver`:
    /// "the budget scales the picture, never the film alone").
    static func film(of frame: LibraryFrame, bodySeed: Int) -> ResolvedFilmEdge? {
        guard frame.pair == nil, frame.edit.filmEdge.effective else { return nil }
        return FilmEdgeResolver.resolve(frame: frame, edit: frame.edit, bodySeed: bodySeed, source: PortedFilmGeometry(),
                                        budgetMP: .greatestFiniteMagnitude)
    }

    /// What the library tile would draw for this frame.
    static func source(of frame: LibraryFrame, bodySeed: Int) -> LightTableSource {
        // A develop whose file is missing is drawn as none is, as the library tile does (`FrameView`).
        if let developed = frame.shownDevelop {
            let p = Layer2Copies.shared.served(frame) ?? developed.picture
            if case .rendered = p { return .none }
            return .picture(p)
        }
        if case .rendered = frame.picture { return .none }
        if let film = film(of: frame, bodySeed: bodySeed) {
            return .film(film.geometry, picture: frame.picture, framing: film.framing, source: frame.originalSize,
                         stock: frame.edit.params.filmStock)
        }
        let g = frame.pictureGeometry
        if frame.pair != nil || g.isIdentity { return .picture(frame.picture) }
        return .cut(frame.picture, g, source: frame.originalSize)
    }

    /// The kept develop's long edge, where the frame has one (the table's `LightTableSteps.choose`).
    static func keptEdge(of frame: LibraryFrame) -> Int? {
        guard let d = frame.shownDevelop, d.size.longEdge > 0 else { return frame.shownDevelop == nil ? nil : 0 }
        return d.size.longEdge
    }

    /// The words a reader is given for a film (`captionOf`): "_DSC0061 · 135 · Film Edge".
    static func caption(of frame: LibraryFrame) -> String {
        var parts = [frame.stem]
        if frame.pair != nil { parts.append(L("A half-frame pair")) }
        else if frame.edit.filmEdge.effective {
            parts.append(frame.edit.filmEdge.format.label)
            parts.append(frame.edit.filmEdge.mode == .strip ? L("Film Edge") : L("Film Edge, filed"))
        }
        return parts.joined(separator: " · ")
    }
}
