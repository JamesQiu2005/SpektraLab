//  export_selftest.swift — the export's own arithmetic and its saved recipes, checked on this Mac.
//
//      tools/selftest.sh                # with the scheduler's checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  Two things an export gets wrong quietly, with no engine and no page needed to show it:
//
//  - **the recipes** (`Model/ExportRecipe.swift`, `Services/ExportRecipeStore.swift`): the four
//    containers and the four colour spaces, a recipe's name, what an older build's kept recipe reads
//    as, and the store's file — written whole, read back the same, never fatal when it cannot be read;
//  - **the plan** (`Engine/ExportPlan.swift`): how large the original is decoded for the size a recipe
//    names, what the file's pixels then are, and what the engine is told of the film's size when the
//    host has made the cut. A file a few pixels off its label, or a cropped frame developed as though
//    it filled the whole film, would be a picture nobody asked for.
//
//  - **the file** (`Engine/ExportWriter.swift`): every container in every colour space, written by
//    ImageIO on this Mac and read back — its kind, its pixels, its depth, the profile it carries, the
//    camera's metadata it brought along and the orientation it left behind. PNG and TIFF keep every
//    value they are handed, and are held to that.
//
//  Compiled with those sources and `Geometry.swift` alone: no engine, no UIKit.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks against a
//  rule broken on purpose, one at a time, and requires each run to fail.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Checker {
    var passed = 0
    var failed = 0
    var quiet = false
    mutating func expect(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passed += 1 } else {
            failed += 1
            if !quiet { print("  FAILED: \(what())") }
        }
    }
}

/// What is wrong with a list of recipes as a store may hold it; empty when nothing is.
func faults(of recipes: [ExportRecipe]) -> [String] {
    var out: [String] = []
    if recipes.isEmpty { out.append("no recipe at all") }
    if Set(recipes.map(\.id)).count != recipes.count { out.append("two recipes with one id") }
    for r in recipes {
        if r.size == .preview { out.append("\(r.name): the preview size kept as a recipe's") }
        if !(1...100).contains(r.quality) { out.append("\(r.name): quality \(r.quality)") }
        if let t = r.title {
            if t.isEmpty || t != t.trimmingCharacters(in: .whitespaces) || t.count > ExportRecipe.longestTitle || t.contains("\n") {
                out.append("\"\(t)\": not a name a chip holds")
            }
        }
    }
    let named = recipes.compactMap(\.title)
    if Set(named).count != named.count { out.append("two recipes saved under one name") }
    return out
}

