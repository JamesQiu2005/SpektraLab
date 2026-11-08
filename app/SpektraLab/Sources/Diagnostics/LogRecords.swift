//  LogRecords.swift — what the log says: every record the app notes, in one place.
//
//  RFC-016 §5.6, the desktop's rule and this log's: *a record that nobody has
//  asked a question about does not exist.* These are the questions a build in
//  other people's hands has to answer by itself, and the records that answer
//  them. **This file is also the whole of what the consent asks for** — the
//  page in Settings (`DiagnosticsPage`) says it in the user's words, and a
//  record added here is a sentence owed there.
//
//  | the question | the record |
//  |---|---|
//  | Which build, on which reference device, set up how? | `app` `launch` |
//  | Did the session before end while the app was in use, and in what? | `app` `previous` (`LogStore`), and the operating system's own `system` reports |
//  | Did each develop and export run as it was planned: its time, its memory? | `job` `start`, `job` `end` (the scheduler's own record); Develop's cards a strip's run at a time (kind `stockStrip`) |
//  | What was exported, and did the file get where it was sent? | `export` |
//  | What does this reference device's camera offer, and what was a shot? | `camera` `ready`, `shot`, `refused`, `stopped` |
//  | How large is the library, where from, and what does it take on disk? | `library` `state`, `import`, `original` |
//  | Which films, which controls? | `library` `state` (films in use), `develop` `visit`, `export` |
//  | How much memory did the app hold as it ran, and during what? | `memory` `mark`, `rise`, `fall`, `low`, `session` (`MemoryLog`) |
//  | Did the log itself get out? | `upload` |
//
//  **What a record never carries**: a picture; a file's name (a frame is its
//  first eight hex, which names nothing); where or when a picture was taken.
//  A film or a paper is named as the app shows it, never by its profile's id.

import Foundation
import UIKit

extension Log {
    /// A frame, as the log names it: eight hex of its id.
    static func frame(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// A stock by the name the app shows.
    static func stock(_ id: String) -> String { StockCatalog.shared.stock(id)?.name ?? "unknown" }

    /// The paper a frame is printed on, by the name the app shows — or
    /// "scanned": a slide is the picture itself and names no paper, whatever
    /// paper the frame still holds for the next negative (the owner, 2026-10-09).
    static func paper(_ params: FilmParams) -> String {
        StockCatalog.shared.isScanned(params) ? StockCatalog.scannedWord : stock(params.printStock)
    }

    /// The host's own name for its model: "reference device18,3". A simulator says which it plays.
    static var machine: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated + " (simulator)" }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// "12 MP" classes, so a histogram has a handful of rows.
    static func megapixelClass(_ size: PixelSize) -> String {
        let mp = size.megapixels
        return mp <= 13 ? "to 12 MP" : mp <= 26 ? "to 24 MP" : mp <= 50 ? "to 48 MP" : "over 48 MP"
    }

    private static func counted<S: Sequence>(_ items: S, by name: (S.Element) -> String?) -> [String: Int] {
        var out: [String: Int] = [:]
        for item in items { if let key = name(item) { out[key, default: 0] += 1 } }
        return out
    }

    // MARK: the app

