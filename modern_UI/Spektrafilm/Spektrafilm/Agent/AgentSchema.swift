//  AgentSchema.swift — the edit document an agent reads and patches (RFC-026 §3).
//
//  The document is the sidecar's four editable sections, `params`,
//  `adjustments`, `geometry` and `decode`, under their Codable names, and an
//  edit is a JSON merge patch over it. This file is the one table of what a
//  field means, what range the interface allows and whether it can be written
//  at all; `AgentSchemaTests` holds it to every stored field of the model, so
//  a field added to `FilmParams` without a row here fails the suite rather
//  than being silently out of an agent's reach.
//
//  **The ranges are the interface's, not the wire's.** Parity means an agent
//  can do what a person can, and a person cannot drag Exp. Comp. to +8 or the
//  couplers past 1.5 (trap 22). A value outside is refused, not clamped: an
//  agent that asked for +6 EV should hear that it did not get it.

import CoreGraphics
import Foundation

/// Why an agent call did not do what it asked. `refused` is the caller's to
/// fix (a value out of range, access switched off) and exits 2; `failed` is
/// ours (a decode or a render that went wrong) and exits 1.
enum AgentError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case failed(String)

    var description: String {
        switch self {
        case .refused(let s), .failed(let s): s
        }
    }
    var exitCode: Int32 {
        switch self {
        case .refused: 2
        case .failed: 1
        }
    }
}

struct AgentField: Sendable {
    enum Kind: Sendable {
        case number(ClosedRange<Double>)
        case integer(ClosedRange<Int>)
        case bool
        case choice([String])
        /// A stock id from the catalogue, of this stage.
        case film, paper
        /// A curve: `[[x, y], …]`, x ascending from 0 to 1, y in 0…1.
        case points
        /// `[width, height]`, normalised.
        case size
    }

    let path: String
    let kind: Kind
    let doc: String
    /// Why it cannot be written, or nil when it can.
    let readOnly: String?

    init(_ path: String, _ kind: Kind, _ doc: String, readOnly: String? = nil) {
        self.path = path; self.kind = kind; self.doc = doc; self.readOnly = readOnly
    }

    /// The row as `schema` prints it.
    @MainActor
    var json: JSONValue {
        var o: [String: JSONValue] = ["path": .string(path), "doc": .string(doc)]
        switch kind {
        case .number(let r):
            o["type"] = "number"; o["min"] = .number(r.lowerBound); o["max"] = .number(r.upperBound)
        case .integer(let r):
            o["type"] = "integer"; o["min"] = .number(Double(r.lowerBound)); o["max"] = .number(Double(r.upperBound))
        case .bool: o["type"] = "boolean"
        case .choice(let c): o["type"] = "string"; o["enum"] = .array(c.map(JSONValue.string))
        case .film:
            o["type"] = "string"
            o["enum"] = .array(StockCatalog.shared.films.map { .string($0.id) })
        case .paper:
            o["type"] = "string"
            o["enum"] = .array(StockCatalog.shared.papers.map { .string($0.id) })
        case .points: o["type"] = "points"
        case .size: o["type"] = "size"
        }
        if let readOnly { o["readOnly"] = .string(readOnly) }
        return .object(o)
    }
}

enum AgentSchema {
    static let sections = ["params", "adjustments", "geometry", "decode"]

    private static let viaPlace = "Scene Placement goes through the engine's Fit: use `place` / place_scene."