/// A name as the words a chip may show of it (`ExportRecipe.words`), held to what the recipes' row
/// needs of them: joined they are the name, none is a part of a word, and a mark between two words
/// is never left at a chip's edge by itself. `words` is the rule under test, so a broken one can be
/// put in its place.
func wordChecks(_ c: inout Checker, words: (String) -> [String]) {
    let built = ExportRecipe.Format.allCases.flatMap { f in ExportRecipe.Colour.allCases.map { ExportRecipe(format: f, colour: $0).name } }
    let names = built + ["＋ New", "Web", "Print lab", "Instagram  portrait", "小红书 竖图", "朋友圈九宫格", " led by a space", "ends with one ", "·", ""]
    for name in names {
        let w = words(name)
        c.expect(w.joined() == name, "\"\(name)\": its words, joined, are the name (\(w))")
        c.expect(w.allSatisfy { !$0.isEmpty }, "\"\(name)\": no word of it is empty")
        // A word ends where a space ends, or the name does: never inside a run of letters. Walked
        // only as far as the words lie inside the name: a rule that hands back an empty word, or
        // more than the name holds, has failed the two lines above.
        var end = name.startIndex
        for word in w.dropLast() {
            guard let next = name.index(end, offsetBy: word.count, limitedBy: name.endIndex), next > name.startIndex, next < name.endIndex else { break }
            end = next
            let before = name[name.index(before: end)], after = name[end]
            let latin = { (ch: Character) in ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-") }
            c.expect(!(latin(before) && latin(after)), "\"\(name)\": no word is cut (\(w))")
        }
        if name.contains(where: { $0.isLetter || $0.isNumber }) {
            c.expect(w.allSatisfy { $0.contains(where: { $0.isLetter || $0.isNumber }) }, "\"\(name)\": a mark is never a word by itself (\(w))")
        }
    }
    c.expect(words("JPEG · Display P3") == ["JPEG ", "· Display ", "P3"], "the mark between a format and its colour leads the colour")
    c.expect(words("TIFF 16-bit · ProPhoto") == ["TIFF ", "16-bit ", "· ProPhoto"], "\"16-bit\" is one word, and the chip that starts off the page can say \"TIFF 16-bit\"")
    c.expect(words("＋ New") == ["＋ New"], "the row's last chip is whole or not there")
    c.expect(words("Print lab") == ["Print ", "lab"] && words("Web") == ["Web"] && words("").isEmpty, "a saved name breaks at its spaces, and nowhere else")
}

@MainActor
func recipeChecks(_ c: inout Checker, scratch: URL) {
    // The owner's list, 2026-10-08: HEIF, JPG, PNG, TIFF; sRGB, Adobe RGB, Display P3, ProPhoto RGB.
    c.expect(Set(ExportRecipe.Format.allCases.map(\.fileExtension)) == ["jpg", "heic", "png", "tif"], "the four containers, by their extensions")
    c.expect(ExportRecipe.Colour.allCases.map(\.engineName) == ["sRGB", "Adobe RGB (1998)", "Display P3", "ProPhoto RGB"],
             "the four colour spaces, by the engine's own names for them, in the order they are offered")
    c.expect(ExportRecipe.Format.allCases.map(\.bitDepth) == [8, 8, 8, 16], "JPEG, HEIF and PNG are 8 bits a channel, TIFF 16")
    c.expect(ExportRecipe.Format.allCases.filter(\.takesQuality) == [.jpeg, .heif], "quality is JPEG's and HEIF's")
    for f in ExportRecipe.Format.allCases {
        for k in ExportRecipe.Colour.allCases {
            let r = ExportRecipe(format: f, colour: k)
            c.expect(r.name == f.title + " · " + k.rawValue && r.title == nil, "\(f.rawValue) in \(k.rawValue) is a recipe, named for what it makes")
            c.expect(r.mayBand == (k == .proPhoto && f != .tiff), "\(r.name): only ProPhoto in 8 bits is said to band")
        }
    }
    c.expect(ExportRecipe(format: .tiff, colour: .proPhoto).name == "TIFF 16-bit · ProPhoto", "a TIFF's name says its depth")
    c.expect(ExportRecipe(title: "Print lab", format: .tiff).name == "Print lab", "a saved name is the recipe's name")
    c.expect(faults(of: ExportRecipe.builtIn).isEmpty && ExportRecipe.builtIn.count == 5, "the app's own recipes: five, each with an id of its own")
    c.expect(ExportRecipe.builtIn.first.map { $0.format == .jpeg && $0.colour == .sRGB } == true, "the first is JPEG in sRGB, the file free writes")
    c.expect(Set(ExportRecipe.builtIn.map(\.format)) == Set(ExportRecipe.Format.allCases), "one of the app's own for each container")

    // A name as it is kept.
    c.expect(ExportRecipe.cleanTitle("  Web  ") == "Web" && ExportRecipe.cleanTitle(" \n ") == nil, "a name is trimmed, and nothing is no name")
    c.expect(ExportRecipe.cleanTitle(String(repeating: "x", count: 60))?.count == ExportRecipe.longestTitle, "a name no longer than a chip holds")
    c.expect(ExportRecipe.cleanTitle("two\nlines") == "two lines", "a name is one line")

    // A name as the words a chip shows of it while it is partly off the page.
    wordChecks(&c, words: ExportRecipe.words(of:))

    // The same file, whatever it is called.
    var a = ExportRecipe(format: .png, colour: .sRGB), b = ExportRecipe(title: "Other", format: .png, colour: .sRGB)
    b.quality = 60
    c.expect(a.sameSettings(as: b), "a PNG has no quality to differ by, nor does a name change what is made")
    a.format = .jpeg; b.format = .jpeg
    c.expect(!a.sameSettings(as: b), "two JPEGs of different quality are different files")
    b.quality = a.quality; b.destination = .share
    c.expect(!a.sameSettings(as: b), "the same file to another place is another recipe")

    // What an older build kept (`AppSettings.recipe`, before a recipe had an id or a name).
    let old = #"{"format":"TIFF","size":{"longEdge":{"_0":2048}},"colour":"ProPhoto","quality":90,"destination":"Files"}"#
    let read = try? JSONDecoder().decode(ExportRecipe.self, from: Data(old.utf8))
    c.expect(read?.format == .tiff && read?.size == .longEdge(2048) && read?.colour == .proPhoto && read?.quality == 90
             && read?.destination == .files && read?.title == nil, "a recipe kept by a build before recipes had names reads as it was")
    // A window's recipe for the Photos library, which this app does not have: it saves to Files.
    let photos = #"{"format":"HEIF","colour":"Display P3","quality":80,"destination":"Photos"}"#
    let toFiles = try? JSONDecoder().decode(ExportRecipe.self, from: Data(photos.utf8))
    c.expect(toFiles?.destination == .files && toFiles?.format == .heif && toFiles?.quality == 80,
             "a recipe kept for Photos saves to Files, and keeps the rest")
    c.expect(ExportRecipe().destination == .files && ExportRecipe.Destination.allCases == [.files, .share],
             "a new recipe saves to Files; Files and Share are the places offered")
    let odd = #"{"format":"WEBP","colour":"Rec. 2020","quality":400,"title":"   "}"#
    let lenient = try? JSONDecoder().decode(ExportRecipe.self, from: Data(odd.utf8))
    c.expect(lenient?.format == .jpeg && lenient?.colour == .displayP3 && lenient?.quality == 100 && lenient?.title == nil,
             "a value this build does not know takes the default, and does not lose the rest")
    for r in ExportRecipe.builtIn + [ExportRecipe(title: "Mine", format: .heif, size: .full, colour: .adobeRGB, quality: 80, destination: .share)] {
        let back = (try? JSONEncoder().encode(r)).flatMap { try? JSONDecoder().decode(ExportRecipe.self, from: $0) }
        c.expect(back == r, "\(r.name) is written and read back the same")
    }

    // The store.
    let file = scratch.appendingPathComponent("recipes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = ExportRecipeStore(url: file)
    c.expect(store.recipes == ExportRecipe.builtIn && store.problem == nil, "a store with no file has the app's own recipes")
    c.expect(!FileManager.default.fileExists(atPath: file.path), "and writes nothing until something is saved")
    var mine = ExportRecipe(format: .heif, size: .preview, colour: .adobeRGB, quality: 85, destination: .files)
    let saved = store.add(mine, named: "  Web  ")
    c.expect(saved.title == "Web" && saved.id != mine.id && store.recipes.last == saved && store.recipes.count == 6, "a recipe is saved under its name, at the end, with an id of its own")
    c.expect(saved.size != .preview, "the preview size is a frame's state and is not saved in a recipe")
    c.expect(store.add(mine, named: "Web").title == "Web 2" && store.add(mine, named: "Web").title == "Web 3", "a name already taken gets a number")
    c.expect(store.add(mine, named: "").title == nil, "saved with no name, a recipe is named for what it makes")
    c.expect(faults(of: store.recipes).isEmpty, "the list holds: \(faults(of: store.recipes))")
    mine.size = .longEdge(2048)
    c.expect(store.saved(as: mine) == nil, "settings no recipe has light no chip")
    mine.size = saved.size
    c.expect(store.saved(as: mine)?.id == saved.id, "settings a recipe has light its chip")
    var changed = saved
    changed.format = .tiff; changed.colour = .proPhoto; changed.title = "ignored"; changed.id = UUID()
    store.update(saved.id, with: changed)
    c.expect(store.recipe(saved.id)?.format == .tiff && store.recipe(saved.id)?.title == "Web" && store.recipes[5].id == saved.id,
             "an update changes what a recipe makes, and neither its name nor its place")
    store.rename(saved.id, to: "Web 2")
    c.expect(store.recipe(saved.id)?.title == "Web 2 2" || store.recipe(saved.id)?.title == "Web 4", "a rename onto a taken name gets a number too")
    store.rename(saved.id, to: "Lab")
    store.rename(saved.id, to: "Lab")
    c.expect(store.recipe(saved.id)?.title == "Lab", "a rename to its own name leaves it")
    store.rename(saved.id, to: " ")
    c.expect(store.recipe(saved.id)?.title == nil && store.recipe(saved.id)?.name == "TIFF 16-bit · ProPhoto", "a name emptied gives the recipe back the name of what it makes")
    c.expect(faults(of: store.recipes).isEmpty, "the list still holds: \(faults(of: store.recipes))")

    // Its file.
    let again = ExportRecipeStore(url: file)
    c.expect(again.recipes == store.recipes && again.problem == nil, "the file is read back as it was written")
    c.expect(store.remove(saved.id) && store.recipe(saved.id) == nil, "a recipe is removed")
    for r in store.recipes.dropLast() { store.remove(r.id) }
    c.expect(store.recipes.count == 1 && !store.canRemove && !store.remove(store.recipes[0].id) && store.recipes.count == 1,
             "the last recipe is never removed")
    c.expect(ExportRecipeStore(url: file).recipes == store.recipes, "and the file says the same")

    try? Data("{ not json".utf8).write(to: file)
    let broken = ExportRecipeStore(url: file)
    c.expect(broken.recipes == ExportRecipe.builtIn && broken.problem != nil, "a file that cannot be read leaves the app's own recipes, and says so")
    c.expect((try? String(contentsOf: file, encoding: .utf8)) == "{ not json", "and the file is left as it was found")
    try? Data("[]".utf8).write(to: file)
    c.expect(ExportRecipeStore(url: file).recipes == ExportRecipe.builtIn, "a file with no recipe in it is not a sheet with nothing to choose")
    let twice = #"[{"id":"5B1D0001-0000-4000-8000-53504B524543","format":"PNG"},{"id":"5B1D0001-0000-4000-8000-53504B524543","format":"TIFF"},{"format":"HEIF","size":{"preview":{}}}]"#
    try? Data(twice.utf8).write(to: file)
    let cleaned = ExportRecipeStore(url: file)
    c.expect(cleaned.recipes.count == 2 && cleaned.recipes[0].format == .png && faults(of: cleaned.recipes).isEmpty,
             "a file edited by hand: one chip an id, and no preview size: \(faults(of: cleaned.recipes))")
    c.expect(ExportRecipeStore(url: nil).recipes == ExportRecipe.builtIn, "a store that keeps nothing has the app's own")

    // 2026-10-20: a list kept from before, the app's own at the 12 MP they began at, moves to Full once;
    // a recipe the user named keeps its size, and a built-in set to 12 MP afterwards stays there.
    let suite = "spk.export-selftest.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    var kept = ExportRecipe.builtIn.map { r -> ExportRecipe in var r = r; r.size = .megapixels(12); return r }
    kept.append(ExportRecipe(title: "Post", format: .jpeg, size: .megapixels(12), colour: .sRGB, quality: 90, destination: .share))
    try? JSONEncoder().encode(kept).write(to: file)
    let moved = ExportRecipeStore(url: file, defaults: defaults)
    c.expect(moved.recipes.dropLast().allSatisfy { $0.size == .full } && moved.recipes.last?.size == .megapixels(12),
             "the app's own recipes kept at 12 MP move to Full; the user's own keeps 12 MP")
    c.expect(ExportRecipeStore(url: file).recipes == moved.recipes, "and the file says so")
    moved.update(ExportRecipe.builtIn[0].id, with: { var r = ExportRecipe.builtIn[0]; r.size = .megapixels(12); return r }())
    c.expect(ExportRecipeStore(url: file, defaults: defaults).recipe(ExportRecipe.builtIn[0].id)?.size == .megapixels(12),
             "once only: a built-in set to 12 MP afterwards stays at 12 MP")
}

// MARK: - the plan

/// The plan under test, so a broken one can be put in its place.
struct PlanRules {
    var name = "the app's"
    var make: (ExportPlan.Ask, (PixelSize) -> PixelSize?) -> ExportPlan = { ExportPlan.make($0, canvas: $1) }

    static let broken: [PlanRules] = [
        PlanRules(name: "the film's size left as the uncut frame's under the host's cut") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas); p.filmFormatMM = nil; return p
        },
        PlanRules(name: "the size worked out on the uncut picture") { ask, canvas in
            var whole = ask; whole.photo = .default
            let wrong = ExportPlan.make(whole, canvas: canvas)
            var p = ExportPlan.make(ask, canvas: canvas)
            guard ask.film == nil, !ask.photo.isIdentity else { return p }
            (p.decodeLongEdge, p.decoded) = (wrong.decodeLongEdge, wrong.decoded)
            let cut = HostCut.map(ask.photo, imageSize: CGSize(width: wrong.decoded.width, height: wrong.decoded.height)).size
            p.frame = PixelSize(width: Int(cut.width), height: Int(cut.height))
            (p.engineCanvas, p.output) = (p.frame, p.frame)
            return p
        },
        PlanRules(name: "the device's cap ignored") { ask, canvas in
            var free = ask; free.capMegapixels = 0
            return ExportPlan.make(free, canvas: canvas)
        },
        PlanRules(name: "a decode larger than the picture") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas)
            if case .megapixels(let mp) = ask.size, mp > ask.source.megapixels {
                p.decodeLongEdge = ask.source.longEdge * 2
                p.decoded = PixelSize(width: ask.source.width * 2, height: ask.source.height * 2)
            }
            return p
        },
        PlanRules(name: "the film's half turn forgotten") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas); p.turnsAfter = 0; p.engineCanvas = p.output; return p
        },
        PlanRules(name: "a cut too small for the engine's film sent to it all the same") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas)
            if p.engineCuts { p.engineCuts = false; p.cut = ask.photo; p.filmFormatMM = 1 }
            return p
        },
        PlanRules(name: "a phone's own 12 MP photo resampled to twelve million pixels") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas)
            if case .megapixels(let mp) = ask.size, ask.source.megapixels > mp, ask.source.megapixels <= mp * ExportPlan.nominalSlack {
                p.decoded = ask.source.scaled(toMegapixels: mp); p.decodeLongEdge = p.decoded.longEdge
                (p.frame, p.engineCanvas, p.output) = (p.decoded, p.decoded, p.decoded)
            }
            return p
        },
        PlanRules(name: "a 48 MP photo at 12 MP by a scale of 0.496, not every second pixel") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas)
            if case .megapixels(let mp) = ask.size, ask.film == nil, ask.photo.isIdentity, ask.source.megapixels > mp * 3.9 {
                p.decoded = ask.source.scaled(toMegapixels: mp); p.decodeLongEdge = p.decoded.longEdge
                (p.frame, p.engineCanvas, p.output) = (p.decoded, p.decoded, p.decoded)
            }
            return p
        },
        PlanRules(name: "the film laid round the whole picture, not round its framing") { ask, canvas in
            var p = ExportPlan.make(ask, canvas: canvas)
            if let film = ask.film, let whole = canvas(p.decoded) {
                p.output = whole
                p.engineCanvas = film.hostTurns % 2 == 0 ? whole : PixelSize(width: whole.height, height: whole.width)
            }
            return p
        },
    ]
}

