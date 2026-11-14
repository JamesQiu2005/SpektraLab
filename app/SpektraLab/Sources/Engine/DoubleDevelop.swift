//  DoubleDevelop.swift — a double exposure, as the engine is handed it (RFC-048).
//
//  The half-frame pair's `PairDevelop.swift`, for its sibling. Two halves, both
//  made on the main actor when a double exposure's job is submitted
//  (`EngineRouter.prepare`):
//
//  - **the piece** (`DoubleExposure.piece`): both exposures **added** over the
//    whole frame (`PieceAsk.Lay.add`), each cut by its own photograph, laid by
//    its placement — quarter turns, flip, window — and exposed by itself, at
//    the size the job renders. Plain values for the host; `FrameDecoder`
//    composes it on the engine's queue (`PieceAdder`);
//  - **the wire** (`FrameEdit.doubleWire`): the whole's look, as for a
//    photograph, with RFC-048 §3's overrides.
//
//  **What the engine is told** (RFC-048 §3):
//
//  | field | value | why |
//  |---|---|---|
//  | `auto_exposure` | off | each exposure carries its light in its pixels (§4) |
//  | `exposure_compensation_ev` | 0 | the whole's Film Exposure is a gain on both exposures, as on the pair |
//  | `film_format_mm` | the look's own | unlike a pair's piece, a double's *is* one frame |
//  | the cut | none | each exposure was cut and laid by the host; the piece is the frame |
//  | film edge | as for a photograph the host cut to its gate (`HostCut`) | the piece is composed at the gate's shape |
//  | `overscan_pair`, `date_imprint_text_b`, `scene_latitude_split`, `scene_latitude_b_*` | not sent | one frame, one date, one placement |
//  | `date_imprint_text` | the bottom exposure's date, when the back is on | PRD 2 §8.4 |
//
//  Scene Placement and the Latitude card read the whole piece as one scene:
//  the sum *is* the scene the film saw.
//
//  **The frame's size** (RFC-048 §5). At the full tier: the bottom's framed
//  size, no larger than the top fills at scale 1 without being enlarged
//  (`DoubleExposure.frameSize`, the foundation's). Below it: the job's long
//  edge, the same shape. With a film edge, the frame is that size cut to the
//  gate's shape about its middle — **the photograph's own cut** of a frame that
//  wears a film edge (`FilmFraming.largest`), so a double is priced and laid
//  out exactly as the photograph it develops as (`FrameEdit.canvas`), and no
//  picture is enlarged: the gate's cut lies inside the frame, which lies inside
//  each picture's fit. Each exposure is decoded at the long edge its window
//  needs, and no larger (`PieceAsk.longEdge`).
//
//  **A film turned half round is turned here, as on a photograph**
//  (`FrameEdit.hostTurns`): the frame is composed turned back (each placed
//  picture `turnedAfter`), and the canvas the engine makes is turned forward by
//  the host after (`EngineHost.Request.turnsAfter`). A pair cannot do this; a
//  double exposure is one frame, and can.
//
//  **Each exposure's light** (RFC-048 §4): `.metered(reading:plus:key:)` with
//  `plus` = its own EV and the whole's Film Exposure, or `.own(the same)` with
//  its meter off — its own switch, or the whole's Custom. Its gain is 2^stops.
//  The reading is kept in the double under `DoubleExposure.meterKey` — the
//  photograph, its decode, its own cut and the intent, **not its placement** —
//  so moving a picture never meters it again (the pair's rule against pumping).

import CoreGraphics
import Foundation

extension DoubleExposure {
    /// The frame as the engine is handed it at a job's size, and how it lies.
    struct PieceFrame: Equatable, Sendable {
        /// The frame upright, in pixels: what the pictures' windows are cut at.
        var upright: PixelSize
        /// The frame's shape, width over height, upright.
        var aspect: Double
        /// Quarter turns, clockwise, the host gives the engine's canvas after
        /// the render (a film edge turned half round); 0 for nearly every frame.
        var turnsAfter: Int
        /// The piece the engine is handed: `upright`, turned back by `turnsAfter`.
        var handed: PixelSize {
            turnsAfter % 2 == 0 ? upright : PixelSize(width: upright.height, height: upright.width)
        }
    }

