//  ExportRecipe.swift — a named, saved answer to "where, called what, in what".
//
//  The export sheet used to be one radio group: pick a format, and everything
//  else — the folder, the filename, the colour space — was decided in
//  `Exporter` and could not be argued with. That is fine for one person
//  exporting one frame and useless the moment the same person has two
//  destinations they use every week (Capture One calls these 配方 / recipes,
//  and `PRD/export_page_reference_capture_one.png` is the shape the user
//  asked for).
//
//  Three things live here and nothing else does:
//
//  1. `ExportRecipe` — the saved settings, `Codable`, kept in a JSON file the
//     user can read and edit by hand. The PRD asked for the recipes to be
//     "set in some separated json" in so many words, so the file is the
//     format of record and the UI is a way of writing it.
//  2. `ExportColorSpace` — which profile the file is tagged with, resolved
//     against **the profiles actually installed on this machine** rather than
//     a hard-coded list. A name we cannot resolve falls back rather than
//     failing the export, and says so.
//  3. `NamingRule` — the filename, as tokens, with a live sample. The sample
//     is the point: a naming scheme you cannot see the result of is a naming
//     scheme you get wrong once per batch.
//
//  What is deliberately *not* here: rendering. `Exporter` owns the pixels.
//  This file only answers where they go and what tag they carry.

// `@preconcurrency` because ColorSync's dictionary keys are imported as
// global `var`s of `Unmanaged<CFString>`, which Swift 6 reads as shared
// mutable state and refuses from the C callback in `installedRGBProfiles`.
// They are immutable constants in a system framework; this is the annotation
// that says so without hard-coding their string values.
@preconcurrency import ColorSync
import CoreGraphics
import Foundation
import ImageIO

// Read once, at file scope, so the `@convention(c)` callback below — which
// can capture nothing — can still reach them.
nonisolated(unsafe) private let kProfileColorSpace = kColorSyncProfileColorSpace.takeUnretainedValue()
nonisolated(unsafe) private let kProfileDescription = kColorSyncProfileDescription.takeUnretainedValue()
nonisolated(unsafe) private let kProfileURL = kColorSyncProfileURL.takeUnretainedValue()
private let colorSyncRGBSignature = kColorSyncSigRgbData.takeUnretainedValue() as String

// `ExportFormat` is declared in `Exporter.swift` as a `String` raw value, so
// this costs nothing and keeps the recipe file readable — a format reads as
// "TIFF 16-bit" in the JSON, not as an ordinal that shifts when a case is
// inserted.
extension ExportFormat: Codable {}

extension ExportFormat {
    /// Whether a colour space can be chosen at all. The DI package is
    /// normalised film density with a `.cube` beside it indexing exactly
    /// those numbers — tagging it with a rendering space invites whatever
    /// opens it to convert the values and move the cube's domain out from
    /// under it (`Exporter.exportDI`). So the choice is withheld rather than
    /// offered and ignored.
    var takesColorSpace: Bool { self != .di }
    /// 8-bit formats cannot carry a wide-gamut working space usefully.
    var isEightBit: Bool { self == .jpeg || self == .png }
    var takesQuality: Bool { self == .jpeg }

    /// The name the export page's Format pill shows. The raw value carries
    /// the bit depth (`"PNG 8-bit"`), because that is what the recipe file
    /// and the job log want to read; the page shows the depth in its own
    /// control beside it, so the pill would say it twice.
    var shortLabel: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .tiff: "TIFF"
        case .di: "DI package"
        }
    }

    /// The bits this container writes. Not a choice the page can offer
    /// independently of the format: `ExportFormat` *is* the pair, and a
    /// depth control that did nothing would be a control that lies.
    var bitDepth: Int { isEightBit ? 8 : 16 }

    /// The format that writes `depth` bits, when `format` has a counterpart at
    /// that depth. Only PNG and TIFF differ by depth and only from each other:
    /// JPEG has no 16-bit form, the DI package is one thing at one depth, and
    /// asking a format for the depth it already has is not a move. `nil` in
    /// all of those, which is what `depthIsChoosable` says in advance.
    static func withDepth(_ depth: Int, like format: ExportFormat) -> ExportFormat? {
        switch (format, depth) {
        case (.png, 16): return .tiff
        case (.tiff, 8): return .png
        default: return nil
        }
    }

    /// Whether the depth control has anywhere to go. False is drawn disabled
    /// rather than hidden: the row keeps its shape and says *why*.
    var depthIsChoosable: Bool { self == .png || self == .tiff }
}

