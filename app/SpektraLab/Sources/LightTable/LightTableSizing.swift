//  LightTableSizing.swift — how big a library frame is on the table, in millimetres.
//
//  On the website an export says nothing about its size, so the visitor names the format it was
//  shot on and `formats.js` reads the rest from the picture's shape: a strip, a filed frame or a
//  plain picture, whichever shape is nearest. **On the host nothing is guessed** (RFC-045, "What
//  changes", 1): every library frame knows its own format, whether Film Edge is on and in which
//  view, whether it is a half-frame pair, and its crop, and the size comes from the same numbers
//  the develop is made from:
//
//  - **A frame in its film** (Film Edge on): the film's canvas, `FilmGeometry.canvasMM` — the
//    engine's own layout as `FilmLayout` ports it, the canvas's pixels times the gate's millimetres
//    a pixel. It is the size of the file the engine develops, turned as the film is turned. A
//    strip is the film's whole width across (35 mm, 61 on 120) and the frame plus a sliver of the
//    next ones along; filed, the gate and about 1.1 mm of carrier. `formats.js` documents the same
//    numbers as coming from the app (`kFormats`, `overscan.cpp`); here they are the app's own.
//  - **A half-frame pair**: the piece, two 18 × 24 holes and the gap between them
//    (`HalfFramePair.pieceSizeMM`); on its strip, the film round it as the pair's own estimate
//    prices it (`HalfFramePair.canvas(piece:look:)`, `Engine/PairDevelop.swift`), in millimetres.
//    The pair has no layout of its own yet (`FilmGeometry.swift`: "the half-frame pair" is left out
//    of the port), so this is the one size here that is the app's estimate and not its layout: the
//    widest margin a half-frame body draws (0.5 mm a side as a strip, 1.0 filed) where a real body
//    draws 0.40–0.50.
//  - **A bare frame** (no Film Edge): the picture as it is shown and exported — the crop, the
//    straighten, the quarter turns (`LibraryFrame.displaySize`) — at the frame's own film size,
//    `FilmParams.filmFormatMM`, the long edge of the uncut frame in millimetres (36 for 135 on a
//    3:2 photo, 84 for 6 × 9). A crop is a smaller piece of the same negative, as the engine has it
//    (`ExportPlan`: "the film keeps its size under the cut"): the millimetres a pixel are the uncut
//    frame's.
//
//  Pure arithmetic on the app's own types, no UIKit: `tools/lighttable_selftest.swift` holds it
//  against the layout for every format and both views. The library's side — which of the three a
//  frame is — is `LightTableFrames.swift`.

import CoreGraphics
import Foundation

enum LightTableSizing {
    /// **The most a film's picture is ever read at for the table**, pixels on its long edge: by the
    /// table's own textures (`LightTableSteps`) and by an export's bands (`LightTableExportPlan.filmSteps`).
    ///
    /// The owner, 2026-10-24: "The ceiling is based on the Light Table's sizes (A4–A6) … the ceiling should
    /// at least keep that extreme case pixel to pixel at the highest Light Table export resolution, and
    /// anything above that gets shrunk"; and "aren't we allowing the user to put 6x17 and 6x12 images onto
    /// the table?" — the table refuses no film for its size (`LightTableModel.place`: a 6 × 17 strip,
    /// 172.7 mm, overhangs A6's 148). So, from the code's own numbers:
    ///
    /// - the densest file the table writes is the largest short edge an export takes
    ///   (`LightTableExportPlan.shortEdges`, 5,000 px) across A6's short side (105 mm): 47.6 px a mm;
    /// - the largest film any format makes on the table: of every `FilmEdgeFormat`, the strip's length
    ///   along the film — its gate and the strip's margins as the film edge's own estimate of its canvas
    ///   makes them (`FilmEdgeSettings.canvasEstimate`) — and a half-frame pair's at its widest spacing
    ///   (`pair`): today 6 × 17, 168 + 2 × 2.35 = 172.7 mm;
    ///
    /// so 172.7 × 5,000 / 105, rounded up: **8,224 px** (its short side 61.15 mm, 2,912). Every format is
    /// read pixel for pixel in a 5,000 px A6 export; only a film larger than that (a format to come) is read
    /// shrunk to it. A plain frame (no film edge) can be up to 200 mm at its `filmFormatMM`, but the Mac lays
    /// none on the table (`MacLightTableCarry.takes`); where one is laid, it too is read at most this.
    static let sourceCeiling: Int = {
        let densest = Double(LightTableExportPlan.shortEdges.upperBound)
            / Double(min(LightTablePaper.a6.size.width, LightTablePaper.a6.size.height))      // px a mm
        return Int((largestFilmMM * densest).rounded(.up))
    }()

    /// The longest side of the largest film any format makes on the table, mm (`sourceCeiling`).
    static let largestFilmMM: Double = {
        var longest = 0.0
        for format in FilmEdgeFormat.allCases {
            var strip = FilmEdgeSettings()
            strip.format = format
            strip.mode = .strip
            // At a micrometre a pixel, so the canvas's pixels are its size in thousandths of a millimetre.
            let gate = PixelSize(width: Int((format.alongMM * 1000).rounded()), height: Int((format.acrossMM * 1000).rounded()))
            let canvas = strip.canvasEstimate(picture: gate)
            longest = max(longest, Double(max(canvas.width, canvas.height)) / 1000)
        }
        // A half-frame pair at its widest spacing, filed (its larger margin): two holes, the gap, 1 mm each end.
        let pair = HalfFramePair.holeMM.along * 2 + HalfFramePair.spacingRange.upperBound + 2 * 1.0
        return max(longest, pair)
    }()

    /// A frame in its film: the film's canvas, as it lies, mm.
    static func film(_ g: FilmGeometry) -> CGSize { g.canvasMM }

    /// A bare frame: the shown picture at the uncut frame's millimetres a pixel. `display` is the
    /// picture as shown (after its crop and turns), `original` the uncut frame it is cut from.
    static func plain(display: PixelSize, original: PixelSize, filmFormatMM: Double) -> CGSize {
        let k = filmFormatMM / Double(max(original.longEdge, 1))
        return CGSize(width: Double(max(display.width, 1)) * k, height: Double(max(display.height, 1)) * k)
    }

    /// A half-frame pair: the piece, or — on its strip — the film round it. `filmEdge` says the
    /// strip is drawn (`HalfFramePair.wearsFilmEdge`: Film Edge in this build, and the pair's own
    /// switch); `view` is the pair's look's Film Edge view. The arithmetic of
    /// `HalfFramePair.canvas(piece:look:)`, in millimetres instead of pixels: along, the piece and
    /// a margin at each end; across, the film's width as a strip, the hole and 1.1 mm a side filed.
    static func pair(_ pair: HalfFramePair, filmEdge: Bool, view: FilmEdgeView) -> CGSize {
        let piece = pair.pieceSizeMM
        guard filmEdge else { return piece }
        let margin = view == .strip ? 0.5 : 1.0
        let along = pair.pieceLongMM + 2 * margin
        let across = view == .strip ? FilmEdgeFormat.half.filmWidthMM : HalfFramePair.holeMM.across + 2.2
        return pair.turned ? CGSize(width: across, height: along) : CGSize(width: along, height: across)
    }
}
