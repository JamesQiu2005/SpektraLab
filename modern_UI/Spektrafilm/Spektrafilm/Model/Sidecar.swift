//  Sidecar.swift — one frame's settings, in the app's own store. Never writes
//  the source file. Small enough to rewrite whole on every change.

import CryptoKit
import Foundation

struct DecodeSettings: Codable, Equatable, Hashable, Sendable {
    enum WhiteBalance: String, Codable, CaseIterable, Sendable {
        case asShot = "As Shot", daylight = "Daylight", cloudy = "Cloudy", shade = "Shade",
             tungsten = "Tungsten", fluorescent = "Fluorescent", custom = "Custom"
        var kelvin: Double? {
            switch self {
            case .daylight: 5500
            case .cloudy: 6500
            case .shade: 7500
            case .tungsten: 3200
            case .fluorescent: 4000
            case .asShot, .custom: nil
            }
        }
    }
    var whiteBalance: WhiteBalance = .asShot
    /// Kelvin and tint actually applied at decode. For `.asShot` these are
    /// the camera's, filled in after the first decode; for presets the preset's.
    var temperature: Double = 5500
    var tint: Double = 0
    /// Apply the lens's own distortion and vignetting correction at decode.
    ///
    /// **A RAW-only decode setting, and deliberately not an engine
    /// parameter.** The PRD: "only RAW files can apply lens correction. If the
    /// RAW carries lens correction information already, i.e. Nikon NEFs,
    /// otherwise let core image handles it based on EXIF (the standard way)."
    /// That is `CIRAWFilter.isLensCorrectionEnabled` exactly — Core Image
    /// reads the manufacturer's own correction out of the file, and a file
    /// that does not carry one reports `isLensCorrectionSupported == false`,
    /// which is what greys the row rather than offering a switch that does
    /// nothing.
    ///
    /// Off by default: it changes the frame's geometry, and a crop or a
    /// straighten made before it was turned on would no longer describe the
    /// same rectangle.
    var lensCorrection: Bool = false
}

/// The two "As Shot" checkboxes beside the white-balance sliders, as a value.
///
/// The design's rules, in one place so they can be tested without a decode, a
/// window or an engine:
///
///  - A box is ticked when the decode is using the **camera's** value for that
///    axis. That is `.asShot`, where the stored numbers are ignored outright —
///    and it is also a `.custom` setting pinned exactly to the camera's value,
///    which renders the same picture and so must read the same.
///  - Ticking a box pins that axis to the camera's value. Both ticked is
///    `.asShot`; one ticked is `.custom` with the other axis where it was.
///  - Unticking a box, or dragging its slider, is `.custom` at the current
///    value.
///  - A preset sets the numbers itself, so both boxes untick — unless the
///    preset's pair *is* the camera's, which is the same picture again and
///    reads as both ticked.
///
/// `asShot` is nil until a decode has landed. Ticking a box means pinning to
/// that pair, so with nothing to pin to the boxes are disabled and read
/// unticked — which is what `WhiteBalanceBoxes(_:asShot:)` gives by default.
struct WhiteBalanceBoxes: Equatable, Sendable {
    /// The camera's own pair, as the decode reports it.
    typealias AsShot = (temperature: Double, tint: Double)

    var temp = false
    var tint = false

    init(temp: Bool = false, tint: Bool = false) {
        self.temp = temp
        self.tint = tint
    }

    init(_ d: DecodeSettings, asShot: AsShot?) {
        guard let asShot else { return }
        let following = d.whiteBalance == .asShot
        temp = following || d.temperature == asShot.temperature
        tint = following || d.tint == asShot.tint
    }

    /// The settings these boxes describe, keeping whatever the *unticked* axes
    /// hold. With both ticked it is `.asShot` — the state where the decode
    /// takes the camera's values rather than the stored ones.
    func decode(from d: DecodeSettings, asShot: AsShot?) -> DecodeSettings {
        guard let asShot else { return d }
        var out = d
        if temp { out.temperature = asShot.temperature }
        if tint { out.tint = asShot.tint }
        out.whiteBalance = (temp && tint) ? .asShot : .custom
        return out
    }