/// A film that adds a fifth to the width and two fifths to the height of its
/// framing: nothing like a real one, and enough to tell a canvas from a frame.
func toyCanvas(_ framing: PixelSize) -> PixelSize? {
    PixelSize(width: Int((Double(framing.width) * 1.2).rounded()), height: Int((Double(framing.height) * 1.4).rounded()))
}

func planChecks(_ c: inout Checker, _ rules: PlanRules) {
    let phone48 = PixelSize(width: 8064, height: 6048), phone12 = PixelSize(width: 4032, height: 3024)
    func ask(_ source: PixelSize, _ size: ExportRecipe.Size, photo: Geometry = .default, film: ExportPlan.Ask.Film? = nil,
             mm: Double = 36, cap: Double = 48) -> ExportPlan.Ask {
        ExportPlan.Ask(source: source, photo: photo, film: film, filmFormatMM: mm, size: size, capMegapixels: cap)
    }
    func plan(_ a: ExportPlan.Ask) -> ExportPlan { rules.make(a, toyCanvas) }
    func cropped(_ x: Double, _ y: Double, _ w: Double, _ h: Double, turns: Int = 0, angle: Double = 0) -> Geometry {
        var g = Geometry()
        g.crop = CropRect(x: x, y: y, width: w, height: h)
        g.quarterTurns = turns
        g.angle = angle
        return g
    }
    /// What every plan holds to, whatever was asked.
    func holds(_ a: ExportPlan.Ask, _ p: ExportPlan, _ what: String) {
        c.expect(p.decoded.longEdge <= a.source.longEdge && p.decoded.megapixels <= a.source.megapixels + 1e-9,
                 "\(what): nothing is decoded larger than the picture (\(p.decoded.text) of \(a.source.text))")
        c.expect((p.decodeLongEdge ?? a.source.longEdge) == p.decoded.longEdge, "\(what): the decode is the long edge asked of the decoder")
        c.expect(abs(p.decoded.aspect - a.source.aspect) < 0.002, "\(what): the decode has the picture's shape")
        let whole = CGSize(width: p.decoded.width, height: p.decoded.height)
        if let cut = p.cut {
            let made = HostCut.map(cut, imageSize: whole).size
            c.expect(Int(made.width) == p.frame.width && Int(made.height) == p.frame.height, "\(what): the frame handed over is the host's cut of the decode")
            c.expect(!p.engineCuts, "\(what): one of the two cuts, not both")
        } else {
            c.expect(p.frame == p.decoded, "\(what): with no cut by the host the engine is handed the decode whole")
        }
        if a.film == nil {
            c.expect(p.engineCanvas == p.output && p.turnsAfter == 0, "\(what): a frame with no film is not turned by the host")
            // The same micrometres a pixel as the uncut frame at this size.
            let pitch = (p.filmFormatMM ?? a.filmFormatMM) / Double(p.frame.longEdge), uncut = a.filmFormatMM / Double(p.decoded.longEdge)
            c.expect(abs(pitch / uncut - 1) < 1e-9, "\(what): the film keeps its size under the cut (\(pitch * 1000) µm a pixel, \(uncut * 1000) uncut)")
            c.expect(ExportPlan.filmFormatRange.contains(p.filmFormatMM ?? a.filmFormatMM), "\(what): a film size the engine takes")
            let out = a.photo.outputSize(for: whole)
            c.expect(abs(Double(p.output.width) - out.width) <= 1 && abs(Double(p.output.height) - out.height) <= 1,
                     "\(what): the file is the picture as it is cut (\(p.output.text), the cut \(Int(out.width)) x \(Int(out.height)))")
        } else if let film = a.film {
            let framing = HostCut.map(film.framing, imageSize: whole).size
            let canvas = toyCanvas(PixelSize(width: Int(framing.width), height: Int(framing.height)))
            c.expect(p.output == canvas, "\(what): the file is the film round the framing")
            c.expect(p.cut == film.hostCut && p.filmFormatMM == nil && !p.engineCuts, "\(what): under a film edge the cut is the gate, and the gate's millimetres decide")
            let turned = film.hostTurns % 2 == 0 ? p.output : PixelSize(width: p.output.height, height: p.output.width)
            c.expect(p.engineCanvas == turned && p.turnsAfter == ((film.hostTurns % 4) + 4) % 4, "\(what): the engine makes the film turned back, and the host turns it forward")
        }
        c.expect(!ExportPlan.exceeds(max(p.decoded.megapixels, p.engineCanvas.megapixels), a.capMegapixels),
                 "\(what): nothing over this device's cap (\(p.decoded.megapixels) MP decoded, \(p.engineCanvas.megapixels) rendered, cap \(a.capMegapixels))")
        switch a.size {
        case .megapixels(let mp):
            c.expect(p.output.megapixels <= mp * ExportPlan.nominalSlack + 0.01, "\(what): no more than the size named (\(p.output.megapixels) MP for \(mp))")
        case .longEdge(let edge):
            c.expect(p.output.longEdge <= edge + 1, "\(what): no longer than the edge named (\(p.output.longEdge) for \(edge))")
        case .shortEdge(let edge):
            c.expect(min(p.output.width, p.output.height) <= edge + 1, "\(what): no longer than the short edge named (\(p.output) for \(edge))")
        case .full, .preview: break
        }
    }

    // A host's own photos, whole.
    var a = ask(phone48, .megapixels(12))
    var p = plan(a)
    holds(a, p, "48 MP at 12 MP")
    c.expect(p.decodeLongEdge == 4032 && p.output == PixelSize(width: 4032, height: 3024) && p.cut == nil && p.filmFormatMM == nil && !p.isCapped,
             "a phone's 48 MP photo at 12 MP is every second pixel of it — its camera's own 12 MP — and cut by nobody, got \(p.decodeLongEdge.map(String.init) ?? "whole") \(p.output.text)")
    // A short edge (2026-10-20): the picture's short side at the pixels named, never more than it has.
    a = ask(phone48, .shortEdge(1080)); p = plan(a)
    holds(a, p, "48 MP at a short edge of 1,080")
    c.expect(min(p.output.width, p.output.height) <= 1080 && min(p.output.width, p.output.height) >= 1070 && !p.isCapped,
             "a short edge of 1,080 makes a file 1,080 px on its short side, near enough to be even: \(p.output.text)")
    a = ask(phone48, .shortEdge(99_999)); p = plan(a)
    c.expect(p.output == phone48 && p.decodeLongEdge == nil, "a short edge past the original's is the original, never larger: \(p.output.text)")
    a = ask(phone48, .longEdge(99_999)); p = plan(a)
    c.expect(p.output == phone48 && p.decodeLongEdge == nil, "so is a long edge past it: \(p.output.text)")
    // A 12 MP ceiling holds an edge past it (`ExportPlan.Ask.capMegapixels`).
    a = ask(phone48, .longEdge(8000), cap: 12); p = plan(a)
    c.expect(p.output.megapixels <= 12 * ExportPlan.nominalSlack && p.isCapped, "an edge past a 12 MP ceiling is held to it, and says so: \(p.output.text)")
    a = ask(PixelSize(width: 9504, height: 6336), .full, cap: 120); p = plan(a)
    c.expect(p.output == PixelSize(width: 9504, height: 6336) && !p.isCapped, "a 61 MP original goes out whole under the memory's ceiling: \(p.output.text)")
    a = ask(phone48, .megapixels(24)); p = plan(a)
    holds(a, p, "48 MP at 24 MP")
    c.expect(p.decodeLongEdge.map { $0 % 8 == 0 } ?? false && p.decoded.width % 2 == 0 && p.decoded.height % 2 == 0 && abs(p.output.megapixels - 24) < 0.2,
             "a size with no whole division is decoded where both sides are whole, even pixels: \(p.decoded.text)")
    a = ask(phone12, .megapixels(12)); p = plan(a)
    holds(a, p, "12 MP at 12 MP")
    c.expect(p.decodeLongEdge == nil && p.output == phone12, "a phone's own 12 MP photo is its own size at 12 MP, not resampled to twelve million pixels")
    a = ask(phone48, .full); p = plan(a)
    holds(a, p, "48 MP at full size")
    c.expect(p.decodeLongEdge == nil && p.output == phone48 && !p.isCapped, "a phone's own 48 MP photo at full size is every pixel of it, under a 48 MP cap")
    a = ask(phone12, .megapixels(48)); p = plan(a)
    holds(a, p, "12 MP at 48 MP")
    c.expect(p.output == phone12 && p.decodeLongEdge == nil, "a size larger than the picture is the picture's own: nothing is enlarged")
    a = ask(phone48, .longEdge(2048)); p = plan(a)
    holds(a, p, "48 MP at 2,048 px")
    c.expect(p.output == PixelSize(width: 2048, height: 1536), "a long edge is the file's long edge, got \(p.output.text)")
    a = ask(PixelSize(width: 11648, height: 8736), .full); p = plan(a)
    holds(a, p, "a 102 MP file at full size")
    c.expect(p.isCapped && abs(p.output.megapixels - 48) < 0.2, "a file past this device's cap is decoded at the cap, and says so (\(p.output.megapixels) MP)")
    a = ask(PixelSize(width: 11648, height: 8736), .megapixels(12)); p = plan(a)
    holds(a, p, "a 102 MP file at 12 MP")
    c.expect(!p.isCapped && abs(p.output.megapixels - 12) < 0.1, "at a size under the cap the cap is not what set it")
    a = ask(PixelSize(width: 2400, height: 1800), .preview); p = plan(a)
    holds(a, p, "the preview copy")
    c.expect(p.decodeLongEdge == 2400 && p.output == PixelSize(width: 2400, height: 1800), "an original that is away goes out at its preview copy's size, asked of the decoder as that")

    // A photo's own crop: cut by the host, the film's size following the cut.
    let half = cropped(0.25, 0, 0.5, 1)
    a = ask(phone48, .full, photo: half); p = plan(a)
    holds(a, p, "half of a 48 MP frame at full size")
    c.expect(p.cut == half && p.frame == PixelSize(width: 4032, height: 6048) && !p.engineCuts, "a crop is the host's cut, so the export can band")
    c.expect(p.filmFormatMM.map { abs($0 - 27) < 1e-9 } ?? false, "half the width of a 36 mm frame, upright, is 27 mm of film on its long edge, got \(p.filmFormatMM ?? 0)")
    a = ask(phone48, .megapixels(12), photo: half); p = plan(a)
    holds(a, p, "half of a 48 MP frame at 12 MP")
    c.expect(abs(p.output.megapixels - 12) < 0.05 && p.decoded.megapixels > 23, "12 MP of a cropped frame is 12 MP of the crop, decoded as large as that takes (\(p.output.text) from \(p.decoded.text))")
    a = ask(phone48, .longEdge(2048), photo: half); p = plan(a)
    holds(a, p, "half of a 48 MP frame at 2,048 px")
    c.expect(abs(p.output.longEdge - 2048) <= 1, "a long edge is the cut's long edge, got \(p.output.text)")
    a = ask(phone48, .full, photo: cropped(0, 0, 1, 1, turns: 1)); p = plan(a)
    holds(a, p, "a frame turned a quarter")
    c.expect(p.cut != nil && p.filmFormatMM == nil && p.output == PixelSize(width: 6048, height: 8064), "a turn alone is the host's too, and leaves the film its size")
    a = ask(phone48, .megapixels(12), photo: cropped(0.1, 0.2, 0.6, 0.5, turns: 3, angle: 2.5)); p = plan(a)
    holds(a, p, "a frame cropped, turned and straightened")
    a = ask(phone12, .full, photo: cropped(0.4, 0.4, 0.1, 0.1), mm: 17); p = plan(a)
    holds(a, p, "a tenth of a 17 mm frame")
    c.expect(p.engineCuts && p.cut == nil && p.filmFormatMM == nil && p.frame == phone12 && p.output.width < 420,
             "a cut the engine's film cannot follow (1.7 mm) is left to the engine, whole")
    for k in 0..<40 {
        // Cuts of every sort, at every size.
        let u = Double(k) / 39
        let g = cropped(0.05 + 0.3 * u, 0.4 * (1 - u), 0.25 + 0.4 * u, 0.3 + 0.25 * (1 - u), turns: k % 4, angle: k % 3 == 0 ? 0 : (u - 0.5) * 8)
        let sizes: [ExportRecipe.Size] = [.full, .megapixels(12), .megapixels(24), .longEdge(2048), .longEdge(1200)]
        a = ask(k % 2 == 0 ? phone48 : phone12, sizes[k % sizes.count], photo: g, mm: [36.0, 60, 24, 17][k % 4])
        holds(a, plan(a), "cut \(k)")
    }

    // A film edge: the cut is the gate, and the file the film round it.
    let framing = cropped(0, 0.0556, 1, 0.8889)                     // 3:2 out of 4:3
    for turns in 0..<4 {
        var back = framing
        back.quarterTurns = (4 - turns) % 4
        let film = ExportPlan.Ask.Film(framing: framing, hostCut: back, hostTurns: turns)
        for size in [ExportRecipe.Size.full, .megapixels(12), .longEdge(2048)] {
            a = ask(phone48, size, film: film); p = plan(a)
            holds(a, p, "a film turned \(turns), \(size.title)")
        }
        a = ask(phone48, .megapixels(12), film: film); p = plan(a)
        c.expect(abs(p.output.megapixels - 12) < 0.1, "12 MP of a frame in its film is 12 MP of film, got \(p.output.megapixels)")
        a = ask(phone48, .full, film: film); p = plan(a)
        c.expect(p.isCapped && p.engineCanvas.megapixels <= 48 * ExportPlan.nominalSlack, "the film round a 48 MP picture is past the cap, and is held to it (\(p.engineCanvas.megapixels) MP)")
    }
}

