import AppKit
import SwiftUI
import XCTest

/// The Film Edge and Date Back sections (2026-10-01 drawings): they fit the
/// left rail in both languages in the states that grow them, the format menu
/// offers what the engine has, and Date Back offers only the faces the
/// camera draws.
///
/// `TEST_RUNNER_SPK_RENDER_DIR=<dir>` also writes the format menu's content
/// as PNGs (English and zh-Hans), since a snapshot of the window cannot open
/// a popover.
@MainActor
final class FilmEdgeSectionTests: XCTestCase {

    private let railWidth = Theme.Metric.leftPanelWidth
    private let keys = ["ui2.section.filmEdge", "ui2.section.dateBack"]

    override func setUp() async throws {
        // The sections start folded; their rows are what is measured.
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        addTeardownBlock { @MainActor [keys] in
            for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) }
        }
        for k in keys { UserDefaults.standard.set(true, forKey: k) }
    }

    private func width<V: View>(of view: V, offered width: CGFloat) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 4000)).width
    }

    private func inBothLanguages(_ body: (LanguageSetting) -> Void) {
        let language = Localization.shared.language
        defer { Localization.shared.language = language }
        for setting in [LanguageSetting.english, .simplifiedChinese] {
            Localization.shared.language = setting
            body(setting)
        }
    }

    /// Every format, both views, every face and both switches: no state
    /// makes either section wider than the rail.
    func testBothSectionsFitTheRailInEveryState() {
        let s = Session()
        var states: [(FilmEdgeSettings, DateBackSettings)] = []
        for format in FilmEdgeFormat.allCases {
            for face in DateBackFace.allCases {
                var e = FilmEdgeSettings(); e.active = true; e.format = format
                e.view = face == .dots ? .filed : .strip
                e.edgeText = "KODAK PROFESSIONAL PORTRA 800 (PUSH 2)"; e.fNumber = 2.8
                var d = DateBackSettings(); d.active = true; d.face = face; d.text = "'26 10 1"
                states.append((e, d))
                var off = e; off.active = false
                states.append((off, d))
            }
        }
        inBothLanguages { setting in
            for (e, d) in states {
                var p = s.params; p.filmEdge = e; p.dateBack = d; s.params = p
                let fe = width(of: FilmEdgeSection(session: s), offered: railWidth)
                let db = width(of: DateBackSection(session: s), offered: railWidth)
                XCTAssertLessThanOrEqual(fe, railWidth + 0.5, "\(setting) \(e.format) \(e.active): Film Edge \(fe) pt")
                XCTAssertLessThanOrEqual(db, railWidth + 0.5, "\(setting) \(e.format) \(d.face): Date Back \(db) pt")
            }
        }
    }

    func testTheMenuOffersWhatTheEngineHas() {
        XCTAssertEqual(FilmEdgeFormat.allCases.filter(\.isAvailable).map(\.rawValue),
                       ["135", "135_half", "120_645", "120_6x6", "120_6x7", "120_6x8", "120_6x9",
                        "135_xpan", "120_6x12", "120_6x17"])
        XCTAssertEqual(FilmEdgeFormat.allCases.filter { $0.group == .panoramic }.count, 3)
        for f in FilmEdgeFormat.allCases where f.isAvailable {
            XCTAssertNotNil(f.filmCost(.strip), "\(f) has no measured cost")
            XCTAssertNotNil(f.filmCost(.filed), "\(f) has no measured cost")
        }
        inBothLanguages { _ in
            for f in FilmEdgeFormat.allCases {
                XCTAssertFalse(f.title.isEmpty)
                XCTAssertFalse(f.title.contains("…"))
            }
        }
    }

    /// No date on the panoramic formats, nothing but data on 645, all three
    /// on 135 and half frame (answers C1, C7).
    func testFacesFollowTheCamera() {
        for f in FilmEdgeFormat.allCases {
            let faces = DateBackFace.allCases.filter { f.draws($0) }
            switch f {
            case .f135, .f135Half: XCTAssertEqual(faces, [.lcd, .dots, .data])
            case .f645: XCTAssertEqual(faces, [.data])
            default: XCTAssertEqual(faces, [], "\(f) offers a date")
            }
        }
    }

    /// The format menu's content, as PNGs, for looking at.
    func testRenderTheFormatMenu() throws {
        guard let dir = ProcessInfo.processInfo.environment["SPK_RENDER_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_SPK_RENDER_DIR to render")
        }
        inBothLanguages { setting in
            for (name, made) in [("all", { (_: FilmEdgeFormat) in true }),
                                 ("no120", { (f: FilmEdgeFormat) in f.group == .film135 })] {
                let menu = FilmEdgeFormatMenu(selection: .f135, view: .strip, stockName: "Gold 200",
                                              isMade: made, pick: { _ in })
                let r = ImageRenderer(content: menu)
                r.scale = 2
                // A popover proposes its content a size; the renderer's
                // default proposes none, which lays every row out at its ideal.
                r.proposedSize = ProposedViewSize(width: Theme.Metric.edgeFormatMenuWidth, height: nil)
                guard let image = r.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    return XCTFail("no render")
                }
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "format-menu-\(name)-\(setting).png"))
            }
        }
    }
}