    /// The same, with one box ticked or unticked. `nil` leaves a box alone, so
    /// the Temp box's handler does not disturb the Tint box.
    func applying(temp now: Bool?, tint tintNow: Bool?,
                  to d: DecodeSettings, asShot: AsShot?) -> DecodeSettings {
        var boxes = self
        if let now { boxes.temp = now }
        if let tintNow { boxes.tint = tintNow }
        return boxes.decode(from: d, asShot: asShot)
    }
}

struct CropRect: Codable, Equatable, Sendable {
    /// Normalised to the image, origin top-left.
    var x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1
    static let full = CropRect()
    var isFull: Bool { self == .full }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct Sidecar: Codable, Equatable, Sendable {
    var schemaVersion = 3
    var decoder = "coreimage"
    var decode = DecodeSettings()
    var params = FilmParams.default
    var adjustments = Adjustments.default
    /// Crop, straighten, quarter turns and flips (`Model/Geometry.swift`).
    var geometry = Geometry.default
    /// Local adjustments (`Model/Mask.swift`). Layer 2, like the right panel
    /// they live in.
    var masks: [EditMask] = []
    /// The solve the service returned for this frame (EV, filter neutrals),
    /// kept so the UI can show the sliders as offsets from it.
    var solvedEV: Double?
    var state: FrameState = .unprocessed
    /// Which file this belongs to, and enough about it to find it again after
    /// it is moved or renamed. Nil in a sidecar written before the store.
    var source: Source?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, decoder, decode, params, adjustments, geometry, masks, solvedEV, state
        /// Which file these settings belong to (`Source`). Written from the
        /// store's first version; absent in every sidecar that predates it.
        case source
        /// Schema 2's field. Read, never written.
        case crop
    }

    init() {}

