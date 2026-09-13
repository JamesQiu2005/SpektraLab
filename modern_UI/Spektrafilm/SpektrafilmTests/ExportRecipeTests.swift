//  ExportRecipeTests.swift — the export page's model.
//
//  What is worth pinning here is the part that decides *where a file lands
//  and what it is called*, because that is the part whose failures are
//  silent: a naming rule that quietly collapses to one name overwrites a
//  folder of exports one file at a time, and nothing throws.
//
//  The colour-space catalogue is checked against **this machine** rather than
//  against a fixture. That is deliberate: the PRD asked for the list to be
//  read from the system, and a test that asserted a hard-coded list would
//  pass on a machine where the read was broken.

import CoreGraphics
import XCTest

final class ExportRecipeTests: XCTestCase {

    private let source = URL(fileURLWithPath: "/tmp/spk-recipes/_DSC4037.NEF")

    private func context(_ name: String = "_DSC4037", counter: Int = 1) -> NamingRule.Context {
        NamingRule.Context(originalName: name, filmStock: "portra400", printStock: "endura",
                           pixelSize: CGSize(width: 5451, height: 3634), counter: counter,
                           date: Date(timeIntervalSince1970: 1_757_000_000))
    }

    // MARK: - naming

    func testTheDefaultRuleIsTheNamingTheAppAlreadyHad() {
        XCTAssertEqual(NamingRule().stem(context()), "_DSC4037_portra400_endura")
    }

    func testTokenOrderAndSeparatorAreHonoured() {
        var rule = NamingRule()
        rule.toggle(.printStock)                     // two tokens left
        rule.move(.filmStock, before: .originalName)
        rule.separator = "-"
        XCTAssertEqual(rule.stem(context()), "portra400-_DSC4037")
    }

    /// `notes.md` is the authority on how many there are: "Four Naming options,
    /// Original Name, Film, Print, Date are provided and user can only choose
    /// between these four". Two more used to exist, and a test that only
    /// checked the ones it knew about would not have noticed them staying.
    func testThereAreExactlyFourNamingTokens() {
        XCTAssertEqual(NameToken.allCases.map(\.rawValue),
                       ["originalName", "filmStock", "printStock", "date"])
        XCTAssertEqual(NamingRule().chips.count, 4)
    }

    func testDateRenders() {
        var rule = NamingRule()
        rule.toggle(.date)                                  // on
        rule.toggle(.originalName)
        rule.toggle(.filmStock)
        XCTAssertEqual(rule.chosen, [.printStock, .date])
        rule.toggle(.printStock)
        XCTAssertEqual(rule.chosen, [.date])
        // Fixed instant, so this pins the format rather than today's date.
        let expected = DateFormatter()
        expected.dateFormat = "yyyyMMdd"
        expected.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(rule.stem(context()), expected.string(from: context().date))
        XCTAssertEqual(rule.stem(context()).count, 8)
    }

    /// The silent-overwrite case. A rule whose every token renders empty must
    /// not produce an empty filename — every frame would then export to the
    /// same file and the folder would end up with one picture in it.
    func testAnEmptyResultFallsBackToTheOriginalNameRatherThanNothing() {
        var rule = NamingRule()
        rule.toggle(.originalName)
        let blank = NamingRule.Context(originalName: "frame", filmStock: "", printStock: "",
                                       pixelSize: .zero, counter: 1, date: Date())
        XCTAssertEqual(rule.stem(blank), "frame")
    }

    /// "at least one must be selected" — refused by the model rather than by
    /// the chip that draws it, so no view can route around it.
    func testTheLastSelectedTokenCannotBeSwitchedOff() {
        var rule = NamingRule()
        rule.toggle(.filmStock)
        rule.toggle(.printStock)
        XCTAssertEqual(rule.chosen, [.originalName])
        rule.toggle(.originalName)
        XCTAssertEqual(rule.chosen, [.originalName], "the last token on must stay on")
        // And switching another back on is still allowed.
        rule.toggle(.date)
        XCTAssertEqual(rule.chosen, [.originalName, .date])
    }

