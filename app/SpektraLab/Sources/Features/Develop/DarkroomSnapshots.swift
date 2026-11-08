//  DarkroomSnapshots.swift — the darkroom side's pages, for the snapshot harness.
//  Lanes C (develop), D (frame) and E (out), and F4.
//
//  Each page in the state its drawing shows. The develop page is drawn by
//  `design/edit_v2` since 2026-10-09 (`gen_edit_v2.PAGES`): its frame is the
//  Bund on Porta 400 and Porta Enduro, Film Exp. +0.3, Yellow +0.10, Magenta
//  +0.05. The demo library's selected frame is that frame on Supera Enduro
//  (the v1 drawings' paper), so the paper and whatever else a drawing adds —
//  Grain 1.40×, Highlight 1.50, a develop caught at 58 % — is set here, never
//  in the app. A sheet is drawn over the page the drawing draws it over
//  (`SheetStage`): those drawings are v1's, and show v1's develop page under
//  the sheet.
//
//  The sheet's ids (B1–B7, P1–P6) are the library's in the flow map, so the
//  pages keep lane C here:
//
//      C1 Film · C2 Frame · C3 Print · C4 Effects · C5 Scene (pro-control)
//      -pro: under pro-control · -slide, -upright, -placement: the drawn states
//
//  **After the drawn thirteen come the states the design does not draw**
//  (``): every tab with its panel folded, the Latitude card folded,
//  both; pro's other tools; Frame with a film edge on. They are held against
//  nothing and exist to be looked at — a fold is where two parts of this page
//  could meet (`DevelopLayout`, and `tools/develop_selftest.swift`).
//
//  **And black and white** (`-bw`, 2026-10-09), none of it drawn: Print on a
//  silver print, where the enlarger's two filters are the paper's grade; the
//  paper that waits under a film of the other kind; the four films on Film,
//  with their mark and without; Grain's Sub-layers standing down. The demo
//  frame's picture is the colour one the drawings have: these pages are held
//  for their panels, and what a black-and-white develop looks like is the
//  engine's to show (`tools/develop_check.sh`).

import SwiftUI

enum DarkroomSnapshots {
    @MainActor static var pages: [SnapshotPage] {
        drawn + folded + undrawn + blackAndWhite + sheets
    }

    // MARK: the drawn thirteen

    @MainActor private static var drawn: [SnapshotPage] {
        [
            SnapshotPage("C1", "Develop · Film") { model in
                developing(model)
            },
            SnapshotPage("C2", "Develop · Frame") { model in
                DevelopPane(frameID: frameID(model), opening: .tab(.frame))
            },
            SnapshotPage("C3", "Develop · Print") { model in
                DevelopPane(frameID: frameID(model), opening: .tab(.print, status: status("Printing" + Fmt.dot + "Yellow +0.10", 0.7)))
            },
            SnapshotPage("C4", "Develop · Effects") { model in
                let id = edited(model) { $0.params.effects.grain = 1.4; $0.params.sceneLatitude.highlightPullBack = 1.5 }
                return DevelopPane(frameID: id, opening: .tab(.effects, status: status("Developing" + Fmt.dot + "Grain 1.40×", 0.35)))
            },
            SnapshotPage("C4-placement", "Develop · Scene Placement") { model in
                DevelopPane(frameID: placed(model),
                              opening: DevelopOpening(tab: .effects, placementOpen: true,
                                                      status: status("Developing" + Fmt.dot + "Highlight placement 1.50", 0.3)))
            },
            SnapshotPage("C3-slide", "Develop · Print, a slide") { model in
                DevelopPane(frameID: slide(model), opening: .tab(.print))
            },
            SnapshotPage("C1-upright", "Develop · Film, upright") { model in
                DevelopPane(frameID: upright(model), opening: .tab(.film))
            },
            SnapshotPage("C1-pro", "Develop · Film, pro") { model in
                DevelopPane(frameID: pro(model), opening: .tab(.film))
            },
            SnapshotPage("C3-pro", "Develop · Print, pro · Brightness") { model in
                let id = edited(pro(model), model) { $0.params.printBrightnessStops = 0.3 }
                return DevelopPane(frameID: id, opening: DevelopOpening(tab: .print, enlargerTool: .brightness,
                                                                          status: status("Printing" + Fmt.dot + "Brightness +0.3", 0.5)))
            },
            SnapshotPage("C5", "Develop · Scene") { model in
                let id = edited(pro(model), model) { e in
                    e.decode.whiteBalance = .custom; e.decode.temperature = 5200; e.decode.tint = 4
                }
                return DevelopPane(frameID: id, opening: .tab(.scene, status: status("Developing" + Fmt.dot + "Temperature 5200 K", 0.4)))
            },
            SnapshotPage("C4-pro-grain", "Develop · Effects, pro · Grain") { model in
                DevelopPane(frameID: pro(model), opening: DevelopOpening(tab: .effects, effectsPage: .grain))
            },
            SnapshotPage("C4-pro-halation", "Develop · Effects, pro · Halation") { model in
                let id = edited(pro(model), model) { $0.params.effects.halation = 1.3 }
                return DevelopPane(frameID: id, opening: DevelopOpening(tab: .effects, effectsPage: .halation,
                                                                          status: status("Developing" + Fmt.dot + "Halation 1.30×", 0.6)))
            },
            SnapshotPage("C4-pro-placement", "Develop · Effects, pro · Placement") { model in
                _ = pro(model)
                return DevelopPane(frameID: placed(model),
                                     opening: DevelopOpening(tab: .effects, effectsPage: .placement,
                                                             status: status("Developing" + Fmt.dot + "Highlight placement 1.50", 0.3)))
            },
        ]
    }