    /// **The frame at a job's size** (RFC-048 §5): `frameSize` at the bottom's
    /// shape, capped to `longEdge` below the full tier; with a film edge on the
    /// whole, that cut to the gate's shape about its middle and the host's turn
    /// for it. Nil where no exposure has a picture to read.
    func pieceFrame(_ framed: Framed, look: FrameEdit, longEdge: Int?) -> PieceFrame? {
        guard let base = frameSize(framed, longEdge: longEdge), base.width > 0, base.height > 0 else { return nil }
        guard look.filmEdge.effective else {
            return PieceFrame(upright: base, aspect: Double(base.width) / Double(base.height), turnsAfter: 0)
        }
        // The photograph's cut of a frame in its film (`FrameEdit.pictureGeometry`): the look carries no
        // crop and no framing of its own (`asDoubleLook`), so the gate's largest cut about the middle.
        var held = look.asDoubleLook
        held.geometry = .default
        let gate = held.pictureGeometry(source: base).gateSize(for: CGSize(width: base.width, height: base.height))
        let w = max(Int(gate.width.rounded(.down)), 1), h = max(Int(gate.height.rounded(.down)), 1)
        return PieceFrame(upright: PixelSize(width: w, height: h), aspect: Double(gate.width / max(gate.height, 1)),
                          turnsAfter: held.hostTurns(source: base))
    }

    /// The piece as the host is asked for it: each exposure whose photograph
    /// the library still has, with a file to develop from, cut, laid and
    /// exposed, **both added** over the whole frame, at the job's size (nil:
    /// the full tier). An exposure left out (`only`) is not on it: the
    /// press-and-hold of one exposure alone (`alone`).
    func piece(_ frames: Frames, look: FrameEdit, longEdge: Int?) -> PieceAsk {
        piece(frames, look: look, longEdge: longEdge, positions: Position.allCases, alone: false)
    }

    /// **One exposure alone, as it would develop by itself** (PRD 2 D12, RFC-048
    /// §6): the same frame, the same look, with the other exposure left out and
    /// this one at the light its meter chose for it — 2^reading, and the whole's
    /// Film Exposure, without the share of the frame it gave up to the other
    /// (its own EV). With its meter off it is the whole's Film Exposure alone.
    /// A render of it is cached per exposure by whoever asks (the darkroom, on
    /// the first hold: `EngineRouter.prepareAlone`), so it costs nothing until used.
    func alone(_ position: Position, frames: Frames, look: FrameEdit, longEdge: Int?) -> PieceAsk {
        piece(frames, look: look, longEdge: longEdge, positions: [position], alone: true)
    }

    private func piece(_ frames: Frames, look: FrameEdit, longEdge: Int?, positions: [Position], alone: Bool) -> PieceAsk {
        let framed = framed(frames)
        guard let frame = pieceFrame(framed, look: look, longEdge: longEdge) else {
            return PieceAsk(size: PixelSize(width: 0, height: 0), pictures: [])
        }
        let handed = frame.handed
        let whole = CGRect(x: 0, y: 0, width: handed.width, height: handed.height)
        let film = look.params.exposureCompensationEV
        var pictures: [PieceAsk.Picture] = []
        for position in positions {
            guard let e = self[position], let photo = frames[position], let url = photo.developSource,
                  let size = framed[position], size.width > 0, size.height > 0 else { continue }
            let turned = HalfFramePair.turned(size, by: e.placement.base)
            let window = Self.window(e.placement, framed: size, aspect: frame.aspect)
            let key = Self.meterKey(e)
            // Its own stops and the whole's Film Exposure, in its pixels (RFC-048 §4). Alone: as metered.
            let plus = alone ? film : e.exposureEV + film
            let exposure: PieceAsk.Exposure = e.autoExposure && look.params.autoExposure
                ? .metered(reading: reading(position), plus: plus, key: key)
                : .own(alone ? film : plus)
            pictures.append(PieceAsk.Picture(
                index: position.rawValue, url: url, isRAW: photo.developsFromRAW, settings: e.decode,
                longEdge: PieceAsk.longEdge(original: photo.developSize, framed: turned, window: window,
                                            hole: CGSize(width: frame.upright.width, height: frame.upright.height)),
                cut: e.cut, quarterTurns: e.placement.base.quarterTurns, window: window, hole: whole,
                exposure: exposure, meterWire: look.doubleMeterWire(method: e.wireMethod),
                lay: .add, flipped: e.placement.flipped, turnedAfter: (4 - frame.turnsAfter) % 4))
        }
        return PieceAsk(size: handed, pictures: pictures)
    }