// MARK: - the file

/// The writer under test, so a broken one can be put in its place.
struct WriterRules {
    var name = "the app's"
    var write: (CGImage, ExportRecipe.Format, Int, URL, URL?) throws -> ExportWriter.Written = {
        try ExportWriter.write($0, format: $1, quality: $2, to: $3, metadataFrom: $4)
    }

    static let broken: [WriterRules] = [
        WriterRules(name: "the picture's profile lost on the way to the file") { image, format, quality, url, source in
            let plain = image.copy(colorSpace: CGColorSpaceCreateDeviceRGB()) ?? image
            return try ExportWriter.write(plain, format: format, quality: quality, to: url, metadataFrom: source)
        },
        WriterRules(name: "the camera's metadata left behind") { image, format, quality, url, _ in
            try ExportWriter.write(image, format: format, quality: quality, to: url, metadataFrom: nil)
        },
        WriterRules(name: "every file a JPEG, whatever it is called") { image, format, quality, url, source in
            guard format != .jpeg, format != .tiff else { return try ExportWriter.write(image, format: format, quality: quality, to: url, metadataFrom: source) }
            var w = try ExportWriter.write(image, format: .jpeg, quality: quality, to: url, metadataFrom: source)
            w.url = url
            return w
        },
    ]
}

/// A picture of known values: a ramp in each channel, no two neighbours alike.
func ramp(_ space: CGColorSpace, bits: Int, width: Int = 96, height: Int = 64) -> CGImage? {
    let bytes = bits / 8 * 4
    var data = Data(count: width * height * bytes)
    data.withUnsafeMutableBytes { raw in
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * bytes
                let v = [x * 65535 / (width - 1), y * 65535 / (height - 1), (x + y) % 7 * 9000 + 1234, 65535]
                for k in 0..<4 {
                    if bits == 16 { raw.storeBytes(of: UInt16(v[k]).littleEndian, toByteOffset: i + k * 2, as: UInt16.self) }
                    else { raw.storeBytes(of: UInt8(v[k] >> 8), toByteOffset: i + k, as: UInt8.self) }
                }
            }
        }
    }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let order = bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0
    return CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4, bytesPerRow: width * bytes, space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: order | CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)
}

