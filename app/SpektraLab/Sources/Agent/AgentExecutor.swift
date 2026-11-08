//  AgentExecutor.swift — what an agent's call does, in the running app, on its main actor
//  (ARCHITECTURE.md §7.16; the tools are `AgentTools`).
//
//  Every call goes through the app's own objects and their own calls, the ones the window's controls
//  use: the library is `model.macLibrary` (`CatalogSourcesStore`, MAC-LIBRARY-DATA.md §2), a frame's
//  edit is changed by `AppServices.change` (through its develop page's session when one is open, which
//  also asks the develop), an export is a `MacExportRun` batch over the window's `ExportService`. So
//  nothing an agent does is a second way of doing it, and the window shows it as it happens: a listing
//  selects what it lists.
//
//  The rules, in order, for every call:
//  1. **Access** (`AppSettings.agentAccess`, Settings › General › Agents), read now: off refuses
//     everything, the listings included — the person's library is theirs to open to a program.
//  2. **The schema** (`AgentTools.validate`), whole.
//  3. **An export batch under way** refuses what would change a frame or make files from one
//     (`AgentTool.touchesFrames`).
//  4. **What the library must say** — the source, the pictures, the film and the paper — is looked up
//     and checked for *every* argument before the first change.
//
//  **Deletion is the catalog's Trash only**: `trash_images` and `restore_images` are `setTrashed`, which
//  moves no file. Nothing here calls `moveToSystemTrash`, empties a Trash, or removes a file or a
//  source. A Capture One source is read one way; the store's own refusals pass through.

import Foundation

@MainActor
struct AgentExecutor {
    let model: AppServices
    private var store: CatalogSourcesStore { model.macLibrary }

    static let accessOff = "Agent access is off: turn it on in Settings › General › Agents"

    /// One call as the socket hands it: the reply object (`ok`, then `result`, or `refused` and `error`).
    func reply(_ name: String, _ arguments: JSONValue?) async -> JSONValue {
        do {
            let result = try await run(name, arguments)
            Log.note(.app, "agent call", ["tool": name, "ok": true])
            return ["ok": true, "result": result]
        } catch let e as AgentError {
            Log.note(.app, "agent call", ["tool": name, "ok": false, "refused": e.isRefusal])
            return ["ok": false, "refused": .bool(e.isRefusal), "error": .string(e.description)]
        } catch {
            let e = Self.classify(error)
            Log.note(.app, "agent call", ["tool": name, "ok": false, "refused": e.isRefusal])
            return ["ok": false, "refused": .bool(e.isRefusal), "error": .string(e.description)]
        }
    }

    /// The library's own errors as an agent's: what the caller can fix is a refusal.
    static func classify(_ error: Error) -> AgentError {
        if let e = error as? AgentError { return e }
        if let e = error as? MacLibraryError {
            switch e {
            case .offline, .unreadable: return .failed(e.localizedDescription)
            default: return .refused(e.localizedDescription)
            }
        }
        if let e = error as? LibraryError {
            switch e.code {
            case .notFound, .invalidParams, .readOnly, .unsupported, .exists, .inUse, .ambiguous, .crossVolume, .conflict:
                return .refused(e.message)
            default: return .failed(e.message)
            }
        }
        return .failed(error.localizedDescription)
    }

    func run(_ name: String, _ arguments: JSONValue?) async throws -> JSONValue {
        guard model.settings.agentAccess else { throw AgentError.refused(Self.accessOff) }
        let a = try AgentTools.validate(name, arguments)
        if AgentTools.named(name)?.touchesFrames == true, MacExportRun.shared.isRunning || model.exporter.isExporting {
            throw AgentError.refused("An export is under way in SpektraLab. Try again when it has finished.")
        }
        // The library is lazy until a view starts it; a hidden launch may have shown none yet.
        if !["list_stocks", "list_recipes"].contains(name) { await store.start() }
        switch name {
        case "list_sources": return listSources()
        case "open_source": return try await openSource(a)
        case "create_catalog", "create_session": return try await create(a, session: name == "create_session")
        case "list_collections": return try await listCollections(a)
        case "list_images": return try await listImages(a)
        case "import_images": return try await importImages(a)
        case "trash_images", "restore_images": return try await trash(a, name == "trash_images")
        case "set_rating": return try await setRating(a)
        case "set_color_label": return try await setColorLabel(a)
        case "list_recipes": return listRecipes()
        case "export_images": return try await export(a)
        case "list_stocks": return listStocks()
        case "get_develop": return try await getDevelop(a)
        case "set_develop": return try await setDevelop(a)
        default: throw AgentError.refused("No tool named \(name).")
        }
    }