    /// The row's order *is* the output order, which is the whole reason
    /// `order` and `tokens` are separate lists.
    func testDraggingATokenReordersTheFilename() {
        var rule = NamingRule()
        XCTAssertEqual(rule.stem(context()), "_DSC4037_portra400_endura")
        rule.move(.printStock, before: .originalName)
        XCTAssertEqual(rule.chips.first, .printStock)
        XCTAssertEqual(rule.stem(context()), "endura__DSC4037_portra400")
        // Dragging a token *forwards* takes it there and does not stop one
        // short, which is the off-by-one when the target's index shifts as
        // the dragged token leaves the list.
        rule.resetOrder()
        XCTAssertEqual(rule.chips, [.originalName, .filmStock, .printStock, .date])
        rule.move(.date, before: .filmStock)
        XCTAssertEqual(rule.chips, [.originalName, .date, .filmStock, .printStock])
        // And a token already immediately before its target does not move.
        rule.move(.date, before: .filmStock)
        XCTAssertEqual(rule.chips, [.originalName, .date, .filmStock, .printStock])
    }

    /// A stock name with a slash in it would otherwise become a directory.
    func testAFilenameCannotCarryAPathSeparator() {
        var rule = NamingRule()
        rule.toggle(.originalName)
        rule.toggle(.printStock)
        let nasty = NamingRule.Context(originalName: "f", filmStock: "kodak/portra:400",
                                       printStock: "p", pixelSize: .zero, counter: 1, date: Date())
        let stem = rule.stem(nasty)
        XCTAssertFalse(stem.contains("/"), stem)
        XCTAssertFalse(stem.contains(":"), stem)
    }

    // MARK: - the format and its depth

    /// "8 bit" is not a free-standing choice: `ExportFormat` is the container
    /// and the depth together, so the depth pill has to move the format — and
    /// has to say when it cannot.
    func testTheFormatCarriesItsBitDepth() {
        XCTAssertEqual(ExportFormat.jpeg.bitDepth, 8)
        XCTAssertEqual(ExportFormat.png.bitDepth, 8)
        XCTAssertEqual(ExportFormat.tiff.bitDepth, 16)
        XCTAssertEqual(ExportFormat.di.bitDepth, 16)

        XCTAssertEqual(ExportFormat.withDepth(16, like: .png), .tiff)
        XCTAssertEqual(ExportFormat.withDepth(8, like: .tiff), .png)
        XCTAssertNil(ExportFormat.withDepth(16, like: .jpeg), "JPEG has no 16-bit form")
        XCTAssertNil(ExportFormat.withDepth(8, like: .di), "the DI package is one thing at one depth")

        XCTAssertTrue(ExportFormat.png.depthIsChoosable)
        XCTAssertTrue(ExportFormat.tiff.depthIsChoosable)
        XCTAssertFalse(ExportFormat.jpeg.depthIsChoosable)
        XCTAssertFalse(ExportFormat.di.depthIsChoosable)
    }

    // MARK: - what the destination could not hold

    /// RFC-018 §6: "a saturated frame into sRGB is worth a word, a frame that
    /// fits is worth silence" — so the silence is the part to pin. A page that
    /// warns on every export is a page whose warnings are read as noise.
    func testAFrameThatFitsSaysNothing() {
        let proof = SoftProof(image: blankImage(), target: CGColorSpaceCreateDeviceRGB(),
                              targetName: "sRGB", exportPixelSize: CGSize(width: 10, height: 10),
                              compressedFraction: 0, clippedFraction: 0, movedFraction: 0, isPlaceholder: false)
        XCTAssertTrue(ProofCaveat.lines(for: proof).isEmpty)
        // And just under the threshold is still silence.
        let quiet = SoftProof(image: blankImage(), target: CGColorSpaceCreateDeviceRGB(),
                              targetName: "sRGB", exportPixelSize: CGSize(width: 10, height: 10),
                              compressedFraction: 0.00009, clippedFraction: 0.00009,
                              movedFraction: 0, isPlaceholder: false)
        XCTAssertTrue(ProofCaveat.lines(for: quiet).isEmpty)
    }