    static let fields: [AgentField] = {
        var f: [AgentField] = [
            // --- params: Layer 1, the engine's ---
            .init("params.filmStock", .film, "The negative (or slide) film. A slide film is scanned, not printed."),
            .init("params.printStock", .paper, "The paper. Refused while the film is a slide film."),
            .init("params.exposureCompensationEV", .number(-4...4), "Film Exposure, stops, added to the meter."),
            .init("params.autoExposureMethod", .choice(ExposureMethod.allCases.map(\.rawValue)),
                  "The meter's intent while autoExposure is on."),
            .init("params.autoExposure", .bool, "Metering. Off is the Custom method: Film Exposure alone, from the linearized frame."),
            .init("params.filmFormatMM", .number(4...200), "The frame's long edge on the wire.",
                  readOnly: "Derived from filmFrame, filmSide, sideLengthMM and the photograph's aspect."),
            .init("params.filmFrame", .choice(FilmFrame.all.map(\.id)), "Film Type: sets the grain, halation and diffusion scale."),
            .init("params.filmSide", .choice(FilmSide.allCases.map(\.rawValue)), "Which side sideLengthMM measures."),
            .init("params.sideLengthMM", .number(1...500), "Side Length. Setting it makes filmFrame Custom, as typing it does."),
            .init("params.grainActive", .bool, "Grain."),
            .init("params.halationActive", .bool, "Halation."),
            .init("params.printBrightnessStops", .number(-3...3), "Enlarger exposure, stops; positive prints brighter."),
            .init("params.yFilterShift", .number(-1...1), "Enlarger yellow filter offset from the solved neutral (yellow ↔ blue)."),
            .init("params.mFilterShift", .number(-1...1), "Enlarger magenta filter offset from the solved neutral (magenta ↔ green)."),
            .init("params.glareActive", .bool, "The print's veiling glare."),
            .init("params.scanFilm", .bool, "No print: scan the developed film. Always true for a slide film."),
            .init("params.extendedDynamicRange", .bool, "Keep the print's extended range (ignored while scanFilm)."),
            .init("params.preflashExposure", .number(0...0.03), "Pre-flash, as a fraction of the light through clear base."),
            .init("params.printEffects", .bool, "Off keeps only the paper's colour transform: no glare, pre-flash or Tone Mask."),
            .init("params.contrastMask.active", .bool, "Tone Mask (RFC-024)."),
            .init("params.contrastMask.highlights", .number(0...3), "Tone Mask: stops the print's highlights are raised."),
            .init("params.contrastMask.shadows", .number(0...3), "Tone Mask: stops the print's shadows are lowered."),
            .init("params.contrastMask.core", .number(0...3), "Tone Mask: half-width of the untouched core, stops."),
            .init("params.contrastMask.scale", .number(ContrastMaskSettings.scaleRange), "Tone Mask radius, fraction of the long edge."),
            .init("params.contrastMask.scheme", .choice(["gaussian"]), "The mask's extractor.",
                  readOnly: "gaussian is the only product scheme."),
            .init("params.effects.grain", .number(EffectStrengths.grainRange), "Grain strength, × the film's own."),
            .init("params.effects.grainLayered", .bool, "Three-sub-layer grain model."),
            .init("params.effects.halation", .number(EffectStrengths.halationRange), "Halation strength, × the film's own."),
            .init("params.effects.scatter", .number(EffectStrengths.scatterRange), "In-emulsion scatter weight."),
            .init("params.effects.couplersActive", .bool, "DIR couplers."),
            .init("params.effects.couplers", .number(EffectStrengths.couplersRange), "DIR coupler strength."),
            .init("params.effects.glare", .number(EffectStrengths.glareRange), "Glare strength, × the paper's own."),
        ]
        for (name, doc) in [("highlightPullBack", "Stops the scene's top is pulled back."),
                            ("shadowPullBack", "Stops the scene's bottom is pulled up."),
                            ("shadowPercentile", "The robust shadow extreme the Fit targets."),
                            ("highlightPercentile", "The robust highlight extreme the Fit targets."),
                            ("active", "Whether a solved placement curve is rendered."),
                            ("norm", "The curve's norm."),
                            ("highlightKnee", "Solved."), ("highlightRoom", "Solved."),
                            ("shadowKnee", "Solved."), ("shadowRoom", "Solved."),
                            ("rolloff", "Solved."), ("maxLift", "Solved.")] {
            f.append(.init("params.sceneLatitude.\(name)", name == "active" ? .bool
                           : name == "norm" ? .choice(["power"]) : .number(-20...20),
                           "Scene Placement: \(doc)", readOnly: viaPlace))
        }

        // --- adjustments: Layer 2, the grade on the finished print ---
        f += [
            .init("adjustments.enabled", .bool, "The whole grade on or off."),
            .init("adjustments.temperature", .number(-100...100), "Print white balance, blue ↔ amber."),
            .init("adjustments.tint", .number(-100...100), "Print white balance, green ↔ magenta."),
            .init("adjustments.exposure", .number(-3...3), "Exposure on the scan, stops."),
            .init("adjustments.contrast", .number(-50...50), "Contrast."),
            .init("adjustments.brightness", .number(-50...50), "Brightness."),
            .init("adjustments.saturation", .number(-100...100), "Saturation."),
            .init("adjustments.highlights", .number(-100...100), "Highlight recovery."),
            .init("adjustments.shadows", .number(-100...100), "Shadow recovery."),
            .init("adjustments.blackPoint", .number(0...50), "Black point."),
            .init("adjustments.whitePoint", .number(0...50), "White point."),
            .init("adjustments.vignette.amount", .number(-100...100), "Vignetting; negative darkens the corners."),
            .init("adjustments.vignette.midpoint", .number(0...100), "Where the vignette starts."),
        ]
        for c in ["rgb", "luma", "red", "green", "blue"] {
            f.append(.init("adjustments.curves.\(c).points", .points,
                           "The \(c) curve: [[x, y], …] from x = 0 to x = 1."))
        }
        for z in ["master", "shadows", "midtones", "highlights"] {
            f += [
                .init("adjustments.colorBalance.\(z).hue", .number(0...360), "Color Balance \(z): hue, degrees."),
                .init("adjustments.colorBalance.\(z).saturation", .number(0...1), "Color Balance \(z): amount."),
                .init("adjustments.colorBalance.\(z).luminance", .number(-1...1), "Color Balance \(z): lightness."),
            ]
        }

        // --- geometry ---
        f += [
            .init("geometry.crop.x", .number(0...1), "Crop left, normalised, before rotation."),
            .init("geometry.crop.y", .number(0...1), "Crop top."),
            .init("geometry.crop.width", .number(0...1), "Crop width."),
            .init("geometry.crop.height", .number(0...1), "Crop height."),
            .init("geometry.angle", .number(-Geometry.maxAngle...Geometry.maxAngle), "Straighten, degrees, clockwise."),
            .init("geometry.quarterTurns", .integer(0...3), "Rotation in 90° steps."),
            .init("geometry.flipH", .bool, "Flip horizontally."),
            .init("geometry.flipV", .bool, "Flip vertically."),
            .init("geometry.aspect", .choice(CropAspect.allCases.map(\.rawValue)), "The crop's aspect lock."),
            .init("geometry.intendedSize", .size, "The size a crop was last set to by hand.",
                  readOnly: "Kept by crop edits, as a drag keeps it."),
        ]

        // --- decode: the RAW development before the film ---
        f += [
            .init("decode.whiteBalance", .choice(DecodeSettings.WhiteBalance.allCases.map(\.rawValue)),
                  "Decode white balance. A preset sets temperature itself."),
            .init("decode.temperature", .number(2000...12000), "Decode Kelvin (makes whiteBalance Custom)."),
            .init("decode.tint", .number(-150...150), "Decode tint (makes whiteBalance Custom)."),
            .init("decode.lensCorrection", .bool, "The RAW's own lens correction. RAW files that carry one only."),
        ]
        return f
    }()