    /// Which build, on which reference device, set up how. Restated at the head of every
    /// file the session goes on in.
    @MainActor static func launched(_ model: AppServices) {
        guard let store else { return }
        let build = model.diagnostics.build
        let reading = MemoryProbe.read()
        let pair = model.settings.newFrameStocks
        var fields: [String: Any] = [
            "app": build.version, "build": build.build, "commit": build.commit, "configuration": build.configuration,
            "machine": machine, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "language": Locale.preferredLanguages.first ?? "", "region": Locale.current.region?.identifier ?? "",
            // The app's own language, which since 2026-10-12 is the user's choice and need not be the host's.
            "app_language": Language.shared.current.rawValue,
            "ram_gb": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            "allowance_mb": reading.appAvailable.megabytes, "develop_cap_mp": DevicePolicy.current.developCapMegapixels,
            "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermal": Diagnostics.thermal,
            "engine": model.engine.makesPictures ? model.engine.name : "simulated", "engine_sources": model.darkroom.commit,
            "settings": [
                "preview_px": model.settings.previewLongEdge,
                "pro_control": model.settings.proControl, "new_frames": model.settings.newFrameFilm == nil ? "last used" : "chosen",
                "film": stock(pair.film), "paper": StockCatalog.shared.isSlide(pair.film) ? StockCatalog.scannedWord : stock(pair.paper),
                "recipe": recipe(model.settings.recipe),
                "working_limit_gb": Int(model.settings.workingCopiesLimit >> 30), "preview_limit_gb": Int(model.settings.previewCopiesLimit >> 30),
            ] as [String: Any],
        ]
        if let failure = model.darkroom.failure { fields["engine_failure"] = failure }
        #if SPK_LOG_UPLOAD
        // Whether the log is shared, and whether this build has a server: a build with the sending's.
        fields["sharing"] = model.diagnostics.consent.rawValue
        fields["server"] = model.diagnostics.endpoint != nil
        #endif
        store.restate(fields)
        store.write(model.darkroom.failure == nil ? .info : .error, .app, "launch", fields)
    }

    static func recipe(_ r: ExportRecipe) -> [String: Any] {
        ["container": r.format.rawValue, "colour": r.colour.rawValue, "size": r.size.title, "quality": r.quality, "to": r.destination.rawValue]
    }

    // MARK: the library

    /// The library in numbers: how many frames, from where, of what, in which
    /// films, and what the app keeps on disk for them.
    @MainActor static func library(_ model: AppServices) {
        guard store != nil else { return }
        let frames = model.library.frames.filter { !$0.isDemo }
        let photographs = frames.filter { !$0.isPair }
        let s = model.library.storage
        func mb(_ bytes: Int64) -> Int { Int(bytes / 1_048_576) }
        note(.library, "state", [
            "frames": photographs.count, "pairs": frames.count - photographs.count,
            "raw": photographs.filter(\.isRAW).count,
            "from": counted(photographs) { f in
                switch f.source {
                case .photos: f.readsFromPhotos ? "photos, read in place" : "photos, preview only"
                case .linkedFolder: "linked folder"
                case .copiedIn: "in the app"
                }
            },
            "originals": counted(photographs) { f in
                switch f.original {
                case .available: nil
                case .offline: "offline"
                case .missing: "missing"
                case .inCloud: "in iCloud"
                }
            },
            "sizes": counted(photographs) { megapixelClass($0.originalSize) },
            "cameras": counted(photographs) { $0.camera },
            "films": counted(frames) { stock($0.edit.params.filmStock) },
            "papers": counted(frames) { paper($0.edit.params) },
            "film_edge": frames.filter { $0.edit.filmEdge.active }.count,
            // Frames that carry Edit's layer (Light, Curve, Colour), by tool.
            "edited": counted(frames.flatMap { $0.edit.adjustments.isActive ? $0.edit.adjustments.changedTools : [] }) { $0.rawValue },
            "date_back": frames.filter { $0.edit.dateBack.active }.count,
            "favourites": frames.filter(\.isFavourite).count,
            "not_developed": frames.filter { if case .failed = $0.develop { true } else { false } }.count,
            "storage_mb": ["originals": mb(s.copiedInOriginals), "working_copies": mb(s.workingCopies),
                           "previews": mb(s.previewCopies), "cache": mb(s.cache)],
            "limits_mb": ["working_copies": mb(s.workingCopiesLimit), "previews": mb(s.previewCopiesLimit)],
            "folders": model.library.linkedFolders.count,
        ])
    }