/// One pixel's three values as the file holds them, whatever layout the decoder hands back; nil
/// for a layout this does not know, which fails the check that asked.
func values(_ image: CGImage, _ x: Int, _ y: Int) -> [Int]? {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
    let bits = image.bitsPerComponent, step = image.bitsPerPixel / 8, wide = bits / 8
    guard bits == 8 || bits == 16, step >= 3 * wide, !image.bitmapInfo.contains(.byteOrder32Little) else { return nil }
    let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo) && step == 4 * wide
    let at = y * image.bytesPerRow + x * step + (alphaFirst ? wide : 0)
    return (0..<3).map { k in
        let i = at + k * wide
        if bits == 8 { return Int(p[i]) }
        return image.bitmapInfo.contains(.byteOrder16Little) ? Int(p[i + 1]) << 8 | Int(p[i]) : Int(p[i]) << 8 | Int(p[i + 1])
    }
}

func writerChecks(_ c: inout Checker, _ rules: WriterRules, scratch: URL) {
    let folder = scratch.appendingPathComponent("export-selftest-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // A camera's file, with what a camera writes in it, on its side.
    let camera = folder.appendingPathComponent("camera.jpg")
    if let image = ramp(CGColorSpace(name: CGColorSpace.sRGB)!, bits: 8),
       let made = CGImageDestinationCreateWithURL(camera as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.004,
                                             kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifLensModel: "Selftest 35mm",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:10:08 01:00:55"] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SPEKTRA", kCGImagePropertyTIFFModel: "Selftest",
                                             kCGImagePropertyTIFFSoftware: "A camera",
                                             // How a HEIC stores its pixels; an reference device's export carried these
                                             // into a JPEG until 2026-10-15, and one reader would not take it.
                                             kCGImagePropertyTIFFTileWidth: 768, kCGImagePropertyTIFFTileLength: 704] as [CFString: Any],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.23, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 121.47, kCGImagePropertyGPSLongitudeRef: "E"] as [CFString: Any],
        ]
        CGImageDestinationAddImage(made, image, properties as CFDictionary)
        c.expect(CGImageDestinationFinalize(made), "the test's own camera file is written")
    }

    let spaces: [(ExportRecipe.Colour, CFString, [String])] = [
        (.sRGB, CGColorSpace.sRGB, ["sRGB"]), (.adobeRGB, CGColorSpace.adobeRGB1998, ["Adobe RGB"]),
        (.displayP3, CGColorSpace.displayP3, ["P3"]), (.proPhoto, CGColorSpace.rommrgb, ["ROMM", "ProPhoto"]),
    ]
    for format in ExportRecipe.Format.allCases {
        for (colour, name, words) in spaces {
            let what = "\(format.rawValue) in \(colour.rawValue)"
            guard let space = CGColorSpace(name: name), let image = ramp(space, bits: format.bitDepth) else {
                c.expect(false, "\(what): the test's own picture"); continue
            }
            let url = folder.appendingPathComponent("out-\(colour.rawValue).\(format.fileExtension)")
            guard let written = try? rules.write(image, format, 90, url, camera) else { c.expect(false, "\(what): written"); continue }
            c.expect(written.url == url && written.bytes > 0 && written.size == PixelSize(width: image.width, height: image.height),
                     "\(what): the file is where it was asked, at the picture's size")
            guard let file = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let found = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any] else {
                c.expect(false, "\(what): read back"); continue
            }
            let kind = CGImageSourceGetType(file).flatMap { UTType($0 as String) }
            c.expect(kind?.conforms(to: ExportWriter.type(format)) == true, "\(what): the container is the one named, got \(kind?.identifier ?? "none")")
            c.expect((found[kCGImagePropertyDepth] as? NSNumber)?.intValue == format.bitDepth, "\(what): \(format.bitDepth) bits a channel")
            let profile = found[kCGImagePropertyProfileName] as? String ?? ""
            c.expect(words.contains { profile.contains($0) }, "\(what): the file carries its colour space's profile, got \"\(profile)\"")
            c.expect(((found[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1, "\(what): the picture is upright, and the file says so")
            let exif = found[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = found[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let gps = found[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            c.expect((exif[kCGImagePropertyExifFNumber] as? NSNumber).map { abs($0.doubleValue - 2.8) < 0.01 } ?? false
                     && (exif[kCGImagePropertyExifExposureTime] as? NSNumber).map { abs($0.doubleValue - 0.004) < 0.0001 } ?? false
                     && (exif[kCGImagePropertyExifLensModel] as? String) == "Selftest 35mm", "\(what): the exposure and the lens travel")
            c.expect((tiff[kCGImagePropertyTIFFMake] as? String) == "SPEKTRA" && (tiff[kCGImagePropertyTIFFModel] as? String) == "Selftest",
                     "\(what): the camera's name travels")
            // The source's coding tiles are the source's: a JPEG saying TileWidth/TileLength is
            // describing tiles it does not have (the owner's reference device, 2026-10-15: the one
            // export ChatGPT would not read, sized for a HEIC's 768 x 704 tiles).
            let sourceTIFF = (CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(camera as CFURL, nil)!, 0, nil)
                              as? [CFString: Any])?[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            c.expect(sourceTIFF[kCGImagePropertyTIFFTileWidth] as? Int == 768 && sourceTIFF[kCGImagePropertyTIFFTileLength] as? Int == 704,
                     "the test's own camera file carries its coding tiles, so the check below can fire")
            let tiles = ((tiff[kCGImagePropertyTIFFTileWidth] as? NSNumber)?.intValue, (tiff[kCGImagePropertyTIFFTileLength] as? NSNumber)?.intValue)
            if format == .heif {
                // A HEIC's tiles are its own and true of it: its encoder's numbers, never the source's.
                c.expect(tiles.0 != 768 || tiles.1 != 704, "\(what): the source's coding tiles do not travel into the export")
            } else {
                c.expect(tiles.0 == nil && tiles.1 == nil, "\(what): the source's coding tiles do not travel into the export")
            }
            c.expect((tiff[kCGImagePropertyTIFFSoftware] as? String) == "SpektraLab", "\(what): the software named is this app")
            c.expect((gps[kCGImagePropertyGPSLatitude] as? NSNumber).map { abs($0.doubleValue - 31.23) < 0.01 } ?? false, "\(what): the place travels")
            if !format.takesQuality, let back = CGImageSourceCreateImageAtIndex(file, 0, nil) {
                // PNG and TIFF keep every value.
                var same = back.width == image.width && back.height == image.height
                for (x, y) in [(0, 0), (95, 0), (0, 63), (95, 63), (17, 5), (60, 41)] where same {
                    guard let a = values(image, x, y), let b = values(back, x, y) else { same = false; break }
                    same = a == b
                }
                c.expect(same, "\(what): the file's values are the picture's own, every one")
            }
        }
    }
    // Asked for a depth the picture is not at, the writer refuses: nothing is reduced behind anyone's back.
    if let sixteen = ramp(CGColorSpace(name: CGColorSpace.sRGB)!, bits: 16) {
        let url = folder.appendingPathComponent("wrong.jpg")
        var refused = false
        do { _ = try ExportWriter.write(sixteen, format: .jpeg, quality: 90, to: url) } catch ExportWriter.Failure.depth { refused = true } catch {}
        c.expect(refused && !FileManager.default.fileExists(atPath: url.path), "a 16-bit picture is not written as an 8-bit file: the depth is made by the transform")
    }
    c.expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).allSatisfy { !$0.contains(".partial-") },
             "nothing half-written is left beside the files")
}

/// Lists a store must never hold, each for `faults(of:)` to name.
func brokenLists() -> [(String, [ExportRecipe])] {
    let one = ExportRecipe.builtIn[0]
    var preview = one; preview.size = .preview
    var loud = one; loud.quality = 140
    var long = ExportRecipe.builtIn[1]; long.title = String(repeating: "n", count: ExportRecipe.longestTitle + 1)
    var padded = ExportRecipe.builtIn[1]; padded.title = " Web"
    var lineA = ExportRecipe.builtIn[1], lineB = ExportRecipe.builtIn[2]
    lineA.title = "Web"; lineB.title = "Web"
    return [("no recipe", []), ("one id twice", [one, one]), ("the preview size saved", [preview]), ("a quality past 100", [loud]),
            ("a name longer than a chip", [long]), ("a name with a space before it", [padded]), ("one name twice", [lineA, lineB])]
}

@main
struct ExportSelfTest {
    @MainActor
    static func main() {
        let scratch = FileManager.default.temporaryDirectory
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let lists = brokenLists()
            for (name, list) in lists {
                if faults(of: list).isEmpty { print("  NOT CAUGHT: \(name)") } else { caught += 1 }
            }
            let rules = PlanRules.broken
            for rule in rules {
                var c = Checker(quiet: true)
                planChecks(&c, rule)
                if c.failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            let writers = WriterRules.broken
            for rule in writers {
                var c = Checker(quiet: true)
                writerChecks(&c, rule, scratch: scratch)
                if c.failed == 0 { print("  NOT CAUGHT: \(rule.name)") } else { caught += 1 }
            }
            // A name's words, broken four ways: cut inside a word, the mark left by itself, a letter
            // lost, and the name never broken at all (the chip that showed no words).
            let splitters: [(String, (String) -> [String])] = [
                ("a name cut inside its words", { name in stride(from: 0, to: name.count, by: 3).map { String(name.dropFirst($0).prefix(3)) } }),
                ("the mark between two words left a word of its own", { name in
                    name.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element }
                }),
                ("a name that loses its spaces", { name in name.split(separator: " ").map(String.init) }),
                ("a name never broken into words", { name in name.isEmpty ? [] : [name] }),
            ]
            for (name, split) in splitters {
                var c = Checker(quiet: true)
                wordChecks(&c, words: split)
                if c.failed == 0 { print("  NOT CAUGHT: \(name)") } else { caught += 1 }
            }
            let total = lists.count + rules.count + writers.count + splitters.count
            print("export self-test: \(caught) of \(total) broken rules caught")
            exit(caught == total ? 0 : 1)
        }
        var c = Checker()
        recipeChecks(&c, scratch: scratch)
        planChecks(&c, PlanRules())
        writerChecks(&c, WriterRules(), scratch: scratch)
        print("export checks: \(c.passed) passed, \(c.failed) failed")
        exit(c.failed == 0 ? 0 : 1)
    }
}