// MARK: - colour space

/// A profile to tag the exported file with.
///
/// Two kinds, because the two have different failure modes. A built-in is a
/// `CGColorSpace` name that Core Graphics guarantees — it cannot go missing.
/// An installed profile is a file on this machine, which can be moved,
/// deleted, or live on a volume that is not mounted today; that one resolves
/// at export time and falls back when it cannot.
enum ExportColorSpace: Hashable, Codable, Sendable {
    /// A `CGColorSpace` name (`kCGColorSpaceDisplayP3` and friends), stored
    /// as its string value so the JSON stays legible.
    case builtIn(String)
    /// An ICC profile installed on this machine, by file path.
    case installed(path: String)

    static let displayP3 = ExportColorSpace.builtIn(CGColorSpace.displayP3 as String)
    static let sRGB = ExportColorSpace.builtIn(CGColorSpace.sRGB as String)

    /// The profile, or `nil` when it cannot be resolved on this machine.
    /// Callers fall back; they do not fail the export over a tag.
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .builtIn(let name):
            return CGColorSpace(name: name as CFString)
        case .installed(let path):
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return CGColorSpace(iccData: data as CFData)
        }
    }
}

/// What the colour-space picker offers: the profiles this machine actually
/// has, plus the handful Core Graphics guarantees.
///
/// The PRD asked for "available color space read from the system", and this
/// is that read. It is done once and cached: `ColorSyncIterateInstalledProfiles`
/// walks every profile in every ColorSync search path, which is slow enough
/// to be worth not doing inside a SwiftUI body.
enum ColorSpaceCatalog {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { space.hashValue.description + name }
        let name: String
        let space: ExportColorSpace
        /// True for the guaranteed ones, which sort first.
        let isBuiltIn: Bool
    }

    /// Always present, whatever ColorSync reports, and in the order a
    /// photographer reaches for them.
    static let builtIns: [Entry] = [
        Entry(name: "Display P3", space: .builtIn(CGColorSpace.displayP3 as String), isBuiltIn: true),
        Entry(name: "sRGB", space: .builtIn(CGColorSpace.sRGB as String), isBuiltIn: true),
        Entry(name: "Adobe RGB (1998)", space: .builtIn(CGColorSpace.adobeRGB1998 as String), isBuiltIn: true),
        Entry(name: "ROMM RGB (ProPhoto)", space: .builtIn(CGColorSpace.rommrgb as String), isBuiltIn: true),
        Entry(name: "Rec. 2020", space: .builtIn(CGColorSpace.itur_2020 as String), isBuiltIn: true),
    ].filter { $0.space.cgColorSpace != nil }

    /// Built-ins first, then every installed RGB profile, de-duplicated by
    /// name so the five above do not appear twice (they are installed as
    /// files too, and a picker with "sRGB" in it twice is a picker nobody
    /// trusts).
    static let all: [Entry] = {
        var seen = Set(builtIns.map { $0.name.lowercased() })
        var out = builtIns
        for e in installedRGBProfiles() where !seen.contains(e.name.lowercased()) {
            seen.insert(e.name.lowercased())
            out.append(e)
        }
        return out
    }()

    static func name(for space: ExportColorSpace) -> String? {
        all.first { $0.space == space }?.name
    }

    /// Every installed profile whose data space is RGB, by description and
    /// file URL, sorted by name.
    ///
    /// Only RGB: the catalogue is for tagging an RGB export, and offering the
    /// machine's CMYK and grey profiles in that picker is offering choices
    /// that cannot work. Anything without a description, a URL, or an RGB
    /// data space is skipped rather than guessed at.
    private static func installedRGBProfiles() -> [Entry] {
        var found: [Entry] = []
        withUnsafeMutablePointer(to: &found) { sink in
            ColorSyncIterateInstalledProfiles({ info, userInfo in
                guard let info = info as? [CFString: Any],
                      let userInfo else { return true }
                // The data space is the **string** "RGB " rather than the
                // four-char code the name `kColorSyncSigRgbData` suggests.
                // Established by dumping a real profile dictionary; guessing
                // it produces a picker that is silently always empty, which
                // is the kind of check that cannot fail.
                guard info[kProfileColorSpace] as? String == colorSyncRGBSignature else { return true }
                guard let description = info[kProfileDescription] as? String,
                      !description.isEmpty,
                      let url = info[kProfileURL] as? URL else { return true }
                let sink = userInfo.assumingMemoryBound(to: [Entry].self)
                sink.pointee.append(Entry(name: description,
                                          space: .installed(path: url.path),
                                          isBuiltIn: false))
                return true
            }, nil, UnsafeMutableRawPointer(sink), nil)
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - naming

/// One piece of a filename.
///
/// **Four, and only four** — `notes.md` is the authority: "Four Naming
/// options, Original Name, Film, Print, Date are provided and user can only
/// choose between these four". There used to be six (`dimensions`,
/// `counter`), and the page offered no order control at all. `dimensions` and
/// `counter` still decode out of an old recipe file and are dropped on read,
/// which is what `NamingRule.init(from:)` is for.
enum NameToken: String, Codable, CaseIterable, Identifiable, Sendable {
    case originalName, filmStock, printStock, date

    var id: String { rawValue }

    var label: String {
        switch self {
        case .originalName: "Original Name"
        case .filmStock: "Film"
        case .printStock: "Print"
        case .date: "Date"
        }
    }
}

/// The filename, as the selected tokens joined by a separator.
///
/// Deliberately not a printf-style format string: a format string is a thing
/// you get wrong silently, and the whole value of this control is the sample
/// underneath it, which a token list can always produce.
///
/// Two lists, and the split is the point. `order` holds **all four** tokens in
/// the order the chip row shows them, which `notes.md` says the user drags
/// into shape; `tokens` holds the ones switched on. The filename is
/// `order.filter(tokens.contains)` — so the row's order *is* the output order
/// and there is no third thing to keep in step.
struct NamingRule: Codable, Hashable, Sendable {
    /// Switched on. Never empty: `notes.md` says at least one must be
    /// selected, and the setters here are what make that true rather than a
    /// rule the view is trusted to remember.
    private(set) var tokens: [NameToken] = [.originalName, .filmStock, .printStock]
    /// Every token, in the row's order.
    private(set) var order: [NameToken] = NameToken.allCases
    var separator: String = "_"

    init() {}

    struct Context: Sendable {
        var originalName: String
        var filmStock: String
        var printStock: String
        var pixelSize: CGSize
        var counter: Int
        var date: Date
    }

    // MARK: editing

    var chosen: [NameToken] { order.filter { tokens.contains($0) } }

    func isOn(_ t: NameToken) -> Bool { tokens.contains(t) }

    /// Turn a token on, or off — **unless it is the last one on**, in which
    /// case nothing happens. Refusing here rather than disabling the chip in
    /// the view is what makes "at least one" a property of the model: the
    /// view has no state of its own that could bypass it.
    mutating func toggle(_ t: NameToken) {
        if let i = tokens.firstIndex(of: t) {
            guard tokens.count > 1 else { return }
            tokens.remove(at: i)
        } else {
            tokens = order.filter { tokens.contains($0) || $0 == t }
        }
    }

    /// Drag one chip to another position in the row. Both lists move together
    /// so `tokens` keeps its invariant of being a subset of `order`.
    mutating func move(_ t: NameToken, before target: NameToken) {
        guard t != target,
              let from = order.firstIndex(of: t),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        // The target's index is one lower once `t` is out of the list, which
        // is the difference between dropping a chip *on* its neighbour and
        // dropping it one place past.
        order.insert(t, at: from < to ? to - 1 : to)
        tokens = order.filter { tokens.contains($0) }
    }

    /// Every token back to its canonical place, leaving the selection alone.
    mutating func resetOrder() { order = NameToken.allCases }

    /// The chip row as drawn: all four, in the row's order.
    var chips: [NameToken] { order }

    // MARK: output

    /// The filename stem — no extension, and no directory.
    ///
    /// A rule whose every token renders empty falls back to the original
    /// name: an empty stem is a way to overwrite one file repeatedly.
    func stem(_ c: Context) -> String {
        let parts = chosen.compactMap { t -> String? in
            let s: String
            switch t {
            case .originalName: s = c.originalName
            case .filmStock: s = c.filmStock
            case .printStock: s = c.printStock
            case .date: s = NamingRule.dateFormatter.string(from: c.date)
            }
            return s.isEmpty ? nil : s
        }
        let joined = parts.joined(separator: separator)
        guard !joined.isEmpty else { return c.originalName }
        // A filename cannot carry a path separator, whatever a stock name
        // happens to contain.
        return joined.replacingOccurrences(of: "/", with: "-")
                     .replacingOccurrences(of: ":", with: "-")
    }

    // MARK: coding

    /// Read leniently, on purpose. A recipe file is a document a person can
    /// edit, and one the *previous* version of this app wrote — so a token
    /// this build no longer has is dropped rather than allowed to fail the
    /// whole decode, which would take every other recipe in the file with it
    /// and show the user the built-in defaults instead of their own settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        separator = (try? c.decode(String.self, forKey: .separator)) ?? "_"
        let rawOrder = (try? c.decode([String].self, forKey: .order)) ?? []
        let rawTokens = (try? c.decode([String].self, forKey: .tokens)) ?? []
        let known = rawOrder.compactMap(NameToken.init(rawValue:))
        // Anything the file did not mention keeps its canonical place, so a
        // file written before `order` existed still gets all four chips.
        order = known + NameToken.allCases.filter { !known.contains($0) }
        var on = rawTokens.compactMap(NameToken.init(rawValue:))
        if on.isEmpty { on = [.originalName] }
        tokens = order.filter { on.contains($0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(separator, forKey: .separator)
    }

    private enum CodingKeys: String, CodingKey { case tokens, order, separator }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The sample the UI shows under the token row.
    static let sampleContext = Context(originalName: "_DSC4037", filmStock: "portra400",
                                       printStock: "endura", pixelSize: CGSize(width: 5451, height: 3634),
                                       counter: 1, date: Date())
}

// MARK: - size

/// The pixels the export should write.
///
/// `.original` is the frame's own size after the crop and the straighten —
/// what the export path writes today, and the only thing it can write: see
/// `ExportRecipe.outputSize`'s note.
enum OutputSize: Hashable, Codable, Sendable {
    case original
    case custom(width: Int, height: Int)

    var isOriginal: Bool { self == .original }
}

// MARK: - open with

/// An application to hand the finished files to, or none.
///
/// Stored by path rather than by bundle identifier because that is what
/// `NSWorkspace` opens and what the picker returns; a path that has moved
/// since is reported when the export finishes rather than at pick time.
struct OpenWith: Hashable, Codable, Sendable {
    var path: String
    var name: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
}

// MARK: - destination

/// Where the files land.
enum ExportFolder: Hashable, Codable, Sendable {
    /// Beside the frame that was opened — today's behaviour, and still the
    /// default, because it is the one that needs no setting up.
    case besideOriginal
    /// A folder the user chose. Stored as a path; a path that no longer
    /// exists is reported at export time rather than silently recreated
    /// somewhere else.
    case fixed(path: String)
}

/// What to do when the file already exists.
enum ExistingFilePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case addSuffix, overwrite, skip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .addSuffix: "Add a suffix"
        case .overwrite: "Overwrite"
        case .skip: "Skip"
        }
    }
}

