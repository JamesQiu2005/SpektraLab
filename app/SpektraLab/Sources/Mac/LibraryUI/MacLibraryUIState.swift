//  MacLibraryUIState.swift — the Mac library page's own state (design/MAC-LIBRARY-UI.md).
//
//  The views read the library through `MacLibraryData` (MacLibraryModels.swift, the data branch's
//  protocol, copied verbatim): sources, the collection tree, the rows, the facets, the query. What is
//  here is only the page's: the navigator tab, the selection and its keys, the thumbnail size, the
//  sidebar's width, what is folded. `MacLibraryUI.store` is the one place the page reaches its store.

import Observation
import SwiftUI
import UIKit

@MainActor
enum MacLibraryUI {
    /// The store the page reads: the app's `CatalogSourcesStore` (MAC-LIBRARY-DATA.md).
    static func store(_ model: AppServices) -> any MacLibraryData { model.macLibrary }
}

/// The develop column read again (a frame made, developed, changed).
@MainActor
protocol MacDevelopRefreshing: AnyObject {
    func refreshDevelopInfo()
}

extension CatalogSourcesStore: MacDevelopRefreshing {}

// MARK: - Mac points

/// The design's figures are Mac points (the HIG's). The app runs *scaled Catalyst mode*, where a window
/// point is drawn at 77 % of a Mac's, so a Mac figure is written `pt(x)`.
@MainActor
enum MacMetric {
    static let scale: CGFloat = UIDevice.current.userInterfaceIdiom == .mac ? 1 : 0.77
    static func pt(_ mac: CGFloat) -> CGFloat { (mac / scale).rounded(.toNearestOrEven) }
    static func font(_ mac: CGFloat, _ weight: Font.Weight = .regular) -> Font { Theme.Font.ui(mac / scale, weight) }

    /// **The window's left column is one width in every mode** (the owner, 2026-10-26) — and it is one
    /// *number*: the develop column's, `PaneDividers.columnWidth` (scene points, dragged and kept since
    /// 2026-10-24). This page reads and writes that number through these two conversions rather than
    /// keeping its own, so a drag in either mode moves both.
    ///
    /// The two pages are drawn at different factors (`InterfaceScale`): the develop page draws a window
    /// point at `choice × padTarget / MacMetric.scale` window points, this page a page point at
    /// `choice × 10/9`, and this page's figures are Mac points, `pt(x) = x / MacMetric.scale` page points.
    /// So a develop column `C` stands at `C × padTarget / scale` window points, and a figure `W` here at
    /// `W / scale × 10/9`: equal where
    ///
    ///     W  =  C × padTarget × 0.9          (0.866 C)
    ///
    /// The scale is in both and cancels, and so does the interface-scale choice. (2026-10-27, measured in
    /// the window shell at 1427 × 977: with an extra `× MacMetric.scale` here, as unpublished-revision had it, the
    /// library's wall stood at 405 of 2000 capture px against the develop page's 530 — 0.77 of it, the
    /// jump on every mode press the rule exists to prevent; unpublished-revision's own measurement could not be
    /// reproduced.)
    static func columnFigure(_ padPoints: CGFloat) -> CGFloat {
        (padPoints * InterfaceScale.padTarget * 0.9).rounded()
    }
    static func padPoints(forColumn figure: CGFloat) -> CGFloat {
        figure / (InterfaceScale.padTarget * 0.9)
    }
    /// The narrowest and widest the column may be dragged here, in this page's figures.
    static var sidebarRange: ClosedRange<CGFloat> {
        columnFigure(PaneDividers.minColumn)...columnFigure(700)
    }
    static let row: CGFloat = 24
    static let indent: CGFloat = 14
    static let tabBar: CGFloat = 30
    static let bottomBar: CGFloat = 30
    static let gridHeader: CGFloat = 32
    /// The floating browser panel's header: the window bar's 44 less the panel's 8 pt inset from it, so
    /// its controls stand on the bar's rhythm.
    static let panelHeader: CGFloat = 36
    /// Thumbnail cells, Mac points.
    static let cellDefault: Double = 112
    static let cellRange: ClosedRange<Double> = 64...256
    static let cellGap: CGFloat = 2
    /// The browser's width beside the viewer (Capture One's viewer and browser, side by side).
    static let browserWidth: CGFloat = 430
    static let browserRange: ClosedRange<CGFloat> = 240...900
    static let viewerBar: CGFloat = 26
}

enum MacNavigator: String, CaseIterable, Hashable {
    case library, filters, info

