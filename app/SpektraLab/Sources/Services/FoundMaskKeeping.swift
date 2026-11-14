//  FoundMaskKeeping.swift — which found masks' files are named, and when the ones nothing names go (RFC-052 §8.2, M1c).
//
//  A found mask's file (`FoundMaskFiles`, `Masks/<frame>/<asset>.spkmask`) is the edit's own: it stays while anything
//  could show it again. **Named** is the union of
//
//  - **every frame's edit** in the library (a Clone Variant's or a pasted layer names a file in another frame's folder
//    until it is adopted);
//  - **every state of the frame's edit history** (`EditHistoryStore`: an Undo, a Go to This Step, can bring back a
//    layer made with a file the edit no longer names), and whatever the page's session holds that the store has not
//    written yet (`extra`);
//  - **`layers.json` as it is on disk**, read as text: an entry this build cannot read (a later build's, kept as it was
//    by `LayerShelf`) names its assets in a shape this build does not know, so any `"asset": "<32 hex>"` in the file
//    counts.
//
//  **When**: at the page's close, the frame's own folder (`pageClosed`): first the named files of other folders are
//  adopted into it, then what nothing names goes — only files older than `FoundMaskFiles.sweepAge`. **Nothing is swept
//  when the history cannot be read** (a newer build's store, SQLite saying no): a file kept a launch too long costs a
//  few hundred kilobytes; one swept wrongly is a mask that cannot be had back. A frame removed takes its folder
//  (`framesRemoved`), handing on a file another frame names; at launch, the folders of frames the library no longer has
//  go the same way (`launchTidy`). *Clear Working Copies*, the working copies' limit and the caches' tidy never come
//  here (`WorkingCopies`, `StorageTidy`: other folders), and neither does a 2.3.x build (`FoundMaskFiles`' note).
//
//  The calls are the page's and the library's (`OpenFrameSession`, `AppServices.remove`, the launch): wired by the
//  interface stage. Nothing here is on the main actor; the names are values handed in.

import Foundation

enum FoundMaskKeeping {
    /// The assets a layers value names.
    static func assets(_ layers: LocalLayers?) -> Set<String> {
        Set((layers?.items ?? []).flatMap { $0.parts.compactMap { $0.kind == .found ? $0.asset : nil } })
    }

    static func assets(_ edit: FrameEdit) -> Set<String> { assets(edit.layers) }

    /// The assets of each layer, by the layer's id.
    static func assetsByLayer(_ layers: LocalLayers?) -> [UUID: Set<String>] {
        var out: [UUID: Set<String>] = [:]
        for l in layers?.items ?? [] {
            let a = Set(l.parts.compactMap { $0.kind == .found ? $0.asset : nil })
            if !a.isEmpty { out[l.id] = a }
        }
        return out
    }

    private static let assetPattern = try! NSRegularExpression(pattern: "\"asset\"\\s*:\\s*\"([0-9a-f]{32})\"")

