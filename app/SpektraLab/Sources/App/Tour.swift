//  Tour.swift — the flow map's arrows, walked in a real window.
//
//      SpektraLab --tour <dir>
//
//  The snapshot harness draws pages one at a time in a window that is never
//  shown, which says nothing about whether a sheet presents, stacks, changes
//  height or gives way to a cover. Those are UIKit presentations and only
//  happen in a real scene. The tour opens the app normally, walks the router
//  through every kind of presentation the flow map has, captures the window
//  after each step, and quits.
//
//  It drives the router and the stores, not the buttons: it checks that each
//  route presents what `Routes.swift` says, over the right thing. Under Mac
//  Catalyst the window is sized to the drawings' page. It is a check of the
//  app's plumbing on a Mac, not of a host.

import SwiftUI
import UIKit

struct TourRequest {
    let directory: URL
    init?(arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--tour"), i + 1 < arguments.count else { return nil }
        directory = URL(fileURLWithPath: arguments[i + 1])
    }
}

@MainActor
enum Tour {
    private static var started = false

    /// Once, and not as a view's `.task`: a view's task is cancelled when the
    /// view leaves the screen, which presenting a cover over it does — and a
    /// cancelled tour stops waiting between its steps.
    static func startIfAsked(model: AppServices) {
        guard !started, let request = TourRequest() else { return }
        started = true
        Task { @MainActor in await run(request, model: model) }
    }

