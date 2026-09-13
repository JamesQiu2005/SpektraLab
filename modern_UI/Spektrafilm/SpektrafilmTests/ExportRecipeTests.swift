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
        rule.tokens = [.filmStock, .originalName]
        rule.separator = "-"
        XCTAssertEqual(rule.stem(context()), "portra400-_DSC4037")
    }

    func testDimensionsDateAndCounterRender() {
        var rule = NamingRule()
        rule.tokens = [.dimensions]
        XCTAssertEqual(rule.stem(context()), "5451x3634")
        rule.tokens = [.counter]
        XCTAssertEqual(rule.stem(context(counter: 7)), "007")
        rule.tokens = [.date]
        // Fixed instant, so this pins the format rather than today's date.
        XCTAssertEqual(rule.stem(context()).count, 8)
    }

    /// The silent-overwrite case. An empty rule must not produce an empty
    /// filename — every frame would then export to the same file and the
    /// folder would end up with one picture in it.
    func testAnEmptyRuleFallsBackToTheOriginalNameRatherThanNothing() {
        var rule = NamingRule()
        rule.tokens = []
        XCTAssertEqual(rule.stem(context()), "_DSC4037")
        // Same again when every token renders empty.
        rule.tokens = [.filmStock, .printStock]
        let blank = NamingRule.Context(originalName: "frame", filmStock: "", printStock: "",
                                       pixelSize: .zero, counter: 1, date: Date())
        XCTAssertEqual(rule.stem(blank), "frame")
    }

    /// A stock name with a slash in it would otherwise become a directory.
    func testAFilenameCannotCarryAPathSeparator() {
        var rule = NamingRule()
        rule.tokens = [.filmStock]
        let nasty = NamingRule.Context(originalName: "f", filmStock: "kodak/portra:400",
                                       printStock: "p", pixelSize: .zero, counter: 1, date: Date())
        let stem = rule.stem(nasty)
        XCTAssertFalse(stem.contains("/"), stem)
        XCTAssertFalse(stem.contains(":"), stem)
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
        edited.naming.tokens = [.originalName, .counter]
        edited.colorSpace = .sRGB
        store.selected = edited

        let reopened = ExportRecipeStore(url: url)
        XCTAssertNil(reopened.problem)
        let back = try! XCTUnwrap(reopened.recipes.first { $0.id == edited.id })
        XCTAssertEqual(back, edited)
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