    static let byPath: [String: AgentField] = Dictionary(uniqueKeysWithValues: fields.map { ($0.path, $0) })

    /// Every prefix that has fields under it, so the walk can tell "go
    /// deeper" from "no such key".
    static let branches: Set<String> = {
        var s = Set<String>()
        for f in fields {
            var parts = f.path.split(separator: ".").map(String.init)
            while parts.count > 1 { parts.removeLast(); s.insert(parts.joined(separator: ".")) }
        }
        return s
    }()

    @MainActor
    static var json: JSONValue {
        [
            "document": "An edit is a JSON merge patch over {params, adjustments, geometry, decode}. Unknown keys, nulls, read-only fields and values outside a range are refused and nothing is written.",
            "fields": .array(fields.map(\.json)),
        ]
    }
}

// MARK: - the document and the patch

/// The four sections, as a value.
struct AgentDocument: Equatable {
    var params: FilmParams
    var adjustments: Adjustments
    var geometry: Geometry
    var decode: DecodeSettings

    init(params: FilmParams, adjustments: Adjustments, geometry: Geometry, decode: DecodeSettings) {
        self.params = params; self.adjustments = adjustments; self.geometry = geometry; self.decode = decode
    }

    init(_ sidecar: Sidecar) {
        self.init(params: sidecar.params, adjustments: sidecar.adjustments,
                  geometry: sidecar.geometry, decode: sidecar.decode)
    }