    var symbol: String {
        switch self {
        case .library: "folder"
        case .filters: "line.3.horizontal.decrease.circle"
        case .info: "info.circle"
        }
    }
    var title: String {
        switch self {
        case .library: L("Library")
        case .filters: L("Filters")
        case .info: L("Info")
        }
    }
}

// MARK: - words and colours the page gives the store's values

enum MacWords {
    /// A collection's name: the fixed rows in the app's own words (the store's are placeholders, and
    /// Capture One's are in its UI language), the others as they are.
    static func title(_ c: MacCollection) -> String {
        switch c.kind {
        case .allImages: L("All Images")
        case .recentImports: L("Recent Imports")
        case .recentCaptures: L("Recent Captures")
        case .trash: L("Trash")
        case .inLibrary: L("In Catalog")
        default:
            switch c.id {
            case "app.favourites": L("Favourites")
            case "app.copied": L("Copied in")
            default: c.title.isEmpty ? L("Untitled") : L(shown: c.title)
            }
        }
    }

    static func symbol(_ c: MacCollection) -> String {
        switch c.kind {
        case .allImages: "photo.on.rectangle"
        case .recentImports: "square.and.arrow.down"
        case .recentCaptures: "camera"
        case .trash: "trash"
        case .inLibrary: "shippingbox"
        case .project: "briefcase"
        case .group: "folder.badge.gearshape"
        case .smartAlbum: "gearshape"
        case .folder: "folder"
        case .album, .other: c.id == "app.favourites" ? "heart" : "rectangle.stack"
        }
    }

    /// A source's symbol, by what it is and never by whose file it is: a Capture One catalog is a catalog
    /// (the owner, 2026-10-24: no difference on the person's side). The sidebar's picker and Import To.
    static func symbol(_ kind: MacSource.Kind) -> String {
        switch kind {
        case .catalog, .captureOneCatalog, .appLibrary: "books.vertical"
        case .session, .captureOneSession: "camera.viewfinder"
        case .folder: "folder"
        }
    }

    static func sort(_ s: MacImageQuery.Sort) -> String {
        switch s {
        case .captureDate: L("Date Taken")
        case .fileName: L("Name")
        case .rating: L("Rating")
        case .importDate: L("Date Imported")
        case .addedDate: L("Date Added")
        }
    }

    static func colorName(_ tag: Int) -> String {
        switch tag {
        case 1: L("Red")
        case 2: L("Orange")
        case 3: L("Yellow")
        case 4: L("Green")
        case 5: L("Blue")
        case 6: L("Pink")
        case 7: L("Purple")
        default: L("None")
        }
    }

    static func color(_ tag: Int) -> Color? {
        switch tag {
        case 1: Color(hex: 0xD8402F)
        case 2: Color(hex: 0xE2852E)
        case 3: Color(hex: 0xE5D23B)
        case 4: Color(hex: 0x55B83F)
        case 5: Color(hex: 0x3A78D4)
        case 6: Color(hex: 0xC94FC0)
        case 7: Color(hex: 0x7A45C7)
        default: nil
        }
    }

    static func rating(_ r: Int) -> String { r == 0 ? L("No Rating") : String(repeating: "★", count: r) }

    static func kind(_ raw: String) -> String {
        switch raw {
        case "raw": "RAW"
        case "raster": L("Image")
        case "movie": L("Movie")
        case "pair": L("Half-Frame Pair")
        default: L("Other")
        }
    }

    /// "October", for a "2026-10" facet value, in the app's language.
    static func month(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
        else { return key }
        return date.formatted(Date.FormatStyle().month(.wide).locale(Language.shared.current.locale))
    }
}

// MARK: - the page's state

@MainActor
@Observable
final class MacLibraryBrowser {
    /// One for the window: the page is left for the edit page and comes back to the same place.
    static let shared = MacLibraryBrowser()

    /// The browser's width as the person dragged it, kept across launches, as `PaneDividers` keeps the
    /// develop column's (the owner, 2026-10-26). Stored as dragged, fitted where it is used; written when
    /// a drag ends.
    static let browserWidthKey = "mac.browserWidth"
    @ObservationIgnored private let defaults: UserDefaults

