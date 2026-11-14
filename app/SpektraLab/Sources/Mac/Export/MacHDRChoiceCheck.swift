//  MacHDRChoiceCheck.swift — a debug build's proof, in the running app, that Enable HDR is remembered (2.4.0; the
//  owner, 2026-11-13: "the app should remember the state of whether EDR / HDR is opened in a persistent way, not
//  the current behavior of always default to off").
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --library real --defaults-suite <name> --hdr-headroom 4 \
//          --import <folder> --hdr-choice-check <dir> [--hdr-choice-check-exit]
//      CFFIXED_USER_HOME=<same>/home SpektraLab --library real --defaults-suite <same> --hdr-headroom 4 \
//          --import <folder2> --hdr-choice-check <dir2> --hdr-choice-relaunch <dir> [--hdr-choice-check-exit]
//
//  `tools/hdr_choice_check.sh` runs both, with copies of the fixtures (a develop writes a sidecar), under a scratch
//  home and a defaults suite of the run's own (AGENTS.md trap 24): the suite is where Settings' *Enable HDR by
//  Default* is kept, so the relaunch reads what the first run left, never the person's. `--hdr-headroom 4` makes
//  every screen an HDR one, so the row is live on any Mac. Writes `<dir>/report.json`.
//
//  **The rule held** (the owner's): the last state the person chose is what a photograph that never chose shows,
//  and it survives a relaunch — switching Enable HDR on a photograph is that photograph's own choice *and* Settings'
//  Enable HDR by Default (one stored value, `settings.hdrByDefault`, so the two never disagree); a photograph that
//  chose keeps its own.
//
//  The first run, on four photographs A–D, Develop opened on A with the four in its strip, Enable HDR switched as the
//  row switches it (`OpenFrameSession.switchHDR`): A on → B (never chose) shows on, the default on and kept in the
//  suite → A's develop, its film off and on again, a paste of another group, leave A on → C switched off: the default
//  off, A still on, B off → D on: the default on, B on, C still off → Clone Variant of A (on, its own) and of B
//  (never chose: follows). The library flushed, the app exits.
//
//  The relaunch (`--hdr-choice-relaunch <dir>`): Settings' default still on; A, C, D their own; B, B's variant and a
//  photograph imported at this launch (E) never chose, and show on; Develop on B shows on.
//
//  Not in a release build.

#if targetEnvironment(macCatalyst) && DEBUG
import Foundation
import UIKit

