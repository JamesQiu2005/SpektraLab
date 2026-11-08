//  AppRouter.swift — where a tap goes: the flow map's arrows, as state.
//
//  The router owns the page stack and the sheets shown over it.
//
//  - **Pushed** (a page with a way back to the Library): Develop.
//  - **Sheets** (over a page, on a scrim): Import, Info, Original missing,
//    Copy Settings, Export, Exporting. A sheet may present one over
//    itself, so sheets are a stack.
//  - **Covers** (a full page of its own, with Cancel or Done): Settings, Crop.
//
//  The two halves of the app never construct each other's pages. The library
//  side asks for `.export(ids)`; the darkroom side asks for `.settings`. What
//  each route shows is in `Routes.swift`.

import Observation
import SwiftUI

enum SheetRoute: Equatable, Identifiable, Sendable {
    /// A4.
    case importSources
    /// B5.
    case info(LibraryFrame.ID)
    /// F3.
    case locate(LibraryFrame.ID)
    /// C7.
    case copySettings(LibraryFrame.ID)
    /// E1, and F4 when an original is away.
    case export([LibraryFrame.ID])
    /// E2.
    case exporting
    /// H2 (design/pair v2): the second frame of a half-frame pair that begins
    /// with this one. `keepFilmEdge`: from a half frame's Film Edge, whose
    /// framing and film edge the pair takes (the desktop's *Enter Half-Frame Pair*).
    case pairWith(LibraryFrame.ID, keepFilmEdge: Bool)

    /// The sheet's slot, not its content: Export becoming Exporting is one
    /// sheet changing height, not one closing and another opening.
    var id: String {
        switch self {
        case .importSources: "import"
        case .info: "info"
        case .locate: "locate"
        case .copySettings: "copy"
        case .export, .exporting: "export"
        case .pairWith: "pairWith"
        }
    }

    /// Where the drawing puts the sheet's top edge on its 852 pt page.
    var top: CGFloat {
        switch self {
        case .importSources: 252
        case .info: 112
        case .locate: 372
        // The drawing's seven groups at 150; each group past them (Edit's Light, Curve and Colour, 2026-10-15)
        // raises the sheet by its row, as far as under the status bar.
        case .copySettings: max(56, 150 - 54 * CGFloat(max(0, ClipboardGroup.offered.count - 7)))
        case .export: 128
        case .exporting: 380
        case .pairWith: 232
        }
    }

    /// The sheet's height as a share of the screen, from the drawing.
    var detent: PresentationDetent {
        .fraction((Theme.Metric.designHeight - top) / Theme.Metric.designHeight)
    }

    /// Every height this slot takes, so the sheet can move between them.
    var slotDetents: Set<PresentationDetent> {
        switch self {
        case .export, .exporting: [SheetRoute.export([]).detent, SheetRoute.exporting.detent]
        default: [detent]
        }
    }
}

enum CoverRoute: Equatable, Identifiable, Sendable {
    /// B6, with Sources (F1) and Storage (F5) pushed inside it.
    case settings
    /// D1: Develop's crop, of the picture before the film.
    case crop(LibraryFrame.ID)
    /// Edit's crop (2026-10-20): the same page, of the finished picture.
    case printCrop(LibraryFrame.ID)
    /// D2-D5: the Film Edge flow, opened at a step.
    case filmEdge(LibraryFrame.ID, FilmEdgeStep)
    /// H8 (design/pair v2): a frame of a kept pair placed under its hole —
    /// where Crop is for a photograph. Behind `FeatureFlags.halfFramePair`.
    case pairPlace(LibraryFrame.ID, HalfFramePair.Side)

    var id: String {
        switch self {
        case .settings: "settings"
        case .crop: "crop"
        case .printCrop: "printCrop"
        case .filmEdge: "filmEdge"
        case .pairPlace: "pairPlace"
        }
    }
}

@MainActor
@Observable
final class AppRouter {
    var path: [Route] = []
    var sheets: [SheetRoute] = []
    var cover: CoverRoute?

    func open(_ route: Route) {
        #if DEBUG
        NSLog("[navtrace] open %@ path %@", String(describing: route), String(describing: path))   // the window's windows: what was asked
        #endif
        path.append(route)
    }
    /// The page on top goes, and the one under it is in front: a pushed
    /// page's ‹, and the edge swipe, which UIKit's own stack does.
    func back() { path = BackWay.back(path) }
    func home() { path = [] }

    /// Where a pushed page's ‹ goes and what it says, as the path stands
    /// now: the page under it (`BackWay`). A page reads it once, when it is
    /// opened — while it is popped, the path no longer holds it.
    func backWay(for route: Route) -> BackWay { BackWay(to: route, in: path) }

    /// **The Library, from anywhere**: every sheet and cover goes and the
    /// stack is the Library alone. The Develop page's library button is what
    /// calls this.
    func toLibrary() {
        if !sheets.isEmpty { sheets = [] }
        if cover != nil { cover = nil }
        if !path.isEmpty { path = [] }
    }

    /// **The develop page, from anywhere**: every sheet and cover goes and the stack is that frame's
    /// develop over the Library (its ‹ is the Library's).
    func toDevelop(_ id: LibraryFrame.ID) {
        if !sheets.isEmpty { sheets = [] }
        if cover != nil { cover = nil }
        path = [.develop(id)]
    }

    /// Present a sheet over whatever is on top.
    func present(_ sheet: SheetRoute) {
        sheets.append(sheet)
    }

    /// Change the top sheet in place: Export → Exporting.
    func swapSheet(for sheet: SheetRoute) {
        if sheets.isEmpty { sheets = [sheet] } else { sheets[sheets.count - 1] = sheet }
    }