    /// Every `"asset": "<32 hex>"` in a JSON file's text: `layers.json` with the entries no build of this one reads.
    static func assets(inJSON data: Data) -> Set<String> {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let ns = text as NSString
        return Set(assetPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// Every asset a state of `frame`'s history names. Throws where the store cannot be read (then nothing is swept).
    static func assets(inHistoryOf frame: UUID, store: any EditHistoryStore) async throws -> Set<String> {
        guard let listing = try await store.listing(frame) else { return [] }
        let last = listing.steps.last?.seq ?? listing.base.seq
        let states = try await store.states(frame, seqs: listing.base.seq...max(listing.base.seq, last))
        return states.values.reduce(into: Set<String>()) { $0.formUnion(assets($1.edit)) }
    }

    /// What a sweep of `frame`'s folder keeps; nil where the history cannot be read (sweep nothing).
    static func names(frame: UUID, edits: [UUID: FrameEdit], layersFile: URL?, history: (any EditHistoryStore)?,
                      extra: Set<String> = []) async -> Set<String>? {
        var named = extra
        for e in edits.values { named.formUnion(assets(e)) }
        if let layersFile, let data = try? Data(contentsOf: layersFile) { named.formUnion(assets(inJSON: data)) }
        if let history {
            guard let h = try? await assets(inHistoryOf: frame, store: history) else { return nil }
            named.formUnion(h)
        }
        return named
    }

    // MARK: the page

    /// A page opened on `frame`: the files its edit names that are in another frame's folder are copied into its own,
    /// and the ones no folder holds are said (`missing`, by layer), for the rows to be marked.
    static func pageOpened(frame: UUID, edit: FrameEdit, files: FoundMaskFiles = .shared) async -> (adopted: Int, missing: [UUID: Set<String>]) {
        let adopted = await files.adopt(assets(edit), into: frame)
        return (adopted, await missing(edit.layers, files: files))
    }

    /// A page closed on `frame`: adopt, then sweep its folder of what nothing names (`names`). `extra`: the session's
    /// states the store has not been sent yet. What was adopted and what went.
    @discardableResult
    static func pageClosed(frame: UUID, edits: [UUID: FrameEdit], layersFile: URL?, history: (any EditHistoryStore)?,
                           extra: Set<String> = [], files: FoundMaskFiles = .shared, now: Date = Date()) async -> (adopted: Int, swept: [String]) {
        let adopted = await files.adopt(edits[frame].map { assets($0) } ?? [], into: frame)
        guard let keep = await names(frame: frame, edits: edits, layersFile: layersFile, history: history, extra: extra) else {
            return (adopted, [])
        }
        return (adopted, await files.sweep(frame: frame, keeping: keep, now: now))
    }

    /// Of a layers value, the layers whose found parts have no whole file: by layer id, the assets missing. What the
    /// interface marks; the bake fails on the same parts (`MaskBaker.Failure.missingFound`).
    static func missing(_ layers: LocalLayers?, files: FoundMaskFiles = .shared) async -> [UUID: Set<String>] {
        var out: [UUID: Set<String>] = [:]
        for (layer, a) in assetsByLayer(layers) {
            let gone = await files.missing(a)
            if !gone.isEmpty { out[layer] = gone }
        }
        // A found part with no asset at all is missing too.
        for l in layers?.items ?? [] where l.parts.contains(where: { $0.kind == .found && $0.asset == nil }) {
            out[l.id, default: []].insert("")
        }
        return out
    }

    // MARK: the library

    /// Frames gone from the library: their folders, each file another frame still names handed to it first.
    /// `remaining`: the edits of the frames that stay.
    static func framesRemoved(_ ids: Set<UUID>, remaining: [UUID: FrameEdit], files: FoundMaskFiles = .shared) async {
        let others = remaining.mapValues { assets($0) }
        for id in ids { await files.remove(frame: id, handing: others) }
    }

    /// At launch, after the library is read: the folders of frames it no longer has. A frame `layers.json` still has
    /// an entry for — one this build did not read, a frame of a shelf a later build keeps — is kept as though it were
    /// there, with the assets its entry's text names.
    @discardableResult
    static func launchTidy(edits: [UUID: FrameEdit], layersFile: URL?, files: FoundMaskFiles = .shared) async -> (handed: Int, removed: Int) {
        var frames = edits.mapValues { assets($0) }
        if let layersFile, let data = try? Data(contentsOf: layersFile),
           let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let entries = record["frames"] as? [String: Any] {
            for (key, entry) in entries {
                guard let id = UUID(uuidString: key) else { continue }
                // A top-level fragment would raise rather than throw: only an object or an array is written out.
                let text = JSONSerialization.isValidJSONObject(entry) ? ((try? JSONSerialization.data(withJSONObject: entry)) ?? Data()) : Data()
                frames[id, default: []].formUnion(assets(inJSON: text))
            }
        }
        return await files.tidy(frames: frames)
    }
}