@MainActor
enum MacHDRChoiceCheck {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: "--hdr-choice-check"), i + 1 < arguments.count, arguments[i + 1].hasPrefix("/") else { return }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let exits = arguments.contains("--hdr-choice-check-exit")
        let relaunch = arguments.firstIndex(of: "--hdr-choice-relaunch").flatMap { j in
            j + 1 < arguments.count ? URL(fileURLWithPath: arguments[j + 1]) : nil
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let r = MacHistoryCheck.Report()
            if ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.isEmpty == false,
               arguments.contains("--defaults-suite"), model.defaults !== UserDefaults.standard {
                if let previous = relaunch { await relaunched(model, r, previous: previous) } else { await first(model, r, out: out) }
            } else {
                r.check(false, "CFFIXED_USER_HOME and --defaults-suite are set (the debug build keeps its library and settings where the person's are): refused to run")
            }
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let report: [String: Any] = ["steps": r.steps, "failures": r.failures, "checks": r.checks, "passed": r.failures.isEmpty]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("hdr-choice-check: wrote \(out.appending(path: "report.json").path), \(r.checks) checks, \(r.failures.count) failures")
            if exits {
                await model.history.drained()
                model.library.flush()
                await model.macLibrary.host.shutdown()
                exit(r.failures.isEmpty ? 0 : 1)
            }
        }
    }

    /// What the first run made, for the relaunch to hold itself to.
    struct Recorded: Codable {
        var a: UUID, b: UUID, c: UUID, d: UUID
        var variantA: UUID?, variantB: UUID?
    }

    private static func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        await MacHistoryCheck.until(seconds, done)
    }

    /// A photograph's state as its frame holds it: its own choice ("on", "off", "never") and what it shows.
    private static func state(_ model: AppServices, _ id: UUID) -> String {
        guard let e = model.library.frame(id)?.edit else { return "gone" }
        let own = e.hdrChoice.map { $0 ? "on" : "off" } ?? "never"
        return "\(own)/\(e.hdr ? "shows on" : "shows off")"
    }

    /// The default as the model has it, as the frames follow it, and as the suite keeps it.
    private static func defaultState(_ model: AppServices) -> (settings: Bool, frames: Bool, kept: Bool) {
        (model.settings.hdrByDefault, FrameEdit.hdrByDefault, model.defaults.bool(forKey: "settings.hdrByDefault"))
    }

    /// One step along Develop's strip, and the page of `to` open.
    private static func step(_ model: AppServices, _ by: Int, to id: UUID) async -> OpenFrameSession? {
        NotificationCenter.default.post(name: .spkCheckStep, object: by)
        _ = await until(30) { model.openSession(id) != nil }
        return model.openSession(id)
    }

    // MARK: - the first run

    private static func first(_ model: AppServices, _ r: MacHistoryCheck.Report, out: URL) async {
        let photos = await MacHistoryCheck.photographs(model, atLeast: 4)
        guard photos.count >= 4 else { r.check(false, "four photographs imported (\(photos.count))"); return }
        let (a, b, c, d) = (photos[0].id, photos[1].id, photos[2].id, photos[3].id)
        let start = defaultState(model)
        r.note("start", ["default": start.settings, "frames_follow": start.frames, "shows_hdr": HDRDisplays.shared.showsHDR,
                         "a": state(model, a), "b": state(model, b)])
        r.check(HDRDisplays.shared.showsHDR, "the row is live (--hdr-headroom 4: every screen an HDR one)")
        r.check(!start.settings && model.library.frame(b)?.edit.hdrChoice == nil, "a fresh suite: the default off, B never chose")

        MacDevelopCarry.shared.frames = [a, b, c, d]
        model.router.toLibrary()
        model.router.open(.develop(a))
        guard await until(30, { model.openSession(a) != nil }), let pageA = model.openSession(a) else {
            r.check(false, "Develop opens on A"); return
        }
        // A: switched on, as the row switches it.
        pageA.switchHDR(true)
        r.note("A switched on", ["a": state(model, a), "default": defaultState(model).settings])
        r.check(model.library.frame(a)?.edit.hdrChoice == true, "A switched on is A's own choice (\(state(model, a)))")
        r.check(defaultState(model) == (true, true, true),
                "A switched on is the default too: Settings' Enable HDR by Default on, the frames following it, kept in the suite (\(defaultState(model)))")

        // B never chose: it shows what was last chosen.
        guard let pageB = await step(model, 1, to: b) else { r.check(false, "a step along the strip opens B"); return }
        r.check(pageB.edit.hdrChoice == nil && pageB.edit.hdr, "B, which never chose, shows on after A was switched on (\(state(model, b)))")
        guard let againA = await step(model, -1, to: a) else { r.check(false, "a step back opens A"); return }
        r.check(againA.edit.hdr && againA.edit.hdrChoice == true, "back on A: still on (\(state(model, a)))")

        // Nothing else on A resets it: a develop, the film off (Apple's decode) and on again, a paste of another group.
        againA.change { $0.params.exposureCompensationEV = 0.4 }
        r.check(model.library.frame(a)?.edit.hdrChoice == true, "A's develop (Exp. Comp.) keeps it on (\(state(model, a)))")
        againA.change { $0.setAppliesFilm(false) }
        againA.change { $0.setAppliesFilm(true) }
        r.check(model.library.frame(a)?.edit.hdrChoice == true, "A's film off and on again keeps it on (\(state(model, a)))")
        var light = FrameEdit.default
        light.adjustments.exposure = 0.25
        _ = model.pasteOntoLibrary(SettingsClip(groups: [.light], settings: light, sourceName: "hdr choice check", sourceAspect: 1.5), onto: [b])
        r.check(model.library.frame(b)?.edit.hdrChoice == nil, "a paste of Light onto B leaves B never chosen (\(state(model, b)))")

        // C: switched off. The default off; A keeps its own; B follows.
        guard let pageC = await step(model, 2, to: c) else { r.check(false, "two steps on open C"); return }
        pageC.switchHDR(false)
        r.check(model.library.frame(c)?.edit.hdrChoice == false, "C switched off is C's own choice (\(state(model, c)))")
        r.check(defaultState(model) == (false, false, false), "C switched off is the default too (\(defaultState(model)))")
        r.check(model.library.frame(a)?.edit.hdr == true, "A, which chose on, stays on (\(state(model, a)))")
        r.check(model.library.frame(b)?.edit.hdr == false, "B, which never chose, follows: off (\(state(model, b)))")

        // D: switched on. The default on; C keeps its own off.
        guard let pageD = await step(model, 1, to: d) else { r.check(false, "a step on opens D"); return }
        pageD.switchHDR(true)
        r.check(defaultState(model) == (true, true, true), "D switched on is the default again (\(defaultState(model)))")
        r.check(model.library.frame(c)?.edit.hdr == false && model.library.frame(b)?.edit.hdr == true,
                "C keeps its own off, B follows on (\(state(model, c)), \(state(model, b)))")

        // Clone Variant: A's carries A's own choice; B's never chose, as B.
        let importer = ImportService(model: model)
        let va = importer.cloneFrame(of: a, variant: "hdr-choice-a"), vb = importer.cloneFrame(of: b, variant: "hdr-choice-b")
        r.check(va.flatMap { model.library.frame($0)?.edit.hdrChoice } == true, "A's variant carries A's own on")
        r.check(vb.map { model.library.frame($0)?.edit.hdrChoice == nil && model.library.frame($0)?.edit.hdr == true } == true,
                "B's variant never chose, and shows on")

        model.router.toLibrary()
        _ = await until(10) { model.openSession(d) == nil }
        r.note("end", ["a": state(model, a), "b": state(model, b), "c": state(model, c), "d": state(model, d),
                       "default": defaultState(model).settings])
        let kept = Recorded(a: a, b: b, c: c, d: d, variantA: va, variantB: vb)
        if let data = try? JSONEncoder().encode(kept) {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? data.write(to: out.appending(path: "recorded.json"))
        }
    }

    // MARK: - the relaunch

    private static func relaunched(_ model: AppServices, _ r: MacHistoryCheck.Report, previous: URL) async {
        guard let data = try? Data(contentsOf: previous.appending(path: "recorded.json")),
              let kept = try? JSONDecoder().decode(Recorded.self, from: data) else {
            r.check(false, "the first run's recorded.json is there to read"); return
        }
        let photos = await MacHistoryCheck.photographs(model, atLeast: 5)
        let known = Set([kept.a, kept.b, kept.c, kept.d] + [kept.variantA, kept.variantB].compactMap { $0 })
        let fresh = photos.first { !known.contains($0.id) }
        r.note("relaunched", ["default": defaultState(model).settings, "a": state(model, kept.a), "b": state(model, kept.b),
                              "c": state(model, kept.c), "d": state(model, kept.d), "new": fresh.map { state(model, $0.id) } ?? "none"])
        r.check(defaultState(model) == (true, true, true), "after a relaunch the default is still the last chosen, on (\(defaultState(model)))")
        r.check(model.library.frame(kept.a)?.edit.hdrChoice == true, "A keeps its own on (\(state(model, kept.a)))")
        r.check(model.library.frame(kept.c)?.edit.hdrChoice == false && model.library.frame(kept.c)?.edit.hdr == false,
                "C keeps its own off (\(state(model, kept.c)))")
        r.check(model.library.frame(kept.d)?.edit.hdrChoice == true, "D keeps its own on (\(state(model, kept.d)))")
        r.check(model.library.frame(kept.b)?.edit.hdrChoice == nil && model.library.frame(kept.b)?.edit.hdr == true,
                "B, which never chose, shows on (\(state(model, kept.b)))")
        r.check(kept.variantB.map { model.library.frame($0)?.edit.hdr == true } == true, "B's variant shows on")
        if let fresh {
            r.check(fresh.edit.hdrChoice == nil && model.library.frame(fresh.id)?.edit.hdr == true,
                    "a photograph imported at this launch (\(fresh.fileName)) shows on (\(state(model, fresh.id)))")
        } else { r.check(false, "a photograph imported at this launch") }
        MacDevelopCarry.shared.frames = [kept.b]
        model.router.toLibrary()
        model.router.open(.develop(kept.b))
        if await until(30, { model.openSession(kept.b) != nil }), let page = model.openSession(kept.b) {
            r.check(page.edit.hdr, "Develop on B: its Enable HDR row shows on (\(state(model, kept.b)))")
        } else { r.check(false, "Develop opens on B") }
        model.router.toLibrary()
    }
}
#endif