    private static func run(_ request: TourRequest, model: AppServices) async {
        try? FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let page = CGSize(width: Theme.Metric.designWidth, height: Theme.Metric.designHeight)
            scene.sizeRestrictions?.minimumSize = page
            scene.sizeRestrictions?.maximumSize = page
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        let router = model.router
        var step = 0
        func capture(_ name: String) async {
            try? await Task.sleep(nanoseconds: 1_300_000_000)      // a presentation's animation
            step += 1
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
                print("tour \(name): no window"); return
            }
            func write(_ w: UIWindow, _ file: String) {
                let image = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in
                    w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: request.directory.appendingPathComponent(file))
            }
            let stem = String(format: "%02d-%@", step, name)
            write(window, stem + ".png")
            // What is on top, in words: the pictures and this line must agree.
            // On a reference device a sheet is a card in the page's own window. Under Mac
            // Catalyst it is a window of its own, so each presented page is
            // written beside the page under it: NN-name+1.png, +2.png.
            var top = window.rootViewController
            var depth = 0
            var kinds: [String] = []
            while let next = top?.presentedViewController {
                top = next; depth += 1
                if let own = next.view.window, own !== window { write(own, stem + "+\(depth).png") }
                kinds.append(next.modalPresentationStyle == .fullScreen ? "cover" : "sheet")
            }
            print("tour \(stem)  presented \(kinds.isEmpty ? "nothing" : kinds.joined(separator: " > ")), path \(router.path.count), sheets \(router.sheets.map(\.id)), cover \(router.cover?.id ?? "-")")
        }

        guard let frame = model.library.selected else { print("tour: the library is empty"); exit(1) }
        let id = frame.id

        if CommandLine.arguments.contains("--v5-navigation") {
            var failures: [String] = []
            func check(_ condition: Bool, _ message: String) {
                if !condition { failures.append(message); print("V5 FAIL: " + message) }
            }
            router.home()
            router.open(.develop(id))
            await capture("v5-from-library")
            check(router.backWay(for: .develop(id)).to == nil, "Library entry returns to Library")
            guard let session = model.openSession(id) else { print("V5 FAIL: no page session"); exit(1) }
            let edit = session.edit
            let jobs = Set(model.scheduler.snapshots.map(\.id))
            session.show(.edit)
            session.pageNavigation.open(.brightness)
            session.changeEdit { $0.exposure = 0.75; $0.temperature = 12 }
            await capture("v5-light-controls")
            model.resetPage(.light, in: session)
            check(session.edit.adjustments.exposure == 0 && session.edit.adjustments.temperature == 12,
                  "Reset Light preserves Colour")
            let clip = SettingsClip(groups: [.light], settings: { var s = FrameEdit(); s.adjustments.shadows = 23; return s }(), sourceName: "")
            model.library.clipboard = nil
            check(!model.pasteSettings(into: session), "empty clipboard refuses Paste")
            model.library.clipboard = clip
            check(model.pasteSettings(into: session), "visible Paste transaction accepts clipboard")
            await capture("v5-paste")
            check(session.edit.adjustments.shadows == 23 && session.edit.params == edit.params && session.edit.decode == edit.decode,
                  "Light preset preserves photographic fields")
            check(Set(model.scheduler.snapshots.map(\.id)) == jobs, "Layer 2 reset/preset submit no engine jobs")
            session.pageNavigation.open(.curve)
            await capture("v5-curve-controls")
            session.pageNavigation.open(.wheels)
            await capture("v5-colour-controls")
            session.change { $0 = edit }
            session.pageNavigation.select(.format)
            session.show(.edit)
            session.pageNavigation.select(.darkroom)
            session.pageNavigation.darkroom = .effects
            await capture("v5-edit-effects")
            let navigation = session.pageNavigation
            router.present(.copySettings(id))
            await capture("v5-copy")
            router.dismissAllSheets()
            await capture("v5-after-copy")
            check(model.openSession(id) === session && session.pageNavigation == navigation, "Copy return preserves session and navigation")
            router.present(.export([id]))
            await capture("v5-export")
            router.dismissAllSheets()
            await capture("v5-after-export")
            check(model.openSession(id) === session && session.pageNavigation == navigation, "Export return preserves session and navigation")
            router.show(.crop(id))
            await capture("v5-crop")
            router.dismissCover()
            await capture("v5-after-crop")
            check(model.openSession(id) === session && session.pageNavigation == navigation, "Crop cancel preserves session and navigation")
            check(session.edit == edit, "navigation and cancelled sheets do not change photographic edits")
            session.show(.develop)
            check(session.pageNavigation.step == .format, "Develop restores Format")
            session.show(.edit)
            check(session.pageNavigation.darkroom == .effects, "Edit restores Effects")
            session.pageNavigation.panelFolded = true
            await capture("v5-folded")
            router.back()
            await capture("v5-back-to-library")
            check(router.path.isEmpty, "Back pops to the Library")
            let pairID = PairSnapshots.kept(model)
            let pairSession = model.session(for: pairID)
            pairSession.enter(); pairSession.pick(.left)
            model.changePair(pairID) { piece, look in
                var left = HalfFramePair.PrintTrim(look.params), right = left
                left.brightnessStops = 1; left.preflashExposure = 0.01
                right.brightnessStops = -1
                piece[.left]?.print = left; piece[.right]?.print = right
                piece[.left]?.exposureEV = 2; piece[.right]?.exposureEV = -2
            }
            let sibling = pairSession.pair?[.right]
            model.resetPage(.enlarger, in: pairSession)
            check(pairSession.pair?[.left]?.print?.brightnessStops == 0 && pairSession.pair?[.left]?.print?.preflashExposure == 0.01,
                  "pair Enlarger reset preserves selected frame pre-flash")
            check(pairSession.pair?[.right] == sibling, "pair reset preserves entire sibling")
            model.applyLook(SettingsClip(groups: [.filmExposure], settings: { var s = FrameEdit(); s.params.exposureCompensationEV = 0.8; return s }(), sourceName: ""), to: pairSession)
            check(pairSession.pair?[.left]?.exposureEV == 0.8 && pairSession.pair?[.right] == sibling,
                  "pair preset applies to picked exposure and preserves sibling")
            check(pairSession.transferableSettings.params.exposureCompensationEV == 0.8,
                  "pair copy reads picked frame exposure")
            pairSession.leave()
            let result: [String: Any] = ["failures": failures, "passed": failures.isEmpty,
                                       "scope": "programmatic navigation and real-window presentation; no simulated finger gestures"]
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: request.directory.appendingPathComponent("v5-results.json"))
            print("V5 navigation tour: \(failures.count) failures")
            exit(failures.isEmpty ? 0 : 1)
        }

        await capture("library")
        router.present(.importSources);                 await capture("import-sheet")
        router.dismissSheet();                          await capture("library-after-import")
        router.present(.info(id));                      await capture("info-sheet")
        router.dismissSheet();                          await capture("library-after-info")
        router.open(.develop(id));                      await capture("develop")
        router.present(.copySettings(id));              await capture("copy-settings-sheet")
        router.dismissSheet();                          await capture("develop-after-copy")
        router.present(.export([id]));                  await capture("export-sheet")
        model.exporter.start([id], recipe: model.settings.recipe)
        router.swapSheet(for: .exporting);              await capture("exporting-sheet")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        await capture("exporting-finished")
        router.dismissAllSheets();                      await capture("develop-after-export")
        router.show(.crop(id));                         await capture("crop-cover")
        router.dismissCover();                          await capture("develop-after-crop")
        // The Film Edge flow is a cover like Crop.
        router.show(.filmEdge(id, .film));              await capture("film-edge-cover")
        router.dismissCover();                          await capture("develop-after-film-edge")
        // A film edge and a date put on the frame, as the flow's Develop puts them:
        // the develop page shows the film, and Date Back opens the flow at its step.
        model.library.update(id) { f in
            f.edit.filmEdge.active = true
            f.edit.filmEdge.cameraSeed = model.settings.bodySeed
            f.edit.filmEdge.turn = f.edit.filmEdge.format.defaultTurn(pictureAspect: f.originalSize.aspect)
            f.edit.dateBack.active = true
        }
        await capture("develop-in-its-film")
        router.show(.filmEdge(id, .date));              await capture("date-step-cover")
        router.dismissCover();                          await capture("develop-after-date")
        model.library.update(id) { f in f.edit.filmEdge.active = false; f.edit.dateBack.active = false }
        router.back();                                  await capture("library-after-develop")
        router.show(.settings);                         await capture("settings-cover")
        router.dismissCover();                          await capture("library-after-settings")
        if FeatureFlags.halfFramePair {
            // A half-frame pair (design/pair v2), by each way in as its page takes it (`PairWay`:
            // what a button calls, since the tour has no finger). The Library's Pair on the frame
            // on top: the sheet that asks for the second frame, and a touch on a frame there,
            // which makes the pair, sends the sheet away and pushes the pair's darkroom. Then the
            // pair in the Library; its darkroom, and the page a frame's picture is placed on over
            // that; and a half frame's Film Edge: the flow's cover gone, then the same sheet over
            // the develop page, and a touch there, from which the way back is to the Library.
            let second = model.library.photographs().map(\.id).first { $0 != id } ?? id
            // What a way in made, in words: the pictures and this line must agree, and what is
            // not as the way in promises is said FAILED. The page on top is the pair's when the
            // pair's session is the one held and the frame's is not. From a half frame's Film
            // Edge the frame keeps the hole it was framed for, and its film edge goes with it.
            func said(_ way: String, _ made: LibraryFrame.ID?, fromFilmEdge: Bool = false) {
                guard let made, let pair = model.library.frame(made)?.pair else { print("tour \(way): FAILED, no pair was made"); return }
                let hole = pair.left?.frame == id ? "left" : pair.right?.frame == id ? "right" : "neither"
                var wrong: [String] = []
                if model.library.selectedID != made { wrong.append("the pair is not the Library's frame on top") }
                if router.path != [.develop(made)] { wrong.append("the path is not the pair's darkroom alone") }
                if model.openSession(made) == nil || model.openSession(id) != nil { wrong.append("the page on top is not the pair's") }
                if fromFilmEdge, hole != "left" { wrong.append("the half frame is not in the first hole") }
                if fromFilmEdge, !pair.onStrip { wrong.append("its film edge was not kept") }
                print("tour \(way): the first frame in the \(hole) hole, \(pair.onStrip ? "on its strip" : "on bare film")"
                      + (wrong.isEmpty ? "; the pair on top in the Library, its darkroom the one page over it" : " -- FAILED: " + wrong.joined(separator: "; ")))
            }
            PairWay.ask(for: id, on: router);               await capture("pair-with-sheet")
            let pairID = PairWay.make(id, with: second, keepFilmEdge: false, model: model)
            await capture("pair-made-from-the-sheet")
            said("the Library's Pair", pairID)
            router.home();                                  await capture("library-with-a-pair")
            if let pairID {
                router.open(.develop(pairID));          await capture("pair-darkroom")
                router.show(.pairPlace(pairID, .right)); await capture("pair-place-over-darkroom")
                router.dismissCover();                  await capture("pair-darkroom-after-placing")
                router.present(.export([pairID]));      await capture("pair-export-sheet")
                router.dismissSheet()
                router.back();                          await capture("library-after-pair-darkroom")
            }
            // The frame on Half, as the flow's Format line writes it before it leaves for a pair.
            let filmEdgeWas = model.library.frame(id)?.edit.filmEdge
            model.library.update(id) { f in
                f.edit.filmEdge.active = true
                f.edit.filmEdge.format = .half
                f.edit.filmEdge.cameraSeed = model.settings.bodySeed
                f.edit.filmEdge.turn = FilmEdgeFormat.half.defaultTurn(pictureAspect: f.originalSize.aspect)
                f.edit.filmEdge.framing = nil
            }
            router.open(.develop(id))
            router.show(.filmEdge(id, .film));          await capture("film-edge-before-pair")
            PairWay.leaveFilmEdge(of: id, on: router)
            // Two presentations, one after the other: the cover's way out, then the sheet's way in.
            try? await Task.sleep(nanoseconds: 900_000_000)
            await capture("pair-with-sheet-after-film-edge")
            let edgePairID = PairWay.make(id, with: second, keepFilmEdge: true, model: model)
            await capture("pair-made-from-film-edge")
            said("a half frame's Film Edge", edgePairID, fromFilmEdge: true)
            router.back();                              await capture("library-after-film-edge-pair")
            // As it was: the pairs go, and their frames stay; the frame's film edge is what it was.
            for made in [pairID, edgePairID].compactMap({ $0 }) {
                guard let pair = model.library.frame(made) else { continue }
                model.scheduler.cancelAll(frameID: made)
                model.library.remove([made])
                ImportService.discard([pair])
                PairGuide.discard(pair.picture)
            }
            if let filmEdgeWas { model.library.update(id) { $0.edit.filmEdge = filmEdgeWas } }
            await capture("library-after-pair")
        }
        await capture("library-end")
        print("tour: \(step) steps -> \(request.directory.path)")
        exit(0)
    }
}
