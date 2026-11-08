//  AppSettings.swift — the app's own preferences (B6), kept in UserDefaults.
//
//  Preferences, not a frame's settings: nothing here changes a picture that
//  has been made. What new frames start with, how large the preview copy is,
//  the export recipe Develop's ↑ shares with.

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults?
    /// True while `init` reads what was kept. Every property below saves when
    /// it is set, and a save writes them all: without this, the first value
    /// read back would write the others' defaults over what was kept.
    @ObservationIgnored private var isLoading = true

    /// What a new frame develops with. Nil is *Last used*.
    var newFrameFilm: String? { didSet { save() } }
    var newFramePaper: String? { didSet { save() } }
    /// The last pair a frame was developed with: what *Last used* means.
    var lastFilm = "kodak_portra_400" { didSet { save() } }
    var lastPaper = "kodak_portra_endura" { didSet { save() } }
    /// The preview copy's long edge. A placeholder until it is measured.
    var previewLongEdge = DevicePolicy.current.previewLongEdge { didSet { save() } }
    /// Keep an export going when the app is left (the operating system 26's continued-processing
    /// task; whether it keeps the GPU on this host is unverified: RFC-036 §9.5).
    var finishInBackground = true { didSet { save() } }
    /// The recipe Export opens with, and Develop's ↑ shares with.
    var recipe = ExportRecipe() { didSet { save() } }
    /// **The body**: the camera a new film edge is shot through — its gate,
    /// its margins, where the frame sits on the perforations (RFC-032 §26.1:
    /// one host is one camera). Drawn once at random the first time the app
    /// runs and moved by Settings' *Another*; a frame keeps the body it was
    /// given. 19 where nothing is kept (the drawings' own body).
    var bodySeed = 19 { didSet { save() } }
    /// **Pro-control**: the develop page's second level (the owner,
    /// 2026-10-07: "the basic version would have roughly the same information
    /// density as the current version with pro-control exposing more"). The
    /// switch at the end of the page's tabs; kept, so the page opens as it
    /// was left. It changes which controls a page shows and no picture.
    var proControl = false { didSet { save() } }
    /// F5's limits for what the app keeps on the device, in bytes: the working
    /// copies of originals, and the preview copies. design/flow's
    /// placeholders until they are measured. (They lived only in the library's
    /// report until 2026-10-10, and were the placeholders again at every launch.)
    var workingCopiesLimit: Int64 = 5 << 30 { didSet { save() } }
    var previewCopiesLimit: Int64 = 10 << 30 { didSet { save() } }
    /// The full-size renders' own budget, in bytes (the owner, 2026-10-24: "a LRU should also be
    /// maintained that cache the full-size render on the recently viewed certain amount of image depends
    /// on the cache size set by user"): the `.spkfull` files of the pictures looked at most recently,
    /// counted by their size on disk (a 100 MP RAW's is ~1 GB, a 12 MP JPEG's ~120 MB), apart from the
    /// thumbnails and previews (`previewCopiesLimit`) and the working copies (`workingCopiesLimit`).
    var fullRenderCacheLimit: Int64 = 8 << 30 { didSet { save() } }
    /// **Lens Correction** (Settings › Develop): a RAW's decode applies its
    /// lens's distortion and vignetting profile where the operating system has one
    /// (`CIRAWFilter.isLensCorrectionEnabled`, on by Apple's own default for a
    /// RAW it can correct). A setting for the whole library, not an edit (the
    /// owner, 2026-10-21: "we put 'use lens correction' in settings, not
    /// edit"): each frame still records it in its edit's decode, which the
    /// app's model keeps equal to this (`AppServices.holdLensCorrection`).
    var lensCorrection = true { didSet { save() } }
    /// **Crop re-maps the frame** (Settings › Develop; v1.3.3's, restored 2026-10-26): whether
    /// Develop's crop changes the physical scale of grain, halation and the coupler diffusion. Off --
    /// the default, as in v1.3.3, and the physically true answer -- a crop shows less of the same
    /// negative. On, the cropped rectangle *is* the frame the Film Format describes
    /// (`FrameEdit.wireFilmFormatMM`). A statement about what a crop means in this app, not an edit:
    /// it is read where the wire is made (`EngineRouter.cropIsFrame`, `ExportService.cropIsFrame`), so a
    /// develop's stamp and a kept full render follow it, and switching it re-develops the open page.
    var cropRemapsFrame = false { didSet { save() } }
    /// **Canvas Colour Space** (2.2.1, Develop's "···" menu): the space Develop's canvas shows its picture in
    /// (`CanvasGamut`); ProPhoto RGB, the picture as it is made, unless another was chosen.
    var canvasGamut = CanvasGamut.proPhoto { didSet { save() } }
    /// **Check for updates at launch** (Settings › General, 2.2.1): once, a few seconds after a plain launch
    /// (`UpdateCheck`). On unless turned off.
    var checksForUpdates = true { didSet { save() } }
    /// Which of the gallery's three views the Library shows (`GalleryView`): 全部 unless another was
    /// chosen (the owner, 2026-10-21: the reference device opens on 全部, the pill switches, and is remembered).
    var galleryView = GalleryView.all { didSet { save() } }
    /// **Allow agents to use SpektraLab** (Settings › General › Agents; ARCHITECTURE.md §7.16): whether a
    /// program on this Mac may call the app through its command line and MCP server (`AgentExecutor`).
    /// Off by default, and read at every call: it is the person's consent to another program changing
    /// their library, so turning it off refuses an agent's very next call.
    var agentAccess = false { didSet { save() } }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        defer { isLoading = false }
        guard let d = defaults else { return }
        newFrameFilm = d.string(forKey: "settings.newFrameFilm")
        newFramePaper = d.string(forKey: "settings.newFramePaper")
        lastFilm = d.string(forKey: "settings.lastFilm") ?? lastFilm
        lastPaper = d.string(forKey: "settings.lastPaper") ?? lastPaper
        if d.object(forKey: "settings.previewLongEdge") != nil { previewLongEdge = d.integer(forKey: "settings.previewLongEdge") }
        if d.object(forKey: "settings.finishInBackground") != nil { finishInBackground = d.bool(forKey: "settings.finishInBackground") }
        if let data = d.data(forKey: "settings.recipe"), let r = try? JSONDecoder().decode(ExportRecipe.self, from: data) {
            recipe = r
            // The 12 MP every recipe began at, once, to Full (`ExportRecipe.movedToFullKey`).
            if !d.bool(forKey: ExportRecipe.movedToFullKey + ".settings") {
                if recipe.size == ExportRecipe.formerDefaultSize {
                    recipe.size = .full
                    if let data = try? JSONEncoder().encode(recipe) { d.set(data, forKey: "settings.recipe") }
                }
                d.set(true, forKey: ExportRecipe.movedToFullKey + ".settings")
            }
        }
        let body = d.integer(forKey: "settings.bodySeed")
        bodySeed = FilmEdgeSettings.bodyRange.contains(body) ? body : Int.random(in: FilmEdgeSettings.bodyRange)
        if body != bodySeed { d.set(bodySeed, forKey: "settings.bodySeed") }
        proControl = d.bool(forKey: "settings.proControl")
        if let kept = d.object(forKey: "settings.workingCopiesLimit") as? NSNumber, kept.int64Value > 0 { workingCopiesLimit = kept.int64Value }
        if let kept = d.object(forKey: "settings.previewCopiesLimit") as? NSNumber, kept.int64Value > 0 { previewCopiesLimit = kept.int64Value }
        if let kept = d.object(forKey: "settings.fullRenderCacheLimit") as? NSNumber, kept.int64Value > 0 { fullRenderCacheLimit = kept.int64Value }
        if d.object(forKey: "settings.lensCorrection") != nil { lensCorrection = d.bool(forKey: "settings.lensCorrection") }
        cropRemapsFrame = d.bool(forKey: "settings.cropRemapsFrame")
        canvasGamut = d.string(forKey: "settings.canvasGamut").flatMap(CanvasGamut.init(rawValue:)) ?? canvasGamut
        if d.object(forKey: "settings.checksForUpdates") != nil { checksForUpdates = d.bool(forKey: "settings.checksForUpdates") }
        galleryView = d.string(forKey: "settings.galleryView").flatMap(GalleryView.init(rawValue:)) ?? galleryView
        agentAccess = d.bool(forKey: "agent.access")
    }

    /// Another camera body: a new gate, new margins, new holes.
    func anotherBody() {
        var next = bodySeed
        while next == bodySeed { next = Int.random(in: FilmEdgeSettings.bodyRange) }
        bodySeed = next
    }

    /// The pair a new frame develops with: the chosen default, or the last
    /// used — as a frame can have it (`StockCatalog.newFramePair`): on a paper
    /// that prints the film.
    var newFrameStocks: (film: String, paper: String) {
        StockCatalog.shared.newFramePair(film: newFrameFilm ?? lastFilm, paper: newFramePaper ?? lastPaper)
    }
    var newFramesText: String { newFrameFilm == nil ? L("Last used") : StockCatalog.shared.pairText(film: newFrameStocks.film, paper: newFrameStocks.paper) }

    private func save() {
        guard let d = defaults, !isLoading else { return }
        d.set(newFrameFilm, forKey: "settings.newFrameFilm")
        d.set(newFramePaper, forKey: "settings.newFramePaper")
        d.set(lastFilm, forKey: "settings.lastFilm")
        d.set(lastPaper, forKey: "settings.lastPaper")
        d.set(previewLongEdge, forKey: "settings.previewLongEdge")
        d.set(finishInBackground, forKey: "settings.finishInBackground")
        if let data = try? JSONEncoder().encode(recipe) { d.set(data, forKey: "settings.recipe") }
        d.set(bodySeed, forKey: "settings.bodySeed")
        d.set(proControl, forKey: "settings.proControl")
        d.set(NSNumber(value: workingCopiesLimit), forKey: "settings.workingCopiesLimit")
        d.set(NSNumber(value: previewCopiesLimit), forKey: "settings.previewCopiesLimit")
        d.set(NSNumber(value: fullRenderCacheLimit), forKey: "settings.fullRenderCacheLimit")
        d.set(lensCorrection, forKey: "settings.lensCorrection")
        d.set(cropRemapsFrame, forKey: "settings.cropRemapsFrame")
        d.set(canvasGamut.rawValue, forKey: "settings.canvasGamut")
        d.set(checksForUpdates, forKey: "settings.checksForUpdates")
        d.set(galleryView.rawValue, forKey: "settings.galleryView")
        d.set(agentAccess, forKey: "agent.access")
    }
}