    func testAPictureThatDoesNotFitSaysSoAndSaysWhatItLost() {
        let rolled = SoftProof(image: blankImage(), target: CGColorSpaceCreateDeviceRGB(),
                               targetName: "sRGB", exportPixelSize: CGSize(width: 10, height: 10),
                               compressedFraction: 0.04, clippedFraction: 0, movedFraction: 0, isPlaceholder: false)
        let lines = ProofCaveat.lines(for: rolled)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].isWarning, "a rolled-in pixel kept its detail; it is not a warning")
        XCTAssertTrue(lines[0].text.contains("4 %"), lines[0].text)

        // Clipping is the one that lost something, so it is the one drawn in
        // the accent.
        let cut = SoftProof(image: blankImage(), target: CGColorSpaceCreateDeviceRGB(),
                            targetName: "sRGB", exportPixelSize: CGSize(width: 10, height: 10),
                            compressedFraction: 0, clippedFraction: 0.02, movedFraction: 0, isPlaceholder: false)
        XCTAssertEqual(ProofCaveat.lines(for: cut).map(\.isWarning), [true])
    }

    private func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    // MARK: - where it lands

    func testSubfolderAndFixedFolderAreApplied() {
        var r = ExportRecipe()
        XCTAssertEqual(r.directory(for: source).path, "/tmp/spk-recipes/_prints")
        r.subfolder = "  "        // whitespace is "none", not a folder called " "
        XCTAssertEqual(r.directory(for: source).path, "/tmp/spk-recipes")
        r.folder = .fixed(path: "/tmp/elsewhere")
        r.subfolder = "out"
        XCTAssertEqual(r.directory(for: source).path, "/tmp/elsewhere/out")
    }

    func testTheExtensionFollowsTheFormat() throws {
        var r = ExportRecipe()
        for (format, ext) in [(ExportFormat.jpeg, "jpg"), (.png, "png"), (.tiff, "tif"), (.di, "tif")] {
            r.format = format
            let url = try XCTUnwrap(r.destination(for: source, context: context()))
            XCTAssertEqual(url.pathExtension, ext)
        }
    }

    /// The three existing-file policies, against a directory that really has
    /// the file in it — the whole point of the policy is what it does when
    /// the file is there, so a test on an empty directory checks nothing.
    func testTheExistingFilePolicies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var r = ExportRecipe()
        r.format = .tiff
        r.folder = .fixed(path: dir.path)
        r.subfolder = ""
        let ctx = context()
        let first = try XCTUnwrap(r.destination(for: source, context: ctx))
        XCTAssertEqual(first.lastPathComponent, "_DSC4037_portra400_endura.tif")

        // Nothing on disk yet: every policy gives the plain name.
        for policy in ExistingFilePolicy.allCases {
            r.existing = policy
            XCTAssertEqual(r.destination(for: source, context: ctx), first, "\(policy)")
        }

        try Data("x".utf8).write(to: first)

        r.existing = .overwrite
        XCTAssertEqual(r.destination(for: source, context: ctx), first)

        r.existing = .skip
        XCTAssertNil(r.destination(for: source, context: ctx),
                     "skip must decline to name a destination when the file is there")

        r.existing = .addSuffix
        let second = try XCTUnwrap(r.destination(for: source, context: ctx))
        XCTAssertEqual(second.lastPathComponent, "_DSC4037_portra400_endura-1.tif")
        // And it keeps counting rather than settling on -1 forever.
        try Data("x".utf8).write(to: second)
        let third = try XCTUnwrap(r.destination(for: source, context: ctx))
        XCTAssertEqual(third.lastPathComponent, "_DSC4037_portra400_endura-2.tif")
    }

    /// `directory(for:)` must not create anything. The export creates it, so
    /// that the failure has somewhere to be reported; a describing call that
    /// left folders behind would scatter empty `_prints` directories around
    /// just from opening the sheet.
    func testDescribingADestinationCreatesNoDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-nocreate-\(UUID().uuidString)")
        var r = ExportRecipe()
        r.folder = .fixed(path: dir.path)
        r.subfolder = "sub"
        _ = r.directory(for: source)
        _ = r.destination(for: source, context: context())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "describing a destination must not create it")
    }

    // MARK: - colour space

    /// Read from the system, as the PRD asked. Asserted against what this
    /// machine reports rather than a fixture, so a broken read fails here.
    func testTheCatalogueResolvesEveryProfileItOffers() {
        XCTAssertFalse(ColorSpaceCatalog.all.isEmpty)
        for entry in ColorSpaceCatalog.all {
            XCTAssertNotNil(entry.space.cgColorSpace, "\(entry.name) does not resolve")
            XCTAssertFalse(entry.name.isEmpty)
        }
        // The five guaranteed ones are always there.
        XCTAssertEqual(ColorSpaceCatalog.builtIns.count, 5)
        XCTAssertTrue(ColorSpaceCatalog.all.contains { $0.name == "Display P3" })
        XCTAssertTrue(ColorSpaceCatalog.all.contains { $0.name == "sRGB" })
    }

    /// The system list and the built-ins overlap — "Display P3" and
    /// "Adobe RGB (1998)" are installed as files too. A picker with the same
    /// name in it twice is a picker nobody trusts.
    func testTheCatalogueHasNoDuplicateNames() {
        let names = ColorSpaceCatalog.all.map { $0.name.lowercased() }
        XCTAssertEqual(names.count, Set(names).count, "duplicate names: \(names)")
    }

    func testTheCatalogueReadsInstalledProfilesAndNotOnlyTheBuiltIns() {
        // If the ColorSync read silently returned nothing, `all` would be
        // exactly the built-ins. That is the failure this catches.
        XCTAssertGreaterThan(ColorSpaceCatalog.all.count, ColorSpaceCatalog.builtIns.count,
                             "no installed profiles were read from the system")
    }

    func testEveryOfferedSpaceCanBeNamedBack() {
        for entry in ColorSpaceCatalog.all {
            XCTAssertEqual(ColorSpaceCatalog.name(for: entry.space), entry.name)
        }
    }

    /// The DI package's channels are densities, not colours, and the `.cube`
    /// beside it indexes exactly those numbers. So it offers no profile, and
    /// resolves to none.
    func testTheDIPackageTakesNoColourSpace() {
        var r = ExportRecipe()
        r.format = .di
        XCTAssertFalse(r.format.takesColorSpace)
        let (space, fellBack) = r.resolvedColorSpace()
        XCTAssertNil(space, "the DI route must not be handed a rendering profile")
        XCTAssertFalse(fellBack)
    }

    /// A profile that was installed when the recipe was saved and is not
    /// there now: the export falls back and *says* it fell back, rather than
    /// failing or silently writing an untagged file.
    func testAMissingProfileFallsBackAndReportsIt() {
        var r = ExportRecipe()
        r.format = .tiff
        r.colorSpace = .installed(path: "/nowhere/does-not-exist.icc")
        XCTAssertNil(r.colorSpace.cgColorSpace)
        let (space, fellBack) = r.resolvedColorSpace()
        XCTAssertNotNil(space)
        XCTAssertTrue(fellBack, "a fallback the user is not told about is a silent colour change")
    }

    // MARK: - the file the recipes live in

    @MainActor
    func testRecipesRoundTripThroughTheJSONFile() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipes-\(UUID().uuidString)/export-recipes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ExportRecipeStore(url: url)
        XCTAssertNil(store.problem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the store must seed its file on first run")

        var edited = try! XCTUnwrap(store.selected)
        edited.name = "Wechat"
        edited.subfolder = "wechat"
        edited.naming.toggle(.printStock)
        edited.naming.move(.date, before: .filmStock)
        edited.colorSpace = .sRGB
        edited.format = .tiff
        edited.outputSize = .custom(width: 2048, height: 1365)
        edited.openWith = OpenWith(path: "/Applications/Preview.app")
        store.selected = edited

        let reopened = ExportRecipeStore(url: url)
        XCTAssertNil(reopened.problem)
        let back = try! XCTUnwrap(reopened.recipes.first { $0.id == edited.id })
        XCTAssertEqual(back, edited)
    }

    /// A file written by an earlier build: six naming tokens, no `order`, and
    /// none of the fields this round added. It must decode — a recipe file is
    /// a document a person keeps, and a decode that threw over one absent key
    /// would take every recipe in it with it and show the built-in defaults
    /// instead of their own settings.
    @MainActor
    func testARecipeFileFromAnEarlierBuildStillLoads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "export-recipes.json")
        let old = """
        [{"id":"6B1F0C1A-0000-4000-8000-000000000001","name":"Old","format":"PNG 8-bit",
          "colorSpace":{"builtIn":{"_0":"kCGColorSpaceSRGB"}},
          "folder":{"fixed":{"path":"/tmp/old"}},"subfolder":"out",
          "naming":{"separator":"-","tokens":["filmStock","dimensions","counter"]},
          "existing":"overwrite","quality":0.8}]
        """
        try Data(old.utf8).write(to: url)

        let store = ExportRecipeStore(url: url)
        XCTAssertNil(store.problem, "an older file is not a broken file")
        let r = try XCTUnwrap(store.recipes.first)
        XCTAssertEqual(r.name, "Old")
        XCTAssertEqual(r.folder, .fixed(path: "/tmp/old"))
        XCTAssertEqual(r.existing, .overwrite)
        // The two tokens that no longer exist are dropped; the one that does
        // survives, and the row is the four it always is.
        XCTAssertEqual(r.naming.chosen, [.filmStock])
        XCTAssertEqual(r.naming.chips.count, 4)
        // And the fields it predates take their defaults rather than throwing.
        XCTAssertEqual(r.outputSize, .original)
        XCTAssertNil(r.openWith)
    }

    /// The PRD's "separated json" means a file a person can hand-edit, which
    /// means a file a person can break. Losing the ability to export over a
    /// typo would be the worse failure, so it falls back and reports.
    @MainActor
    func testAnUnreadableFileFallsBackToTheDefaultsAndSaysSo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "export-recipes.json")
        try Data("{ not json at all".utf8).write(to: url)

        let store = ExportRecipeStore(url: url)
        XCTAssertEqual(store.recipes, ExportRecipe.defaults)
        XCTAssertNotNil(store.problem, "a broken file must be reported, not swallowed")
        // And the broken file is left alone rather than overwritten, so the
        // user can still fix their typo.
        XCTAssertEqual(try Data(contentsOf: url), Data("{ not json at all".utf8))
    }

    @MainActor
    func testAnEmptyListFallsBackRatherThanLeavingNothingToSelect() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "export-recipes.json")
        try Data("[]".utf8).write(to: url)
        let store = ExportRecipeStore(url: url)
        XCTAssertEqual(store.recipes, ExportRecipe.defaults)
        XCTAssertNotNil(store.selected)
    }

    /// The last recipe cannot be removed: the sheet would have nothing to
    /// show and no way back.
    @MainActor
    func testTheLastRecipeCannotBeRemoved() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipes-\(UUID().uuidString)/export-recipes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ExportRecipeStore(url: url)
        while store.recipes.count > 1 { store.remove(store.recipes[0]) }
        XCTAssertEqual(store.recipes.count, 1)
        store.remove(store.recipes[0])
        XCTAssertEqual(store.recipes.count, 1, "the store must always have something to select")
        XCTAssertNotNil(store.selected)
    }

    @MainActor
    func testDuplicateMakesANewIdentityAndSelectsIt() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "spk-recipes-\(UUID().uuidString)/export-recipes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ExportRecipeStore(url: url)
        let original = store.selected!
        store.duplicate(original)
        XCTAssertNotEqual(store.selected?.id, original.id)
        XCTAssertEqual(store.selected?.format, original.format)
        XCTAssertTrue(store.selected?.name.hasSuffix("copy") ?? false)
    }
}
