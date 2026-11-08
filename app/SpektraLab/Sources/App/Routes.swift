//  Routes.swift — what each route shows.
//
//  The one place that names both halves of the app: the library side
//  (`Import`, `Library`, `Settings`) and the darkroom side
//  (`Features/Develop`, `Frame`, `Export`).

import SwiftUI

struct RouteContent: View {
    let route: Route
    @Environment(AppRouter.self) private var router
    var body: some View {
        // each page at the interface scale (InterfaceScale.swift),
        // but the Light Table, whose Actual Size is the window's own points. An reference device's pages as they were.
        switch route {
        case .photo(let id): PhotoRoute(id: id, back: router.backWay(for: route)).interfaceScaled(.padPoints)   // a reference device: LibraryScreen(viewerID:); a window: DevelopController.swift
        case .lightTable: LightTablePane()
        case .develop(let id): DevelopRoute(id: id, opening: { var o = DevelopOpening(); o.back = router.backWay(for: route); return o }()).interfaceScaled(.padPoints)
        }
    }
}

struct SheetContent: View {
    let route: SheetRoute
    var body: some View {
        switch route {
        case .importSources: ImportSheet()
        case .info(let id): InfoSheet(frameID: id)
        case .locate(let id): LocateSheet(frameID: id)
        case .copySettings(let id): CopySettingsDialog(frameID: id)
        case .export, .exporting: EmptyView()     // the Export page, over the window (SheetHost)
        case .pairWith(let first, let keepFilmEdge): PairWithSheet(first: first, keepFilmEdge: keepFilmEdge)
        }
    }
}

struct CoverContent: View {
    let route: CoverRoute
    var body: some View {
        // each cover at the interface scale (InterfaceScale.swift).
        switch route {
        case .settings:
            SettingsWindowRoot().interfaceScaled(.macPoints)       // the Mac's change : its own page, Sources/Mac/Settings
        case .crop(let id): CropScreen(frameID: id).interfaceScaled(.padPoints)
        case .printCrop(let id): CropScreen(frameID: id, target: .finished).interfaceScaled(.padPoints)
        case .filmEdge(let id, let step): FilmEdgeFlow(frameID: id, entry: step).interfaceScaled(.padPoints)
        case .pairPlace(let id, let side): PairPlaceFlow(pairID: id, side: side).interfaceScaled(.padPoints)
        }
    }
}
