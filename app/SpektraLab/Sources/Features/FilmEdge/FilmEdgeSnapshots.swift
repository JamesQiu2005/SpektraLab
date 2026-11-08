//  FilmEdgeSnapshots.swift — the Film Edge flow's pages, for the snapshot harness.
//  Lane D: D2 Film, D3 Frame, D4 Edge, D5 Date, D6 the Frame tab with an edge on.
//
//  The drawings' frame is the street picture, upright, on Gold 200, shot
//  1 October 2026 through body No. 19, frame 5, the film at 90° — what
//  `gen_overscan` renders (`CAM, FRM = 19, 5`; `flow_mask`'s Gold 200).
//  The demo library's street frame is given exactly that here, never in the app.
//
//  After the drawn five come states the design does not draw and this build
//  makes by interpretation: the Edge step's Holes, Light and Body panels, the
//  Date step's Size ruler, the panoramic and 120 formats, the date alone, a
//  black-and-white film's edge.
//  They are held against nothing (``) and exist to be looked at.

import SwiftUI

enum FilmEdgeSnapshots {
    @MainActor static var pages: [SnapshotPage] {
        [
            SnapshotPage("D2", "Film Edge · Film") { model in
                FilmEdgeFlow(frameID: street(model), entry: .film, snapshot: .init(draft: draft(model)))
            },
            SnapshotPage("D3", "Film Edge · Frame") { model in
                FilmEdgeFlow(frameID: street(model), entry: .frame, snapshot: .init(draft: draft(model, framed: true)))
            },
            SnapshotPage("D4", "Film Edge · Edge") { model in
                FilmEdgeFlow(frameID: street(model), entry: .edge,
                             snapshot: .init(draft: draft(model, framed: true, on: true),
                                             status: DarkroomSnapshots.status("Developing" + Fmt.dot + "Film edge 135", 0.58)))
            },
            SnapshotPage("D5", "Film Edge · Date") { model in
                FilmEdgeFlow(frameID: street(model), entry: .date,
                             snapshot: .init(draft: draft(model, framed: true, on: true, date: .lcd)))
            },
            // The Frame tab with a film edge and Date Back active.
            SnapshotPage("D6", "Frame, edge on") { model in
                DevelopPane(frameID: wearing(model, draft(model, framed: true, on: true, date: .lcd)), opening: .tab(.frame))
            },

            // --- not drawn by the design
            SnapshotPage("D4-holes", "Edge · Holes") { model in
                var e = draft(model, framed: true, on: true)
                e.filmEdge.holes = .black
                return FilmEdgeFlow(frameID: street(model), entry: .edge, snapshot: .init(draft: e, tool: .holes))
            },
            SnapshotPage("D4-light", "Edge · Light") { model in
                FilmEdgeFlow(frameID: street(model), entry: .edge,
                             snapshot: .init(draft: draft(model, framed: true, on: true), tool: .light))
            },
            SnapshotPage("D4-body", "Edge · Body") { model in
                FilmEdgeFlow(frameID: street(model), entry: .edge,
                             snapshot: .init(draft: draft(model, framed: true, on: true), tool: .body))
            },
            SnapshotPage("D5-size", "Date · Size") { model in
                FilmEdgeFlow(frameID: street(model), entry: .date,
                             snapshot: .init(draft: draft(model, framed: true, on: true, date: .dots), sizing: true))
            },
            SnapshotPage("D5-data", "Date · Data") { model in
                FilmEdgeFlow(frameID: street(model), entry: .date,
                             snapshot: .init(draft: draft(model, framed: true, on: true, date: .data)))
            },
            // 2026-10-20: the edge print's brightness, the date's, and the data line beside a date face.
            SnapshotPage("D4-print", "Edge · Edge Print 2.0×") { model in
                var e = draft(model, framed: true, on: true)
                e.filmEdge.edgeBrightness = 2
                return FilmEdgeFlow(frameID: street(model), entry: .edge, snapshot: .init(draft: e, tool: .print))
            },
            SnapshotPage("D5-brightness", "Date · Brightness 2.0×") { model in
                var e = draft(model, framed: true, on: true, date: .lcd)
                e.dateBack.brightness = 2
                return FilmEdgeFlow(frameID: street(model), entry: .date, snapshot: .init(draft: e, dateControl: .brightness))
            },
            SnapshotPage("D5-date-and-data", "Date · LCD and Data") { model in
                var e = draft(model, framed: true, on: true, date: .lcd)
                e.dateBack.alsoData = true
                return FilmEdgeFlow(frameID: street(model), entry: .date, snapshot: .init(draft: e))
            },
            SnapshotPage("D5-alone", "Date Back alone") { model in
                FilmEdgeFlow(frameID: street(model), entry: .date, snapshot: .init(draft: draft(model, date: .lcd)))
            },
            // What greys now that every step is open from the start (2026-10-19): the frame
            // number where the edge print is not in the scan, the faces while the date is off.
            SnapshotPage("D4-filed", "Body · Filed: no frame no.") { model in
                var e = draft(model, framed: true, on: true)
                e.filmEdge.mode = .filed
                return FilmEdgeFlow(frameID: street(model), entry: .edge, snapshot: .init(draft: e, tool: .body))
            },
            SnapshotPage("D5-off", "Date, off: faces wait") { model in
                FilmEdgeFlow(frameID: street(model), entry: .date, snapshot: .init(draft: draft(model, framed: true, on: true)))
            },
            SnapshotPage("D2-xpan", "Film · XPan") { model in
                FilmEdgeFlow(frameID: bund(model), entry: .film, snapshot: .init(draft: format(model, .xpan)))
            },
            SnapshotPage("D3-617", "Frame · 6×17") { model in
                FilmEdgeFlow(frameID: bund(model), entry: .frame, snapshot: .init(draft: format(model, .f6x17)))
            },
            // A black-and-white film's own edge: HB5 Plus, the one layout that is
            // Kodak's turned half a turn — the bars along the top band, the name
            // upside down along the bottom one — as the guide ghosts it and as
            // the film is drawn with the edge on.
            SnapshotPage("D3-hb5", "Frame · HB5 Plus") { model in
                var e = draft(model, framed: true)
                e.params.load(film: "ilford_hp5_plus_400")
                return FilmEdgeFlow(frameID: street(model), entry: .frame, snapshot: .init(draft: e))
            },
            SnapshotPage("D4-hb5", "Edge · HB5 Plus") { model in
                var e = draft(model, framed: true, on: true)
                e.params.load(film: "ilford_hp5_plus_400")
                return FilmEdgeFlow(frameID: street(model), entry: .edge, snapshot: .init(draft: e))
            },
            SnapshotPage("D4-645", "Edge · 645") { model in
                var e = format(model, .f645)
                e.filmEdge.active = true
                e.filmEdge.cameraSeed = 19
                return FilmEdgeFlow(frameID: bund(model), entry: .edge, snapshot: .init(draft: e))
            },
            SnapshotPage("D5-617", "Date · 6×17") { model in
                var e = format(model, .f6x17)
                e.filmEdge.active = true
                e.filmEdge.cameraSeed = 19
                return FilmEdgeFlow(frameID: bund(model), entry: .date, snapshot: .init(draft: e))
            },
            SnapshotPage("D6-617", "Frame tab · 6×17") { model in
                var e = format(model, .f6x17)
                e.filmEdge.active = true
                e.filmEdge.cameraSeed = 19
                return DevelopPane(frameID: wearing(model, e, on: bund(model)), opening: .tab(.frame))
            },
        ]
    }

