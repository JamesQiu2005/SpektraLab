//  MacDriver.swift — a debug build's way round the Mac app without a mouse.
//
//      SpektraLab --mac-drive [--capture-window <dir>]
//      notifyutil -p com.spektralab.mac.drive.develop     # the selected frame's Develop
//      notifyutil -p com.spektralab.mac.drive.develop.captureone   # Develop on a Capture One frame
//      notifyutil -p com.spektralab.mac.drive.library     # back to the Library
//      notifyutil -p com.spektralab.mac.drive.settings    # Settings
//      notifyutil -p com.spektralab.mac.drive.settings.general  # Settings on General (.settings.diagnostics;
//.settings.supporters: General › About › Supporters)
//      notifyutil -p com.spektralab.mac.drive.import      # the Import sheet
//      notifyutil -p com.spektralab.mac.drive.export      # Export, for the selected frame
//      notifyutil -p com.spektralab.mac.drive.export.strip  # the develop page's Export: the filmstrip's chosen frames
//      notifyutil -p com.spektralab.mac.drive.export.go   # the Export page's Export, into <home>/Exported
//      notifyutil -p com.spektralab.mac.drive.filmedge    # the selected frame: Film Edge and Date Back on
//      notifyutil -p com.spektralab.mac.drive.dateonly    # the selected frame: Date Back alone, no film edge
//      notifyutil -p com.spektralab.mac.drive.plain       # the selected frame: both off
//      notifyutil -p com.spektralab.mac.drive.di.on       # …the Digital Intermediate in the paper's place (.di.off)
//      notifyutil -p com.spektralab.mac.drive.film.gold200  # …its film: Gold 200 (.film.provia: Provia 100F,
//.film.cinestill / .film.vision500t: on 2383)
//      notifyutil -p com.spektralab.mac.drive.format.6x7  # …its film edge: 120 6x7
//      notifyutil -p com.spektralab.mac.drive.lighttable  # the Light Table
//      notifyutil -p com.spektralab.mac.drive.comp.1      # the selected frame's Film Exposure: +1 (.comp.0: 0)
//      notifyutil -p com.spektralab.mac.drive.pair.minilab # Portra 400 / Endura (.pair.optical: Portra / 2383)
//      notifyutil -p com.spektralab.mac.drive.grain.80    # grain amount 0.8 (.grain.120: 1.2)
//      notifyutil -p com.spektralab.mac.drive.select.next # the next frame of the library selected
//      notifyutil -p com.spektralab.mac.drive.keystone.12 # the selected frame's crop: Vertical +12° (.keystone.0: none)
//      notifyutil -p com.spektralab.mac.drive.straighten.5 # …and its straighten: +5° (.straighten.0: level)
//      notifyutil -p com.spektralab.mac.drive.crop        # the selected frame's crop page
//      notifyutil -p com.spektralab.mac.drive.printcrop   # …its crop of the finished picture (both in the page
//                                                         when Develop is open on it; .crop.done, .crop.cancel,
//.crop.rotate, .crop.flip; .crop.line.7, .-20, .80, .120:
//                                                         a ⌘-drag's line at that angle, levelled; .crop.place.1,
//.2, .0: under a film edge, the picture placed in the gate; .undo, .redo)
//      notifyutil -p com.spektralab.mac.drive.cropframe.on  # Settings' Crop re-maps the frame on (.cropframe.off;
//.settings.develop: Settings on its Develop section)
//      notifyutil -p com.spektralab.mac.drive.crop.quarter  # the selected frame's crop: the middle quarter of each
//                                                         side, the photo's own shape (.crop.whole: none)
//      notifyutil -p com.spektralab.mac.drive.zoom.100    # the develop page's picture at 100 %, as a double tap (.zoom.fit)
//      notifyutil -p com.spektralab.mac.drive.column.560  # the develop page's column as dragged (.column.393, .700;
//.strip.96, .160, .220: the filmstrip's height)
//      notifyutil -p com.spektralab.mac.drive.light       # Light Mode on (.dark: off, .system), as Settings › Appearance
//      notifyutil -p com.spektralab.mac.drive.settings.appearance  # Settings on Appearance (.appearance.picker: its
//                                                         Background picker; .bg.black, .bg.warm, .bg.red, .bg.paper,
//.bg.blue, .bg.default: a ground; .scale.80 … .150)
//      notifyutil -p com.spektralab.mac.drive.flow.film   # the film-edge flow at a step (.flow.frame, .flow.edge, .flow.date)
//      notifyutil -p com.spektralab.mac.drive.decode.curve  # Film & Paper's Decode on a part (.decode.exposure, .decode.wb)
//      notifyutil -p com.spektralab.mac.drive.scenecurve.s  # the selected frame's Decode curve: an S on RGB (.scenecurve.0: none)
//      notifyutil -p com.spektralab.mac.drive.surface.edit  # the open page on Edit (.surface.develop; .step.format, .step.film)
//      notifyutil -p com.spektralab.mac.drive.histogram.spektralab  # the histogram's style (.histogram.c1), .histogram.fold / .open
//      notifyutil -p com.spektralab.mac.drive.rows.film.fold  # the Film strip folded (.rows.paper.fold; .rows.open: both open)
//      notifyutil -p com.spektralab.mac.drive.fold.filmedge  # Format's 片边 folded (.fold.dateback, .fold.decode;
//.fold.open: all three open)
//      notifyutil -p com.spektralab.mac.drive.applyfilm.off   # the open page's Apply Film Emulation (.applyfilm.on)
//      notifyutil -p com.spektralab.mac.drive.curve       # the open page on Edit › Adjust › 曲线 (.curve.set: an S on
//                                                         RGB and a lift on red, .curve.0: none; on the curve in
//                                                         front, Edit's or Decode's: .curve.tab.<rgb|luma|red|green|
//                                                         blue>, .curve.select.<0|1>, .curve.hold.1 (a drag held:
//                                                         the crosshair), .curve.release, .curve.end.right;
//.curve.norows draws the plot as a reply without
//                                                         per-channel rows does, .curve.rows puts it back)
//      notifyutil -p com.spektralab.mac.drive.wheels      # the open page on Edit › Adjust › 色轮 (.wheels.shadows,
//.wheels.midtones, .wheels.highlights: the zone picked;
//.wheels.set: a hue, strength and luminance on each zone;
//.wheels.0: the colour balance back to rest)
//
//  With `--notify-tag <t>` every name above is `com.spektralab.mac.drive.<t>.<step>` (and the
//  capture `com.spektralab.mac.capture.<t>`): Darwin notifications reach every instance.
//
//  Drives the router, so an agent with neither Accessibility
//  nor Screen Recording can open the pages the Mac app has and capture them
//  (MacWindowCapture). Every step is printed. Not in a release build.