    // MARK: folded — not drawn

    /// Every tab with its panel folded away, with the Latitude card folded to
    /// its head, and with both: the page as a finger leaves it, where the
    /// drawings show it only open.
    @MainActor private static var folded: [SnapshotPage] {
        var out: [SnapshotPage] = []
        for (suffix, panel, card) in [("panel-folded", true, false), ("card-folded", false, true), ("folded", true, true)] {
            for tab in DevelopTab.allCases {
                let stem: String = switch tab {
                case .film: "C1"
                case .frame: "C2"
                case .print: "C3"
                case .effects: "C4"
                case .scene: "C5"
                }
                out.append(SnapshotPage("\(stem)-\(suffix)", "Develop · \(tab.title), \(suffix)") { model in
                    let id = tab == .scene ? pro(model) : frameID(model)
                    return DevelopPane(frameID: id, opening: DevelopOpening(tab: tab, panelFolded: panel, latitudeFolded: card))
                })
            }
        }
        // The two the page has had since v1: the split, and the picture zoomed.
        out.append(SnapshotPage("C1-compare", "Develop · Compare") { model in
            DevelopPane(frameID: withOriginal(model), opening: DevelopOpening(tab: .film, compare: true))
        })
        out.append(SnapshotPage("C1-zoomed", "Develop · zoomed") { model in
            DevelopPane(frameID: frameID(model), opening: DevelopOpening(tab: .film, zoom: 2))
        })
        // Scene Placement's own page with the panel folded and brought back is
        // still that page; and pro-control's row of five chips, folded.
        out.append(SnapshotPage("C4-placement-card-folded", "Develop · Scene Placement, card folded") { model in
            DevelopPane(frameID: placed(model), opening: DevelopOpening(tab: .effects, placementOpen: true, latitudeFolded: true))
        })
        out.append(SnapshotPage("C4-pro-folded", "Develop · Effects, pro, folded") { model in
            DevelopPane(frameID: pro(model), opening: DevelopOpening(tab: .effects, effectsPage: .couplers, panelFolded: true,
                                                                       latitudeFolded: true))
        })
        return out
    }

    // MARK: pro's other tools, and Frame in its film — not drawn