    /// Frames that have just arrived: from where, how many of how many asked for, of what.
    static func imported(from source: String, asked: Int, _ frames: [LibraryFrame], _ more: [String: Any] = [:]) {
        var fields: [String: Any] = ["from": source, "asked": asked, "arrived": frames.count,
                                     "raw": frames.filter(\.isRAW).count,
                                     "sizes": counted(frames) { megapixelClass($0.originalSize) },
                                     "cameras": counted(frames) { $0.camera }]
        fields.merge(more) { _, new in new }
        note(.library, "import", fields, level: frames.count < asked ? .warn : .info)
    }

    /// An original that stays in Photos, brought here to be worked on — or not.
    static func original(_ outcome: String, asked: Bool, seconds: Double? = nil, bytes: Int64? = nil, why: String? = nil) {
        var fields: [String: Any] = ["outcome": outcome, "asked": asked]
        fields["s"] = seconds
        fields["mb"] = bytes.map { Double($0) / 1_048_576 }
        fields["why"] = why
        note(.library, "original", fields, level: outcome == "here" ? .info : .warn)
    }

    // MARK: jobs

    /// A job has begun to run. Written before the engine is, so a session the operating system
    /// ends in the middle of one names it (`LogStore.Ending.open`).
    static func began(_ job: RenderJob, mode: RenderMode?) {
        var fields: [String: Any] = ["id": job.id, "kind": job.kind.rawValue, "tier": job.tier.rawValue, "mp": job.canvas.megapixels]
        fields["mode"] = mode?.name
        // A half-frame pair's frames that print as their own: each a print more of the same negative,
        // priced by arithmetic and not yet measured on a host (`CostModel`) — the record says how many.
        if job.printLayers > 0 { fields["print_layers"] = job.printLayers }
        // The app as the job found it: a job the operating system ends leaves no record of its own (`JobRecord`), and
        // whether the camera's memory is still the app's when a shot's first develop opens it is not known.
        let reading = MemoryProbe.read()
        fields["footprint_mb"] = Int(reading.footprint >> 20)
        fields["allowance_mb"] = Int(reading.appAvailable >> 20)
        fields["since_shot_s"] = memory?.sinceShot
        memory?.tell(job: "\(job.kind.rawValue) \(job.tier.rawValue) \(String(format: "%.1f", job.canvas.megapixels)) MP")
        note(.job, "start", fields)
    }

