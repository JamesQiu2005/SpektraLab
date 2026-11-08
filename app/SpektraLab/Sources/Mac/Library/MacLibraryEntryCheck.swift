// Narrow integration gate for library documents picked by Import and editable metadata.
// This exercises production dispatch and the real helper; it is separate from live picker/key tests.
#if DEBUG
import Foundation

@MainActor
enum MacLibraryEntryCheck {
    private static var started = false
    static func startIfAsked(model: AppServices, arguments: [String] = CommandLine.arguments) {
        guard !started, let index = arguments.firstIndex(of: "--library-entry-check"), index + 1 < arguments.count else { return }
        started = true
        let out = URL(fileURLWithPath: arguments[index + 1])
        func argument(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        let photo = argument("--library-entry-photo").map { URL(fileURLWithPath: $0) }
        let captureOne = argument("--library-entry-c1").map { URL(fileURLWithPath: $0) }
        Task {
            let store = model.macLibrary
            await store.start()
            var checks: [[String: Any]] = []
            var failures: [String] = []
            func check(_ passed: Bool, _ name: String) {
                checks.append(["name": name, "passed": passed])
                if !passed { failures.append(name) }
                NSLog("[library-entry-check] %@ %@", passed ? "PASS" : "FAIL", name)
            }
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                guard let photo else { throw MacLibraryError.notSupported("--library-entry-photo is required") }
                var files: [URL] = []
                for number in 1...2 {
                    let copy = out.appending(path: "metadata-\(number).jpg")
                    try FileManager.default.copyItem(at: photo, to: copy)
                    files.append(copy)
                }
                let catalog = out.appending(path: "Picked.spkcatalog")
                let made = try await store.client.create(at: catalog, kind: .catalog)
                _ = try await store.client.add(made.library, files.map { .init(url: $0) }, copy: false)
                try await store.client.close(made.library)
                let importing = MacImportSession(store: store)
                defer { importing.close() }
                let openedCatalog = await importing.receivePicks([catalog])
                check(openedCatalog && store.selectedSource?.kind == .catalog && store.images.count == 2,
                      "Import opens .spkcatalog as a populated source")
                check(importing.picked.isEmpty && importing.files.isEmpty, "catalog package never enters the photo scanner")
                let ids = store.images.map(\.id)
                try await store.setRating(4, for: ids)
                try await store.setColorLabel(.green, for: ids)
                check(store.images.count == 2 && store.images.allSatisfy { $0.rating == 4 && $0.colorLabel == .green },
                      "batch rating and label update the visible rows")
                await store.synchronize(store.selectedSourceID)
                check(store.images.count == 2 && store.images.allSatisfy { $0.rating == 4 && $0.colorLabel == .green },
                      "rating and label survive reading the source again")
                try await store.setRating(0, for: ids)
                try await store.setColorLabel(.unlabelled, for: ids)
                check(store.images.allSatisfy { $0.rating == 0 && $0.colorLabel == nil }, "No Rating and No Label clear native metadata")
                let sessionFolder = out.appending(path: "Picked Session")
                let session = try await store.client.create(at: sessionFolder, kind: .session)
                try await store.client.close(session.library)
                let database = sessionFolder.appending(path: "Picked Session.spksession")
                check(FileManager.default.fileExists(atPath: database.path), "fixture is a real .spksession database")
                let openedSession = await importing.receivePicks([database])
                check(openedSession && store.selectedSource?.kind == .session, "Import opens a directly selected .spksession")
                let sourceCount = store.sources.count
                _ = try await store.open(sessionFolder)
                check(store.sources.count == sourceCount, "session file and session folder select the same source")
                let mixed = await importing.receivePicks([catalog, photo])
                await importing.scanFinished()
                check(!mixed && importing.files.count == 1 && importing.destination == store.selectedSourceID.map { .source($0) },
                      "mixed library and photo picks scan only the photo and use the opened catalog")
                if let captureOne {
                    let before = MacCatalogCheck.census(MacCatalogCheck.files(under: captureOne))
                    let opened = await importing.receivePicks([captureOne])
                    check(opened && store.selectedSource?.kind == .captureOneCatalog && !store.images.isEmpty,
                          "Import opens .cocatalog through the Capture One mirror")
                    if let row = store.images.first(where: { $0.colorLabel != nil }) ?? store.images.first {
                        check(row.colorLabel != nil, "Capture One test fixture includes a source label")
                        try await store.setRating(5, for: [row.id])
                        try await store.setColorLabel(.red, for: [row.id])
                        await store.synchronize(store.selectedSourceID)
                        let changed = store.images.first { $0.id == row.id }
                        check(changed?.rating == 5 && changed?.colorLabel == .red, "Capture One metadata overrides survive synchronization")
                        try await store.setColorLabel(.unlabelled, for: [row.id])
                        await store.synchronize(store.selectedSourceID)
                        check(store.images.first { $0.id == row.id }?.colorLabel == nil,
                              "No Label overrides a Capture One source label instead of restoring it")
                        try await store.setColorLabel(nil, for: [row.id])
                        check(store.images.first { $0.id == row.id }?.colorLabel == row.colorLabel,
                              "clearing an override restores the Capture One source label")
                    }
                    check(before == MacCatalogCheck.census(MacCatalogCheck.files(under: captureOne)),
                          "Capture One source census is unchanged after opening and metadata edits")
                }
            } catch {
                check(false, error.localizedDescription)
            }
            if arguments.contains("--library-entry-capture") {
                let browser = MacLibraryBrowser.shared
                if let row = store.images.first { browser.selection = [row.id]; browser.focus = row.id }
                browser.show(.info)
                try? await Task.sleep(for: .milliseconds(300))
                MacWindowCapture.capture()
                browser.show(.library)
                try? await Task.sleep(for: .milliseconds(300))
                MacWindowCapture.capture()
            }
            let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures,
                                         "live_ui_verified": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: out.appending(path: "report.json"))
            }
            await store.host.shutdown()
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}
#endif