    // MARK: - sources

    private func listSources() -> JSONValue {
        ["sources": .array(store.sources.filter { $0.kind != .appLibrary }.map(sourceJSON))]
    }

    private func sourceJSON(_ s: MacSource) -> JSONValue {
        let status: String
        var problem: JSONValue = .null
        switch s.status {
        case .unknown: status = "not_opened"
        case .ready: status = "ready"
        case .offline: status = "offline"
        case .busy: status = "busy"
        case .inUse: status = "in_use"
        case .failed(let why): status = "failed"; problem = .string(why)
        }
        return ["id": .string(s.id.uuidString), "name": .string(s.name), "kind": .string(Self.kindName(s.kind)),
                "status": .string(status), "problem": problem, "image_count": s.imageCount.map { .number(Double($0)) } ?? .null,
                "read_only": .bool(s.isReadOnly), "accepts_imports": .bool(s.acceptsImports),
                "selected": .bool(s.id == store.selectedSourceID), "path": s.path.map(JSONValue.string) ?? .null]
    }

    private static func kindName(_ k: MacSource.Kind) -> String {
        switch k {
        case .appLibrary: "app_library"
        case .catalog: "catalog"
        case .session: "session"
        case .captureOneCatalog: "capture_one_catalog"
        case .captureOneSession: "capture_one_session"
        case .folder: "folder"
        }
    }

    /// The named source, or the selected one.
    private func source(_ raw: String?) throws -> MacSource {
        if let raw {
            guard let id = UUID(uuidString: raw), let s = store.sources.first(where: { $0.id == id && $0.kind != .appLibrary }) else {
                throw AgentError.refused("No source \(raw): list_sources gives their ids.")
            }
            return s
        }
        guard let s = store.selectedSource, s.kind != .appLibrary else {
            throw AgentError.refused("No source is selected: name one (list_sources), or open_source first.")
        }
        return s
    }

    /// The source selected in the window, as a listing needs it; a source that would not open says why.
    private func selected(_ s: MacSource) async throws -> MacSource {
        // Not selected, or selected and not ready: opened here, and waited for. Just after a launch the window's
        // own `start()` may still be opening the last source (its status not yet known), and a call that only
        // read the status then was refused for a source that opened a moment later (seen 2026-11-09).
        if store.selectedSourceID != s.id || store.sources.first(where: { $0.id == s.id })?.status != .ready {
            await store.select(source: s.id)
        }
        let now = store.sources.first { $0.id == s.id } ?? s
        guard now.status == .ready else {
            throw AgentError.failed("\(now.name) could not be opened" + (store.activity.problem.map { ": \($0)" } ?? "."))
        }
        return now
    }

