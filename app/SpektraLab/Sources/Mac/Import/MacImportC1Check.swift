//  MacImportC1Check.swift — a debug build's proof that a Capture One catalog or session is never an import
//  destination, and that Remove from SpektraLab works on a picture 2.4.0 imported into one (2026-11-16, Round 4b E2).
//
//      CFFIXED_USER_HOME=<scratch>/home SpektraLab --import-c1-check <dir> \
//          --import-c1-check-catalog <x.cocatalog> --import-c1-check-session <C1 session folder> \
//          --import-c1-check-picture <a.jpg> [--import-c1-check-exit]
//
//  `tools/import_c1_check.sh` builds the fixtures (a Capture One catalog on the SDK's schema, `variant_c1_fixture.py`;
//  a session folder with its `.cosessiondb`) and launches the app in the background. The owner, testing 2.4.0: "I
//  just imported one image, and somehow 'Remove from SpektraLab' didn't work. It happened because we're adding
//  images into a Capture One catalog." Steps, each in `<dir>/report.json`:
//
//  1. **A Capture One catalog alone**: it takes no imports (`acceptsImports`); the import page offers no
//     destination but New Catalog…, and says why in its note; the store refuses an import into it (`readOnly`).
//  2. **With a SpektraLab catalog too**, the Capture One catalog shown: Import To is the SpektraLab catalog and
//     lists nothing else; an import from the page lands there, none in the Capture One catalog.
//  3. **A Capture One session** shown: the same.
//  4. **A drop on the window** with the Capture One catalog shown (`MacImportDrop.perform`, the window's own way in):
//     the page that opens imports to the SpektraLab catalog, with the note.
//  5. **Remove from SpektraLab** on a row 2.4.0 put into the Capture One catalog's mirror (added here through the
//     helper, as 2.4.0's import did): it leaves the grid for the catalog's Trash, and Put Back brings it back. On
//     one of Capture One's own pictures with nothing of SpektraLab's: refused, with the reason, and it stays.
//  6. **Capture One's files**: the catalog package, its pictures and the session folder, name, size, mtime and
//     SHA-256 of every entry, the same at the end as at the start.
//
//  Not in a release build.

#if DEBUG
import CryptoKit
import Foundation
import UIKit

@MainActor
enum MacImportC1Check {
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard let i = MacCheckFolder.index(of: "--import-c1-check", in: arguments) else { return }
        setvbuf(stdout, nil, _IOLBF, 0)        // each line as it is printed, for the script watching the log
        func arg(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let out = URL(fileURLWithPath: arguments[i + 1])
        let exits = arguments.contains("--import-c1-check-exit")
        guard let catalog = arg("--import-c1-check-catalog"), let session = arg("--import-c1-check-session"),
              let picture = arg("--import-c1-check-picture") else {
            print("import-c1-check: supply --import-c1-check-catalog, --import-c1-check-session and --import-c1-check-picture; nothing was run")
            if exits { exit(2) }
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            let report = await run(model, out: out, catalog: URL(fileURLWithPath: catalog),
                                   session: URL(fileURLWithPath: session), picture: URL(fileURLWithPath: picture))
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            print("import-c1-check: wrote \(out.appending(path: "report.json").path)")
            if exits {
                await model.macLibrary.host.shutdown()
                exit(report["passed"] as? Bool == true ? 0 : 1)
            }
        }
    }

    private final class Report {
        var steps: [[String: Any]] = []
        var failures: [String] = []
        var checks = 0
        func record(_ name: String, _ facts: [String: Any] = [:]) {
            var s = facts
            s["step"] = name
            steps.append(s)
            print("import-c1-check: \(name) \(facts)")
        }
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            print("import-c1-check: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        var result: [String: Any] { ["steps": steps, "failures": failures, "checks": checks, "passed": failures.isEmpty && checks > 0] }
    }

    /// Every entry under `root`: its path below it, size, modification time and (files) SHA-256.
    static func census(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { return out }
        for case let url as URL in walk {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
            var line = "\(v?.fileSize ?? -1) \(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if v?.isDirectory != true, let data = try? Data(contentsOf: url) {
                line += " " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            out[rel] = line
        }
        return out
    }

