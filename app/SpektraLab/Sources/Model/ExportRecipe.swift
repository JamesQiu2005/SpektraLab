//  ExportRecipe.swift — what Export makes: format, size, colour, where it goes.
//
//  The desktop's recipes on a sheet (design/flow, E1): Format, Size, Colour,
//  Quality, and Save to Files or Share. The host's recipe is the
//  small one — no naming templates, no Digital Intermediate.
//
//  **A recipe is saved under a name** (the owner, 2026-10-08: "an actual
//  create export recipe feature must exist"), as the desktop's are
//  (`Export/ExportRecipe.swift` there, the maintainer's): the ones the app
//  starts with, and whatever the user saves beside them (`ExportRecipeStore`).
//  Four containers and four colour spaces, every pair of them offered:
//  HEIF, JPEG, PNG and TIFF; sRGB, Adobe RGB, Display P3 and ProPhoto RGB.
//
//  **The format is the pair**, as on the desktop: a container and the bits it
//  writes. JPEG, HEIF and PNG are 8 bits a channel, TIFF is 16. A depth
//  control beside it would be a second way to say the same thing.
//
//  **Every size develops again from the original.** An export is never an
//  upscaled preview: the size named here is the size the engine renders, and
//  when the original cannot be read (its disk is unplugged) the only size on
//  offer is the preview copy's, named as that (F4), with the file's name saying
//  so. A reduced render is never labelled full (AGENTS.md).

import Foundation

