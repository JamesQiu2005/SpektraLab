//  TextFitTests.swift — the 2026-09-28 rules: **no abbreviation anywhere in
//  the interface, and no text runs out of its frame.**
//
//  The user's examples were "Org. Name", a zoom pill reading "100…", and an
//  export page whose labels ran into their pills. These pin the rules where
//  they can be checked without a window: the strings themselves, the columns
//  measured off them, and the logic that shortens a line by whole parts
//  instead of by letters.

import XCTest

@MainActor
final class TextFitTests: XCTestCase {

    // MARK: - no abbreviations

    /// A word cut short and closed with a period. Two shapes: a capitalised
    /// short word ("Org.", "Exp.", "Comp.") anywhere, or any short word whose
    /// period is followed by more of the same sentence ("approx. 3",
    /// "incl. grain"). A sentence's own last word — "…pull-back. The curve…"
    /// — is neither. Proper names their owners write this way are exempt.
    private static let abbreviation = try! NSRegularExpression(
        pattern: #"\b[A-Z][a-z]{1,4}\.(?=\s|$|\))|\b[a-z]{1,6}\.\s+[a-z0-9]"#)
    private static let properNames = ["Rec. 2020"]

    private func abbreviations(in text: String) -> [String] {
        var t = text
        for name in Self.properNames { t = t.replacingOccurrences(of: name, with: "") }
        let range = NSRange(t.startIndex..., in: t)
        return Self.abbreviation.matches(in: t, range: range).compactMap { m in
            Range(m.range, in: t).map { String(t[$0]) }
        }
    }

    /// The pattern itself, against the cases it exists for — so a later edit
    /// to it cannot quietly stop matching anything.
    func testTheAbbreviationPatternCatchesAbbreviations() {
        XCTAssertEqual(abbreviations(in: "Org. Name"), ["Org."])
        XCTAssertEqual(abbreviations(in: "Exp. Comp."), ["Exp.", "Comp."])
        XCTAssertEqual(abbreviations(in: "about approx. 3 stops"), ["approx. 3"])
        XCTAssertEqual(abbreviations(in: "Highlight and shadow pull-back. The curve is fitted again."), [])
        XCTAssertEqual(abbreviations(in: "Color space Rec. 2020"), [])
        // A key named on its own ends a sentence; it is not a cut word.
        XCTAssertEqual(abbreviations(in: "Drop images here, or press ⌘O."), [])
    }

    /// Every label and title in both languages' tables — sentences (captions,
    /// help) are exempt only in that their final period is not an
    /// abbreviation.
    func testNoStringInTheTableIsAbbreviated() {
        for key in S.allCases {
            for text in [key.english, key.simplifiedChinese] {
                XCTAssertEqual(abbreviations(in: text), [], "\(key.rawValue): \"\(text)\"")
            }
        }
    }

    func testTheTabsSayDevelopmentInFull() {
        XCTAssertEqual(S.tabPreDev.english, "Before Development")
        XCTAssertEqual(S.tabPostDev.english, "After Development")
    }

    func testExportNamesAreInFull() {
        XCTAssertEqual(NameToken.originalName.label, "Original Name")
        for t in NameToken.allCases { XCTAssertFalse(t.label.contains("."), t.label) }
        for f in ExportFormat.allCases { XCTAssertFalse(f.shortLabel.contains("DI "), f.shortLabel) }
        XCTAssertEqual(ExportFormat.di.shortLabel, "Digital Intermediate")
        XCTAssertFalse(ExportRecipe.defaults.map(\.name).contains("DI package"))
        XCTAssertEqual(SideUnit.inch.title, "inch")
    }

    /// The built-in recipe shipped as "DI package"; a file still carrying that
    /// exact name reads with the full one, and a name the user chose is kept.
    func testTheShippedDigitalIntermediateNameIsReadInFull() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-textfit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "export-recipes.json")
        let recipes = [
            ExportRecipe(name: "DI package", format: .di, colorSpace: .displayP3),
            ExportRecipe(name: "DI package", format: .jpeg, colorSpace: .displayP3),
            ExportRecipe(name: "My DI package", format: .di, colorSpace: .displayP3),
        ]
        try JSONEncoder().encode(recipes).write(to: url)
        let names = ExportRecipeStore(url: url).recipes.map(\.name)
        XCTAssertEqual(names, ["Digital Intermediate Package", "DI package", "My DI package"])
    }

    // MARK: - columns hold their labels

    /// The export page's label column is measured off its labels, so none of
    /// them can meet its control — in the language and at the scale in use.
    func testTheExportLabelColumnHoldsEveryLabel() {
        let column = ExportPage.labelColumn
        XCTAssertGreaterThanOrEqual(column, Theme.Metric.Export.labelWidth, "narrower than the drawing's column")
        for label in ExportPage.columnLabels {
            let width = Theme.textWidth(label, size: 11)
            XCTAssertLessThanOrEqual(width + 10, column + 0.5,
                                     "\"\(label)\" is \(width) pt and would meet its control in a \(column) pt column")
        }
    }

    func testTextWidthGrowsWithTheString() {
        XCTAssertGreaterThan(Theme.textWidth("Existing File", size: 11), Theme.textWidth("Size", size: 11))
        XCTAssertGreaterThan(Theme.textWidth("Size", size: 12), Theme.textWidth("Size", size: 11))
        XCTAssertEqual(Theme.textWidth("", size: 11), 0)
    }

    // MARK: - a line shortens by whole parts

    func testALineDropsWholePartsFromTheEnd() {
        let status = "DSC03710.ARW  ·  6000×4000  ·  ProPhoto RGB  ·  render 95 ms"
        XCTAssertEqual(FittingLine.candidates(status), [
            "DSC03710.ARW  ·  6000×4000  ·  ProPhoto RGB  ·  render 95 ms",
            "DSC03710.ARW  ·  6000×4000  ·  ProPhoto RGB",
            "DSC03710.ARW  ·  6000×4000",
            "DSC03710.ARW",
        ])
        // The Latitude note's single-spaced separator is the same separator.
        XCTAssertEqual(FittingLine.candidates("Portra 400 · Supra Endura"),
                       ["Portra 400  ·  Supra Endura", "Portra 400"])
        XCTAssertEqual(FittingLine.candidates("decoded"), ["decoded"])
        for line in FittingLine.candidates(status) {
            XCTAssertFalse(line.contains("…"), "a candidate was cut inside a part: \(line)")
        }
    }
}