    @MainActor private static var undrawn: [SnapshotPage] {
        [
            SnapshotPage("C3-pro-colour", "Develop · Print, pro · Colour") { model in
                DevelopPane(frameID: pro(model), opening: DevelopOpening(tab: .print, enlargerTool: .colour))
            },
            SnapshotPage("C3-pro-preflash", "Develop · Print, pro · Pre-flash") { model in
                let id = edited(pro(model), model) { $0.params.preflashExposure = 0.01 }
                return DevelopPane(frameID: id, opening: DevelopOpening(tab: .print, enlargerTool: .preflash))
            },
            SnapshotPage("C4-pro-glare", "Develop · Effects, pro · Glare") { model in
                DevelopPane(frameID: pro(model), opening: DevelopOpening(tab: .effects, effectsPage: .glare))
            },
            SnapshotPage("C4-pro-couplers", "Develop · Effects, pro · Couplers") { model in
                DevelopPane(frameID: pro(model), opening: DevelopOpening(tab: .effects, effectsPage: .couplers))
            },
            SnapshotPage("C5-lens", "Develop · Scene · Lens") { model in
                DevelopPane(frameID: pro(model), opening: DevelopOpening(tab: .scene, sceneTool: .lens))
            },
            // A slide under Effects: the paper's veil has no paper.
            SnapshotPage("C4-slide", "Develop · Effects, a slide") { model in
                DevelopPane(frameID: slide(model), opening: .tab(.effects))
            },
        ]
    }

    // MARK: black and white — not drawn

    static let triEx = "kodak_tri_x_400"

    @MainActor private static var blackAndWhite: [SnapshotPage] {
        [
            // A silver print: the ninth paper chosen and in view, the eight
            // colour papers waiting, the two rulers named for the grade.
            SnapshotPage("C3-bw", "Develop · Print, a silver print") { model in
                let id = edited(silver(model), model) { $0.params.yFilterShift = 0.1; $0.params.mFilterShift = 0.05 }
                return DevelopPane(frameID: id, opening: .tab(.print))
            },
            SnapshotPage("C3-bw-pro", "Develop · Print, a silver print, pro") { model in
                model.settings.proControl = true
                let id = edited(silver(model), model) { $0.params.yFilterShift = 0.1; $0.params.mFilterShift = 0.05 }
                return DevelopPane(frameID: id, opening: DevelopOpening(tab: .print, enlargerTool: .colour))
            },
            // The same row as it opens, on its first four: colour papers, waiting.
            SnapshotPage("C3-bw-waits", "Develop · Print, a silver print, the colour papers") { model in
                DevelopPane(frameID: silver(model),
                              opening: DevelopOpening(tab: .print, cardsOpenOn: StockCatalog.shared.papers.first?.id))
            },
            // A colour frame, its papers moved along to the last: the silver paper waits, that card alone.
            SnapshotPage("C3-silver-waits", "Develop · Print, the silver paper waiting") { model in
                let papers = StockCatalog.shared.papers
                return DevelopPane(frameID: frameID(model),
                                     opening: DevelopOpening(tab: .print, cardsOpenOn: papers.dropLast(3).last?.id))
            },
            // Film, moved along to the four.
            SnapshotPage("C1-bw", "Develop · Film, the black-and-white films") { model in
                DevelopPane(frameID: frameID(model), opening: DevelopOpening(tab: .film, cardsOpenOn: triEx))
            },
            // The row as it opens on a frame whose film is past the fourth card: the chosen one in view.
            SnapshotPage("C1-bw-opens", "Develop · Film, opened on a black-and-white frame") { model in
                DevelopPane(frameID: silver(model), opening: .tab(.film))
            },
            // Its grain is one layer whatever the frame says: Sub-layers stands down.
            SnapshotPage("C4-bw-pro-grain", "Develop · Effects, pro · Grain, a black-and-white film") { model in
                model.settings.proControl = true
                return DevelopPane(frameID: silver(model), opening: DevelopOpening(tab: .effects, effectsPage: .grain))
            },
            SnapshotPage("C4-bw", "Develop · Effects, a black-and-white film") { model in
                DevelopPane(frameID: silver(model), opening: .tab(.effects))
            },
        ]
    }

    /// The drawings' frame on Tri-Ex 400, loaded as a film card loads it: on
    /// its silver paper.
    @MainActor static func silver(_ model: AppServices) -> LibraryFrame.ID {
        edited(model) { $0.params.load(film: triEx) }
    }