    var json: JSONValue {
        get throws {
            [
                "params": try .from(params),
                "adjustments": try .from(adjustments),
                "geometry": try .from(geometry),
                "decode": try .from(decode),
            ]
        }
    }

    /// Check a patch against the schema and return the leaf paths it writes.
    /// Throws `.refused` naming the first path that is wrong; nothing is
    /// applied by this, so a refusal leaves the frame untouched.
    @MainActor
    static func validate(_ patch: JSONValue) throws -> [String] {
        guard let top = patch.object else { throw AgentError.refused("An edit must be a JSON object.") }
        var leaves: [String] = []
        func walk(_ value: JSONValue, _ path: String) throws {
            if let field = AgentSchema.byPath[path] {
                if let why = field.readOnly { throw AgentError.refused("\(path) is read-only: \(why)") }
                try check(value, field)
                leaves.append(path)
                return
            }
            guard AgentSchema.branches.contains(path) else {
                throw AgentError.refused("\(path) is not an editable field. `schema` lists them.")
            }
            guard let o = value.object else { throw AgentError.refused("\(path) must be an object.") }
            for (k, v) in o.sorted(by: { $0.key < $1.key }) { try walk(v, "\(path).\(k)") }
        }
        for (k, v) in top.sorted(by: { $0.key < $1.key }) {
            guard AgentSchema.sections.contains(k) else {
                throw AgentError.refused("\(k) is not a section. The sections are \(AgentSchema.sections.joined(separator: ", ")).")
            }
            try walk(v, k)
        }
        return leaves
    }

    @MainActor
    private static func check(_ v: JSONValue, _ f: AgentField) throws {
        func no(_ want: String) -> AgentError { .refused("\(f.path) must be \(want); got \(v.text()).") }
        switch f.kind {
        case .number(let r):
            guard let d = v.number, d.isFinite else { throw no("a number") }
            guard r.contains(d) else { throw no("within \(r.lowerBound)…\(r.upperBound)") }
        case .integer(let r):
            guard let d = v.number, d == d.rounded(), r.contains(Int(d)) else {
                throw no("an integer within \(r.lowerBound)…\(r.upperBound)")
            }
        case .bool:
            guard v.bool != nil else { throw no("true or false") }
        case .choice(let c):
            guard let s = v.string, c.contains(s) else { throw no("one of \(c.joined(separator: ", "))") }
        case .film:
            guard let s = v.string, StockCatalog.shared.stock(s)?.isFilm == true else {
                throw no("a film id (`stocks` lists them)")
            }
        case .paper:
            guard let s = v.string, StockCatalog.shared.stock(s)?.isPaper == true else {
                throw no("a paper id (`stocks` lists them)")
            }
        case .points:
            guard case .array(let a) = v, a.count >= 2 else { throw no("at least two [x, y] points") }
            var xs: [Double] = []
            for p in a {
                guard case .array(let xy) = p, xy.count == 2, let x = xy[0].number, let y = xy[1].number,
                      (0...1).contains(x), (0...1).contains(y) else { throw no("[x, y] pairs within 0…1") }
                xs.append(x)
            }
            guard xs.first == 0, xs.last == 1, zip(xs, xs.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw no("points with x strictly ascending from 0 to 1")
            }
        case .size:
            throw no("left alone")
        }
    }