    /// **What a page's develop of this double under `look` tells the strip its
    /// pixels are** (`EngineHost.Request.stripPixels`), so that the page's own
    /// decode is made the strip's only where it *is* the strip's. The cards
    /// compose the piece with the film edge and the date off
    /// (`EngineRouter.doubleCardPlan`); the date is printed by the engine and
    /// changes no pixel of the piece, but **a film edge cuts the frame to its
    /// gate and may turn it** (`pieceFrame`), and then the page's piece is
    /// other pixels: a 4:3 frame cut to a 35 mm gate, a film turned half round.
    /// Handed over as the card's, that piece was scaled into the card's size —
    /// squeezed, windowed at the gate's shape, or turned — and every card of
    /// the double developed from it (the 2026-11-07 review).
    ///
    /// So both pieces are asked at the strip's size and compared by their
    /// keys, which name every pixel's making (`PieceAsk.key`: the size, each
    /// picture's window, hole and turns): the same, the card's key; otherwise
    /// the page's own, which no strip's feed is (`EngineHost.feedStrip`
    /// declines it). Called on the double as the job develops it (`mirrored`).
    func stripPixels(_ frames: Frames, look: FrameEdit) -> String {
        var card = look
        card.filmEdge.active = false; card.dateBack.active = false
        let cards = piece(frames, look: card, longEdge: StockPreviewSize.openLongEdge).key
        let page = piece(frames, look: look, longEdge: StockPreviewSize.openLongEdge).key
        return page == cards ? cards : page
    }

    /// The canvas a develop of a frame `piece` pixels large (upright) makes
    /// under `look`: the frame, or — with a film edge — the film round it, as a
    /// photograph's is priced (`FilmEdgeSettings.canvasEstimate`). An estimate,
    /// for pricing the job before it runs.
    func canvas(piece: PixelSize, look: FrameEdit) -> PixelSize {
        var held = look.asDoubleLook
        held.geometry = .default
        return held.canvas(preview: piece)
    }
}

extension FrameEdit {
    /// The wire the engine's meter is opened with for one exposure of a double
    /// alone: this look with the meter on and that exposure's intent, no
    /// exposure of its own, no cut, no film edge and no date — **on one frame
    /// of the look's own film format** (the pair's `meterWire` puts its picture
    /// on a half frame; a double's frame is a whole one).
    func doubleMeterWire(method: String?) -> [String: ParamValue] {
        var alone = self
        alone.params.autoExposure = true
        alone.params.autoExposureMethod = method
        alone.params.exposureCompensationEV = 0
        alone.params.pairSplit = 0
        alone.geometry = .default
        return alone.engineWire(previewLongEdge: nil)
    }

    /// The rows a double exposure's wire never carries (RFC-048 §3): a pair's
    /// strip, a pair's second date, a pair's second Scene Placement.
    static func isPairOnly(_ field: String) -> Bool {
        field == "overscan_pair" || field == "date_imprint_text_b" || field == "scene_latitude_split"
            || field.hasPrefix("scene_latitude_b_")
    }

    /// Everything `spk_open` is handed for a double exposure's piece under this
    /// look, complete (RFC-048 §3). `film` is the frame's side of a film edge
    /// and its one date — the bottom exposure's (`EngineRouter.wire(_:frames:look:longEdge:)`).
    /// The frame handed over beside this wire has to be the piece
    /// (`DoubleExposure.piece`): already cut, so the wire's own cut is none.
    func doubleWire(previewLongEdge: Int?, film: FilmWire) -> [String: ParamValue] {
        var look = self
        // The piece is the frame — each exposure cut and laid by the host — and each carries its light.
        look.geometry = .default
        look.filmEdge.framing = nil
        look.params.autoExposure = false
        look.params.exposureCompensationEV = 0
        // One Scene Placement for the whole, on the engine's own rows: never a pair's second.
        look.params.pairSplit = 0
        look.params.placementIsRight = false
        // `film_format_mm` stays the look's own: one frame of its film.
        return look.engineWire(previewLongEdge: previewLongEdge, film: film).filter { !Self.isPairOnly($0.key) }
    }
}
