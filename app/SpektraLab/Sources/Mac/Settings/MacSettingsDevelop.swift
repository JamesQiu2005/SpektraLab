//  MacSettingsDevelop.swift — Settings › Develop on the Mac: what new frames start with.
//
//  - **New frames**: the film and the paper a new frame develops with, or *Last used* — the window's
//    `StockPairPicker` as two pop-up buttons. The pair is always one a frame could have (`StockPair`): a
//    film chosen over a paper that cannot print it brings its own, a paper of the other kind is refused.
//    A slide's papers wait.
//  - **Develop**: the preview copy's long edge, *Crop re-maps the frame* (v1.3.3's, restored 2026-10-26: Mac only, the
//    window's Settings drawing has no row for it and keeps the default, off), *Enable HDR by Default*
//    (2026-11-06: Mac only, shown while a screen of this Mac shows HDR, `HDRDisplays`), and *Finish in the background*
//    while `FeatureFlags.backgroundFinish` says it is built (it is not: the row is the window's, kept and hidden).
//  - **Lens Profiles** (2.4.0): the lens database 编辑 › 镜头's 镜头校正 reads (`LensLibrary`) — how many lenses it holds
//    from Adobe's install and added by hand; Adobe's profiles found on this Mac and *Install to SpektraLab* (progress,
//    Cancel; the window is never blocked; it ends with what was installed and skipped); *Add .lcp…*; *Remove* for each.
//    Every write forgets the kept resolutions and resolves the open photograph again (`AppServices.lensDatabaseChanged`).
//    It replaces 2.3's *Lens Correction* checkbox, which is each frame's own since 2.4.0.
//  - **Film edge**: the body every new film edge is shot through (`AppSettings.bodySeed`, RFC-032 §26.1),
//    and *Another*. A film edge drawn in the film-edge flow takes this body
//    (`FilmEdgeJourney.written`), so it is a setting here.

import SwiftUI

struct MacSettingsDevelop: View {
    @Environment(AppServices.self) private var model
    @Environment(AppSettings.self) private var settings
    /// Whether a screen of this Mac shows HDR: the Enable HDR row's gate (D5).
    private var hdr: HDRDisplays { .shared }

