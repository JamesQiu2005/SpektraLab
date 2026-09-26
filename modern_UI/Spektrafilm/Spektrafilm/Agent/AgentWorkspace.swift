//  AgentWorkspace.swift — the window's `Session`, driven without a window
//  (RFC-026 §2).
//
//  **Parity by construction.** There is no second engine path for agents:
//  this opens a frame with `Session.open`, edits it through the setters the
//  panels call, processes it with `solveNow` and writes it with `Exporter`.
//  What an agent can do is therefore what the interface can do, with the same
//  rules, the same sidecar and the same pixels; a frame edited here opens in
//  the window exactly as the agent left it.
//
//  Every public method waits for the session to *settle* — the decode landed,
//  the engine developed, the render scheduler caught up with the parameters —
//  because an answer about a frame is only true once the frame is rendered.

import CoreGraphics
import Foundation

@MainActor
final class AgentWorkspace {
    let session: Session
    private(set) var url: URL?
    /// How long a decode, a develop or a render may take before the call
    /// gives up. 100 MP on the full tier is the ceiling this covers.
    var timeout: Double = 300

    init(session: Session = Session()) {
        self.session = session
    }

    // MARK: waiting

    private func wait(_ what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > deadline {
                throw AgentError.failed("Timed out waiting for \(what). \(session.lastError ?? session.status)")
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    /// The engine has everything it was asked for, and nothing is in flight.
    private var settled: Bool {
        session.serviceSessionIDForExport != nil && !session.scheduler.pending
            && session.scheduler.sent == session.params && !session.busy
    }

    // MARK: opening

    /// Open one file, unless it is already the open one. The file must exist
    /// and be a kind the app opens; nothing is created or moved.
    func open(_ path: String) async throws {
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw AgentError.refused("No file at \(target.path).")
        }
        if url == target, session.selection == target { return }
        guard !Library.frames(from: [target]).isEmpty else {
            throw AgentError.refused("\(target.lastPathComponent) is not an image SpektraLab opens.")
        }
        if url != nil { session.flushSave() }
        session.lastError = nil
        session.open(urls: [target])
        url = target
        try await wait("the engine to start") { session.serviceReady || session.lastError != nil }
        // Not a wait on `decoded`: a frame processed before reopens from its
        // cached print and decodes only when something needs the pixels.
        // This is that something, and the same call Process and Export make.
        guard await session.ensureDecoded() != nil else {
            url = nil
            throw AgentError.failed(session.lastError ?? "\(target.lastPathComponent) did not decode.")
        }
    }

    /// Develop the negative (the first render), without solving the filter
    /// pack. Idempotent.
    func develop() async throws {
        guard session.selection != nil else { throw AgentError.refused("No frame is open.") }
        guard await session.ensureDeveloped() != nil else {
            throw AgentError.failed(session.lastError ?? "The engine did not develop the frame.")
        }
        try await settle()
    }

    /// Wait for every edit so far to be rendered.
    func settle() async throws {
        try await wait("the render") { settled || (session.lastError != nil && !session.busy) }
        if let e = session.lastError, !settled { throw AgentError.failed(e) }
        session.flushSave()
    }

    // MARK: the commands

    /// The Process button: develop, meter, and solve the enlarger's filter
    /// pack for this film and paper. Resets the Y/M shifts, as it does there.
    func process() async throws {
        try await develop()
        session.lastError = nil
        session.solveNow()
        try await wait("the solve") { !session.busy }
        if let e = session.lastError { throw AgentError.failed(e) }
        try await settle()
    }

    func edit(_ patch: JSONValue) async throws -> [String] {
        guard session.selection != nil else { throw AgentError.refused("No frame is open.") }
        // Wait for anything still landing, so the patch merges over the
        // document the person would see rather than one a decode replaces.
        if session.serviceSessionIDForExport != nil { try await settle() }
        let written = try session.applyAgentEdit(patch)
        try await develop()
        return written
    }

    /// Back to the defaults, as the panels' reset items do: Layer 1, the
    /// grade and the geometry. The decode (white balance, lens correction) is
    /// the file's and stays.
    func reset() async throws {
        guard session.selection != nil else { throw AgentError.refused("No frame is open.") }
        session.resetParams()
        session.recomputeFilmFormat()
        session.resetAdjustments()
        session.geometry = .default
        try await develop()
    }

    var document: JSONValue {
        get throws { try session.agentDocument.json }
    }

    func describe() throws -> JSONValue {
        guard let url, let d = session.decoded else { throw AgentError.refused("No frame is open.") }
        let p = session.params
        let size = session.sourceImageSize
        let long = session.sourceLongEdge > 0 ? Double(session.sourceLongEdge) : Double(max(size.width, size.height))
        let aspect = size.height > 0 ? Double(size.width / size.height) : 1
        var o: [String: JSONValue] = [
            "file": .string(url.path),
            "raw": .bool(d.isRAW),
            "pixels": [.number((aspect >= 1 ? long : long * aspect).rounded()),
                       .number((aspect >= 1 ? long / aspect : long).rounded())],
            "state": .string("\(session.frameStates[url] ?? .unprocessed)"),
            "film": .string(session.catalog.stock(p.filmStock)?.name ?? p.filmStock),
            "paper": .string(p.scanFilm ? "none (film scan)" : session.catalog.stock(p.printStock)?.name ?? p.printStock),
            "filmIsSlide": .bool(session.filmIsPositive),
            "lensCorrectionAvailable": .bool(session.lensCorrectionEnabled),
        ]
        if let t = d.asShotTemperature, let tn = d.asShotTint {
            o["asShotWhiteBalance"] = ["temperature": .number(t), "tint": .number(tn)]
        }
        if let ev = session.sidecar.solvedEV { o["meteredEV"] = .number(ev) }
        if let e = session.exif {
            o["exif"] = .object([("iso", e.iso), ("shutter", e.shutter), ("aperture", e.aperture)]
                .reduce(into: [:]) { if let v = $1.1 { $0[$1.0] = .string(v) } })
        }
        return .object(o)
    }

    func latitude() async throws -> JSONValue {
        try await develop()
        guard let r = await session.measureLatitude() else {
            throw AgentError.refused(session.latitude.failure ?? "The frame could not be measured.")
        }
        return Self.latitudeJSON(r, placement: session.params.sceneLatitude)
    }

    /// Scene Placement through the engine's Fit. A refused fit changes
    /// nothing and is reported as a refusal, in the engine's own words.
    func place(highlight: Double, shadow: Double) async throws -> JSONValue {
        guard (0...6).contains(highlight), (0...6).contains(shadow) else {
            throw AgentError.refused("Pull-backs are stops within 0…6.")
        }
        try await develop()
        guard let r = await session.placeSceneNow(highlight: highlight, shadow: shadow) else {
            throw AgentError.refused(session.latitude.failure ?? "The frame could not be measured.")
        }
        if !r.fit.valid, highlight > 0 || shadow > 0 {
            let why = r.fit.issues.map(\.message).joined(separator: " ")
            // The engine's words say *that* it must exceed the minimum; the
            // number is what lets the caller try again.
            let mins = [("highlight", r.fit.highlight, highlight), ("shadow", r.fit.shadow, shadow)]
                .filter { $0.2 > 0 }
                .map { "\($0.0) minimum \(String(format: "%.2f", $0.1.minimumPullBack)) stops" }
            throw AgentError.refused("The Fit refused this placement: \(why) (\(mins.joined(separator: ", "))).")
        }
        try await settle()
        return Self.latitudeJSON(r, placement: session.params.sceneLatitude)
    }

    static func latitudeJSON(_ r: SceneLatitudeResponse, placement: SceneLatitudeSettings) -> JSONValue {
        let read = LatitudeReadout(r)
        func side(_ s: SceneLatitudeResponse.Fit.Side) -> JSONValue {
            ["pullBack": .number(s.pullBack), "minimumPullBack": .number(s.minimumPullBack),
             "sceneExtremeEV": .number(s.sceneExtremeEV), "mediumBoundaryEV": .number(s.mediumBoundaryEV)]
        }
        return [
            "medium": ["shadowEV": .number(r.medium.shadowEV), "highlightEV": .number(r.medium.highlightEV),
                       "latitudeStops": .number(r.medium.latitudeStops)],
            "scene": ["p0_1": .number(r.scene.p0_1), "p50": .number(r.scene.p50), "p99_9": .number(r.scene.p99_9)],
            "fractionOfFrame": ["belowShadow": .number(read.below), "within": .number(read.within),
                                "aboveHighlight": .number(read.above)],
            "suggested": ["highlightPullBack": .number(r.suggested.highlightPullBack),
                          "shadowPullBack": .number(r.suggested.shadowPullBack),
                          "valid": .bool(r.suggested.valid)],
            "fit": ["valid": .bool(r.fit.valid), "highlight": side(r.fit.highlight), "shadow": side(r.fit.shadow),
                    "issues": .array(r.fit.issues.map { .string($0.message) })],
            "placement": ["active": .bool(placement.active),
                          "highlightPullBack": .number(placement.highlightPullBack),
                          "shadowPullBack": .number(placement.shadowPullBack)],
        ]
    }

    /// A small sRGB JPEG of the finished print, through the export path — so
    /// what an agent looks at is what an export would write, downscaled.
    func preview(to out: URL? = nil, longEdge: Int = 1024) async throws -> URL {
        guard (64...4096).contains(longEdge) else { throw AgentError.refused("The long edge must be within 64…4096.") }
        try await develop()
        let dir = FileManager.default.temporaryDirectory.appending(path: "spektralab-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var recipe = ExportRecipe()
        recipe.name = "Agent preview"
        recipe.format = .jpeg
        recipe.quality = 0.85
        recipe.colorSpace = .sRGB
        recipe.folder = .fixed(path: dir.path)
        recipe.subfolder = ""
        recipe.existing = .overwrite
        recipe.outputSize = .longEdge(longEdge)
        let files = try await write(recipe)
        guard let file = files.first else { throw AgentError.failed("The preview wrote nothing.") }
        let target = out ?? FileManager.default.temporaryDirectory
            .appending(path: "spektralab-\(url?.deletingPathExtension().lastPathComponent ?? "preview")-\(UUID().uuidString.prefix(8)).jpg")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// Export with one of the person's recipes (the first when none is
    /// named), optionally into another folder. Never overwrites unless the
    /// recipe says so.
    func export(recipe name: String?, to folder: String?) async throws -> [URL] {
        let recipes = ExportRecipeStore().recipes
        guard var recipe = name.map({ n in recipes.first { $0.name == n } }) ?? recipes.first else {
            throw AgentError.refused("No recipe named \(name ?? "") — `recipes` lists them.")
        }
        if let folder {
            recipe.folder = .fixed(path: (folder as NSString).expandingTildeInPath)
            recipe.subfolder = ""
        }
        try await develop()
        return try await write(recipe)
    }

    private func write(_ recipe: ExportRecipe) async throws -> [URL] {
        guard let url, let sid = session.serviceSessionIDForExport else { throw AgentError.refused("No frame is open.") }
        let out = session.geometry.outputSize(for: session.sourceImageSize)
        let scale = session.sourceLongEdge > 0
            ? session.sourceLongEdge / max(session.sourceImageSize.width, session.sourceImageSize.height) : 1
        let context = NamingRule.Context(
            originalName: url.deletingPathExtension().lastPathComponent,
            filmStock: session.params.filmStock, printStock: session.params.printStock,
            pixelSize: CGSize(width: (out.width * scale).rounded(), height: (out.height * scale).rounded()),
            counter: 1, date: Date())
        do {
            switch try await Exporter.export(session: session, recipe: recipe, context: context, sessionID: sid) {
            case .wrote(let urls, _, _): return urls
            case .skipped(let existing):
                throw AgentError.refused("\(existing.path) exists and the recipe says to skip it.")
            }
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.failed("\(error)")
        }
    }

    // MARK: listings

    static func stocksJSON(_ catalog: StockCatalog = .shared) -> JSONValue {
        func row(_ s: Stock) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(s.id), "name": .string(s.name), "use": .string(s.use)]
            if let t = s.type { o["type"] = .string(t) }
            if let t = s.targetPrint { o["declaredPaper"] = .string(t) }
            return .object(o)
        }
        return ["films": .array(catalog.films.map(row)), "papers": .array(catalog.papers.map(row))]
    }

    static func recipesJSON() -> JSONValue {
        .array(ExportRecipeStore().recipes.map { r in
            var o: [String: JSONValue] = ["name": .string(r.name), "format": .string(r.format.rawValue)]
            switch r.folder {
            case .besideOriginal: o["folder"] = "beside the original"
            case .fixed(let p): o["folder"] = .string(p)
            }
            if !r.subfolder.isEmpty { o["subfolder"] = .string(r.subfolder) }
            switch r.outputSize {
            case .original: o["size"] = "original"
            case .longEdge(let e): o["size"] = .string("long edge \(e) px")
            }
            return .object(o)
        })
    }
}