    private static let jobEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// The scheduler's own record of a job: its plan and its budget beside
    /// what was measured (RFC-036 R8), as `scheduler-log.jsonl` has it.
    static func ended(_ record: JobRecord) {
        var fields: [String: Any] = ["id": record.jobID, "kind": record.kind, "tier": record.tier, "outcome": record.outcome]
        if let data = try? jobEncoder.encode(record), var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for known in ["jobID", "kind", "tier", "outcome", "at"] { object[known] = nil }
            fields["job"] = object
        }
        note(.job, "end", fields, level: record.outcome.hasPrefix("failed") ? .error : .info)
    }

    // MARK: Develop's strips

    /// A strip's cards have begun to be made or read back (`StockPreviews`):
    /// one job for the run of them, kind `stockStrip`, so a session the operating system ends in
    /// the middle of one names it, as it names any job. Each card's own
    /// record is the scheduler's, not a line here.
    static func stripBegan(_ id: UUID, frame: UUID, cards: Int, canvas: PixelSize) {
        let reading = MemoryProbe.read()
        let fields: [String: Any] = ["id": id, "kind": "stockStrip", "tier": RenderTier.live.rawValue, "mp": canvas.megapixels,
                                     "frame": Log.frame(frame), "cards": cards,
                                     "footprint_mb": Int(reading.footprint >> 20), "allowance_mb": Int(reading.appAvailable >> 20)]
        memory?.tell(job: "stockStrip live")
        note(.job, "start", fields)
    }

    /// The run is over: what it made and read back, each card's time, the
    /// footprint at its highest, the budget at its least. `job` carries what a
    /// job's record does, so the log's tools read a strip as a job.
    static func stripEnded(_ id: UUID, outcome: String, fields: [String: Any]) {
        var all = fields
        all["id"] = id
        all["kind"] = "stockStrip"
        all["tier"] = RenderTier.live.rawValue
        all["outcome"] = outcome
        memory?.tell(job: nil)
        note(.job, "end", all)
    }

    // MARK: export

    /// One frame's export, ended: what was asked, what was made, where it went.
    @MainActor static func exported(_ frame: LibraryFrame, recipe: ExportRecipe, made: ExportService.Prepared?, outcome: String,
                                    why: String? = nil, seconds: Double, file: URL? = nil, brought: Double? = nil) {
        var fields: [String: Any] = Log.recipe(recipe)
        fields["frame"] = Log.frame(frame.id)
        fields["outcome"] = outcome
        fields["why"] = why
        fields["s"] = seconds
        fields["pair"] = frame.isPair
        fields["film"] = stock(frame.edit.params.filmStock)
        fields["paper"] = paper(frame.edit.params)
        fields["film_edge"] = frame.edit.filmEdge.active ? frame.edit.filmEdge.format.rawValue : nil
        fields["date_back"] = frame.edit.dateBack.active ? frame.edit.dateBack.style.rawValue : nil
        // Edit's tools baked into the file (Layer 2): which, by name.
        fields["edited"] = frame.edit.adjustments.isActive ? frame.edit.adjustments.changedTools.map(\.rawValue) : nil
        if let made {
            fields["out"] = "\(made.plan.output.width)x\(made.plan.output.height)"
            fields["mp"] = made.plan.output.megapixels
            fields["from_preview"] = made.fromPreview
            fields["capped"] = made.plan.isCapped
            fields["raw"] = made.isRAW
        }
        fields["brought_s"] = brought
        fields["bytes"] = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }?.int64Value
        note(.export, outcome, fields, level: outcome == "saved" || outcome == "stopped" ? .info : .error)
    }

    // MARK: the develop page

    /// The settings a visit to the develop page changed, by name: every key of
    /// the edit whose value is another at the end ("params.filmStock").
    static func changes<T: Encodable>(from before: T, to after: T) -> [String] {
        func tree(_ edit: T) -> [String: Any] {
            ((try? JSONEncoder().encode(edit)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        }
        var out: [String] = []
        func compare(_ a: Any?, _ b: Any?, _ path: String) {
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                for key in Set(x.keys).union(y.keys).sorted() { compare(x[key], y[key], path.isEmpty ? key : path + "." + key) }
            } else if !((a as? NSObject)?.isEqual(b) ?? (b == nil)) {
                out.append(path)
            }
        }
        compare(tree(before), tree(after), "")
        return out
    }

    /// A half-frame pair as the log compares it: what the engine reads for
    /// itself is no change of anybody's — a frame's meter reading and what it
    /// was read for, and the camera's own white balance in numbers (a hole's
    /// decode is its frame's, copied whenever the piece is written).
    static func compared(_ pair: HalfFramePair) -> HalfFramePair {
        var pair = pair
        for side in HalfFramePair.Side.allCases {
            guard var hole = pair[side] else { continue }
            hole.meteredEV = nil
            hole.meteredFor = nil
            if hole.decode.whiteBalance == .asShot { hole.decode.temperature = 0; hole.decode.tint = 0 }
            pair[side] = hole
        }
        return pair
    }

    /// What differs between a pair as it was and as it is, by name under
    /// `pair.`: "pair.left.print.yFilterShift", "pair.right.dated",
    /// "pair.spacingMM"; "pair.right" for a hole filled or emptied; "pair"
    /// alone where the pair itself came or went while its page was open. A
    /// page of a photograph has neither and says nothing.
    static func pairChanges(from before: HalfFramePair?, to after: HalfFramePair?) -> [String] {
        guard let before, let after else { return before == nil && after == nil ? [] : ["pair"] }
        return changes(from: compared(before), to: compared(after)).map { "pair." + $0 }
    }

    /// What differs between two states of a page's edit, by name. A pair's
    /// look holds its two frames' Scene Placements as the one the page shows
    /// and the other, and picking a frame trades them (`HalfFramePair.show`):
    /// here each is held to the frame it is of and named for it, so a frame
    /// picked is not a placement moved.
    static func editChanges(from before: FrameEdit, to after: FrameEdit, ofPair: Bool) -> [String] {
        guard ofPair else { return changes(from: before, to: after) }
        func byFrame(_ look: FrameEdit) -> FrameEdit {
            var look = look
            let first = look.params.firstPlacement, second = look.params.secondPlacement
            look.params.sceneLatitude = first
            look.params.sceneLatitudeOther = second
            look.params.placementIsRight = false
            // Where the second frame begins is the piece's arithmetic (`HalfFramePair.hold`), nobody's setting.
            look.params.pairSplit = 0
            return look
        }
        let other = "params.sceneLatitudeOther", shown = "params.sceneLatitude"
        return changes(from: byFrame(before), to: byFrame(after)).map { name in
            if name.hasPrefix(other) { return "pair.right.sceneLatitude" + name.dropFirst(other.count) }
            if name.hasPrefix(shown) { return "pair.left.sceneLatitude" + name.dropFirst(shown.count) }
            return name
        }
    }

    /// A visit to the develop page, ended: how long, how many pictures the
    /// engine made for it, which settings it touched (`touched`: moved at
    /// all, put back or not) and which it left other than it found them.
    /// On a half-frame pair the page is its darkroom: what a frame has for
    /// itself is in the pair, not in the look, and is named under `pair.`;
    /// `picked` are the layers the visit picked (the film, a frame).
    ///
    /// Edit's Light, Curve and Colour (Layer 2, `adjustments.` in the edit) are
    /// named under their tool: "edit.light.exposure", "edit.curve.rgb.points",
    /// "edit.colour.shadows.hue", "edit.colour.vibrance", "edit.colour.hsl.blue.hue",
    /// "edit.colour.channel.red.green" (`Adjustments.logName`; HSL and the channel
    /// mixer are written only once moved, so a first move names the group:
    /// "edit.colour.hsl"). `surfaces` is the
    /// time spent on each of the page's two surfaces, Develop and Edit, and
    /// `endedOn` the one the visit left from.
    static func developVisit(_ frame: LibraryFrame?, from before: FrameEdit, to after: FrameEdit,
                             pairFrom: HalfFramePair? = nil, pairTo: HalfFramePair? = nil, touched: Set<String>,
                             picked: Set<String> = [], seconds: Double, pictures: Int,
                             surfaces: [String: Double]? = nil, endedOn: DevelopSurface? = nil) {
        // What the engine solves for itself is not a change of the visit's.
        let solved: Set<String> = ["solvedEV", "placementNeedsFit"]
        let ofPair = pairFrom != nil || pairTo != nil
        let changed = (editChanges(from: before, to: after, ofPair: ofPair).filter { !solved.contains($0) }
            + pairChanges(from: pairFrom, to: pairTo)).map(visitName)
        var fields: [String: Any] = ["s": seconds, "pictures": pictures, "changed": changed,
                                     "touched": Set(touched.subtracting(solved).map(visitName)).union(changed).sorted(),
                                     "film": stock(after.params.filmStock), "paper": paper(after.params)]
        fields["frame"] = frame.map { Log.frame($0.id) }
        fields["pair"] = frame?.isPair
        fields["raw"] = frame?.isRAW
        if ofPair { fields["picked"] = picked.sorted() }
        fields["surfaces"] = surfaces
        fields["ended_on"] = endedOn?.rawValue
        fields["edited"] = after.adjustments.isActive ? after.adjustments.changedTools.map(\.rawValue) : nil
        note(.develop, "visit", fields)
    }

    /// A setting's name in a visit's line: Layer 2's under Edit's tool, the rest as they are.
    static func visitName(_ name: String) -> String {
        let prefix = "adjustments."
        return name.hasPrefix(prefix) ? Adjustments.logName(String(name.dropFirst(prefix.count)))
            : name == "adjustments" ? "edit" : name
    }
}