#if DEBUG
import UIKit
import notify

@MainActor
enum MacDriver {
    private static var tokens: [Int32] = []
    /// `crop.rotate`: the crop page in front turns its crop, as its Rotate does.
    static let cropRotate = Notification.Name("spk.drive.crop.rotate")
    /// `crop.flip`: …its Flip.
    static let cropFlip = Notification.Name("spk.drive.crop.flip")
    /// `crop.line.<deg>`: a ⌘-drag's line drawn at that angle on the screen, then levelled (its object the angle).
    static let cropLine = Notification.Name("spk.drive.crop.line")
    /// `crop.place.<n>`: under a film edge, the picture placed under the gate (its object [dx, dy, scale]).
    static let cropPlace = Notification.Name("spk.drive.crop.place")
    /// `wheels.<zone>`: the colour wheels' tool picks that zone (its object the zone's raw value).
    static let wheelZone = Notification.Name("spk.drive.wheels.zone")
    /// `curve.<step>`: the curve tool in front (CurvePanel.swift, RFC-035): `tab.<channel>`, `select.<n>`,
    /// `hold.<n>` (a drag held on point n, its crosshair drawn), `release`, `end.right` (its black point to x 0.2).
    static let curveStep = Notification.Name("spk.drive.curve")
    /// `zoom.100` / `zoom.fit`: the develop page's picture at 100 % about its middle, or fitted (its object
    /// true for 100 %).
    static let zoomHundred = Notification.Name("spk.drive.zoom")

    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--mac-drive"), tokens.isEmpty else { return }
        let steps: [(String, @MainActor (AppServices) -> Void)] = [
            ("develop", { m in
                if let w = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.keyWindow {
                    NSLog("drive scale: window %.0fx%.0f pt, displayScale %.2f, screen scale %.2f native %.2f, idiom %d",
                          w.bounds.width, w.bounds.height, w.traitCollection.displayScale, w.screen.scale, w.screen.nativeScale,
                          UIDevice.current.userInterfaceIdiom.rawValue)
                }
                guard let id = m.library.selected?.id else { print("drive develop: nothing selected"); return }
                m.router.open(.develop(id))
            }),
            // The first frame read from a Capture One catalog or session (CaptureOneSource).
            ("develop.captureone", { m in
                guard let f = m.library.frames.first(where: {
                    if case .linkedFolder(let disk, _) = $0.source { return disk == "Capture One" } else { return false }
                }) else { print("drive develop.captureone: no Capture One frame"); return }
                m.router.toLibrary()
                m.router.open(.develop(f.id))
            }),
            ("library", { m in m.router.dismissAllSheets(); m.router.dismissCover(); m.router.toLibrary() }),
            ("settings", { m in m.router.cover = .settings }),
            ("import", { m in m.router.present(.importSources) }),
            ("export", { m in
                guard let id = m.library.selected?.id else { print("drive export: nothing selected"); return }
                m.router.present(.export([id]))
            }),
            // The develop page's Export, as its picture bar's button sends it: the frames chosen in the
            // filmstrip as one batch, or the open frame (`DevelopController.exportIDs`).
            ("export.strip", { m in
                guard let pad = DevelopController.front, let id = pad.current else { print("drive export.strip: no develop page"); return }
                NSLog("drive export.strip: %d frames, %d chosen", pad.exportIDs(id).count, pad.chosen.count)
                m.router.present(.export(pad.exportIDs(id)))
            }),
            // The Export page in front's own Export, with the last recipe, into <home>/Exported.
            ("export.go", { m in if !MacExportCheck.pressFront(recipe: m.settings.recipe) { print("drive export.go: no export page") } }),
            // A film edge and a date put on the frame — through the page's
            // session when Develop is open on it, so the page develops it, else in the library.
            ("filmedge", { m in edit(m) { e, f in
                e.filmEdge.active = true
                if e.filmEdge.cameraSeed == 0 { e.filmEdge.cameraSeed = m.settings.bodySeed }
                e.filmEdge.turn = e.filmEdge.format.defaultTurn(pictureAspect: f.originalSize.aspect)
                e.dateBack.active = true
            } }),
            ("dateonly", { m in edit(m) { e, _ in e.filmEdge.active = false; e.dateBack.active = true } }),
            // The film on the frame (a negative: its paper stays), and the film edge's format.
            ("film.gold200", { m in edit(m) { e, _ in e.params.filmStock = "kodak_gold_200" } }),
            ("film.provia", { m in edit(m) { e, _ in e.params.filmStock = "fujifilm_provia_100f" } }),
            // The Digital Intermediate in the paper's place, as its card chooses it (.di.off: printed again).
            ("di.on", { m in edit(m) { e, _ in e.params.scanFilm = false; e.params.digitalIntermediate = true } }),
            ("di.off", { m in edit(m) { e, _ in e.params.digitalIntermediate = false } }),
            // The canvas's colour space (`CanvasGamut`), and the recipe Export opens with in sRGB or Display P3.
            ("gamut.srgb", { m in m.settings.canvasGamut = .sRGB }),
            ("gamut.adobe", { m in m.settings.canvasGamut = .adobeRGB }),
            ("gamut.prophoto", { m in m.settings.canvasGamut = .proPhoto }),
            ("recipe.srgb", { m in m.settings.recipe.colour = .sRGB }),
            ("recipe.p3", { m in m.settings.recipe.colour = .displayP3 }),
            // CineStill 800T and its emulsion, each on the paper the catalogue pairs it with (2383).
            ("film.cinestill", { m in edit(m) { e, _ in e.params.filmStock = "cinestill_800t"; e.params.printStock = "kodak_2383" } }),
            ("film.vision500t", { m in edit(m) { e, _ in e.params.filmStock = "kodak_vision3_500t"; e.params.printStock = "kodak_2383" } }),
            ("format.6x7", { m in edit(m) { e, f in
                e.filmEdge.format = .f6x7
                e.filmEdge.turn = e.filmEdge.format.defaultTurn(pictureAspect: f.originalSize.aspect)
            } }),
            // Film Exposure, as the slider sets it, and the next frame of the library selected.
            ("comp.0", { m in edit(m) { e, _ in e.params.exposureCompensationEV = 0 } }),
            ("comp.1", { m in edit(m) { e, _ in e.params.exposureCompensationEV = 1 } }),
            // v2 integration: exercise listed/unlisted pairs and grain-only checkpoint edits through
            // the real session, scheduler and canvas. These routes exist only in a Debug Mac build.
            ("pair.minilab", { m in edit(m) { e, _ in
                e.params.filmStock = "kodak_portra_400"; e.params.printStock = "kodak_portra_endura"
            } }),
            ("pair.optical", { m in edit(m) { e, _ in
                e.params.filmStock = "kodak_portra_400"; e.params.printStock = "kodak_2383"
            } }),
            ("grain.80", { m in edit(m) { e, _ in e.params.effects.grain = 0.8 } }),
            ("grain.120", { m in edit(m) { e, _ in e.params.effects.grain = 1.2 } }),
            ("select.next", { m in
                let ids = m.library.frames.map(\.id)
                guard !ids.isEmpty else { return }
                let at = m.library.selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
                m.library.selectedID = ids[(at + 1) % ids.count]
                NSLog("drive select: %@", m.library.selected?.fileName ?? "-")
            }),
            ("plain", { m in edit(m) { e, _ in e.filmEdge.active = false; e.dateBack.active = false } }),
            // Develop's crop: a keystone (Vertical +12°, the crop page's dial), or none, and the crop page.
            ("keystone.12", { m in edit(m) { e, _ in e.geometry = e.geometry.perspective(vertical: 12, horizontal: 0) } }),
            ("keystone.0", { m in edit(m) { e, _ in e.geometry = e.geometry.perspective(vertical: 0, horizontal: 0) } }),
            // …its straighten, as the crop page's dial sets it (.straighten.0: level).
            ("straighten.5", { m in edit(m) { e, f in e.geometry = e.geometry.straightened(to: 5, in: CGSize(width: f.originalSize.width, height: f.originalSize.height)) } }),
            ("straighten.0", { m in edit(m) { e, f in e.geometry = e.geometry.straightened(to: 0, in: CGSize(width: f.originalSize.width, height: f.originalSize.height)) } }),
            // The film-edge flow at a step (.flow.film … .flow.date), over the selected frame's Develop.
            ("flow.film", { m in flow(m, .film) }),
            ("flow.frame", { m in flow(m, .frame) }),
            ("flow.edge", { m in flow(m, .edge) }),
            ("flow.date", { m in flow(m, .date) }),
            ("crop", { m in
                guard let id = m.library.selected?.id else { print("drive crop: nothing selected"); return }
                m.router.show(.crop(id))
            }),
            // Edit's crop of the finished picture; with Develop open on the frame both are made in the page
            // (`InlineCrop`), and `crop.done` / `crop.cancel` finish or leave the one open there.
            ("printcrop", { m in
                guard let id = m.library.selected?.id else { print("drive printcrop: nothing selected"); return }
                m.router.show(.printCrop(id))
            }),
            ("cropframe.on", { m in m.settings.cropRemapsFrame = true; m.cropRemapsFrameChanged() }),
            ("cropframe.off", { m in m.settings.cropRemapsFrame = false; m.cropRemapsFrameChanged() }),
            ("crop.quarter", { m in edit(m) { e, _ in e.geometry.crop = CropRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25) } }),
            ("crop.whole", { m in edit(m) { e, _ in e.geometry.crop = .full } }),
            ("zoom.100", { _ in NotificationCenter.default.post(name: zoomHundred, object: true) }),
            ("zoom.fit", { _ in NotificationCenter.default.post(name: zoomHundred, object: false) }),
            ("crop.done", { m in m.router.inlineCrop?.finishes += 1 }),
            ("crop.cancel", { m in m.router.inlineCrop = nil }),
            ("crop.rotate", { _ in NotificationCenter.default.post(name: cropRotate, object: nil) }),
            ("crop.flip", { _ in NotificationCenter.default.post(name: cropFlip, object: nil) }),
            // A ⌘-drag on the crop page's picture, fed through the release's own function: a line 7° down
            // to the right (level), −20° (level), 80° (upright), 120° (upright, the other way round).
            ("crop.line.7", { _ in NotificationCenter.default.post(name: cropLine, object: 7.0) }),
            ("crop.line.-20", { _ in NotificationCenter.default.post(name: cropLine, object: -20.0) }),
            ("crop.line.80", { _ in NotificationCenter.default.post(name: cropLine, object: 80.0) }),
            ("crop.line.120", { _ in NotificationCenter.default.post(name: cropLine, object: 120.0) }),
            // Under a film edge, the picture placed under the gate (CropScreen's `filmStage`): enlarged ×1.6
            // and moved a fifth of the gate right and a tenth up (.crop.place.1), ×1.3 a quarter left (.2),
            // or back at the largest cut (.0).
            ("crop.place.1", { _ in NotificationCenter.default.post(name: cropPlace, object: [0.2, -0.1, 1.6]) }),
            ("crop.place.2", { _ in NotificationCenter.default.post(name: cropPlace, object: [-0.25, 0.0, 1.3]) }),
            ("crop.place.0", { _ in NotificationCenter.default.post(name: cropPlace, object: [0.0, 0.0, 0.0]) }),
            // The develop page's column and filmstrip, as their grips leave them (PaneDividers): column.393 … .700,
            // strip.96 … .220.
            ("column.393", { _ in split(column: 393) }), ("column.560", { _ in split(column: 560) }),
            ("column.700", { _ in split(column: 700) }),
            ("strip.96", { _ in split(strip: 96) }), ("strip.160", { _ in split(strip: 160) }),
            ("strip.220", { _ in split(strip: 220) }),
            // Settings › Appearance: Light (浅色) and Dark, as its mode's cards set them.
            ("light", { _ in UserDefaults.standard.set(AppAppearance.light.rawValue, forKey: AppAppearance.key) }),
            ("dark", { _ in UserDefaults.standard.set(AppAppearance.dark.rawValue, forKey: AppAppearance.key) }),
            // Settings › Appearance (AppearancePage.swift, 2026-10-24): the section; its mode (`light` and `dark`
            // above, and `system`); a chosen ground (bg.black, bg.warm, bg.red — Dark's; bg.paper, bg.blue —
            // Light's; bg.default both back); the Background picker open.
            ("settings.appearance", { m in SettingsRequest.next = .appearance; m.router.cover = .settings }),
            ("settings.develop", { m in SettingsRequest.next = .previewSize; m.router.cover = .settings }),
            // Settings on a section whether it is up or not (SettingsWindowRoot.drive), and General's Supporters.
            ("settings.general", { m in settings(m, .general, .language) }),
            ("settings.diagnostics", { m in settings(m, .diagnostics, .diagnostics) }),
            ("settings.supporters", { m in settings(m, .general, .credits, supporters: true) }),
            ("system", { _ in UserDefaults.standard.set(AppAppearance.system.rawValue, forKey: AppAppearance.key) }),
            ("bg.black", { _ in AppBackground.choose(0x000000, light: false) }),
            ("bg.warm", { _ in AppBackground.choose(0x2A231D, light: false) }),
            ("bg.red", { _ in AppBackground.choose(0x5A1E1E, light: false) }),
            ("bg.paper", { _ in AppBackground.choose(0xEEEAE3, light: true) }),
            ("bg.blue", { _ in AppBackground.choose(0xC9D8EA, light: true) }),
            ("bg.default", { _ in AppBackground.choose(nil, light: false); AppBackground.choose(nil, light: true) }),
            ("appearance.picker", { _ in NotificationCenter.default.post(name: AppearanceSettings.openPicker, object: nil) }),
            // Settings › Appearance's Interface Scale (InterfaceScale.swift): scale.80, .100, .120, .150.
            ("scale.80", { _ in UserDefaults.standard.set(80, forKey: InterfaceScale.key) }),
            ("scale.100", { _ in UserDefaults.standard.set(100, forKey: InterfaceScale.key) }),
            ("scale.120", { _ in UserDefaults.standard.set(120, forKey: InterfaceScale.key) }),
            ("scale.150", { _ in UserDefaults.standard.set(150, forKey: InterfaceScale.key) }),
            // The menu bar's Undo and Redo, as ⌘Z and ⇧⌘Z reach them (`DevelopMenuCommands`).
            ("undo", { _ in if let f = MacFlowUndo.front { f.undo() } else { UndoRedoRecipient.session?.undo() } }),
            ("redo", { _ in if let f = MacFlowUndo.front { f.redo() } else { UndoRedoRecipient.session?.redo() } }),
            // Film & Paper's Decode: the part its chips show, on the open page; and its curve.
            ("decode.exposure", { m in decodeTool(m, .exposure) }),
            ("decode.wb", { m in decodeTool(m, .whiteBalance) }),
            ("decode.curve", { m in decodeTool(m, .curve) }),
            ("scenecurve.s", { m in edit(m) { e, _ in
                e.params.sceneCurve = CurveSet()
                e.params.sceneCurve.rgb.insert(CGPoint(x: 0.4, y: 0.34))
                e.params.sceneCurve.rgb.insert(CGPoint(x: 0.6, y: 0.66))
            } }),
            ("scenecurve.0", { m in edit(m) { e, _ in e.params.sceneCurve = CurveSet() } }),
            // The panels of a wide window (DevelopInspectorParts.swift, HistogramPanel.swift), on the open page.
            ("surface.develop", { m in page(m) { $0.show(.develop) } }),
            ("surface.edit", { m in page(m) { $0.show(.edit) } }),
            ("step.film", { m in page(m) { $0.pageNavigation.select(.filmAndPaper); $0.pageNavigation.panelFolded = false } }),
            ("step.format", { m in page(m) { $0.pageNavigation.select(.format); $0.pageNavigation.panelFolded = false } }),
            ("histogram.c1", { _ in DevelopPanelPrefs.shared.histogramStyle = .captureOne }),
            ("histogram.spektralab", { _ in DevelopPanelPrefs.shared.histogramStyle = .spektraLab }),
            ("histogram.fold", { _ in DevelopPanelPrefs.shared.histogramCollapsed = true }),
            ("histogram.open", { _ in DevelopPanelPrefs.shared.histogramCollapsed = false }),
            ("rows.film.fold", { _ in DevelopPanelPrefs.shared.filmRowCollapsed = true }),
            ("rows.paper.fold", { _ in DevelopPanelPrefs.shared.paperRowCollapsed = true }),
            ("rows.open", { _ in DevelopPanelPrefs.shared.filmRowCollapsed = false; DevelopPanelPrefs.shared.paperRowCollapsed = false }),
            // Develop's sections: Format's 片边 and 日期后背 (FilmEdgeColumn.swift), Film & Paper's Decode: one folded, or all three open.
            ("fold.filmedge", { _ in DevelopPanelPrefs.shared.filmEdgeCollapsed = true }),
            ("fold.dateback", { _ in DevelopPanelPrefs.shared.dateBackCollapsed = true }),
            ("fold.decode", { _ in DevelopPanelPrefs.shared.decodeCollapsed = true }),
            ("fold.open", { _ in
                let p = DevelopPanelPrefs.shared
                p.filmEdgeCollapsed = false; p.dateBackCollapsed = false; p.decodeCollapsed = false
            }),
            ("applyfilm.off", { m in page(m) { $0.change { $0.setAppliesFilm(false) } } }),
            ("applyfilm.on", { m in page(m) { $0.change { $0.setAppliesFilm(true) } } }),
            // Edit › Adjust › 色轮 (MacColourWheel.swift): the tool open, a zone picked, values on the zones.
            ("wheels", { m in page(m) { $0.show(.edit); $0.pageNavigation.tool = .adjust; $0.pageNavigation.adjust = .wheels } }),
            ("wheels.shadows", { _ in NotificationCenter.default.post(name: wheelZone, object: "shadows") }),
            ("wheels.midtones", { _ in NotificationCenter.default.post(name: wheelZone, object: "midtones") }),
            ("wheels.highlights", { _ in NotificationCenter.default.post(name: wheelZone, object: "highlights") }),
            ("wheels.set", { m in page(m) { s in s.changeEdit { a in
                a.colorBalance.shadows = ColorZone(hue: 210, saturation: 0.36, luminance: -0.2)
                a.colorBalance.midtones = ColorZone(hue: 120, saturation: 0.09, luminance: 0)
                a.colorBalance.highlights = ColorZone(hue: 40, saturation: 0.25, luminance: 0.3)
            } } }),
            ("wheels.0", { m in page(m) { s in s.changeEdit { $0.colorBalance = ColorBalance() } } }),
            // The curve (RFC-035): Edit › Adjust › 曲线 open; an S on RGB and a lift on red (`curve.set`; `curve.0`
            // back to rest); and the steps of the curve tool in front, Edit's or Decode's (`curveStep`).
            ("curve", { m in page(m) { $0.show(.edit); $0.pageNavigation.tool = .adjust; $0.pageNavigation.adjust = .curve } }),
            ("curve.set", { m in page(m) { s in s.changeEdit { a in
                a.curves = CurveSet()
                a.curves.rgb.insert(CGPoint(x: 0.25, y: 0.2)); a.curves.rgb.insert(CGPoint(x: 0.75, y: 0.82))
                a.curves.red.insert(CGPoint(x: 0.5, y: 0.56))
            } } }),
            ("curve.0", { m in page(m) { s in s.changeEdit { $0.curves = CurveSet() } } }),
            ("curve.tab.rgb", { _ in NotificationCenter.default.post(name: curveStep, object: "tab.rgb") }),
            ("curve.tab.luma", { _ in NotificationCenter.default.post(name: curveStep, object: "tab.luma") }),
            ("curve.tab.red", { _ in NotificationCenter.default.post(name: curveStep, object: "tab.red") }),
            ("curve.tab.green", { _ in NotificationCenter.default.post(name: curveStep, object: "tab.green") }),
            ("curve.tab.blue", { _ in NotificationCenter.default.post(name: curveStep, object: "tab.blue") }),
            ("curve.select.1", { _ in NotificationCenter.default.post(name: curveStep, object: "select.1") }),
            ("curve.select.0", { _ in NotificationCenter.default.post(name: curveStep, object: "select.0") }),
            ("curve.hold.1", { _ in NotificationCenter.default.post(name: curveStep, object: "hold.1") }),
            // A reply without per-channel rows, as an old engine (or the demo before a measurement)
            // gives one: the colour tabs' no-hills state (RFC-035 §3.2, trap 16). `curve.rows` puts the
            // real one back.
            ("curve.norows", { _ in NotificationCenter.default.post(name: curveStep, object: "norows") }),
            ("curve.rows", { _ in NotificationCenter.default.post(name: curveStep, object: "rows") }),
            ("curve.release", { _ in NotificationCenter.default.post(name: curveStep, object: "release") }),
            ("curve.end.right", { _ in NotificationCenter.default.post(name: curveStep, object: "end.right") }),
            ("lighttable", { m in m.router.dismissAllSheets(); m.router.dismissCover(); m.router.toLibrary(); m.router.open(.lightTable) }),
        ]
        for (name, step) in steps {
            var token: Int32 = 0
            notify_register_dispatch("com.spektralab.mac.drive" + MacWindowCapture.notifyTag(arguments) + "." + name, &token, .main) { _ in
                MainActor.assumeIsolated {
                    step(model)
                    print("drive \(name): path \(model.router.path.count), sheets \(model.router.sheets.map(\.id)), cover \(model.router.cover?.id ?? "-")")
                }
            }
            tokens.append(token)
        }
    }

    /// Settings on `section` (and on General's Supporters): asked of the page that is up, and of the one a
    /// cover opens when none is (`SettingsRequest`, `SettingsWindowRoot.supportersAsked`); the page that takes
    /// the notification clears both.
    private static func settings(_ m: AppServices, _ section: MacSettingsSection, _ request: SettingsPage, supporters: Bool = false) {
        SettingsRequest.next = request
        SettingsWindowRoot.supportersAsked = supporters
        NotificationCenter.default.post(name: SettingsWindowRoot.drive, object: nil,
                                        userInfo: ["section": section.rawValue, "supporters": supporters])
        m.router.cover = .settings
    }

    private static func split(column: CGFloat? = nil, strip: CGFloat? = nil) {
        if let column { PaneDividers.shared.columnWidth = column }
        if let strip { PaneDividers.shared.filmstripHeight = strip }
        PaneDividers.shared.save()
    }

    private static func decodeTool(_ m: AppServices, _ tool: DecodeTool) {
        guard let id = m.library.selected?.id, let session = m.openSession(id) else { print("drive decode: no open page"); return }
        session.pageNavigation.step = .filmAndPaper
        session.pageNavigation.decodeTool = tool
    }

    private static func page(_ m: AppServices, _ change: (OpenFrameSession) -> Void) {
        // The page the window shows (a wide window's keys and Undo follow it), else the selected frame's.
        guard let session = UndoRedoRecipient.session ?? m.library.selected.flatMap({ m.openSession($0.id) }) else {
            print("drive page: no open page"); return
        }
        change(session)
    }

    private static func flow(_ m: AppServices, _ step: FilmEdgeStep) {
        guard let id = m.library.selected?.id else { print("drive flow: nothing selected"); return }
        // One cover after another, not in the same moment: a cover replaced by its own kind in one
        // update keeps the old one's state (its step) under the new entry.
        guard m.router.cover != nil else { m.router.show(.filmEdge(id, step)); return }
        m.router.dismissCover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { m.router.show(.filmEdge(id, step)) }
    }

    private static func edit(_ m: AppServices, _ mutate: (inout FrameEdit, LibraryFrame) -> Void) {
        guard let f = m.library.selected else { print("drive edit: nothing selected"); return }
        if let session = m.openSession(f.id) {
            session.change { mutate(&$0, f) }
        } else {
            m.library.update(f.id) { lf in var e = lf.edit; mutate(&e, lf); lf.edit = e }
        }
        NSLog("drive edit: %@ film edge %d date %d", f.id.uuidString, m.library.frame(f.id)?.edit.filmEdge.active == true ? 1 : 0,
              m.library.frame(f.id)?.edit.dateBack.active == true ? 1 : 0)
    }
}
#endif