// MARK: - the recipe

struct ExportRecipe: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String = "Untitled"
    var format: ExportFormat = .jpeg
    var colorSpace: ExportColorSpace = .displayP3
    var folder: ExportFolder = .besideOriginal
    /// A subfolder created inside `folder`. Empty means none. The default is
    /// `_prints`, which is where exports have always gone.
    var subfolder: String = "_prints"
    var naming = NamingRule()
    var existing: ExistingFilePolicy = .addSuffix
    /// JPEG only, 0…1.
    var quality: Double = 0.95
    /// The pixels to write. Applied by `Exporter.exportPrint` through
    /// `Renderer.applyResize` — the same `geometryResample` the canvas
    /// samples with — after the geometry and *before* the output transform,
    /// so the proof's clipping statistics describe the pixels that reach the
    /// file rather than a larger set that was resampled away.
    var outputSize: OutputSize = .original
    /// Hand the finished files to this application. `nil` is "None", which is
    /// the default and opens nothing.
    var openWith: OpenWith?

    /// Read leniently for the same reason `NamingRule.init(from:)` does: a
    /// recipe file written by an earlier build is missing every field added
    /// since, and a decode that threw over one absent key would replace the
    /// user's whole file with the built-in defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        format = (try? c.decode(ExportFormat.self, forKey: .format)) ?? .jpeg
        colorSpace = (try? c.decode(ExportColorSpace.self, forKey: .colorSpace)) ?? .displayP3
        folder = (try? c.decode(ExportFolder.self, forKey: .folder)) ?? .besideOriginal
        subfolder = (try? c.decode(String.self, forKey: .subfolder)) ?? "_prints"
        naming = (try? c.decode(NamingRule.self, forKey: .naming)) ?? NamingRule()
        existing = (try? c.decode(ExistingFilePolicy.self, forKey: .existing)) ?? .addSuffix
        quality = (try? c.decode(Double.self, forKey: .quality)) ?? 0.95
        outputSize = (try? c.decode(OutputSize.self, forKey: .outputSize)) ?? .original
        openWith = try? c.decodeIfPresent(OpenWith.self, forKey: .openWith)
    }

    init(id: UUID = UUID(), name: String = "Untitled", format: ExportFormat = .jpeg,
         colorSpace: ExportColorSpace = .displayP3, folder: ExportFolder = .besideOriginal,
         subfolder: String = "_prints", naming: NamingRule = NamingRule(),
         existing: ExistingFilePolicy = .addSuffix, quality: Double = 0.95,
         outputSize: OutputSize = .original, openWith: OpenWith? = nil) {
        self.id = id
        self.name = name
        self.format = format
        self.colorSpace = colorSpace
        self.folder = folder
        self.subfolder = subfolder
        self.naming = naming
        self.existing = existing
        self.quality = quality
        self.outputSize = outputSize
        self.openWith = openWith
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, format, colorSpace, folder, subfolder, naming, existing, quality,
             outputSize, openWith
    }

    /// The directory this recipe writes into for a given source frame,
    /// **without creating it** — creation belongs to the export, which is the
    /// only place that can report the failure to the user.
    func directory(for source: URL) -> URL {
        let base: URL
        switch folder {
        case .besideOriginal: base = source.deletingLastPathComponent()
        case .fixed(let path): base = URL(fileURLWithPath: path)
        }
        let sub = subfolder.trimmingCharacters(in: .whitespaces)
        return sub.isEmpty ? base : base.appending(path: sub)
    }

    /// The full destination, honouring `existing`. Returns `nil` only for
    /// `.skip` when the file is already there — the one case where "no URL"
    /// is the answer rather than an error.
    func destination(for source: URL, context: NamingRule.Context,
                     fileManager: FileManager = .default) -> URL? {
        let dir = directory(for: source)
        let stem = naming.stem(context)
        let first = dir.appending(path: "\(stem).\(format.ext)")
        guard fileManager.fileExists(atPath: first.path) else { return first }
        switch existing {
        case .overwrite: return first
        case .skip: return nil
        case .addSuffix:
            // `-1`, `-2`, … the way every other exporter does it. Bounded so
            // a directory that somehow refuses to stop matching cannot spin.
            for n in 1...9999 {
                let u = dir.appending(path: "\(stem)-\(n).\(format.ext)")
                if !fileManager.fileExists(atPath: u.path) { return u }
            }
            return first
        }
    }

    /// `outputSize` as the export path wants it: a size in pixels, or nil for
    /// the frame's own. Kept here rather than in `Exporter` so the page and
    /// the file read the same field through the same accessor — a second
    /// reading of `.custom` is a second chance to round it differently.
    var pixelSize: CGSize? {
        switch outputSize {
        case .original: nil
        case .custom(let w, let h): w > 0 && h > 0 ? CGSize(width: w, height: h) : nil
        }
    }

    /// The profile to tag with, resolved against this machine, with the
    /// fallback stated. `nil` colour space means "the format decides", which
    /// is what the DI package needs.
    func resolvedColorSpace() -> (space: CGColorSpace?, fellBack: Bool) {
        guard format.takesColorSpace else { return (nil, false) }
        if let s = colorSpace.cgColorSpace { return (s, false) }
        return (CGColorSpace(name: CGColorSpace.displayP3), true)
    }

    static let defaults: [ExportRecipe] = [
        ExportRecipe(name: "JPEG — Display P3", format: .jpeg, colorSpace: .displayP3),
        ExportRecipe(name: "TIFF 16-bit — ProPhoto", format: .tiff,
                     colorSpace: .builtIn(CGColorSpace.rommrgb as String)),
        ExportRecipe(name: "PNG 8-bit — sRGB", format: .png, colorSpace: .sRGB),
        ExportRecipe(name: "DI package", format: .di, colorSpace: .displayP3, subfolder: "_prints"),
    ]
}