    private func openSource(_ a: [String: JSONValue]) async throws -> JSONValue {
        switch (a["id"]?.string, a["path"]?.string) {
        case (let id?, nil):
            let s = try await selected(try source(id))
            return ["source": sourceJSON(s)]
        case (nil, let path?):
            let url = try Self.absolute(path, "path")
            guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError.refused("Nothing is at \(url.path).") }
            let s = try await store.open(url)
            return ["source": sourceJSON(store.sources.first { $0.id == s.id } ?? s)]
        default:
            throw AgentError.refused("open_source needs one of id or path.")
        }
    }

    private func create(_ a: [String: JSONValue], session: Bool) async throws -> JSONValue {
        let name = a["name"]!.string!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.contains("/"), !name.hasPrefix(".") else { throw AgentError.refused("name must be a plain name, with no / and no leading dot.") }
        let folder = try Self.absolute(a["folder"]!.string!, "folder")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw AgentError.refused("No folder at \(folder.path).")
        }
        let s = session ? try await store.newSession(named: name, in: folder) : try await store.newCatalog(named: name, in: folder)
        return ["source": sourceJSON(store.sources.first { $0.id == s.id } ?? s)]
    }

    // MARK: - collections and images

    private func listCollections(_ a: [String: JSONValue]) async throws -> JSONValue {
        let s = try await selected(try source(a["source"]?.string))
        var rows: [JSONValue] = []
        func walk(_ cs: [MacCollection], _ depth: Int) {
            for c in cs {
                rows.append(["id": .string(c.id), "name": .string(c.title), "kind": .string(Self.kindName(c.kind)),
                             "depth": .number(Double(depth)), "image_count": c.imageCount.map { .number(Double($0)) } ?? .null,
                             "selected": .bool(c.id == store.selectedCollectionID)])
                walk(c.children, depth + 1)
            }
        }
        walk(store.tree.fixed, 0)
        walk(store.tree.user, 0)
        walk(store.tree.folders, 0)
        return ["source": .string(s.id.uuidString), "collections": .array(rows)]
    }

    private static func kindName(_ k: MacCollection.Kind) -> String {
        switch k {
        case .allImages: "all_images"
        case .recentImports: "recent_imports"
        case .recentCaptures: "recent_captures"
        case .trash: "trash"
        case .inLibrary: "in_library"
        case .project: "project"
        case .group: "group"
        case .album: "album"
        case .smartAlbum: "smart_album"
        case .folder: "folder"
        case .other(let raw): raw
        }
    }

    private func listImages(_ a: [String: JSONValue]) async throws -> JSONValue {
        let s = try await selected(try source(a["source"]?.string))
        let offset = Int(a["offset"]?.number ?? 0)
        let limit = Int(a["limit"]?.number ?? 100)
        let collection = a["collection"]?.string ?? store.tree.defaultSelection
        if let c = a["collection"]?.string, store.tree.find(c) == nil {
            throw AgentError.refused("No collection \(c) in \(s.name): list_collections gives their ids.")
        }
        // The filter is the call's, whole: what it does not name is cleared, so a listing never depends on
        // a tick the person left in the window.
        var q = store.query.cleared
        q.text = a["text"]?.string ?? ""
        if let r = a["min_rating"]?.number, r > 0 { q.minimumRating = Int(r) }
        if case .array(let names)? = a["color_labels"] {
            q.colorLabels = Set(names.compactMap { $0.string.flatMap(Self.colourLabel)?.rawValue })
        }
        if collection != store.selectedCollectionID { await store.select(collection: collection) }
        if q != store.query { await store.apply(q) }
        while store.images.count < offset + limit, store.images.count < store.total {
            let before = store.images.count
            await store.loadMore()
            if store.images.count == before { break }
        }
        let page = store.images.count > offset ? Array(store.images[offset..<min(offset + limit, store.images.count)]) : []
        return ["source": .string(s.id.uuidString), "collection": collection.map(JSONValue.string) ?? .null,
                "total": .number(Double(store.total)), "offset": .number(Double(offset)), "images": .array(page.map(imageJSON))]
    }

    private func imageJSON(_ i: MacImage) -> JSONValue {
        let state: JSONValue
        switch i.develop?.state {
        case nil: state = .null
        case .developed?: state = "developed"
        case .inQueue?: state = "in_queue"
        case .failed?: state = "failed"
        case .notDeveloped?: state = "not_developed"
        }
        return ["id": .string(Self.idText(i.id)), "file_name": .string(i.fileName), "path": .string(i.url.path),
                "kind": .string(i.kind.rawValue), "rating": .number(Double(i.rating)),
                "color_label": .string(Self.colourName(i.colorLabel)), "captured": i.capturedLocal.map(JSONValue.string) ?? .null,
                "trashed": .bool(i.isTrashed), "offline": .bool(i.isOffline),
                "film": i.develop?.film.map(JSONValue.string) ?? .null, "paper": i.develop?.paper.map(JSONValue.string) ?? .null,
                "developed": state]
    }

    static func idText(_ id: MacImage.ID) -> String { id.source.uuidString + "/" + id.image }

    static func colourLabel(_ name: String) -> MacColorLabel? {
        guard let i = AgentTools.colourNames.firstIndex(of: name) else { return nil }
        return MacColorLabel(rawValue: i)
    }

    static func colourName(_ label: MacColorLabel?) -> String { AgentTools.colourNames[label?.rawValue ?? 0] }

    /// Each id as a picture of the library — the loaded row, else the helper's own record — or the refusal
    /// that names the first one that is not.
    private func pictures(_ raw: [String]) async throws -> [MacImage] {
        var out: [MacImage] = []
        var seen = Set<MacImage.ID>()
        for text in raw {
            let id = try imageID(text)
            guard seen.insert(id).inserted else { continue }
            if let row = store.images.first(where: { $0.id == id }) { out.append(row); continue }
            do { out.append(try await store.detail(of: id).image) } catch {
                if let e = error as? LibraryError, e.code == .notFound || e.code == .invalidParams {
                    throw AgentError.refused("No picture \(text) in that source.")
                }
                throw Self.classify(error)
            }
        }
        return out
    }

    private func imageID(_ text: String) throws -> MacImage.ID {
        if let slash = text.firstIndex(of: "/") {
            let s = try source(String(text[..<slash]))
            let image = String(text[text.index(after: slash)...])
            guard !image.isEmpty else { throw AgentError.refused("\(text) names no picture.") }
            return MacImage.ID(source: s.id, image: image)
        }
        return MacImage.ID(source: try source(nil).id, image: text)
    }

    private func imageArgs(_ a: [String: JSONValue], _ key: String = "images") -> [String] {
        if case .array(let items)? = a[key] { return items.compactMap(\.string) }
        return a[key]?.string.map { [$0] } ?? []
    }

    /// The pictures by source, in the order first named.
    private func bySource(_ pictures: [MacImage]) -> [(source: MacSource, images: [MacImage])] {
        var order: [MacSource.ID] = []
        var groups: [MacSource.ID: [MacImage]] = [:]
        for p in pictures {
            if groups[p.id.source] == nil { order.append(p.id.source) }
            groups[p.id.source, default: []].append(p)
        }
        return order.compactMap { id in store.sources.first { $0.id == id }.map { ($0, groups[id]!) } }
    }

    // MARK: - import, trash, rating, label

    private func importImages(_ a: [String: JSONValue]) async throws -> JSONValue {
        let s = try source(a["source"]?.string)
        let mode = a["mode"]?.string.flatMap(MacImportMode.init(rawValue:))
        guard s.acceptsImports else {
            throw AgentError.refused(s.isReadOnly ? MacLibraryError.readOnly.localizedDescription : "\(s.name) takes no imports: import into a SpektraLab catalog or session.")
        }
        let fm = FileManager.default
        var urls: [URL] = []
        for path in imageArgs(a, "paths") {
            let url = try Self.absolute(path, "paths")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw AgentError.refused("Nothing is at \(url.path).") }
            if isDir.boolValue {
                // A folder's own files, one level, as the import page lists a folder dropped on it.
                let inside = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                urls += inside.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { throw AgentError.refused("Those folders hold no files.") }
        let added = try await store.importFiles(urls, into: s.id, mode: mode)
        return ["source": .string(s.id.uuidString), "asked": .number(Double(urls.count)), "added": .number(Double(added)),
                "mode": .string((mode ?? s.defaultImport).rawValue)]
    }

    private func trash(_ a: [String: JSONValue], _ trashed: Bool) async throws -> JSONValue {
        let groups = bySource(try await pictures(imageArgs(a)))
        for g in groups where g.source.kind == .captureOneCatalog || g.source.kind == .captureOneSession || !g.source.isHelperBacked {
            throw AgentError.refused("\(g.source.name) is Capture One's, read one way: it has no Trash of SpektraLab's.")
        }
        var count = 0
        for g in groups {
            try await store.setTrashed(trashed, for: g.images.map(\.id))
            count += g.images.count
        }
        return [trashed ? "trashed" : "restored": .number(Double(count))]
    }

    private func setRating(_ a: [String: JSONValue]) async throws -> JSONValue {
        let rating = a["rating"]?.number.map { Int($0) }
        let groups = bySource(try await pictures(imageArgs(a)))
        for g in groups {
            // null hands a Capture One row back to Capture One's own value; anywhere else there is none to hand back to.
            let r = rating ?? (g.source.kind == .captureOneCatalog ? nil : 0)
            try await store.setRating(r, for: g.images.map(\.id))
        }
        return ["rated": .number(Double(groups.reduce(0) { $0 + $1.images.count })), "rating": rating.map { .number(Double($0)) } ?? .null]
    }

    private func setColorLabel(_ a: [String: JSONValue]) async throws -> JSONValue {
        let label = a["color"]?.string.flatMap(Self.colourLabel)
        let groups = bySource(try await pictures(imageArgs(a)))
        for g in groups {
            let l = label ?? (g.source.kind == .captureOneCatalog ? nil : .unlabelled)
            try await store.setColorLabel(l, for: g.images.map(\.id))
        }
        return ["labelled": .number(Double(groups.reduce(0) { $0 + $1.images.count })),
                "color": label.map { .string(Self.colourName($0)) } ?? .null]
    }

    // MARK: - export

    private func listRecipes() -> JSONValue {
        ["recipes": .array(model.recipes.recipes.map { r in
            ["name": .string(r.name), "format": .string(r.format.rawValue), "colour": .string(r.colour.rawValue),
             "size": .string(r.size.title), "quality": .number(Double(r.quality))]
        })]
    }

    private func export(_ a: [String: JSONValue]) async throws -> JSONValue {
        let all = model.recipes.recipes
        var recipe: ExportRecipe
        if let name = a["recipe"]?.string {
            guard let r = all.first(where: { $0.name == name }) ?? all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw AgentError.refused("No recipe named \(name). The recipes: " + all.map(\.name).joined(separator: ", ") + ".")
            }
            recipe = r
        } else {
            guard let first = all.first else { throw AgentError.failed("There are no export recipes.") }
            recipe = first
        }
        // A recipe's size as Export opens it (a preview-size one at 12 MP), into the folder named: never Share.
        recipe = ExportRecipe.opening(recipe)
        recipe.destination = .files
        let folder = try Self.absolute(a["folder"]!.string!, "folder")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw AgentError.refused("\(folder.path) is a file, not a folder.") }
        }
        let chosen = try await pictures(imageArgs(a))
        if !fm.fileExists(atPath: folder.path) {
            do { try fm.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                throw AgentError.failed("The folder could not be made: \(error.localizedDescription)")
            }
        }
        // Each picture's frame, made where it has none (read in place, as the Export page makes them).
        var frameOf: [MacImage.ID: LibraryFrame.ID] = [:]
        var why: [MacImage.ID: String] = [:]
        for g in bySource(chosen) {
            let loaded = Set(store.images.map(\.id))
            let rows = g.images.filter { loaded.contains($0.id) }
            if !rows.isEmpty { frameOf.merge(try await store.frames(for: rows.map(\.id), focus: nil).frames) { a, _ in a } }
            for p in g.images where frameOf[p.id] == nil {
                do { frameOf.merge(try await store.frames(for: [p.id], focus: p.id).frames) { a, _ in a } } catch {
                    why[p.id] = Self.classify(error).description
                }
            }
        }
        var frames: [LibraryFrame.ID] = []
        var imageOf: [LibraryFrame.ID: MacImage] = [:]
        var leftOut: [MacImage] = []
        for p in chosen {
            if let f = frameOf[p.id], imageOf[f] == nil { frames.append(f); imageOf[f] = p } else if frameOf[p.id] == nil { leftOut.append(p) }
        }
        let run = MacExportRun.shared
        guard !frames.isEmpty else {
            throw AgentError.failed("None of the pictures could be made a frame: " + leftOut.map { "\($0.fileName) (\(why[$0.id] ?? "unreadable"))" }.joined(separator: ", "))
        }
        guard run.start(frames, leftOut: leftOut.map { .init(name: $0.fileName, why: why[$0.id] ?? "This picture cannot be opened") },
                        recipe: recipe, folder: folder, exporter: model.exporter) else {
            throw AgentError.failed("The export could not begin.")
        }
        while run.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        var rows: [JSONValue] = []
        var saved = 0
        // The batch's lines first, then one for each picture left out, in the order given (`MacExportRun.start`).
        let batchLines = run.lines.filter { $0.frameID != nil }.count
        for line in run.lines {
            let image = line.frameID.map { imageOf[$0] } ?? leftOut[safe: line.id - batchLines]
            var row: [String: JSONValue] = ["image": image.map { .string(Self.idText($0.id)) } ?? .null, "name": .string(line.name)]
            switch line.state {
            case .saved(let url): row["state"] = "saved"; row["file"] = .string(url.path); saved += 1
            case .failed(let w): row["state"] = "failed"; row["problem"] = .string(w)
            case .leftOut(let w): row["state"] = "left_out"; row["problem"] = .string(w)
            case .stopped: row["state"] = "stopped"
            case .waiting, .running: row["state"] = "unfinished"
            }
            rows.append(.object(row))
        }
        // The batch is over and read: the Export page opens on none of it.
        run.reset()
        return ["recipe": .string(recipe.name), "folder": .string(folder.path), "saved": .number(Double(saved)),
                "pictures": .array(rows)]
    }

    // MARK: - develop

    private func listStocks() -> JSONValue {
        let catalog = StockCatalog.shared
        func row(_ s: Stock) -> JSONValue {
            ["id": .string(s.id), "name": .string(s.name), "kind": .string(s.kind), "positive": .bool(s.isPositive),
             "monochrome": .bool(s.isMonochrome)]
        }
        return ["films": .array(catalog.films.map(row)), "papers": .array(catalog.papers.map(row)),
                "digital_intermediate": [
                    "id": .string(StockPreviewCard.digitalIntermediate),
                    "about": "Instead of a paper: the negative scanned as a Digital Intermediate. Colour negative films only; set_develop's digital_intermediate.",
                ]]
    }

    /// The frame a picture's develop is kept in, if it has one (nothing is made).
    private func frameID(of p: MacImage) -> LibraryFrame.ID? {
        guard let id = p.develop?.frameID, model.library.frame(id) != nil else { return nil }
        return id
    }

    /// The edit as it stands: on its develop page when one is open, in the library otherwise.
    private func edit(_ id: LibraryFrame.ID) -> FrameEdit? { model.openSession(id)?.edit ?? model.library.frame(id)?.edit }

    private func getDevelop(_ a: [String: JSONValue]) async throws -> JSONValue {
        let p = try await pictures([a["image"]!.string!])[0]
        return developJSON(p, frame: frameID(of: p))
    }

    private func developJSON(_ p: MacImage, frame id: LibraryFrame.ID?) -> JSONValue {
        let catalog = StockCatalog.shared
        guard let id, let e = edit(id), let f = model.library.frame(id) else {
            let pair = model.settings.newFrameStocks
            return ["image": .string(Self.idText(p.id)), "has_frame": false,
                    "note": "Not opened in SpektraLab yet: a new frame starts with this film and paper.",
                    "film": .string(pair.film), "film_name": catalog.stock(pair.film).map { .string($0.name) } ?? .null,
                    "paper": .string(pair.paper), "paper_name": catalog.stock(pair.paper).map { .string($0.name) } ?? .null]
        }
        let params = e.params
        let scanned = catalog.isScanned(params)
        let di = params.digitalIntermediate && !params.scanFilm
        let state: String
        switch CatalogSourcesStore.developInfo(f).state {
        case .developed: state = "developed"
        case .inQueue: state = "in_queue"
        case .failed: state = "failed"
        case .notDeveloped: state = "not_developed"
        }
        return ["image": .string(Self.idText(p.id)), "has_frame": true,
                "film": .string(params.filmStock), "film_name": catalog.stock(params.filmStock).map { .string($0.name) } ?? .null,
                "paper": scanned || di ? .null : .string(params.printStock),
                "paper_name": scanned || di ? .null : catalog.stock(params.printStock).map { .string($0.name) } ?? .null,
                "scanned": .bool(scanned && !di), "digital_intermediate": .bool(di),
                "film_exposure_ev": .number(params.exposureCompensationEV),
                "applies_film": .bool(e.appliesFilm), "pair": .string(catalog.pairText(params)),
                "developed": .string(state), "open_in_develop": .bool(model.openSession(id) != nil)]
    }

    private func setDevelop(_ a: [String: JSONValue]) async throws -> JSONValue {
        let film = a["film"]?.string, paper = a["paper"]?.string
        let di = a["digital_intermediate"]?.bool, ev = a["film_exposure_ev"]?.number
        guard film != nil || paper != nil || di != nil || ev != nil else {
            throw AgentError.refused("set_develop needs at least one of film, paper, digital_intermediate, film_exposure_ev.")
        }
        let catalog = StockCatalog.shared
        if let film, catalog.stock(film)?.isFilm != true { throw AgentError.refused("No film \(film): list_stocks gives their ids.") }
        if let paper, catalog.stock(paper)?.isPaper != true {
            throw AgentError.refused(paper == StockPreviewCard.digitalIntermediate
                ? "The Digital Intermediate is not a paper: set digital_intermediate to true." : "No paper \(paper): list_stocks gives their ids.")
        }
        if paper != nil, di == true { throw AgentError.refused("Choose a paper or the Digital Intermediate, not both.") }
        let p = try await pictures([a["image"]!.string!])[0]
        if p.kind == .pair { throw AgentError.refused("\(p.fileName) is a half-frame pair: change it on its Develop page.") }
        let existing = frameID(of: p)
        // The film the rules are held to: the one asked for, else the frame's, else a new frame's.
        let held = film ?? existing.flatMap { edit($0)?.params.filmStock } ?? model.settings.newFrameStocks.film
        let heldName = catalog.stock(held)?.name ?? held
        if let paper {
            if catalog.isSlide(held) { throw AgentError.refused("\(heldName) is a slide film: it is scanned, never printed.") }
            if let why = catalog.whyNotPrinted(film: held, on: paper) {
                throw AgentError.refused("\(catalog.stock(paper)?.name ?? paper) cannot print \(heldName): it is \(why).")
            }
        }
        if di == true, !StockPreviewRules.takesDigitalIntermediate(held, catalog) {
            throw AgentError.refused("The Digital Intermediate is for a colour negative film, and \(heldName) is not one.")
        }
        // Everything checked: the frame (made now where the picture has none, read in place), then the change.
        let id: LibraryFrame.ID
        if let existing { id = existing } else {
            guard let made = try await store.frames(for: [p.id], focus: p.id).frames[p.id] else {
                throw AgentError.failed("\(p.fileName) could not be made a frame.")
            }
            id = made
        }
        guard let f = model.library.frame(id), !f.isPair else { throw AgentError.refused("\(p.fileName) is a half-frame pair: change it on its Develop page.") }
        // As Develop's strips and slider change them (`StockPreviewPanel`): a film is loaded, a paper printed
        // on, never `filmStock` or `printStock` set alone (PAGES.md §4 rules 8–9).
        model.change(id) { e in
            if let film { e.params.load(film: film) }
            if let paper { e.params.print(on: paper) }
            if di == true { e.params.scanFilm = false; e.params.digitalIntermediate = true }
            if di == false, e.params.digitalIntermediate { e.params.print(on: e.params.printStock) }
            if let ev { e.params.exposureCompensationEV = ev }
        }
        store.refreshDevelopInfo()
        let row = store.images.first { $0.id == p.id } ?? p
        return developJSON(row, frame: id)
    }

    // MARK: - small things

    /// An absolute path (a `~` is the home's), or the refusal.
    static func absolute(_ path: String, _ key: String) throws -> URL {
        let p = (path as NSString).expandingTildeInPath
        guard p.hasPrefix("/") else { throw AgentError.refused("\(key) must be an absolute path; got \(path).") }
        return URL(fileURLWithPath: p).standardizedFileURL
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
