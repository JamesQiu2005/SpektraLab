//  MacSettingsDevelop.swift — Settings › Develop on the Mac: what new frames start with.
//
//  - **New frames**: the film and the paper a new frame develops with, or *Last used* — the window's
//    `StockPairPicker` as two pop-up buttons. The pair is always one a frame could have (`StockPair`): a
//    film chosen over a paper that cannot print it brings its own, a paper of the other kind is refused.
//    A slide's papers wait.
//  - **Develop**: the preview copy's long edge, Lens Correction (`AppServices.holdLensCorrection` holds every
//    RAW frame's decode to it), *Crop re-maps the frame* (v1.3.3's, restored 2026-10-26: Mac only, the
//    window's Settings drawing has no row for it and keeps the default, off), and *Finish in the background* while `FeatureFlags.backgroundFinish` says
//    it is built (it is not: the row is the window's, kept and hidden).
//  - **Film edge**: the body every new film edge is shot through (`AppSettings.bodySeed`, RFC-032 §26.1),
//    and *Another*. A film edge drawn in the film-edge flow takes this body
//    (`FilmEdgeJourney.written`), so it is a setting here.

import SwiftUI

struct MacSettingsDevelop: View {
    @Environment(AppServices.self) private var model
    @Environment(AppSettings.self) private var settings