    /// Schema 2 stored a bare `crop` and had no angle, turns or flips. It
    /// decodes into `geometry.crop` unchanged — the two mean the same thing
    /// at angle 0 — so an existing sidecar opens with its crop intact rather
    /// than silently resetting to the full frame.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        self.decoder = try c.decodeIfPresent(String.self, forKey: .decoder) ?? "coreimage"
        decode = try c.decodeIfPresent(DecodeSettings.self, forKey: .decode) ?? DecodeSettings()
        params = try c.decodeIfPresent(FilmParams.self, forKey: .params) ?? .default
        adjustments = try c.decodeIfPresent(Adjustments.self, forKey: .adjustments) ?? .default
        solvedEV = try c.decodeIfPresent(Double.self, forKey: .solvedEV)
        state = try c.decodeIfPresent(FrameState.self, forKey: .state) ?? .unprocessed
        masks = try c.decodeIfPresent([EditMask].self, forKey: .masks) ?? []
        source = try c.decodeIfPresent(Source.self, forKey: .source)
        if let g = try c.decodeIfPresent(Geometry.self, forKey: .geometry) {
            geometry = g
        } else if let legacy = try c.decodeIfPresent(CropRect.self, forKey: .crop) {
            geometry = Geometry(crop: legacy)
        }
        schemaVersion = 3
    }

    /// Schema 2's `crop` is deliberately not written back: one field, one
    /// meaning. A file written here and read by an older build loses its
    /// crop, which is the honest outcome — that build cannot honour the
    /// angle or the turns either.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(decoder, forKey: .decoder)
        try c.encode(decode, forKey: .decode)
        try c.encode(params, forKey: .params)
        try c.encode(adjustments, forKey: .adjustments)
        try c.encode(geometry, forKey: .geometry)
        if !masks.isEmpty { try c.encode(masks, forKey: .masks) }
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(solvedEV, forKey: .solvedEV)
        try c.encode(state, forKey: .state)
    }

    // MARK: - where a frame's settings live

    /// `~/Library/Application Support/SpektraLab/Sidecars/`.
    ///
    /// **Not beside the image**, which is where these used to go and which
    /// the user objected to in plain terms: opening a folder of RAWs littered
    /// their Pictures library with `_DSC2949.NEF.spektra.json`.
    ///
    /// **And not inside the app bundle**, which was the suggestion. That one
    /// cannot work, for three separate reasons, any one of which is fatal:
    /// the bundle is code-signed, so writing into it breaks the signature and
    /// Gatekeeper then refuses to launch the app at all; it is replaced
    /// wholesale by the next update, taking every edit with it; and it
    /// frequently is not writable anyway — `/Applications` needs admin
    /// rights, and an app run from a quarantined download is path-randomised
    /// into a read-only image. Application Support is the directory macOS
    /// provides for exactly this: per-user, writable, backed up by Time
    /// Machine, and untouched by an app update.
    static var storeDirectory: URL { storeOverride.value ?? defaultStoreDirectory }

    /// The real store, ignoring any override. Tests assert on this.
    static let defaultStoreDirectory: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SpektraLab")
            .appending(path: "Sidecars")

    /// Where the store actually is. Nil means the real one.
    ///
    /// Under XCTest this defaults to a directory of its own, and that is not
    /// tidiness — it is correctness. The suite copies its fixtures to a fresh
    /// temporary folder on every run (`develop-writes-a-sidecar-copy-the-fixture`),
    /// so each run hashes to keys nothing will ever look up again. Beside the
    /// image those files died with the temp folder; in a central store they
    /// accumulate in the user's Application Support for ever, and every
    /// identity lookup then has to scan them. One night of runs left 90 files
    /// for four fixtures.
    private static let storeOverride = Guarded<URL?>(
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? nil
            : FileManager.default.temporaryDirectory
                .appending(path: "spektralab-test-sidecars-\(ProcessInfo.processInfo.processIdentifier)"))

    /// Point the store somewhere else. For tests that want to inspect it.
    static func useStore(at url: URL?) {
        storeOverride.value = url
        index.value = nil
    }

    /// The store file name for an image: its own name, then a digest of its
    /// absolute path.
    ///
    /// The name is there so the folder can be read by a human; the digest is
    /// what makes it unique. Two frames called `_DSC2949.NEF` in two
    /// different shoots are different pictures and must not share settings,
    /// and a flat store keyed on the basename alone would silently merge
    /// them — the same class of collision that
    /// `HANDOFF-FRONTEND-POLISH §3.2` records for `a.NEF` / `a.tif`, which is
    /// why the extension stays in the name here too.
    ///
    /// 16 hex digits, not 12. The digest is a *name*, and a collision between
    /// two real frames merges one photograph's edits into another silently —
    /// there is no error to notice. 64 bits puts the birthday bound past any
    /// library that will ever exist; 48 bits does not, quite, and the four
    /// extra characters cost nothing.
    ///
    /// `standardizedFileURL` so `/tmp/a/../a/x.NEF` and `/tmp/a/x.NEF` are
    /// one frame. Symlinks are deliberately *not* resolved: that would touch
    /// the disk on every lookup, and this has to be cheap enough to call per
    /// frame while a folder is being listed.
    static func key(for image: URL) -> String {
        let path = image.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return "\(image.lastPathComponent)-\(hex).spektra.json"
    }

    static func url(for image: URL) -> URL { storeDirectory.appending(path: key(for: image)) }

    // MARK: - which file these settings belong to

    /// Enough about a file to recognise it again after it has been moved,
    /// renamed, or copied to another disk.
    ///
    /// The key above is the file's **path**, which makes the common lookup
    /// free but means a photograph that moves loses its edits — the app sees
    /// a new image with no settings, and the old sidecar becomes an orphan
    /// nobody can identify. Beside the image that never happened, because the
    /// sidecar travelled with the picture; a central store has to earn that
    /// back, and this is how.
    ///
    /// Three ways to recognise the same file, cheapest first:
    ///
    ///  - **volume + inode.** Survives a rename or a move anywhere within one
    ///    disk, which is what nearly every reorganisation is. Free: it is a
    ///    `stat`.
    ///  - The path, which is the key itself.
    ///
    /// An inode can be reused after a file is deleted, so an inode match is
    /// only trusted when the size matches too.
    ///
    /// **Content is deliberately not a way of recognising a file.** An
    /// earlier version also matched on size plus a digest of the first 64 KB,
    /// so that edits would survive a copy to another disk. That is wrong, and
    /// the suite caught it: byte-identical files are not the same
    /// photograph. Delete a frame and later add an identical one — which is
    /// what the tests do every run, copying one fixture into a fresh
    /// temporary folder each time — and the new file inherits the dead one's
    /// grade. Two `OpenPathTests` cases began failing because a frame arrived
    /// carrying a white balance nobody had set on it, so the change under
    /// test was a no-op and no reopen ever started.
    ///
    /// Losing the edits on a cross-volume move is a visible, recoverable
    /// disappointment. Silently grading a photograph with another
    /// photograph's settings is neither. The digest is still *recorded*,
    /// because it makes the store diagnosable, but nothing matches on it.
    struct Source: Codable, Equatable, Sendable {
        var path: String
        var volumeID: Int?
        var inode: Int?
        var size: Int?
        /// Hex SHA-256 of the first 64 KB. Nil if the file could not be read.
        var headDigest: String?

        /// Whether these describe the same file. Deliberately not `==`: two
        /// `Source` values can disagree about the path and still be one file,
        /// which is the entire point.
        func matches(_ other: Source) -> Bool {
            guard let a = inode, let b = other.inode, a == b,
                  let va = volumeID, let vb = other.volumeID, va == vb,
                  let sa = size, let sb = other.size, sa == sb else { return false }
            return true
        }
    }

    static let headSampleBytes = 64 * 1024

    /// Read a file's identity. Never throws: an unreadable file simply has
    /// less identity, and the path key still works.
    static func identity(of image: URL, includingDigest: Bool = true) -> Source {
        let path = image.standardizedFileURL.path
        var source = Source(path: path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            source.inode = (attrs[.systemFileNumber] as? NSNumber)?.intValue
            source.volumeID = (attrs[.systemNumber] as? NSNumber)?.intValue
            source.size = (attrs[.size] as? NSNumber)?.intValue
        }
        guard includingDigest else { return source }
        if let handle = try? FileHandle(forReadingFrom: image) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: headSampleBytes) {
                source.headDigest = SHA256.hash(data: head)
                    .compactMap { String(format: "%02x", $0) }.joined()
            }
        }
        return source
    }

    /// The store, indexed by identity, built once and kept for the session.
    ///
    /// Only consulted on a **miss** — a frame whose path key has no file — so
    /// the common case never pays for it. Built in one pass rather than per
    /// lookup: opening a folder of 500 new frames is 500 misses, and scanning
    /// the store once each time would be quadratic for no reason.
    private static let index = Guarded<[(source: Source, url: URL)]?>(nil)

    private static func identityIndex() -> [(source: Source, url: URL)] {
        if let cached = index.value { return cached }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)) ?? []
        let built: [(Source, URL)] = names.filter { $0.hasSuffix(".spektra.json") }.compactMap { name in
            let url = storeDirectory.appending(path: name)
            guard let data = try? Data(contentsOf: url),
                  let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data),
                  let source = sidecar.source else { return nil }
            return (source, url)
        }
        index.value = built
        return built
    }

    /// Record a write in the cached index instead of discarding it.
    ///
    /// Throwing the index away on every save was quadratic: each following
    /// miss rebuilt it by reading and decoding every file in the store, and a
    /// folder import is a miss per frame. Keeping it current costs one array
    /// edit.
    private static func noteWrite(_ source: Source, at url: URL) {
        guard var current = index.value else { return }
        current.removeAll { $0.url == url }
        current.append((source, url))
        index.value = current
    }

    private static func noteRemoval(of url: URL) {
        guard var current = index.value else { return }
        current.removeAll { $0.url == url }
        index.value = current
    }

    /// Every sidecar in the store whose frame is no longer where it was, with
    /// the path it remembers. The basis for a "clean up" that can say what it
    /// is about to remove instead of guessing — nothing here deletes, because
    /// an absent file is as likely to be an unmounted volume as a deleted
    /// photograph.
    static func orphans() -> [(url: URL, rememberedPath: String)] {
        identityIndex()
            .filter { !FileManager.default.fileExists(atPath: $0.source.path) }
            .map { ($0.url, $0.source.path) }
    }

    // MARK: - the two names that lived beside the image

    /// The old home: `<original>.spektra.json` beside the image. Read for
    /// migration, and **moved** rather than copied — leaving it would leave
    /// the mess the user asked to be rid of. The name is unambiguous (it
    /// carries the full file name), so deleting it cannot destroy a sibling's
    /// settings.
    static func neighbourURL(for image: URL) -> URL {
        image.deletingLastPathComponent()
            .appending(path: image.lastPathComponent + ".spektra.json")
    }

    /// The oldest name, from before the extension was kept. Read once and
    /// migrated, but **never deleted**: `a.NEF` and `a.tif` in one folder
    /// both resolve to `a.spektra.json`, so it may belong to a sibling and
    /// removing it would destroy that frame's settings.
    static func legacyURL(for image: URL) -> URL {
        image.deletingPathExtension().appendingPathExtension("spektra.json")
    }

    static func load(for image: URL) -> Sidecar? {
        // 1. Where this frame's settings are if it has not moved.
        if let data = try? Data(contentsOf: url(for: image)),
           let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
            return sidecar
        }

        // 2. The frame may have been moved or renamed since it was last
        //    edited, in which case its settings are in the store under the
        //    *old* path's key. Recognise the file itself and re-key it, so
        //    the move costs one scan and never happens again for this frame.
        let wanted = identity(of: image, includingDigest: false)
        if wanted.inode != nil,
           let hit = identityIndex().first(where: { candidate in
               // The frame this sidecar was written for must be **gone** from
               // where it used to be. Otherwise this is not the same
               // photograph that moved — it is a second copy of it, and two
               // copies of one file are two frames a photographer may want
               // graded differently. Without this, duplicating a folder would
               // silently make both copies share one set of edits, and the
               // first thing it actually broke was a test that copies one
               // fixture into several temporary directories: identical bytes,
               // identical digests, and the wrong sidecar answered.
               guard !FileManager.default.fileExists(atPath: candidate.source.path) else { return false }
               return candidate.source.matches(wanted)
           }),
           let data = try? Data(contentsOf: hit.url),
           var sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
            sidecar.source = wanted
            if (try? sidecar.save(for: image)) != nil, hit.url != url(for: image) {
                try? FileManager.default.removeItem(at: hit.url)
                noteRemoval(of: hit.url)
            }
            return sidecar
        }

        // 3. Migration from the two names that lived beside the image.
        let neighbour = neighbourURL(for: image)
        if let data = try? Data(contentsOf: neighbour),
           let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
            // Move, not copy — but only once the new copy is on disk and
            // readable. A failed write must leave the user's only copy of
            // their edits exactly where it was.
            if (try? sidecar.save(for: image)) != nil,
               (try? Data(contentsOf: url(for: image))) != nil {
                try? FileManager.default.removeItem(at: neighbour)
            }
            return sidecar
        }
        guard let data = try? Data(contentsOf: legacyURL(for: image)),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) else { return nil }
        try? sidecar.save(for: image)
        return sidecar
    }

    /// Remove every name — "reset to defaults" must not leave an older file
    /// that would be re-adopted on the next open. The ambiguous stem name is
    /// the one exception, for the reason `legacyURL` gives.
    static func remove(for image: URL) {
        try? FileManager.default.removeItem(at: url(for: image))
        try? FileManager.default.removeItem(at: neighbourURL(for: image))
        noteRemoval(of: url(for: image))
    }

    func save(for image: URL) throws {
        let destination = Sidecar.url(for: image)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Stamped on every write, so a sidecar always knows which file it
        // belongs to and the store can be read without the app.
        var out = self
        out.source = Sidecar.identity(of: image)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: destination, options: .atomic)
        Sidecar.noteWrite(out.source ?? Sidecar.identity(of: image), at: destination)
    }
}
