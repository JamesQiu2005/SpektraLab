//  TextFitTests.swift — the 2026-09-28 rule: **no text in the interface is
//  cut to "…", and none runs out of its frame.**
//
//  The user's examples were a zoom pill reading "100…", export labels that ran
//  into their pills, and — at the 130 % interface scale — pill text taller
//  than the pill. These pin the rule where it can be checked without a
//  window: the columns and heights measured off the type, and the logic that
//  shortens a line by whole parts instead of by letters.

import XCTest

@MainActor
final class TextFitTests: XCTestCase {

    // MARK: - names

    /// The built-in recipe shipped as "DI package", then "Digital
    /// Intermediate Package"; a file still carrying either exact name reads
    /// with today's, and a name the user chose is kept.
    func testTheShippedDigitalIntermediateNameIsReadInFull() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-textfit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "export-recipes.json")
        let recipes = [
            ExportRecipe(name: "DI package", format: .di, colorSpace: .displayP3),
            ExportRecipe(name: "Digital Intermediate Package", format: .di, colorSpace: .displayP3),
            ExportRecipe(name: "DI package", format: .jpeg, colorSpace: .displayP3),
            ExportRecipe(name: "My DI package", format: .di, colorSpace: .displayP3),
        ]
        try JSONEncoder().encode(recipes).write(to: url)
        let names = ExportRecipeStore(url: url).recipes.map(\.name)
        XCTAssertEqual(names, ["Digital Intermediate", "Digital Intermediate", "DI package", "My DI package"])
    }

    // MARK: - Settings in Chinese

    /// Every caption Settings shows from another file has its Chinese. The
    /// lookup falls back to English silently, which is how a key typo once
    /// left every one of them in English on a Chinese page.
    func testSettingsNotesHaveChinese() {
        let notes = [Diagnostics.perNodeTimingsNote, Diagnostics.exportJobLogNote,
                     Diagnostics.memoryReserveNote, Diagnostics.memoryCapNote,
                     Diagnostics.diskCacheCapNote, Diagnostics.logDirectoryNote,
                     DiagnosticBundle.fileNamesNote]
            + LogLevelSetting.allCases.map(\.detail)
        for note in notes {
            XCTAssertFalse((SettingsWindow.zh[note] ?? "").isEmpty, "no Chinese for: \(note)")
        }
        for level in LogLevelSetting.allCases {
            XCTAssertFalse((SettingsWindow.logLevelZH[level.label] ?? "").isEmpty, "no Chinese for \(level.label)")
        }
    }

    // MARK: - pills hold their text

    /// A pill is never shorter than a line of the type it holds, at the scale
    /// in use. At 130 % the drawing's heights were, and the words ran out of
    /// the top and bottom of their pills.
    func testControlsAreTallerThanTheirText() {
        XCTAssertGreaterThanOrEqual(Theme.Metric.controlHeight, Theme.lineHeight(size: 10.5) + 2)
        XCTAssertGreaterThanOrEqual(Theme.Metric.Export.rowHeight, Theme.lineHeight(size: 11) + 2)
        XCTAssertGreaterThanOrEqual(Theme.Metric.Export.chipHeight, Theme.lineHeight(size: 11) + 2)
        // And never shorter than the drawing's own.
        XCTAssertGreaterThanOrEqual(Theme.Metric.controlHeight, Theme.Metric.controlHeightDrawn)
        XCTAssertGreaterThanOrEqual(Theme.Metric.Export.rowHeight, Theme.Metric.Export.rowHeightDrawn)
    }

    func testLineHeightGrowsWithTheSize() {
        XCTAssertGreaterThan(Theme.lineHeight(size: 11), Theme.lineHeight(size: 9))
        XCTAssertGreaterThan(Theme.lineHeight(size: 11), Theme.textWidth("", size: 11))
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