// MARK: - the store

/// The recipes, in a JSON file the user can open.
///
/// `~/Library/Application Support/Filmify/export-recipes.json`. Written
/// atomically, read once at startup, and **never fatal**: a file that has
/// been hand-edited into something unparseable falls back to the defaults and
/// reports it, because losing the ability to export over a typo in a settings
/// file would be the worse failure.
@MainActor
@Observable
final class ExportRecipeStore {
    private(set) var recipes: [ExportRecipe]
    /// Set when the file could not be read or written, for the UI to show.
    /// Nil when everything is fine.
    private(set) var problem: String?

    var selectedID: UUID?

    var selected: ExportRecipe? {
        get { recipes.first { $0.id == selectedID } ?? recipes.first }
        set {
            guard let newValue, let i = recipes.firstIndex(where: { $0.id == newValue.id }) else { return }
            recipes[i] = newValue
            save()
        }
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Filmify")
        return dir.appending(path: "export-recipes.json")
    }()

    /// The file this store reads and writes. Injectable so a test can point
    /// at a temporary directory — a test that exercised the real path would
    /// overwrite the user's own recipes, which is not a thing a test may do.
    let url: URL

    init(url: URL = ExportRecipeStore.url) {
        self.url = url
        let loaded = Self.load(from: url)
        recipes = loaded.recipes
        problem = loaded.problem
        selectedID = recipes.first?.id
        // Seed the file on first run, so "set in some separated json" is true
        // from the first launch rather than after the first edit.
        if loaded.problem == nil, !FileManager.default.fileExists(atPath: url.path) { save() }
    }