    /// `defaults`: the app's own; a check hands in a suite of its own.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let browser = defaults.double(forKey: Self.browserWidthKey)
        browserWidth = browser > 0 ? CGFloat(browser).clamped(to: MacMetric.browserRange) : MacMetric.browserWidth
    }

    /// The picture the modes last opened (the owner, 2026-10-27: pressing 冲洗 or 编辑 must not require a
    /// selection). With nothing chosen they open the browser's focus, else this picture, else the first
    /// row in the current sort; a library with no rows at all is the only case the modes stand down.
    var lastOpened: MacImage.ID?

    /// A drag of the browser's wall ended: what it left is kept. The column's width is `PaneDividers`' and is
    /// written by its own drags (`PaneDividers.save`, called from either page's wall).
    func saveWidths() {
        defaults.set(Double(browserWidth), forKey: Self.browserWidthKey)
    }

    var navigator: MacNavigator = .library
    /// The thumbnail cell's side, Mac points.
    var cell: Double = MacMetric.cellDefault
    /// The left column's width (`PaneDividers.columnWidth`, in this page's figures): one number for
    /// 图库, 冲洗 and 编辑, dragged at either page's wall.
    var sidebarWidth: CGFloat {
        get { MacMetric.columnFigure(PaneDividers.shared.columnWidth) }
        set { PaneDividers.shared.columnWidth = MacMetric.padPoints(forColumn: newValue) }
    }
    var sidebarShown = true
    /// The viewer: the chosen picture large at the left of the grid, the grid a browser beside it (⌥⌘V).
    /// On by default — the picture is the centre (the owner, 2026-10-26); off, the browser has the window.
    /// In the develop page the same switch is the browser's own place beside the canvas.
    var viewerShown = true
    /// The grid takes the window (the owner, 2026-10-26: "the current version has zero part for viewing
    /// the whole library in a grid — we need an entry button for that"): 图库's viewer steps aside and the
    /// browser — its cells, the size slider, the count — has the whole area right of the column, in every
    /// mode (`MacSharedControls`' grid button; choosing 冲洗/编辑, opening a picture or pressing it again
    /// gives the viewer back).
    var fullGrid = false
    var browserWidth: CGFloat
    /// The import flow (a Finder panel, then the import page) and the export page, over the whole library
    /// page (`MacLibraryPage`). While either is up the library's keys stand down.
    ///
    /// The import page is one *request* at a time (2026-11-05), and the cover is presented by it
    /// (`fullScreenCover(item:)`, the flow's identity its id). A Boolean was not enough: asked again within
    /// the half second a Cancel's dismissal takes, SwiftUI reversed the dismissal and handed back the page
    /// just closed — its session closed, its first appearance done, so it took no drop and no picks — and
    /// that page's Cancel then closed nothing (measured on 2.1.3 itself: 5 of 7 asks 0–350 ms after a
    /// close got the old session). So a new request waits, unpresented, until the last page is off the
    /// screen (`importPresented`), and a page closes only its own request (`closeImport`).
    var importRequest: MacImportRequest? {
        didSet {
            if importRequest != nil, importShown != nil, importShown != importRequest?.id { watchLeavingPage(after: .seconds(3)) }
            // Closed (Cancel, an import): the page must go by itself. The gate run of 2026-11-05 saw one
            // plain Cancel leave it presented, not dismissing, with nothing asked — round 1's "stuck" page,
            // which until then only a new Import or drop let go of.
            if importRequest == nil, oldValue != nil, importShown != nil { watchLeavingPage(after: .milliseconds(1500)) }
        }
    }
    /// The request whose page is on screen, from its appearing to its disappearing (`MacImportFlow`):
    /// still set while a closed page's cover is going away.
    var importShown: MacImportRequest.ID?
    /// What the cover presents: the request, once no other request's page is still on screen.
    var importPresented: MacImportRequest? {
        guard let shown = importShown, shown != importRequest?.id else { return importRequest }
        return nil
    }
    /// A closed page must not stay, nor hold the next one back for ever. A dismissal takes about half a
    /// second; if the page has not said it has gone (`onDisappear`) after `delay`, UIKit is looked at: the
    /// closed page still standing (the cover SwiftUI let stand after Cancel, round 1's "stuck" page) is
    /// taken down — that page's controller only (`MacImportCover`) — a page still going is given time,
    /// and then the next is let through.
    private func watchLeavingPage(after delay: Duration) {
        guard let leaving = importShown else { return }
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard importShown == leaving else { return }
            let stands = MacImportCover.stands(leaving)
            Log.warn(.library, "mac import: a closed page had not gone", ["still_presented": stands, "after": "\(delay)"])
            if stands {
                MacImportCover.takeDown(leaving)
                try? await Task.sleep(for: .seconds(1))
            }
            var waited = 0
            while MacImportCover.going(leaving), waited < 20 {
                try? await Task.sleep(for: .milliseconds(250)); waited += 1
            }
            if importShown == leaving { importShown = nil }
        }
    }
    /// The import page is asked for: set true, a new request if none; false, none.
    var importAsked: Bool {
        get { importRequest != nil }
        set {
            if !newValue { importRequest = nil } else if importRequest == nil { importRequest = MacImportRequest() }
        }
    }
    /// The page of request `id` is done (Cancel, an import, its first Finder panel cancelled): it closes
    /// only if it is still the one asked for, so a late answer from an old page never closes a new one.
    func closeImport(_ id: MacImportRequest.ID) {
        if importRequest?.id == id { importRequest = nil }
    }
    /// Pictures and folders dropped on the window (`MacImportDrop`): the import page takes them as picked
    /// in place of the Finder panel, or, open already, adds them to its picks; a second drop before the
    /// page has taken the first joins it. Let go (and a drop's temporary copies removed) when the page closes.
    var droppedPicks: MacImportDrop.Picks?
    /// A drop's providers are being read (`MacImportDrop.perform`): how many, for the window's note.
    var dropReading: Int?
    var exportAsked = false
    /// The move of the app library into a catalog is on screen (`MacLibraryMovePage`).
    var moveShown = false
    var sourcePickerShown = false
    var modal: Bool { importAsked || exportAsked || moveShown || sourcePickerShown }
    /// The navigator's own Filter field (Xcode's): narrows the rows of the tab shown.
    var rowFilter = ""
    /// Folded sections, closed tree rows and opened years, by id.
    var folded: Set<String> = []
    /// A text field has the keyboard: the arrows, Return and Delete are its.
    var typing = false
    /// The search field's text, handed to the store's query a moment after the typing stops.
    var search = ""

    // Selection: the chosen rows, the one the keys move from (focus), the run's anchor.
    var selection: Set<MacImage.ID> = []
    var focus: MacImage.ID?
    var anchor: MacImage.ID?
    /// Columns in the grid as last laid out: what ↑ and ↓ move by.
    @ObservationIgnored var columns = 1
    /// The grid asks to be scrolled to this.
    var scrollTarget: MacImage.ID?

    /// A collection or library changed: what was chosen there is let go.
    func collectionChanged() {
        selection = []
        focus = nil
        anchor = nil
        scrollTarget = nil
    }

    /// A click: the row alone; with ⌘ added or taken away; with ⇧ the run from the anchor.
    func click(_ id: MacImage.ID, command: Bool, shift: Bool, in rows: [MacImage]) {
        if shift, let a = anchor ?? focus, let i = rows.firstIndex(where: { $0.id == a }),
           let j = rows.firstIndex(where: { $0.id == id }) {
            let run = rows[min(i, j)...max(i, j)].map(\.id)
            if command { selection.formUnion(run) } else { selection = Set(run) }
            focus = id
            return
        }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        focus = id
        anchor = id
    }

    /// An arrow key: `step` places along the grid (±1, ±columns); with ⇧ the selection grows from the anchor.
    func move(_ step: Int, extend: Bool, in rows: [MacImage]) {
        guard !rows.isEmpty else { return }
        let from = focus.flatMap { f in rows.firstIndex { $0.id == f } } ?? (step > 0 ? -1 : rows.count)
        let to = min(max(from + step, 0), rows.count - 1)
        let id = rows[to].id
        if extend, let a = anchor ?? focus, let i = rows.firstIndex(where: { $0.id == a }) {
            selection = Set(rows[min(i, to)...max(i, to)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
        focus = id
        scrollTarget = id
    }

    func selectAll(_ rows: [MacImage]) { selection = Set(rows.map(\.id)) }

    func selectNone() { selection = []; anchor = nil }

    /// The row Return and Info speak of: the focused one if chosen, else the first chosen in the grid's order.
    func primary(_ rows: [MacImage]) -> MacImage? {
        if let f = focus, selection.contains(f), let row = rows.first(where: { $0.id == f }) { return row }
        return rows.first { selection.contains($0.id) }
    }

    func resize(by factor: Double) {
        cell = min(max((cell * factor).rounded(), MacMetric.cellRange.lowerBound), MacMetric.cellRange.upperBound)
    }

    /// A tab of the navigator, the sidebar brought back if it was put away.
    func show(_ tab: MacNavigator) {
        navigator = tab
        sidebarShown = true
    }
}