    /// The document with `patch` merged in. Validate first.
    func merged(with patch: JSONValue) throws -> AgentDocument {
        let m = try json.merged(with: patch)
        do {
            return AgentDocument(params: try m["params"]!.decode(FilmParams.self),
                                 adjustments: try m["adjustments"]!.decode(Adjustments.self),
                                 geometry: try m["geometry"]!.decode(Geometry.self),
                                 decode: try m["decode"]!.decode(DecodeSettings.self))
        } catch {
            throw AgentError.refused("The edit does not describe a frame: \(error)")
        }
    }
}

// MARK: - applying it to a session

extension Session {
    /// The document for the frame on the canvas.
    var agentDocument: AgentDocument { AgentDocument(sidecar) }

    /// Apply a merge patch the way the interface would have made each change:
    /// a film goes through the stage rule, a paper through its gate, the frame
    /// fields through the setters that derive `film_format_mm`, and a crop is
    /// fitted inside the frame. Validates everything before touching anything.
    /// Returns the leaf paths written.
    @discardableResult
    func applyAgentEdit(_ patch: JSONValue) throws -> [String] {
        let leaves = try AgentDocument.validate(patch)
        let now = agentDocument
        let want = try now.merged(with: patch)
        let touched = Set(leaves)
        func has(_ prefix: String) -> Bool { touched.contains { $0 == prefix || $0.hasPrefix(prefix + ".") } }

        // The rules the interface enforces by greying a control, checked on
        // the edit's own end state so an order of keys cannot slip past them.
        let positive = catalog.stock(want.params.filmStock)?.isPositive ?? false
        if positive, has("params.printStock") {
            throw AgentError.refused("\(want.params.filmStock) is a slide film; it is scanned, and takes no paper.")
        }
        if positive, touched.contains("params.scanFilm"), !want.params.scanFilm {
            throw AgentError.refused("\(want.params.filmStock) is a slide film; scanFilm must stay true.")
        }
        if has("decode.lensCorrection"), want.decode.lensCorrection, !lensCorrectionEnabled {
            throw AgentError.refused(lensCorrectionReason)
        }
        if has("geometry.crop"), want.geometry.crop.width <= 0.01 || want.geometry.crop.height <= 0.01 {
            throw AgentError.refused("The crop must be larger than 1 % of the frame on each side.")
        }

        // Decode first: it reopens the frame, and everything after renders on it.
        if has("decode") {
            var d = want.decode
            if (has("decode.temperature") || has("decode.tint")), !has("decode.whiteBalance") {
                d.whiteBalance = .custom
            } else if has("decode.whiteBalance"), let k = d.whiteBalance.kelvin, !has("decode.temperature") {
                d.temperature = k
            }
            decode = d
        }

        // Layer 1. The plain fields in one assignment, then the fields whose
        // setters carry a rule, so each rule sees the rest already in place.
        var p = want.params
        p.filmStock = now.params.filmStock
        p.printStock = now.params.printStock
        p.filmFrame = now.params.filmFrame
        p.filmSide = now.params.filmSide
        p.sideLengthMM = now.params.sideLengthMM
        p.filmFormatMM = now.params.filmFormatMM
        if p != params { params = p }
        if has("params.autoExposure") || has("params.autoExposureMethod") {
            aeMethod = AEMethod.of(want.params)   // retargets the reported EV, as the pill does
        }
        // The film list's rule: a film brings its declared paper, a slide film
        // is scanned. A paper named in the same edit wins over the declared one.
        if has("params.filmStock") { selectFilmStock(want.params.filmStock) }
        if has("params.printStock") { selectPrintStock(want.params.printStock) }
        if has("params.filmFrame") { setFilmFrame(FilmFrame.named(want.params.filmFrame)) }
        if has("params.filmSide") { setFilmSide(FilmSide(rawValue: want.params.filmSide) ?? .short) }
        if has("params.sideLengthMM") { setSideLengthMM(want.params.sideLengthMM) }

        if has("adjustments") { adjustments = want.adjustments }

        if has("geometry") {
            var g = want.geometry
            if has("geometry.crop") {
                g.intendedSize = CGSize(width: g.crop.width, height: g.crop.height)
            }
            let size = sourceImageSize
            geometry = size.width > 0 ? g.fitted(in: size) : g
        }
        return leaves
    }
}