    /// *Last used*, or a film's id.
    private static let lastUsed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
            newFrames
            develop
            lensProfiles
            filmEdge
        }
        .onAppear { LensLibrary.shared.warm() }
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
                                      + "Full size is made when you zoom in past it, and when you export. Applies to frames that arrive from now on. "
                                      + "Larger sizes take more memory and disk: 3,840 px holds 2.25 times the pixels of 2,560 px, and about 0.6 GB more memory while a picture develops.")) {
                MacSettingsPopUp(label: L("Preview size"), options: Self.previewEdges.map { ($0, Fmt.thousands($0) + " px") },
                                 selection: Binding(get: { settings.previewLongEdge }, set: { settings.previewLongEdge = $0 }),
                                 other: Fmt.thousands(settings.previewLongEdge) + " px")
            }
            .macSettingsItem("Develop", "Preview size")
            // v1.3.3's Settings › Film effects › *Crop re-maps the frame*, restored (2026-10-26): what a
            // crop means for the film's physical scale (`FrameEdit.wireFilmFormatMM`). Off by default.
            MacSettingsRow(label: L("Crop re-maps the frame"),
                           caption: L("Whether a crop changes the physical scale of grain and halation. Off — the default, and the physically true answer — a crop shows less of the same negative, so when it fills the picture its grain is enlarged with it. On, the cropped rectangle is the frame: the Film Format describes the crop, so however tight the crop, it has the grain and halation of a whole frame of that size. It applies as you crop, and switching it develops the open picture again. The film's size tops out at 300 mm, which a crop to about an eighth of a 135 frame's long edge reaches. Not under a film edge, where the crop places the picture in the gate."),
                           last: !FeatureFlags.backgroundFinish && !hdr.showsHDR) {
                MacSettingsCheckbox(label: L("Crop re-maps the frame"), on: Binding(get: { settings.cropRemapsFrame },
                                                                                   set: { settings.cropRemapsFrame = $0; model.cropRemapsFrameChanged() }))
            }
            .macSettingsItem("Crop re-maps the frame")
            // Settings › *Enable HDR by Default* (D5, 2026-11-06): Mac only, shown while a
            // screen of this Mac shows HDR (`HDRDisplays`), as every HDR control is. What frames that never chose follow.
            if hdr.showsHDR {
                MacSettingsRow(label: L("Enable HDR by Default"),
                               caption: L("Pictures whose own Enable HDR was never set follow this, and switching Enable HDR on a picture sets it too, so they show what you chose last. On an HDR screen their highlights go past white, as the film held them."),
                               last: !FeatureFlags.backgroundFinish) {
                    MacSettingsCheckbox(label: L("Enable HDR by Default"), on: Binding(get: { settings.hdrByDefault },
                                                                                      set: { settings.hdrByDefault = $0 }))
                }
                .macSettingsItem("Enable HDR by Default")
            }
            if FeatureFlags.backgroundFinish {
                MacSettingsRow(label: L("Finish in the background"), last: true) {
                    MacSettingsCheckbox(label: L("Finish in the background"), on: Binding(get: { settings.finishInBackground },
                                                                                         set: { settings.finishInBackground = $0 }))
                }
                .macSettingsItem("Finish in the background")
            }
        }
    }

    /// The window's six (`SettingsScreen`'s *Preview size*), the device policy's (`DevicePolicy.previewEdges`).
    static var previewEdges: [Int] { DevicePolicy.previewEdges }

    // MARK: lens profiles

    @State private var removing: LensDatabase.Source?

    private var lenses: LensLibrary { .shared }

    private var lensProfiles: some View {
        MacSettingsGroup(title: L("Lens Profiles"),
                         footer: L("SpektraLab ships no lens profiles. These are the profiles Adobe's software installed on this Mac, "
                                   + "read into SpektraLab's own library when you choose. A RAW photograph's Lens Correction, under Edit › Lens, "
                                   + "uses them where macOS and the file have no profile of its lens.")) {
            MacSettingsRow(label: L("Installed from Adobe"), detail: lensCount(.adobeInstalled)) {
                Button(L("Remove")) { removing = .adobeInstalled }
                    .buttonStyle(MacSettingsButtonStyle(kind: .destructive))
                    .disabled(lenses.lenses(of: .adobeInstalled) == 0 || lenses.isInstalling)
                    .accessibilityLabel(L("Remove the lenses installed from Adobe"))
            }
            .macSettingsItem("Lens Profiles", "Installed from Adobe", "Remove")
            MacSettingsRow(label: L("Added by hand"), detail: lensCount(.user)) {
                HStack(spacing: MacMetric.pt(8)) {
                    Button(L("Add .lcp…")) {
                        Task { @MainActor in
                            guard let file = await MacOpenPanel.chooseLensProfile() else { return }
                            await lenses.add(file: file)
                        }
                    }
                    .buttonStyle(MacSettingsButtonStyle())
                    .disabled(lenses.isInstalling || lenses.database == nil)
                    Button(L("Remove")) { removing = .user }
                        .buttonStyle(MacSettingsButtonStyle(kind: .destructive))
                        .disabled(lenses.lenses(of: .user) == 0 || lenses.isInstalling)
                        .accessibilityLabel(L("Remove the lenses added by hand"))
                }
            }
            .macSettingsItem("Added by hand", "Add .lcp…")
            adobeRow
        }
        .confirmationDialog(removing == .user ? L("Remove the lenses added by hand?") : L("Remove the lenses installed from Adobe?"),
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(L("Remove"), role: .destructive) {
                guard let source = removing else { return }
                Task { @MainActor in await lenses.remove(source) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("A photograph corrected with one of them is no longer corrected until its lens is added again."))
        }
    }

    /// "1,234 lenses", or what is happening to them.
    private func lensCount(_ source: LensDatabase.Source) -> String {
        guard lenses.read else { return L("Reading the lens library") }
        let n = lenses.lenses(of: source)
        return n == 1 ? L("1 lens") : L("\(Fmt.thousands(n)) lenses")
    }

    /// Adobe's profiles on this Mac, and Install to SpektraLab with its progress and its outcome.
    private var adobeRow: some View {
        let found = lenses.adobeFiles ?? 0
        let label = lenses.adobeFiles == nil ? L("Looking for Adobe's lens profiles on this Mac")
            : found == 0 ? L("No Adobe lens profiles were found on this Mac")
            : L("Found \(Fmt.thousands(found)) Adobe lens profiles on this Mac")
        return MacSettingsRow(label: label, caption: adobeCaption, last: true) {
            if lenses.isInstalling {
                Button(L("Cancel")) { lenses.cancelInstall() }
                    .buttonStyle(MacSettingsButtonStyle())
                    .accessibilityLabel(L("Cancel the install"))
            } else {
                Button(L("Install to SpektraLab")) { lenses.install() }
                    .buttonStyle(MacSettingsButtonStyle(kind: .primary))
                    .disabled(found == 0 || lenses.database == nil)
            }
        }
        .macSettingsItem("Found %@ Adobe lens profiles on this Mac", "Install to SpektraLab")
    }

    /// Under the Adobe row: the install's progress, or what the last write did, or where Adobe keeps them.
    private var adobeCaption: String? {
        if let p = lenses.progress {
            return p.total == 0 ? L("Starting the install")
                : L("Installing: \(Fmt.thousands(p.done)) of \(Fmt.thousands(p.total)) files read, \(Fmt.thousands(p.skipped)) skipped. You can keep working.")
        }
        switch lenses.lastResult {
        case .installed(let added, let replaced, let unchanged, let skipped, let cancelled)?:
            let done = L("Installed \(Fmt.thousands(added + replaced)) files, \(Fmt.thousands(unchanged)) already in the library, \(Fmt.thousands(skipped)) skipped.")
            let why = lenses.lastSkipped.prefix(3).map { $0.name }.joined(separator: ", ")
            return (cancelled ? L("Cancelled.") + " " : "") + done + (why.isEmpty ? "" : " " + L("Skipped: \(why).") )
        case .added(let name)?:
            return name.map { L("Added \($0).") } ?? L("Added.")
        case .addFailed(let reason)?:
            return L("Could not add the file: \(reason)")
        case .removed(let source)?:
            return source == .user ? L("The lenses added by hand were removed.") : L("The lenses installed from Adobe were removed.")
        case .failed(let reason)?:
            return L("The lens library could not be written: \(reason)")
        case nil:
            guard let found = lenses.adobeFiles, found > 0 else {
                return lenses.adobeFiles == nil ? nil
                    : L("Adobe's Camera Raw, Lightroom and Photoshop install them in /Library/Application Support/Adobe/CameraRaw/LensProfiles.")
            }
            return lenses.lenses(of: .adobeInstalled) == 0 ? L("Reading them takes a few seconds and about 75 MB of space.") : nil
        }
    }

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
