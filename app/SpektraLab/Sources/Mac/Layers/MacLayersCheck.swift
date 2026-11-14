//  MacLayersCheck.swift — the 图层 panel driven and checked in the running app (LAYERS-SPEC §11; traps 33, 34).
//
//  Two things, both a debug build's:
//
//  **Drive steps** (`MacLayersDrive.steps`, beside `MacLibraryDriver`'s under `--mac-drive`): each calls what a
//  click calls — 合成 on the chosen pictures, a row picked, an eye, Balance dragged, 摆放 opened, moved and
//  closed, an exposure swapped, removed and filled, Export pressed — so the real window can be walked and
//  captured (`--capture-window`). `layers.state` writes what the panel holds to the console.
//
//  **`--layers-check [--out DIR]`** (with `--library real --import DIR`, under a scratch `CFFIXED_USER_HOME`): a
//  double made of two photographs in the order they were picked, opened as a page takes it, and walked:
//    1. the order kept (R6, G1); the same photograph twice starts with its top flipped (G8);
//    2. the panel's rows, Balance's place and the pick, read from the page's session as the panel reads them;
//    3. **the canvas against the export** (trap 33): the page's develop and the file Export writes, at one size;
//    4. one exposure alone is another picture than the double, and the other's (R9, G3);
//    5. 摆放: a drag develops, Done is one step of Undo, Cancel is none (R5, G6, G7);
//    6. an emptied layer: the panel's refusal and the Export service's are the same words (R10, G2).
//  Exit 0 when every step did what it should. Trap 34's `batchExporting` is the 1.x app's; here an export reads
//  the library's frame as it stands when its item is reached, and no step above runs under one.

#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import UIKit

@MainActor
enum MacLayersDrive {
    /// The frame the develop page shows, and its session.
    static func open(_ model: AppServices) -> (id: LibraryFrame.ID, session: OpenFrameSession)? {
        guard case .develop(let id)? = MacShellPath.develop(model.router.path), let session = model.openSession(id) else { return nil }
        return (id, session)
    }