    /// The street frame, as the drawings have it: Gold 200, 1 October 2026, frame 5.
    @MainActor static func street(_ model: AppServices) -> LibraryFrame.ID {
        let id = model.library.frames.first { $0.picture == .sample("street.jpg") }?.id ?? DarkroomSnapshots.frameID(model)
        model.library.update(id) { f in
            f.edit.params.load(film: "kodak_gold_200")
            f.edit.frameSeed = 5
            f.captureDate = DemoLibrary.date(2026, 10, 1, 10, 20)
            f.develop = .developed
        }
        return id
    }

    /// The Bund frame: a landscape, for the long formats.
    @MainActor static func bund(_ model: AppServices) -> LibraryFrame.ID {
        let id = DarkroomSnapshots.frameID(model)
        model.library.update(id) { $0.edit.frameSeed = 5 }
        return id
    }

    /// The street frame's edit with the drawings' film edge: 135, Strip, the
    /// film at 90°, body 19 — whole (the Film step) or framed at 1.13× with
    /// the gate 62 % across and 30 % down the spare picture (the Frame step on).
    @MainActor static func draft(_ model: AppServices, framed: Bool = false, on: Bool = false, date: DateBackFace? = nil) -> FrameEdit {
        guard let frame = model.library.frame(street(model)) else { return .default }
        var e = frame.edit
        e.filmEdge.format = .f135
        e.filmEdge.turn = 1
        e.filmEdge.cameraSeed = 19
        e.filmEdge.active = on
        let source = CGSize(width: frame.originalSize.width, height: frame.originalSize.height)
        if framed {
            var g = FilmFraming.largest(format: .f135, turn: 1, source: source, photo: e.geometry)
            let zoom = 1600.0 / 1416.0
            let w = g.crop.width / zoom, h = g.crop.height / zoom
            g.crop = CropRect(x: (1 - w) * 0.62, y: (1 - h) * 0.30, width: w, height: h)
            g.intendedSize = CGSize(width: w, height: h)
            e.filmEdge.framing = g
        }
        if let date {
            e.dateBack.active = true
            e.dateBack.style = date
        }
        return e
    }

    /// The Bund frame's edit in a format, lying the way the picture does.
    @MainActor static func format(_ model: AppServices, _ format: FilmEdgeFormat) -> FrameEdit {
        guard let frame = model.library.frame(bund(model)) else { return .default }
        var e = frame.edit
        e.filmEdge.format = format
        e.filmEdge.turn = format.defaultTurn(pictureAspect: frame.originalSize.aspect)
        e.filmEdge.cameraSeed = 19
        return e
    }

    /// Put an edit on a frame, for a page that reads the frame's own.
    @MainActor static func wearing(_ model: AppServices, _ edit: FrameEdit, on id: LibraryFrame.ID? = nil) -> LibraryFrame.ID {
        let id = id ?? street(model)
        model.library.update(id) { $0.edit = edit }
        return id
    }
}