    func dismissSheet() { if !sheets.isEmpty { sheets.removeLast() } }
    func dismissAllSheets() { sheets = [] }

    func show(_ cover: CoverRoute) {
        // "we don't need another page that pops
        // up". A crop of the frame a wide develop page shows is made in that page — its column's controls
        // swapped for the crop's, the crop over the picture (`InlineCrop`) — whoever asks for it: the
        // header's Crop, Film & Paper's, a key, a check's drive step. Anywhere else it is the cover.
        if let host = inlineCropHost {
            switch cover {
            case .crop(let id) where id == host: inlineCrop = InlineCrop(frameID: id, target: .source); return
            case .printCrop(let id) where id == host: inlineCrop = InlineCrop(frameID: id, target: .finished); return
            default: break
            }
        }
        self.cover = cover
    }
    func dismissCover() { cover = nil }

    /// the crop open in the develop page, in place of a cover; nil when none is.
    var inlineCrop: InlineCrop?
    /// the frame a develop page in a wide window shows, which takes its crops in place
    /// (`show`). Set and cleared by that page; nil everywhere else, and always on a reference device.
    @ObservationIgnored var inlineCropHost: LibraryFrame.ID?

    /// What is on top, by its slot's name: the top sheet, else the cover,
    /// else the page. For the log: where the app was when its memory was read.
    var top: String { sheets.last?.id ?? underTopSheet }

    /// What the top sheet stands over, by its slot's name: the sheet under
    /// it, else the cover, else the page ("export", "settings", "develop",
    /// "library"). For the log: which page a sheet was opened from.
    var underTopSheet: String {
        if sheets.count > 1 { return sheets[sheets.count - 2].id }
        if let cover { return cover.id }
        switch path.last {
        case .photo: return "photo"
        case .develop: return "develop"
        case .lightTable: return "lighttable"
        case nil: return "library"
        }
    }
}

/// Presents the router's sheet at `level`, and lets that sheet present the
/// next one over itself.
struct SheetHost: ViewModifier {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var model
    let level: Int
    /// The root's host stands down while a cover is up: the cover's own host
    /// presents instead, since only the topmost page can.
    var active = true

    func body(content: Content) -> some View {
        // Mac change (PAGES.md; the owner, 2026-10-24: one export page, its controls at
        // the left): Export and Exporting are the Mac's Export page over the whole window (`MacExportPage`,
        // the library's Export's own), not the window's sheet. Every other sheet is the window's.
        let item = Binding<SheetRoute?>(
            get: { active && router.sheets.count > level && !router.sheets[level].isMacExportPage ? router.sheets[level] : nil },
            set: { new in
                if new == nil, router.sheets.count > level { router.sheets.removeSubrange(level...) }
            })
        let page = Binding<SheetRoute?>(
            get: { active && router.sheets.count > level && router.sheets[level].isMacExportPage ? router.sheets[level] : nil },
            set: { new in
                if new == nil, router.sheets.count > level { router.sheets.removeSubrange(level...) }
            })
        content.sheet(item: item) { route in
            SheetLevel(level: level, opened: route).appEnvironment(model)
        }
        .fullScreenCover(item: page) { route in
            MacExportRoute(level: level, opened: route)
                .interfaceScaled(.macPoints)                  // at the interface scale (InterfaceScale.swift, 2026-10-24)
                .modifier(SheetHost(level: level + 1))      // a sheet over it, as over the window's sheet
                .appEnvironment(model)
        }
        // The library's own Export cover hands the page no objects: it takes them from here.
        .onAppear { if level == 0 { MacExportPage.app = model } }
    }
}

extension SheetRoute {
    /// Shown on the Mac as its Export page (`MacExportPage`), not as a sheet.
    var isMacExportPage: Bool {
        switch self {
        case .export, .exporting: true
        default: false
        }
    }
}

/// The Mac's Export page for the router's Export (Develop's button: its frame) or Exporting (a batch under
/// way: the batch's frames). Closing it takes it off the router's stack, as the sheet's ✕ does.
private struct MacExportRoute: View {
    @Environment(AppRouter.self) private var router
    @Environment(ExportService.self) private var exporter
    let level: Int
    let opened: SheetRoute

    var body: some View {
        let current = router.sheets.count > level ? router.sheets[level] : opened
        let ids: [LibraryFrame.ID] = switch current {
        case .export(let ids): ids
        default: exporter.batch?.items.map(\.id) ?? []
        }
        MacExportPage(frameIDs: ids) {
            if router.sheets.count > level { router.sheets.removeSubrange(level...) }
        }
        .id(ids)
    }
}

/// One presented sheet. A view of its own so that it reads the router inside a
/// `body`: a route that changes in place (Export → Exporting) redraws the
/// content and moves the sheet to its new height.
private struct SheetLevel: View {
    @Environment(AppRouter.self) private var router
    let level: Int
    let opened: SheetRoute

    var body: some View {
        let current = router.sheets.count > level ? router.sheets[level] : opened
        let height = Binding<PresentationDetent>(get: { current.detent }, set: { _ in })
        SheetContent(route: current)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .presentationDetents(current.slotDetents, selection: height)
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(Theme.Metric.sheetRadius)
            .presentationBackground(Theme.sheet)
            .appColorScheme()
            .modifier(SheetHost(level: level + 1))
            // A hardware keyboard's Escape puts the top sheet away, as its ✕ does (a window's
            // keyboard, PAGES.md §6). Not the Exporting sheet: its work is under way.
            .background {
                if current != .exporting, router.sheets.count == level + 1 {
                    Color.clear.frame(width: 0, height: 0)
                        .macPageActions(cancel: { router.dismissSheet() })
                }
            }
    }
}