    static func steps(model: AppServices, store: any MacLibraryData, browser: MacLibraryBrowser) -> [(String, @MainActor () -> Void)] {
        let stage = LayersStage.shared
        let actions = MacLibraryActions.shared
        func pick(_ row: LayerPick) -> (String, @MainActor () -> Void) {
            ("layer." + row.key, { open(model)?.session.pick(row: row) })
        }
        func subject(_ o: (id: LibraryFrame.ID, session: OpenFrameSession)) -> ArrangeSubject? {
            stage.arranging(o.id).map { ArrangeSubject(session: o.session, model: model, frameID: o.id, pick: $0) }
        }
        func balance(_ s: Double) -> (String, @MainActor () -> Void) {
            ("balance.\(Int(s * 100))", {
                guard let o = open(model), let from = o.session.double?.balance else { return }
                // A drag: down, eight values on the way, up.
                model.balanceDrag(o.id, .began, to: from)
                for i in 1...8 { model.balanceDrag(o.id, .changed, to: from + (s - from) * Double(i) / 8) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { model.balanceDrag(o.id, .ended, to: s) }
            })
        }
        return [
            ("double.make", { actions.makeDouble(browser.picked(in: store.images), store: store, model: model) }),
            ("pair.make.picked", { actions.makePair(browser.picked(in: store.images), store: store, model: model) }),
            // The second exposure's sheet: the first photograph that is not the one it began with, created.
            ("double.second", {
                guard let first = actions.secondExposure?.first,
                      let second = model.library.photographs(oldestFirst: false).first(where: { $0.id != first }) else { return }
                actions.makeDouble(from: first, with: second.id, model: model)
            }),
            ("double.mirror", { if let first = actions.secondExposure?.first { actions.makeDouble(from: first, with: first, model: model) } }),
            // A second row chosen with ⌘, as a click would: the pick order is the clicks'.
            ("select.add.first", { if let row = store.images.first { browser.click(row.id, command: true, shift: false, in: store.images) } }),
            ("select.add.next", {
                guard let f = browser.focus, let i = store.images.firstIndex(where: { $0.id == f }), store.images.indices.contains(i + 1) else { return }
                browser.click(store.images[i + 1].id, command: true, shift: false, in: store.images)
            }),
            ("select.add.previous", {
                guard let f = browser.focus, let i = store.images.firstIndex(where: { $0.id == f }), i > 0 else { return }
                browser.click(store.images[i - 1].id, command: true, shift: false, in: store.images)
            }),
            pick(.film), pick(.exposure(.top)), pick(.exposure(.bottom)), pick(.frame(.left)), pick(.frame(.right)),
            ("layers.fold", { DevelopPanelPrefs.shared.layersCollapsed.toggle() }),
            ("step.format", { open(model)?.session.pageNavigation.step = .format }),
            ("step.film", { open(model)?.session.pageNavigation.step = .filmAndPaper }),
            ("eye.top", { if let o = open(model) { model.showAlone(o.id, LayerRules.eyeTapped(.top, alone: o.session.alone)) } }),
            ("eye.bottom", { if let o = open(model) { model.showAlone(o.id, LayerRules.eyeTapped(.bottom, alone: o.session.alone)) } }),
            balance(0.3), balance(0.5), balance(0.7),
            ("arrange.open", { MacShellBar.shared.develop?.crop() }),
            ("arrange.drag", {
                guard let o = open(model), let s = subject(o), let p = s.placement else { return }
                s.began()
                s.write(s.dragged(s.zoomed(p, by: 1.6), by: CGSize(width: 0.25, height: -0.15)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { s.ended() }
            }),
            ("arrange.done", { stage.arranging = nil }),
            ("double.swap", { if let o = open(model) { model.swapDouble(o.id) } }),
            ("double.remove.top", { if let o = open(model) { model.removeDouble(o.id, .top) } }),
            ("double.flip.top", { if let o = open(model) { model.flipDouble(o.id, .top) } }),
            ("layer.ask", { if let o = open(model) { stage.asking = .init(frame: o.id, pick: o.session.layerPick) } }),
            ("layer.fill", {
                guard let o = open(model), let asking = stage.asking, case .exposure(let position) = asking.pick,
                      let used = o.session.double,
                      let photo = model.library.photographs(oldestFirst: false).first(where: { p in
                          !DoubleExposure.Position.allCases.contains { used[$0]?.frame == p.id } })
                        ?? model.library.photographs(oldestFirst: false).first else { return }
                model.replaceDouble(o.id, position, with: photo.id)
                stage.asking = nil
            }),
            ("pair.remove.right", {
                if let o = open(model) { model.changePair(o.id) { piece, look in piece.fill(.right, with: nil, look: &look.params) } }
            }),
            ("export", { MacShellBar.shared.develop?.export() }),
            ("dismiss", { stage.refused = nil; stage.asking = nil; actions.secondExposure = nil }),
            ("undo", { _ = open(model)?.session.undo() }),
            ("layers.state", {
                guard let o = open(model) else { NSLog("layers state: no page"); return }
                let has: (UUID) -> Bool = { model.library.frame($0) != nil }
                let rows = LayerRules.rows(o.session.layerPiece, alone: o.session.alone, has: has)
                NSLog("layers state: rows %@ picked %@ alone %@ balance %@ arranging %@ refusal %@ surface %@ undo %d",
                      rows.map { "\($0.pick.key)=\($0.name)\($0.shareText.map { " " + $0 } ?? "")\($0.isEmpty ? " (empty)" : "")" }.joined(separator: " | "),
                      o.session.layerPick.key, o.session.alone.map { "\($0)" } ?? "-",
                      o.session.double?.balance.map { String(format: "%.2f", $0) } ?? "-",
                      stage.arranging(o.id)?.key ?? "-", LayerRules.refusal(o.session.layerPiece, has: has) ?? "-",
                      "\(o.session.pageNavigation.surface)", o.session.canUndo ? 1 : 0)
            }),
        ]
    }
}

@MainActor
enum MacLayersCheck {
    private struct Step: Encodable { var name: String; var ok: Bool; var detail: String; var seconds: Double }

    static func run(_ model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--layers-check") else { return }
        var out = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/layers-check", isDirectory: true)
        if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count { out = URL(fileURLWithPath: arguments[i + 1], isDirectory: true) }
        Task { await walk(model, out: out) }
    }

    private static func walk(_ model: AppServices, out: URL) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var steps: [Step] = []
        var clock = Date()
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            steps.append(Step(name: name, ok: ok, detail: detail, seconds: Date().timeIntervalSince(clock)))
            print("layers-check: \(ok ? "ok  " : "FAIL") \(name) -- \(detail)")
            clock = Date()
        }
        defer {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(steps).write(to: out.appendingPathComponent("layers-check.json"))
            print("layers-check: done, \(steps.filter(\.ok).count) of \(steps.count) as they should be")
            exit(steps.allSatisfy(\.ok) && !steps.isEmpty ? 0 : 1)
        }
        let has: (UUID) -> Bool = { model.library.frame($0) != nil }

        let photos = await settled(model)
        guard photos.count >= 2 else { return step("two photographs", false, "the library has \(photos.count)") }
        // Picked against the library's order: the later in the grid first.
        let grid = model.library.grid().flatMap(\.frames).map(\.id)
        let byGrid = photos.sorted { (grid.firstIndex(of: $0.id) ?? .max) < (grid.firstIndex(of: $1.id) ?? .max) }
        let first = byGrid[1], second = byGrid[0]
        step("two photographs", true, "\(first.fileName) picked first, then \(second.fileName)")

        // 1. The order kept; the mirror starts flipped.
        var order = PickOrder<UUID>()
        order.follow([first.id]); order.follow([first.id, second.id])
        let picked = order.ordered(byGrid.map(\.id))
        guard let id = model.makeDouble(picked[0], picked[1], keepsOrder: true), let made = model.library.frame(id)?.double else {
            return step("made in the order picked", false, "makeDouble returned nothing")
        }
        step("made in the order picked (R6)", made[.bottom]?.frame == first.id && made[.top]?.frame == second.id && made.origin == nil,
             "bottom \(model.library.frame(made[.bottom]?.frame ?? UUID())?.fileName ?? "-"), top \(model.library.frame(made[.top]?.frame ?? UUID())?.fileName ?? "-")")
        if let mirror = model.makeDouble(first.id, first.id, beginsWithFirst: true), let m = model.library.frame(mirror)?.double {
            step("the same photograph twice starts with its top flipped (G8)", m[.top]?.placement.flipped == true && m[.bottom]?.placement.flipped == false,
                 "top flipped \(m[.top]?.placement.flipped ?? false), bottom flipped \(m[.bottom]?.placement.flipped ?? true)")
            model.remove([mirror])
        } else {
            step("the same photograph twice starts with its top flipped (G8)", false, "the mirror double was not made")
        }

        // 2. The page, and what the panel reads from it.
        let session = model.session(for: id)
        session.enter()
        session.open()
        guard await developedOnPage(session) else { return step("the page developed", false, "no develop landed") }
        let rows = LayerRules.rows(session.layerPiece, alone: session.alone, has: has)
        session.pick(row: .exposure(.top))
        let pickedTop = session.layerPick
        session.pageNavigation.surface = .edit
        let keptInEdit = session.layerPick
        session.pageNavigation.surface = .develop
        step("the panel's rows, Balance and the pick", rows.map(\.pick) == [.film, .exposure(.top), .exposure(.bottom)]
                && rows.compactMap(\.shareText) == ["50 %", "50 %"] && LayerRules.showsBalance(session.layerPiece)
                && pickedTop == .exposure(.top) && keptInEdit == .exposure(.top)
                && LayerRules.page(keptInEdit, piece: session.layerPiece, mode: .edit, has: has) == .standsDown,
             "rows \(rows.map(\.name).joined(separator: " · ")); picked \(pickedTop.key), in Edit \(keptInEdit.key)")
        session.pick(row: .film)

        // 3. The canvas against the export (trap 33).
        guard let canvas = session.developedCGImage else { return step("canvas against export", false, "the page has no picture") }
        let edge = max(canvas.width, canvas.height)
        write(canvas, to: out.appendingPathComponent("canvas.png"))
        if let file = await exported(model, id, longEdge: edge, as: out.appendingPathComponent("export.png")) {
            let d = difference(canvas, file)
            // 16 x 16 means: grain and the tiers' own resampling average out, a wrong layer, share or placement does not.
            step("the canvas is the export (trap 33)", d.mean <= 3 && d.worst <= 10,
                 String(format: "16x16 block means: mean difference %.2f, worst block %.2f codes of 255 (canvas %dx%d, export %dx%d)",
                        d.mean, d.worst, canvas.width, canvas.height, file.width, file.height))
        } else {
            step("the canvas is the export (trap 33)", false, "the export did not land")
        }

        // 4. One exposure alone.
        let top = await model.developAlone(id, .top), bottom = await model.developAlone(id, .bottom)
        if let top, let bottom {
            write(top, to: out.appendingPathComponent("alone-top.png")); write(bottom, to: out.appendingPathComponent("alone-bottom.png"))
            let a = difference(top, canvas).mean, b = difference(bottom, canvas).mean, c = difference(top, bottom).mean
            model.showAlone(id, .top)
            let eyes = LayerRules.rows(session.layerPiece, alone: session.alone, has: has).map(\.eye)
            model.showAlone(id, LayerRules.eyeTapped(.top, alone: session.alone))
            step("one exposure alone is another picture (R9, G3)", a > 1 && b > 1 && c > 1 && eyes == [.none, .alone, .out] && session.alone == nil,
                 String(format: "top against the double %.1f, bottom against it %.1f, top against bottom %.1f codes; eyes %@", a, b, c, "\(eyes)"))
        } else {
            step("one exposure alone is another picture (R9, G3)", false, "developAlone returned top \(top != nil), bottom \(bottom != nil)")
        }

        // 5. 摆放: a drag develops; Done is one step of Undo; Cancel is none.
        let before = session.developedCGImage
        let opened = model.library.frame(id)?.double?[.top]?.placement
        let stage = LayersStage.shared
        stage.arranging = .init(frame: id, pick: .exposure(.top))
        session.holdHistory()
        let subject = ArrangeSubject(session: session, model: model, frameID: id, pick: .exposure(.top))
        subject.began()
        if let p = subject.placement { subject.write(subject.dragged(subject.zoomed(p, by: 2), by: CGSize(width: 0.4, height: 0.3))) }
        try? await Task.sleep(for: .milliseconds(1200))
        subject.ended()
        subject.began()
        if let p = subject.placement { subject.write(subject.dragged(p, by: CGSize(width: -0.1, height: 0))) }
        subject.ended()
        let undoable = session.canUndo
        session.releaseHistory()
        stage.arranging = nil
        try? await Task.sleep(for: .milliseconds(2500))
        let moved = model.library.frame(id)?.double?[.top]?.placement
        let after = session.developedCGImage
        let changed = before.flatMap { b in after.map { difference($0, b).mean } } ?? 0
        session.undo()
        let undone = model.library.frame(id)?.double?[.top]?.placement
        step("摆放: develops what it moves, one step of Undo (R5, G6, G7)", moved != opened && moved?.base.scale == 2 && changed > 0.3 && !undoable && undone == opened,
             String(format: "zoom %.2f; the page's picture moved %.2f codes; Undo inside 摆放 %@; one Undo back to where it was: %@",
                    moved?.base.scale ?? 0, changed, undoable ? "offered" : "stands down", undone == opened ? "yes" : "no"))
        // Cancel: moved, put back, no step.
        session.holdHistory()
        let stepsBefore = session.canUndo
        subject.began()
        if let p = subject.placement { subject.write(subject.zoomed(p, by: 1.5)) }
        subject.ended()
        if let opened { model.changeDouble(id) { double, _ in double[.top]?.placement = opened } }
        session.releaseHistory()
        _ = stepsBefore
        let back = model.library.frame(id)?.double?[.top]?.placement
        session.redo()
        let redone = model.library.frame(id)?.double?[.top]?.placement
        session.undo()
        step("摆放's Cancel leaves no step", back == opened && redone?.base.scale == 2,
             "back where it was: \(back == opened); the step before it is still the last one (Redo gives zoom \(String(format: "%.2f", redone?.base.scale ?? 0)))")

        // 5b. What a double shares with a photograph (gap G12): 漏光, 片边 with 日期后背, and Edit's crop each move
        // the page's picture, and the export is that picture.
        func agrees(_ name: String, _ file: String, develops: Bool = true, _ mutate: @escaping (inout FrameEdit) -> Void) async {
            let was = session.developedCGImage
            let stamp = session.developed
            session.change(mutate)
            // Edit's crop asks for no develop: the canvas cuts the picture it has.
            for _ in 0..<200 where develops && session.developed == stamp { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(600))
            guard let now = session.developedCGImage, let was else { return step(name, false, "no picture") }
            let moved = difference(now, was).mean
            write(now, to: out.appendingPathComponent(file + "-canvas.png"))
            let shape = DevelopedFrameView.shownAspect(frame: model.library.frame(id) ?? first, edit: session.edit, model: model, developed: session.developed)
            let edge = max(now.width, now.height)
            guard let exported = await exported(model, id, longEdge: edge, as: out.appendingPathComponent(file + "-export.png")) else {
                return step(name, false, "the export did not land")
            }
            // The canvas draws Edit's crop over the develop it has; the export's file is already cut.
            let shown = session.edit.printCrop.isIdentity ? now : (cropped(now, session.edit.printCrop.crop.rect) ?? now)
            let d = difference(shown, exported)
            let exportShape = Double(exported.width) / Double(max(exported.height, 1))
            step(name, (moved > 0.3) == develops && d.mean <= 3 && abs(exportShape - shape) / shape < 0.02,
                 String(format: "the page's picture moved %.2f codes; canvas against export: mean %.2f, worst %.2f; shown %.3f, exported %.3f (%dx%d)",
                        moved, d.mean, d.worst, shape, exportShape, exported.width, exported.height))
        }
        if EngineFeatures.offers(.leaks) {
            await agrees("漏光 on a double (G12)", "leak") { $0.leak.kind = .band; $0.leak.amount = 1 }
        }
        await agrees("片边 and 日期后背 on a double (G12)", "edge") { $0.filmEdge.active = true; $0.dateBack.active = true }
        await agrees("Edit's crop on a double (G12)", "crop", develops: false) { $0.printCrop.crop = CropRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6) }
        session.change { $0.printCrop = .default; $0.filmEdge.active = false; $0.dateBack.active = false; $0.leak.kind = .off }
        try? await Task.sleep(for: .milliseconds(1500))

        // 6. An emptied layer: one refusal, the panel's and the exporter's.
        model.removeDouble(id, .top)
        let refusal = LayerRules.refusal(session.layerPiece, has: has)
        let emptied = LayerRules.rows(session.layerPiece, has: has)
        var recipe = ExportRecipe()
        recipe.format = .png
        recipe.size = .longEdge(512)
        model.exporter.start([id], recipe: recipe)
        for _ in 0..<600 {
            if let b = model.exporter.batch, b.finished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        var said: String?
        if case .notSaved(let why)? = model.exporter.batch?.items.first?.state { said = why }
        step("an emptied layer: one refusal (R10, G2)", refusal != nil && said == refusal && emptied[1].isEmpty && !LayerRules.showsBalance(session.layerPiece)
                && LayerRules.page(.exposure(.top), piece: session.layerPiece, mode: .develop, has: has) == .empty,
             "the panel: \(refusal ?? "nothing"); Export: \(said ?? "no refusal")")
        session.undo()
        model.remove([id])
    }

    // MARK: - helpers (the double harness's, `DoubleHarness.swift`)

    private static func settled(_ model: AppServices) async -> [LibraryFrame] {
        for _ in 0..<600 {
            let photos = model.library.frames.filter { !$0.isComposite && !$0.isDemo }
            if photos.count >= 2, photos.allSatisfy({ !$0.develop.isBusy }), model.scheduler.snapshots.isEmpty { return photos }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return model.library.frames.filter { !$0.isComposite && !$0.isDemo }
    }

    private static func developedOnPage(_ session: OpenFrameSession) async -> Bool {
        for _ in 0..<600 {
            if session.developed != nil, session.developedCGImage != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func exported(_ model: AppServices, _ id: LibraryFrame.ID, longEdge: Int, as file: URL) async -> CGImage? {
        var recipe = ExportRecipe()
        recipe.format = .png
        recipe.size = .longEdge(longEdge)
        model.exporter.start([id], recipe: recipe)
        for _ in 0..<1200 {
            if let b = model.exporter.batch, b.finished { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let url = model.exporter.batch?.files.first,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.copyItem(at: url, to: file)
        return image
    }

    /// Two pictures as 16 x 16 block means in sRGB codes: the mean difference, and the worst block's.
    private static func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, worst: Double) {
        guard let x = blocks(a), let y = blocks(b) else { return (255, 255) }
        var sum = 0.0, worst = 0.0
        for i in 0..<(x.count / 3) {
            let d = (abs(x[3 * i] - y[3 * i]) + abs(x[3 * i + 1] - y[3 * i + 1]) + abs(x[3 * i + 2] - y[3 * i + 2])) / 3
            sum += d; worst = max(worst, d)
        }
        return (sum / Double(x.count / 3), worst)
    }

    private static func blocks(_ image: CGImage, side: Int = 16) -> [Double]? {
        var px = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out: [Double] = []
        for i in 0..<(side * side) { out.append(Double(px[4 * i])); out.append(Double(px[4 * i + 1])); out.append(Double(px[4 * i + 2])) }
        return out
    }

    private static func cropped(_ image: CGImage, _ n: CGRect) -> CGImage? {
        image.cropping(to: CGRect(x: n.minX * CGFloat(image.width), y: n.minY * CGFloat(image.height),
                                  width: n.width * CGFloat(image.width), height: n.height * CGFloat(image.height)).integral)
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? UIImage(cgImage: image).pngData()?.write(to: url)
    }
}
#endif