    // MARK: the sheets, and Crop

    @MainActor private static var sheets: [SnapshotPage] {
        [
            SnapshotPage("C7", "Copy Settings") { model in
                let id = placed(model)
                SheetStage(top: SheetRoute.copySettings(id).top) {
                    developing(model)
                } sheet: {
                    CopySettingsDialog(frameID: id)
                }
            },
            SnapshotPage("D1", "Crop") { model in
                CropScreen(frameID: frameID(model), snapshotGeometry: drawnCrop)
            },
        ]
    }

    /// `crop_page`'s crop: 4:5 at the frame's full height, its centre at 0.58
    /// of the width — 3,200 × 4,000 of the 6,000 × 4,000 original.
    static let drawnCrop: Geometry = {
        var g = Geometry()
        let w = 3200.0 / 6000.0
        g.crop = CropRect(x: 0.58 - w / 2, y: 0, width: w, height: 1)
        g.aspect = .r4x5
        g.intendedSize = CGSize(width: w, height: 1)
        return g
    }()

    /// The drawings' frame: the demo library's selected one, on the paper the
    /// v2 drawings print it on — Porta Enduro, Porta 400's own.
    @MainActor static func frameID(_ model: AppServices) -> LibraryFrame.ID {
        let id = model.library.selectedID ?? model.library.frames.first?.id ?? UUID()
        model.library.update(id) { $0.edit.params.printStock = "kodak_portra_endura" }
        return id
    }

    /// The drawings' frame with something a drawing adds to it.
    @MainActor static func edited(_ model: AppServices, _ change: (inout FrameEdit) -> Void) -> LibraryFrame.ID {
        edited(frameID(model), model, change)
    }

    @MainActor static func edited(_ id: LibraryFrame.ID, _ model: AppServices, _ change: (inout FrameEdit) -> Void) -> LibraryFrame.ID {
        model.library.update(id) { change(&$0.edit) }
        return id
    }

    /// The drawings' frame, with the page under pro-control.
    @MainActor static func pro(_ model: AppServices) -> LibraryFrame.ID {
        model.settings.proControl = true
        return frameID(model)
    }

    /// The one demo frame whose undeveloped original is in the repository
    /// (the street, `design/src/scene_raw_srgb.jpg`): what Compare can show.
    @MainActor static func withOriginal(_ model: AppServices) -> LibraryFrame.ID {
        model.library.frames.first { $0.originalPicture != nil }?.id ?? frameID(model)
    }

    /// The street frame, upright, on the drawings' pair and at the drawings'
    /// Film Exp. +0.3 (B7).
    @MainActor static func upright(_ model: AppServices) -> LibraryFrame.ID {
        let id = model.library.frames.first { $0.picture == .sample("street.jpg") }?.id ?? frameID(model)
        model.library.update(id) { f in
            f.edit.params.printStock = "kodak_portra_endura"
            f.edit.params.load(film: "kodak_portra_400")
            f.edit.params.exposureCompensationEV = 0.3
            f.develop = .developed
        }
        return id
    }

    /// The drawings' frame on a slide film (B6): loaded as a film card loads
    /// it, so it is scanned and the paper it had waits.
    @MainActor static func slide(_ model: AppServices) -> LibraryFrame.ID {
        edited(model) { $0.params.load(film: "kodak_ektachrome_100") }
    }

    /// The frame with the drawings' Highlight 1.50, which Copy Settings also lists.
    @MainActor static func placed(_ model: AppServices) -> LibraryFrame.ID {
        edited(model) { $0.params.sceneLatitude.highlightPullBack = 1.5 }
    }

    /// B1: the Film tab, Film Exp. +0.3 developing, 58 % in. Every sheet in
    /// lane C and E is drawn over it.
    @MainActor static func developing(_ model: AppServices) -> DevelopPane {
        DevelopPane(frameID: frameID(model), opening: .tab(.film, status: status("Developing" + Fmt.dot + "Film Exp. +0.3", 0.58)))
    }

    static func status(_ text: String, _ progress: Double) -> DevelopStatus {
        DevelopStatus(text: text, busy: true, progress: progress)
    }
}