    /// *Last used*, or a film's id.
    private static let lastUsed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
            newFrames
            develop
            filmEdge
        }
    }

    // MARK: new frames

    private var chosenFilm: String { settings.newFrameStocks.film }
    private var chosenPaper: String { settings.newFrameStocks.paper }

    private var newFrames: some View {
        let catalog = StockCatalog.shared
        let slide = catalog.isSlide(chosenFilm)
        let films: [(String, String)] = [(Self.lastUsed, L("Last used") + " · " + catalog.pairText(film: settings.lastFilm, paper: settings.lastPaper))]
            + catalog.films.map { ($0.id, $0.shortName + " · " + detail($0)) }
        let papers: [(String, String)] = catalog.papers.map { ($0.id, $0.shortName + " · " + L(shown: $0.kind)) }
        var note = L("A frame keeps the pair it arrived with; change it on the develop page.")
        if slide {
            note = L("\(catalog.stock(chosenFilm)?.shortName ?? L("This film")) is a slide: it is scanned, not printed. "
                     + "The paper waits for a negative.") + " " + note
        } else if let why = StockPairPicker.papersNote(film: chosenFilm) {
            note = why + " " + note
        }
        return MacSettingsGroup(title: L("New frames"), footer: note) {
            MacSettingsRow(label: L("Film")) {
                MacSettingsPopUp(label: L("Film"), options: films,
                                 selection: Binding(get: { settings.newFrameFilm == nil ? Self.lastUsed : chosenFilm },
                                                    set: { chooseFilm($0) }))
            }
            .macSettingsItem("New frames", "Last used", "Film")
            MacSettingsRow(label: L("Paper"), last: true) {
                MacSettingsPopUp(label: L("Paper"), options: papers,
                                 selection: Binding(get: { chosenPaper }, set: { choosePaper($0) }),
                                 allowed: { id in slide || catalog.whyNotPrinted(film: chosenFilm, on: id) == nil })
                    .disabled(slide)
            }
            .macSettingsItem("Paper")
        }
    }

    /// "colour negative · ISO 400".
    private func detail(_ stock: Stock) -> String {
        [L(shown: stock.kind), stock.isoText].compactMap { $0 }.joined(separator: " · ")
    }

    /// The window picker's choices (`StockPairPicker.chooseFilm`, `choosePaper`, `take`): *Last used* clears
    /// both; a film or a paper fixes the pair through `StockPair`, which refuses what a frame cannot have.
    private func chooseFilm(_ id: String) {
        guard id != Self.lastUsed else {
            settings.newFrameFilm = nil
            settings.newFramePaper = nil
            return
        }
        var pair = StockPair(film: chosenFilm, paper: chosenPaper)
        pair.load(film: id)
        settings.newFramePaper = pair.paper
        settings.newFrameFilm = pair.film
    }

    private func choosePaper(_ id: String) {
        var pair = StockPair(film: chosenFilm, paper: chosenPaper)
        guard pair.print(on: id) else { return }
        settings.newFramePaper = pair.paper
        settings.newFrameFilm = pair.film
    }

    // MARK: develop

    private var develop: some View {
        MacSettingsGroup(title: L("Develop")) {
            MacSettingsRow(label: L("Preview size"),
                           caption: L("The size every frame is developed at for the library and the develop page. "
                                      + "Full size is made when you zoom in past it, and when you export. Applies to frames that arrive from now on.")) {
                MacSettingsPopUp(label: L("Preview size"), options: Self.previewEdges.map { ($0, Fmt.thousands($0) + " px") },
                                 selection: Binding(get: { settings.previewLongEdge }, set: { settings.previewLongEdge = $0 }),
                                 other: Fmt.thousands(settings.previewLongEdge) + " px")
            }
            .macSettingsItem("Develop", "Preview size")
            MacSettingsRow(label: L("Lens Correction"),
                           caption: L("Lens Correction is for RAW: the lens's own distortion and vignetting profile, where macOS has one. Sony RAW and Apple ProRAW files are not changed by it."),
                           last: false) {
                MacSettingsCheckbox(label: L("Lens Correction"), on: Binding(get: { settings.lensCorrection },
                                                                            set: { settings.lensCorrection = $0; model.holdLensCorrection() }))
            }
            .macSettingsItem("Lens Correction")
            // v1.3.3's Settings › Film effects › *Crop re-maps the frame*, restored (2026-10-26): what a
            // crop means for the film's physical scale (`FrameEdit.wireFilmFormatMM`). Off by default.
            MacSettingsRow(label: L("Crop re-maps the frame"),
                           caption: L("Whether a crop changes the physical scale of grain and halation. Off — the default, and the physically true answer — a crop shows less of the same negative, so when it fills the picture its grain is enlarged with it. On, the cropped rectangle is the frame: the Film Format describes the crop, so however tight the crop, it has the grain and halation of a whole frame of that size. It applies as you crop, and switching it develops the open picture again. The film's size tops out at 200 mm, which a crop to about a fifth of a 135 frame's long edge reaches. Not under a film edge, where the crop places the picture in the gate."),
                           last: !FeatureFlags.backgroundFinish) {
                MacSettingsCheckbox(label: L("Crop re-maps the frame"), on: Binding(get: { settings.cropRemapsFrame },
                                                                                   set: { settings.cropRemapsFrame = $0; model.cropRemapsFrameChanged() }))
            }
            .macSettingsItem("Crop re-maps the frame")
            if FeatureFlags.backgroundFinish {
                MacSettingsRow(label: L("Finish in the background"), last: true) {
                    MacSettingsCheckbox(label: L("Finish in the background"), on: Binding(get: { settings.finishInBackground },
                                                                                         set: { settings.finishInBackground = $0 }))
                }
                .macSettingsItem("Finish in the background")
            }
        }
    }

    /// The window's four (`SettingsScreen`'s *Preview size*).
    static let previewEdges = [1600, 1920, 2400, 2560]

    // MARK: film edge

    private var filmEdge: some View {
        MacSettingsGroup(title: L("Film Edge")) {
            MacSettingsRow(label: L("Body"),
                           caption: L("The camera every new film edge is shot through: its gate, its fog, its leaks. A frame keeps the body it was given."),
                           last: true) {
                HStack(spacing: MacMetric.pt(8)) {
                    Text(L("No. \(settings.bodySeed)")).font(MacMetric.font(12, .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                        .fixedSize()
                    Button(L("Another")) { settings.anotherBody() }
                        .buttonStyle(MacSettingsButtonStyle())
                        .accessibilityLabel(L("Another camera body"))
                }
            }
            .macSettingsItem("Body", "No. %@", "Another")
        }
    }
}
