//  PairLayout.swift — where everything on the pair's page is, as numbers.
//
//  design/pair (`design/src/gen_pair.py`). The page has the Film Edge flow's
//  bands — a top bar, the preview, a row of capsules, the controls, the action
//  — with one difference: **the preview takes what the others leave**. The
//  Film Edge flow's is the drawing's 372 pt on every host, and on an reference device
//  its controls run under the action; here the controls keep their 248 pt and
//  the piece is drawn smaller, whole.
//
//  Every number is `gen_pair.py`'s: `PV_Y`/`PV_H` and `P0` for the bands, and
//  the three panels' places from `P0` (`EM`, `FR`, `FM` there). No SwiftUI, as
//  `DevelopLayout` has none: a page that is arithmetic can be held as arithmetic.

import CoreGraphics

enum PairLayout {
    // MARK: the bands, from the top of the safe area (y = 59 on the drawn page)

    /// 59 → 100: Cancel, the title.
    static let bar: CGFloat = 41
    /// 100 → 472 on the drawn page; whatever the others leave on another.
    static let previewDrawn: CGFloat = 372
    /// The least the piece is drawn in: under this the page would run past its safe area.
    static let previewLeast: CGFloat = 120
    /// 472 → 522: Film and the two frames, the rule on its bottom edge.
    static let layers: CGFloat = 50
    /// 522 → 770: the picked layer's controls. One height for all three, so nothing moves.
    static let controls: CGFloat = 248
    /// 770 → 814, and 4 under it.
    static let actions: CGFloat = 44
    static let actionsBottom: CGFloat = 4

    /// The drawn page inside its safe area: 393 × (818 − 59).
    static let drawn = CGSize(width: 393, height: 759)

    /// The preview's height on a page `height` tall inside its safe area.
    static func preview(in height: CGFloat) -> CGFloat {
        max(previewLeast, height - bar - layers - controls - actions - actionsBottom)
    }

    /// How far the page runs past a safe area `height` tall: 0 on every reference device
    /// the app runs on (an reference device's 647 pt leave the preview 260).
    static func overflow(in height: CGFloat) -> CGFloat {
        max(0, bar + previewLeast + layers + controls + actions + actionsBottom - height)
    }

    // MARK: the piece in the preview (`gen_pair.preview`)

    /// The room above the piece for the GUIDE tag, and under it.
    static let tagRoom: CGFloat = 34
    static let pieceFoot: CGFloat = 12
    /// The piece's side margin.
    static let pieceMargin: CGFloat = 12
    /// The GUIDE tag's top.
    static let tagTop: CGFloat = 6

    /// Where a piece `mm` large sits in a preview `room` large: as large as
    /// fits under the tag and inside the margins, centred.
    static func piece(mm: CGSize, room: CGSize) -> CGRect {
        let free = CGSize(width: room.width - 2 * pieceMargin, height: room.height - tagRoom - pieceFoot)
        let k = max(0, min(free.height / max(mm.height, 0.001), free.width / max(mm.width, 0.001)))
        let size = CGSize(width: mm.width * k, height: mm.height * k)
        return CGRect(x: (room.width - size.width) / 2, y: tagRoom + (free.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    // MARK: the layers' row (`gen_pair.layers_row`)

    enum Layers {
        /// The capsule: 27 tall, its top 11 under the band's.
        static let capsuleTop: CGFloat = 11
        static let capsuleHeight: CGFloat = 27
        /// The capsule is its word and 13 pt either side.
        static let capsulePadding: CGFloat = 13
        static let type: CGFloat = 13.5
    }

    // MARK: the controls' places, from the rule under the layers (`P0` = 522)

    /// A row's title and its value.
    static let label: CGFloat = 14
    /// A ruler's centre line under its label's baseline, as the Film Edge flow's Frame step draws it.
    static let rulerDrop: CGFloat = 28
    /// A two-way switch's segment.
    static let segment: CGFloat = 76

    /// An empty hole (`EM`).
    enum Empty {
        static let button: CGFloat = 20
        static let note: CGFloat = 88
    }

    /// A frame in its hole (`FR`).
    enum Frame {
        static let exposure: CGFloat = 28
        static let seg: CGFloat = 80
        static let applies: CGFloat = 98
        static let scopeNote: CGFloat = 126
        static let rule: CGFloat = 140
        static let picture: CGFloat = 166
        static let chips: CGFloat = 180
        static let note: CGFloat = 232
    }

    /// The film (`FM`).
    enum Film {
        static let seg: CGFloat = 10
        static let camera: CGFloat = 28
        static let cameraNote: CGFloat = 56
        static let rule1: CGFloat = 70
        static let spacing: CGFloat = 96
        static let spacingNote: CGFloat = 160
        static let rule2: CGFloat = 174
        static let swap: CGFloat = 184
        static let note: CGFloat = 232
    }

    // MARK: placing a picture (`gen_pair_v2.page_place`)

    /// 522 → 770 on the drawn page: Picture, its chips, the page's two lines.
    static let placeControls: CGFloat = 248
    /// The placing page's controls, from the rule under the preview (`q0` = 522).
    enum Place {
        static let picture: CGFloat = 30
        static let chips: CGFloat = 46
        static let note: CGFloat = 100
        static let noteLead: CGFloat = 16.3
    }

    // MARK: Add Frame (`gen_pair.page_picker`)

    /// The sheet's top edge on the drawing's 852 pt page.
    static let pickerTop: CGFloat = 232
    /// The grid's top under the sheet's.
    static let pickerGrid: CGFloat = 84
}