    private static func waitFor(_ seconds: Double, _ ok: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end {
            if ok() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return ok()
    }

    private static func isReadOnly(_ error: Error?) -> Bool { (error as? MacLibraryError) == .readOnly }

    static func run(_ model: AppServices, out: URL, catalog: URL, session: URL, picture: URL) async -> [String: Any] {
        let r = Report()
        guard let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !home.isEmpty else {
            r.check(false, "CFFIXED_USER_HOME is set (the debug build shares the owner's bundle id): refused to run")
            return r.result
        }
        let store = model.macLibrary
        let fm = FileManager.default
        let work = out.appending(path: "work")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work.appending(path: "in"), withIntermediateDirectories: true)
        await store.start()
        r.check(store.sources.isEmpty, "the home has no sources (run in a fresh CFFIXED_USER_HOME): \(store.sources.map(\.name))")
        guard store.sources.isEmpty else { return r.result }
        // Capture One's side: the catalog's folder (its package and the pictures it references) and the session.
        let c1Root = catalog.deletingLastPathComponent()
        let before = (census(c1Root), census(session))
        // Written from its bytes (the picture is in the scratch fixtures: a read under ~/Documents hung here in
        // `clonefileat` for minutes, a privacy prompt waiting, 2026-11-16).
        let bytes = (try? Data(contentsOf: picture)) ?? Data()
        func copy(_ name: String) -> URL {
            let u = work.appending(path: "in").appending(path: name)
            try? fm.removeItem(at: u)
            try? bytes.write(to: u)
            return u
        }

        // 1. A Capture One catalog alone.
        let c1: MacSource
        do { c1 = try await store.open(catalog) } catch {
            r.check(false, "the Capture One catalog opens: \(error.localizedDescription)")
            return r.result
        }
        do {
            let page = MacImportSession(store: store)
            defer { page.close() }
            r.record("1 a Capture One catalog alone", ["kind": c1.kind.rawValue, "destinations": page.destinations.map(\.name),
                                                       "destination": page.destinationSource?.name ?? "new catalog",
                                                       "note": page.captureOneNote ?? "-"])
            r.check(c1.kind == .captureOneCatalog && store.selectedSourceID == c1.id, "the Capture One catalog is open and shown")
            r.check(!c1.acceptsImports, "a Capture One catalog takes no imports")
            r.check(page.destinations.isEmpty, "Import To lists no Capture One catalog: \(page.destinations.map(\.name))")
            r.check(page.destination == .newCatalog, "with no SpektraLab catalog, Import To is New Catalog…")
            r.check(page.captureOneNote != nil, "the page says why, in one line")
            var chunkError: Error?, filesError: Error?
            do { _ = try await store.importChunk([MacImportFile(url: copy("chunk.jpg"), header: nil)], into: c1.id, copyIntoLibrary: false, album: nil) }
            catch { chunkError = error }
            do { _ = try await store.importFiles([copy("files.jpg")], into: c1.id, mode: .copy) } catch { filesError = error }
            r.check(isReadOnly(chunkError), "the store refuses the import page's import into it: \(chunkError?.localizedDescription ?? "none")")
            r.check(isReadOnly(filesError), "and an agent's: \(filesError?.localizedDescription ?? "none")")
        }

        // 2. A SpektraLab catalog too; the Capture One catalog shown.
        let own: MacSource
        do { own = try await store.newCatalog(named: "Own", in: work) } catch {
            r.check(false, "a SpektraLab catalog is made: \(error.localizedDescription)")
            return r.result
        }
        do {
            let ownPage = MacImportSession(store: store)
            r.check(ownPage.destination == .source(own.id) && ownPage.captureOneNote == nil,
                    "the SpektraLab catalog shown: Import To is it, with no note")
            ownPage.close()
            await store.select(source: c1.id)
            let c1Count = store.total
            let page = MacImportSession(store: store)
            r.record("2 the Capture One catalog shown, a SpektraLab one there", [
                "destinations": page.destinations.map(\.name), "destination": page.destinationSource?.name ?? "new catalog",
                "note": page.captureOneNote ?? "-", "c1_total": c1Count])
            r.check(page.destination == .source(own.id), "Import To is the SpektraLab catalog, not the Capture One one shown")
            r.check(page.destinations.map(\.id) == [own.id], "Import To lists only SpektraLab's: \(page.destinations.map(\.name))")
            r.check(page.captureOneNote != nil, "and the note says so")
            _ = await page.receivePicks([copy("paged.jpg")])
            await page.scanFinished()
            await page.existingRead()
            let result = await page.run()
            page.close()
            r.record("2 imported from the page", ["into": result.flatMap { id in store.sources.first { $0.id == id.destination }?.name } ?? "-",
                                                  "added": result?.added ?? -1, "problem": page.problem ?? "-"])
            r.check(result?.destination == own.id && result?.added == 1, "the page's import went into the SpektraLab catalog")
            await store.select(source: c1.id)
            r.check(store.total == c1Count, "and none into the Capture One catalog (\(store.total), was \(c1Count))")
        }

        // 3. A Capture One session shown.
        do {
            let s = try await store.open(session)
            let page = MacImportSession(store: store)
            defer { page.close() }
            r.record("3 a Capture One session shown", ["kind": s.kind.rawValue, "destinations": page.destinations.map(\.name),
                                                       "destination": page.destinationSource?.name ?? "new catalog", "note": page.captureOneNote ?? "-"])
            r.check(s.kind == .captureOneSession && !s.acceptsImports, "a Capture One session takes no imports")
            r.check(page.destination == .source(own.id) && page.destinations.map(\.id) == [own.id],
                    "Import To is the SpektraLab catalog, and lists only it")
            r.check(page.captureOneNote != nil, "the note says why")
        } catch {
            r.check(false, "the Capture One session opens: \(error.localizedDescription)")
        }

        // 4. A drop on the window, the Capture One catalog shown.
        do {
            await store.select(source: c1.id)
            let browser = MacLibraryBrowser.shared
            let dropped = copy("dropped.jpg")
            let taken = MacImportDrop.perform([NSItemProvider(object: dropped as NSURL)], router: model.router)
            let up = await waitFor(8) { MacImportDrop.open.map { !$0.closed && !$0.picked.isEmpty } == true && browser.importAsked }
            let page = MacImportDrop.open
            r.record("4 a drop on the window", ["taken": taken, "page": up, "destination": page?.destinationSource?.name ?? "new catalog",
                                                "note": page?.captureOneNote ?? "-"])
            r.check(taken && up, "the window takes the drop and the page opens")
            r.check(page?.destination == .source(own.id), "the drop's page imports to the SpektraLab catalog")
            r.check(page?.captureOneNote != nil, "and says why")
            page?.debugCancel?()
            r.check(await waitFor(5) { !browser.importAsked && MacImportDrop.open == nil }, "Cancel takes the page down")
        }

        // 5. Remove from SpektraLab, in the Capture One catalog.
        do {
            await store.select(source: c1.id)
            // What 2.4.0 did: an import into the mirror, through the helper (the store refuses one now).
            let legacy = copy("from-2.4.0.jpg")
            let h = try await store.handle(c1)
            _ = try await store.client.add(h, [LibraryClient.AddItem(url: legacy)], copy: false)
            await store.select(collection: store.tree.defaultSelection)
            await store.reload()
            let ours = store.images.first { $0.url.standardizedFileURL == legacy.standardizedFileURL }
            let theirs = store.images.first { $0.fromCaptureOne }
            r.record("5 the rows", ["listed": store.images.map(\.fileName), "spektralab_row": ours?.fileName ?? "-",
                                    "capture_one_row": theirs?.fileName ?? "-"])
            r.check(ours?.fromCaptureOne == false, "2.4.0's import is a row of SpektraLab's in the mirror")
            let actions = MacLibraryActions.shared
            if let ours {
                r.check(MacLibraryActions.removeRefusal([ours], frames: [], store: store) == nil, "Remove from SpektraLab is offered for it")
                actions.refusal = nil
                actions.removeFromSpektraLab([ours], frames: [], store: store)
                let gone = await waitFor(5) { !store.images.contains { $0.id.image == ours.id.image } }
                r.record("5 removed", ["gone": gone, "refusal": actions.refusal ?? "-", "listed": store.images.map(\.fileName)])
                r.check(gone, "Remove from SpektraLab takes it out of the grid")
                r.check(actions.refusal == nil, "with nothing refused")
                if let trash = store.tree.fixed.first(where: { $0.kind == .trash }) {
                    await store.select(collection: trash.id)
                    let inTrash = store.images.first { $0.id.image == ours.id.image }
                    r.check(inTrash?.isTrashed == true, "it is in the catalog's Trash")
                    if let inTrash {
                        actions.putBack([inTrash], store: store)
                        r.check(await waitFor(5) { !store.images.contains { $0.id.image == ours.id.image } }, "Put Back takes it out of the Trash")
                    }
                    await store.select(collection: store.tree.defaultSelection)
                    r.check(store.images.contains { $0.id.image == ours.id.image }, "and it is back in All Images")
                } else {
                    r.check(false, "the Capture One catalog has a Trash row")
                }
            }
            if let theirs {
                let why = MacLibraryActions.removeRefusal([theirs], frames: [], store: store)
                r.record("5 one of Capture One's", ["picture": theirs.fileName, "refusal": why ?? "-"])
                r.check(why != nil, "on one of Capture One's own pictures with nothing of SpektraLab's, Remove is greyed with the reason")
                actions.refusal = nil
                actions.removeFromSpektraLab([theirs], frames: [], store: store)
                r.check(await waitFor(3) { actions.refusal != nil }, "reached anyway (an agent, a key), it says why")
                try? await Task.sleep(for: .milliseconds(500))
                await store.reload()
                r.check(store.images.contains { $0.id == theirs.id && !$0.isTrashed }, "and the picture stays")
                actions.refusal = nil
                actions.refusalTitle = nil
            } else {
                r.check(false, "the Capture One catalog lists its own pictures")
            }
        } catch {
            r.check(false, "step 5 ran: \(error.localizedDescription)")
        }

        // 6. Capture One's files.
        let after = (census(c1Root), census(session))
        let changed = Set(before.0.keys).union(after.0.keys).filter { before.0[$0] != after.0[$0] }
            + Set(before.1.keys).union(after.1.keys).filter { before.1[$0] != after.1[$0] }
        r.record("6 Capture One's files", ["catalog_entries": after.0.count, "session_entries": after.1.count, "changed": changed.sorted()])
        r.check(!before.0.isEmpty && !before.1.isEmpty, "the census saw Capture One's files")
        r.check(changed.isEmpty, "Capture One's catalog, its pictures and the session are untouched: \(changed.sorted())")
        print("import-c1-check: \(r.failures.isEmpty ? "passed" : "\(r.failures.count) failure(s)") (\(r.checks) checks)")
        return r.result
    }
}
#endif