struct ExportRecipe: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey {
        case id = "id", title = "title", format = "format", size = "size", colour = "colour", quality = "quality",
            destination = "destination"
    }
    enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg = "JPEG", heif = "HEIF", png = "PNG", tiff = "TIFF"
        var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heif: "heic"
            case .png: "png"
            case .tiff: "tif"
            }
        }
        /// TIFF is 16-bit; the other three are 8.
        var bitDepth: Int { self == .tiff ? 16 : 8 }
        /// JPEG and HEIF lose a little to be small, and say how much. PNG and
        /// TIFF keep every value they are handed.
        var takesQuality: Bool { self == .jpeg || self == .heif }
        /// "TIFF 16-bit": the format with its depth where the depth is not the
        /// usual eight.
        var title: String { self == .tiff ? L("TIFF 16-bit") : rawValue }
    }

    enum Size: Codable, Equatable, Hashable, Sendable {
        /// The keys as they are written: a case's name and its labels are keys, and must not move with a rename.
        enum CodingKeys: String, CodingKey {
            case full = "full", megapixels = "megapixels", longEdge = "longEdge", shortEdge = "shortEdge",
                preview = "preview"
        }
        enum MegapixelsCodingKeys: String, CodingKey { case _0 = "_0" }
        enum LongEdgeCodingKeys: String, CodingKey { case _0 = "_0" }
        enum ShortEdgeCodingKeys: String, CodingKey { case _0 = "_0" }
        /// The original's own size, up to the device's cap.
        case full
        /// A pixel count: 12 MP is the size Export offers beside Full (`twelveMegapixels`).
        case megapixels(Double)
        /// A long edge: 2048.
        case longEdge(Int)
        /// A short edge: 1080 (2026-10-20, the owner's custom size). Never larger than the original.
        case shortEdge(Int)
        /// The preview copy, when the original is away. Never called full.
        case preview

        var title: String {
            switch self {
            case .full: "Full"
            case .megapixels(let mp): "\(Int(mp)) MP"
            case .longEdge(let e): "\(e)"
            case .shortEdge(let e): "short \(e)"
            case .preview: "Preview"
            }
        }
        /// `title` as a page shows it. `title` itself is the log's word for the size, and stays English.
        var shownTitle: String { L(shown: title) }
    }

    /// The space the file's numbers are in, and the profile it carries.
    /// The picture is brought into it by the engine's own transform — its
    /// gamut compression, not a clip (`OutputTransform.swift`).
    enum Colour: String, Codable, CaseIterable, Sendable {
        case sRGB = "sRGB", adobeRGB = "Adobe RGB", displayP3 = "Display P3", proPhoto = "ProPhoto"
        /// The engine's name for the space (`spk_output_transform`'s `dst_cs`,
        /// `engine/src/core/colour.cpp`), which is also its name in full.
        var engineName: String {
            switch self {
            case .sRGB: "sRGB"
            case .adobeRGB: "Adobe RGB (1998)"
            case .displayP3: "Display P3"
            case .proPhoto: "ProPhoto RGB"
            }
        }
        /// As a menu names it: in full.
        var fullName: String { engineName }
    }

    enum Destination: String, Codable, CaseIterable, Sendable {
        case files = "Files", share = "Share"
        /// The raw value is what a kept recipe and the log say; this is the page's word for it.
        var shownTitle: String { L(shown: rawValue) }

        /// Words a 2.1 recipe may hold that name no destination now, and the one each is read as.
        /// "Photos" is the format's destination for the Photos library, which this app does not
        /// write to: 2.1 on the Mac never offered it and read it as Files, and so does this build.
        /// Written back as Files at the next save.
        static let retired: [String: Destination] = ["Photos": .files]

        /// A kept word, or a retired one (`retired`); anything else throws, and the recipe takes its
        /// default for the field (`ExportRecipe.init(from:)`).
        init(from decoder: Decoder) throws {
            let word = try decoder.singleValueContainer().decode(String.self)
            guard let d = Destination(rawValue: word) ?? Self.retired[word] else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "no destination \"\(word)\""))
            }
            self = d
        }
    }

    var id = UUID()
    /// The name it was saved under. Nil is a recipe named for what it makes.
    var title: String? = nil
    var format: Format = .jpeg
    /// Full: the picture's own pixels (the owner, 2026-10-20: a 45 MP RAW went out at 12 MP
    /// because every recipe started there).
    var size: Size = .full
    var colour: Colour = .displayP3
    /// 1…100, for JPEG and HEIF.
    var quality = 95
    var destination: Destination = .files

    /// "JPEG · Display P3", "TIFF 16-bit · ProPhoto": what a recipe makes, as
    /// its chip says it when it has no name of its own.
    var builtName: String { format.title + " · " + colour.rawValue }

    /// The recipe's chip, and Settings' Recipe row: the name it was saved
    /// under, or what it makes.
    var name: String { title ?? builtName }

    /// ProPhoto holds colours far outside what a screen shows, so its steps
    /// are wide: in 8 bits a smooth tone — a sky — can show them. Said under
    /// the Colour row, and never a reason to refuse the pair.
    var mayBand: Bool { colour == .proPhoto && format.bitDepth == 8 }

    /// Whether two recipes make the same file in the same place, whatever
    /// they are called.
    func sameSettings(as other: ExportRecipe) -> Bool {
        format == other.format && size == other.size && colour == other.colour
            && (!format.takesQuality || quality == other.quality) && destination == other.destination
    }

    /// The recipes the app starts with. Their ids are fixed, so a library that
    /// names one of them finds it in every build.
    ///
    /// JPEG · sRGB first (2026-10-20). A library that saved its recipes before it existed
    /// keeps its own list.
    static let builtIn: [ExportRecipe] = [
        ExportRecipe(id: UUID(uuidString: "5B1D0005-0000-4000-8000-53504B524543")!, format: .jpeg, colour: .sRGB),
        ExportRecipe(id: UUID(uuidString: "5B1D0001-0000-4000-8000-53504B524543")!, format: .jpeg, colour: .displayP3),
        ExportRecipe(id: UUID(uuidString: "5B1D0002-0000-4000-8000-53504B524543")!, format: .heif, colour: .displayP3),
        ExportRecipe(id: UUID(uuidString: "5B1D0003-0000-4000-8000-53504B524543")!, format: .tiff, colour: .proPhoto),
        ExportRecipe(id: UUID(uuidString: "5B1D0004-0000-4000-8000-53504B524543")!, format: .png, colour: .sRGB),
    ]

    /// What every recipe was made at until 2026-10-20, and what a library that never
    /// changed it still keeps: moved to Full once (`movedToFull`).
    static let formerDefaultSize = Size.megapixels(12)

    /// The pixel count Export offers beside Full: 12 MP.
    static let twelveMegapixels = 12.0

    /// The once-only move of a kept recipe off the former 12 MP default: the app's own
    /// recipes and the one Export opens with. A recipe the user saved under a name of
    /// their own keeps its size.
    static let movedToFullKey = "recipes.movedToFull.2026-10-20"

    /// The longest name a recipe is saved under: a chip holds about this much.
    static let longestTitle = 28

    /// A name as it is kept: trimmed, one line, no longer than a chip holds.
    /// Nil for a name with nothing in it.
    static func cleanTitle(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(longestTitle)).trimmingCharacters(in: .whitespaces)
    }

    /// A name as the words a chip may show of it, in order, which joined are
    /// the name: each word with the space after it, and a mark that stands
    /// between two words with the word it leads — "TIFF 16-bit · ProPhoto" is
    /// "TIFF ", "16-bit ", "· ProPhoto". A name written without spaces
    /// (Chinese, Japanese) is broken where its language breaks its words.
    ///
    /// For the recipes' row (`RecipeChips`): a chip partly off the page shows
    /// the words of its name that are whole on the page, and no part of
    /// another. The drawings' rule is "never a cut word", and until 2026-10-12
    /// the row kept it by showing such a chip with no words at all — which a
    /// tester of the beta took for a recipe with no name ("recipe名字空了").
    static func words(of name: String) -> [String] {
        // By spaces, each piece keeping the spaces after it.
        var pieces: [String] = []
        var piece = ""
        for character in name {
            if character != " ", piece.last == " " {
                pieces.append(piece)
                piece = ""
            }
            piece.append(character)
        }
        if !piece.isEmpty { pieces.append(piece) }
        // A piece with no letter and no digit in it is a mark: it leads the word after it.
        var words: [String] = []
        var mark = ""
        for piece in pieces {
            guard piece.contains(where: { $0.isLetter || $0.isNumber }) else { mark += piece; continue }
            words += unspaced(mark + piece)
            mark = ""
        }
        if !mark.isEmpty {
            if words.isEmpty { words = [mark] } else { words[words.count - 1] += mark }
        }
        return words
    }

    /// A piece with no space in it, as its words where its script writes them
    /// without one; whole otherwise ("16-bit" is one word, whatever a
    /// dictionary makes of its hyphen).
    private static func unspaced(_ piece: String) -> [String] {
        let unspacedScripts: [ClosedRange<UInt32>] = [0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F]
        guard piece.unicodeScalars.contains(where: { scalar in unspacedScripts.contains { $0.contains(scalar.value) } }) else { return [piece] }
        var starts: [String.Index] = []
        piece.enumerateSubstrings(in: piece.startIndex..., options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.lowerBound)
        }
        // From one word's first character to the next word's: what stands between two words stays with the first.
        guard starts.count > 1 else { return [piece] }
        starts[0] = piece.startIndex
        var words: [String] = []
        for i in starts.indices {
            let word = String(piece[starts[i]..<(i + 1 < starts.count ? starts[i + 1] : piece.endIndex)])
            // What the language's own breaking hands over with no letter in it — the space that ends
            // the piece — is no word: it stays with the one before.
            if word.contains(where: { $0.isLetter || $0.isNumber }) || words.isEmpty { words.append(word) } else { words[words.count - 1] += word }
        }
        return words
    }

    /// The pixels this recipe makes from a frame. `cap` is the device's develop
    /// cap in megapixels: a file larger than the device can develop is decoded
    /// smaller and labelled, never refused and never called full.
    func outputSize(original: PixelSize, preview: PixelSize, capMegapixels: Double) -> PixelSize {
        let capped = original.scaled(toMegapixels: capMegapixels)
        switch size {
        case .full: return capped
        case .megapixels(let mp): return capped.scaled(toMegapixels: mp)
        case .longEdge(let e): return capped.scaled(toLongEdge: e)
        case .shortEdge(let e): return capped.scaled(toShortEdge: e)
        case .preview: return preview
        }
    }

    /// "_DSC0061.jpg"; the preview size says so in its name: "R0000412_preview.jpg".
    func fileName(stem: String) -> String {
        (size == .preview ? stem + "_preview" : stem) + "." + format.fileExtension
    }
}

extension ExportRecipe {
    /// Read leniently, as the desktop reads its recipes: a file written by an
    /// earlier build has none of the fields added since, and one a person has
    /// edited may have a value this build does not know. Either keeps what it
    /// does say and takes the default for the rest — a decode that threw over
    /// one key would put the built-in recipes in place of the user's own.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)).flatMap(Self.cleanTitle)
        format = (try? c.decode(Format.self, forKey: .format)) ?? format
        size = (try? c.decode(Size.self, forKey: .size)) ?? size
        colour = (try? c.decode(Colour.self, forKey: .colour)) ?? colour
        quality = ((try? c.decode(Int.self, forKey: .quality)) ?? quality).clamped(to: 1...100)
        destination = (try? c.decode(Destination.self, forKey: .destination)) ?? destination
    }
}