    private static func load(from url: URL) -> (recipes: [ExportRecipe], problem: String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (ExportRecipe.defaults, nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([ExportRecipe].self, from: data)
            // An empty array is a file that says "no recipes", which is not a
            // state the UI can do anything with.
            return decoded.isEmpty ? (ExportRecipe.defaults, nil) : (decoded, nil)
        } catch {
            return (ExportRecipe.defaults,
                    "\(url.lastPathComponent) could not be read (\(error.localizedDescription)). Using the built-in recipes; your file has not been changed.")
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipes).write(to: url, options: .atomic)
            problem = nil
        } catch {
            problem = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func add() {
        var r = ExportRecipe(name: "Untitled")
        r.id = UUID()
        recipes.append(r)
        selectedID = r.id
        save()
    }

    func duplicate(_ r: ExportRecipe) {
        var copy = r
        copy.id = UUID()
        copy.name = r.name + " copy"
        recipes.append(copy)
        selectedID = copy.id
        save()
    }

    /// Removing the last recipe would leave the sheet with nothing to show
    /// and no way back, so it is refused rather than allowed and worked
    /// around.
    func remove(_ r: ExportRecipe) {
        guard recipes.count > 1, let i = recipes.firstIndex(where: { $0.id == r.id }) else { return }
        recipes.remove(at: i)
        if selectedID == r.id { selectedID = recipes.first?.id }
        save()
    }
}
