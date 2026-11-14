//  LCPReader.swift — an Adobe lens profile (`.lcp`, XMP/RDF) read into numbers, and those numbers made into the
//  app's `LensProfile` for one frame.
//
//  **No profile ships with the app or enters the repository** (they are Adobe's; the owner, 2026-11-13): a person
//  installs the ones Camera Raw left on their Mac, or adds a file, into the app's own database (`LensDatabase`),
//  which keeps the numbers read here, never the XML.
//
//  **The reference** is Adobe's published camera model (the Adobe Camera Model, as Adobe's own patents on it print
//  it, US 8,368,762 and US 11,403,739; no GPL program's code was read, the owner's rule): an ideal point (x, y), in
//  units of the focal length from the principal point, is seen by green at
//
//      x_d = x·(1 + k1 r² + k2 r⁴ + k3 r⁶) + 2(k4 y + k5 x)·x + k5 r²       r² = x² + y²
//      y_d = y·(1 + k1 r² + k2 r⁴ + k3 r⁶) + 2(k4 y + k5 x)·y + k4 r²
//
//  with `FocalLengthX/Y` the focal length over the reference image's longer side (Dmax) and `ImageX/YCenter` the
//  principal point as a share of its width and height (measured on the files: a 3:2 profile's YCenter is ≈ 0.5,
//  not ≈ 0.33, so it is not over Dmax as one patent's text has it). Light falls off as `L = 1 + α1 r² + α2 r⁴ +
//  α3 r⁶` at the *distorted* point (the observed value is the ideal one times L); red and blue are seen at green's
//  distorted point scaled by `ScaleFactor·(1 + k1 r_d² + k2 r_d⁴ + k3 r_d⁶)`, r_d green's distorted radius in the
//  aberration model's own units. What the app applies of each is `LCP.profile`'s, and what verified it is written
//  there.
//
//  **The three ways a file writes the same property** are all read: an attribute (`stCamera:FocalLength="45"`), an
//  element with text (`<stCamera:FocalLength>45</stCamera:FocalLength>`), and a struct as an element with
//  attributes, with an `rdf:Description` child, or with `rdf:parseType="Resource"`. `XMLParser` streams the file
//  (no tree of the whole document is kept); a file it cannot parse is skipped with its reason, never a crash.

import CoreGraphics
import Foundation

enum LCP {
    // MARK: what a file holds

    /// The camera and lens a group of entries was measured on: every `rdf:li` of a file with the same of these is one
    /// variant (a body, RAW or not).
    struct Camera: Codable, Hashable, Sendable {
        var make = "", model = "", uniqueModel = "", cameraPretty = ""
        var lens = "", lensPretty = "", lensID = "", lensInfo = "", profileName = ""
        var raw = true
        var sensorFactor: Double?
        var imageWidth: Double?, imageLength: Double?
        var alternateLensNames: [String] = []
        var alternateLensIDs: [String] = []
    }

    /// A geometric model: the perspective (rectilinear) or fisheye model, or one of the aberration's three.
    struct Geometry: Codable, Equatable, Sendable {
        /// Short keys: the database keeps a quarter of a million of these.
        enum CodingKeys: String, CodingKey { case fx, fy, cx, cy, k, tangential = "t", scale = "s" }
        var fx: Double?, fy: Double?, cx: Double?, cy: Double?
        /// RadialDistortParam1…3 (a fisheye's two).
        var k: [Double] = []
        /// TangentialDistortParam1, 2 (k4, k5): read, not applied (a radial model; 11 entries of Adobe's 250,000 have them).
        var tangential: [Double] = []
        /// The aberration models' ScaleFactor.
        var scale: Double?
    }

    struct Vignette: Codable, Equatable, Sendable {
        enum CodingKeys: String, CodingKey { case fx, fy, cx, cy, alpha = "a", piecewise = "p" }
        var fx: Double?, fy: Double?, cx: Double?, cy: Double?
        /// VignetteModelParam1…3.
        var alpha: [Double] = []
        /// VignetteModelPiecewiseParam: (r, L) pairs, r in the model's units.
        var piecewise: [[Double]] = []
    }

    /// One measured setting: a focal length, focus distance and aperture, and the models at it.
    struct Entry: Codable, Equatable, Sendable {
        enum CodingKeys: String, CodingKey {
            case focal = "f", distance = "d", aperture = "a", fisheye = "fe", geometry = "g", vignette = "v", green = "cg", red = "cr", blue = "cb"
        }
        var focal: Double?, distance: Double?, aperture: Double?
        var fisheye = false
        var geometry: Geometry?
        var vignette: Vignette?
        var green: Geometry?, red: Geometry?, blue: Geometry?
    }

    struct Variant: Codable, Equatable, Sendable {
        var camera: Camera
        var entries: [Entry]
    }

    enum ReadError: Error, CustomStringConvertible {
        case unreadable(String), malformed(String), empty, unkeepable
        /// The log's words for a skipped file (English; Settings, a later stage, says it in the person's language).
        var description: String {
            switch self {
            case .unkeepable: "a value that cannot be kept"
            case .unreadable(let s): "unreadable: \(s)"
            case .malformed(let s): "not well-formed XML: \(s)"
            case .empty: "no camera profile in it"
            }
        }
    }

    // MARK: reading

    static func read(_ url: URL) throws -> [Variant] {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ReadError.unreadable(error.localizedDescription) }
        return try read(data)
    }

    static func read(_ data: Data) throws -> [Variant] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw ReadError.malformed(parser.parserError.map { "\(($0 as NSError).code) line \(parser.lineNumber)" } ?? "line \(parser.lineNumber)")
        }
        var order: [Camera] = []
        var byCamera: [Camera: [Entry]] = [:]
        for node in reader.profiles {
            let (camera, entry) = interpret(node)
            if byCamera[camera] == nil { order.append(camera) }
            byCamera[camera, default: []].append(entry)
        }
        guard !order.isEmpty else { throw ReadError.empty }
        return order.map { Variant(camera: $0, entries: byCamera[$0] ?? []) }
    }

    /// A property, a struct or a list, as the file writes it, whichever of its three ways.
    final class Node {
        var props: [String: String] = [:]
        var kids: [String: Node] = [:]
        var items: [String] = []
        var text = ""
        /// A number; "inf" (709 of Adobe's focus distances: focused at infinity) as 10,000 m, Adobe's own word for it
        /// elsewhere; NaN as none.
        func number(_ name: String) -> Double? {
            guard let v = props[name].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }), !v.isNaN else { return nil }
            return v.isInfinite ? (v > 0 ? 10000 : nil) : v
        }
    }

    /// XMLParser's delegate: a stack of nodes; `rdf:Description`, `rdf:Seq`/`Bag`/`Alt` and the document's wrappers
    /// are transparent (the same node stays on top), every other element a property of the node under it.
    final class Reader: NSObject, XMLParserDelegate {
        private var stack: [(name: String, node: Node, transparent: Bool, profile: Bool)] = [("", Node(), true, false)]
        private(set) var profiles: [Node] = []
        static let transparent: Set<String> = ["rdf:Description", "rdf:Seq", "rdf:Bag", "rdf:Alt", "rdf:RDF", "x:xmpmeta", "x:xapmeta"]

        private static func local(_ name: String) -> String? {
            guard let colon = name.firstIndex(of: ":") else { return nil }
            let prefix = name[..<colon]
            guard prefix == "stCamera" || prefix == "photoshop" else { return nil }
            return String(name[name.index(after: colon)...])
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let top = stack[stack.count - 1]
            let node: Node
            var transparent = false, profile = false
            if Self.transparent.contains(name) {
                node = top.node; transparent = true
            } else if name == "rdf:li" {
                node = Node()
                // An `rdf:li` of photoshop:CameraProfiles' list is one entry; any other list's is an item.
                profile = stack.last { !$0.transparent }?.name == "photoshop:CameraProfiles"
            } else {
                node = Node()
            }
            for (k, v) in attributes { if let l = Self.local(k) { node.props[l] = v } }
            stack.append((name, node, transparent, profile))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack[stack.count - 1].node.text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard stack.count > 1 else { return }
            let done = stack.removeLast()
            if done.transparent { return }
            let parent = stack[stack.count - 1].node
            let text = done.node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if done.name == "rdf:li" {
                if done.profile { profiles.append(done.node) } else if !text.isEmpty { parent.items.append(text) }
                return
            }
            guard let l = Self.local(done.name) else { return }
            if done.node.props.isEmpty && done.node.kids.isEmpty && done.node.items.isEmpty {
                parent.props[l] = text
            } else {
                parent.kids[l] = done.node
            }
        }
    }

    static func interpret(_ n: Node) -> (Camera, Entry) {
        var c = Camera()
        func s(_ k: String) -> String { (n.props[k] ?? "").trimmingCharacters(in: .whitespaces) }
        c.make = s("Make"); c.model = s("Model"); c.uniqueModel = s("UniqueCameraModel"); c.cameraPretty = s("CameraPrettyName")
        c.lens = s("Lens"); c.lensPretty = s("LensPrettyName"); c.lensID = s("LensID"); c.lensInfo = s("LensInfo")
        c.profileName = s("ProfileName")
        c.raw = s("CameraRawProfile").lowercased() != "false"
        c.sensorFactor = n.number("SensorFormatFactor")
        c.imageWidth = n.number("ImageWidth"); c.imageLength = n.number("ImageLength")
        c.alternateLensNames = n.kids["AlternateLensNames"]?.items ?? []
        c.alternateLensIDs = n.kids["AlternateLensIDs"]?.items ?? []
        var e = Entry(focal: n.number("FocalLength"), distance: n.number("FocusDistance"), aperture: n.number("ApertureValue"))
        let model: Node?
        if let p = n.kids["PerspectiveModel"] { model = p } else if let f = n.kids["FisheyeModel"] { model = f; e.fisheye = true } else { model = nil }
        func geometry(_ g: Node) -> Geometry {
            Geometry(fx: g.number("FocalLengthX"), fy: g.number("FocalLengthY"), cx: g.number("ImageXCenter"), cy: g.number("ImageYCenter"),
                     k: (1...3).compactMap { g.number("RadialDistortParam\($0)") },
                     tangential: (1...2).compactMap { g.number("TangentialDistortParam\($0)") }, scale: g.number("ScaleFactor"))
        }
        if let model {
            e.geometry = geometry(model)
            if let v = model.kids["VignetteModel"] ?? n.kids["VignetteModel"] {
                e.vignette = Vignette(fx: v.number("FocalLengthX"), fy: v.number("FocalLengthY"), cx: v.number("ImageXCenter"),
                                      cy: v.number("ImageYCenter"), alpha: (1...3).compactMap { v.number("VignetteModelParam\($0)") },
                                      piecewise: (v.kids["VignetteModelPiecewiseParam"]?.items ?? []).compactMap { item in
                                          let p = item.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                                          return p.count == 2 ? p : nil
                                      })
                if e.vignette?.alpha.isEmpty == true && e.vignette?.piecewise.isEmpty == true { e.vignette = nil }
            }
            e.green = model.kids["ChromaticGreenModel"].map(geometry)
            e.red = model.kids["ChromaticRedGreenModel"].map(geometry)
            e.blue = model.kids["ChromaticBlueGreenModel"].map(geometry)
        }
        return (c, e)
    }
}

// MARK: - a frame's profile

extension LCP {
    /// The frame a profile is made for: its pixels in the sensor's (landscape) orientation, and its sensor's size as
    /// a crop of 35 mm's diagonal where its EXIF says (35 mm equivalent over focal length).
    struct Target: Equatable, Sendable {
        var width: Double = 3, height: Double = 2
        var sensorFactor: Double?
        var focal: Double?, distance: Double?, aperture: Double?
    }

    /// The diagonal of a 35 mm frame, which `SensorFormatFactor` is a crop of.
    static let fullFrameDiagonal = 43.2666

    /// Which terms `profile` makes. `piecewise`: Adobe's measured (r, L) knots where an entry has them, over its
    /// polynomial.
    ///
    /// **The default is what verified** (2026-11-13, `tools/lens_database_selftest.swift`): distortion only.
    /// - distortion: Adobe's against Core Image's own correction of a Canon EOS R6 Mark III with the RF 28-70mm F2 at
    ///   70 mm (a profile measured on an EOS R), 0.055 % of the half-diagonal at worst against 0.43 % uncorrected; and
    ///   against Sony's own parameters (FE 24-70mm F2.8 GM II 0.046 %, FE 35mm F1.8 0.020–0.022 %).
    /// - light falloff: left off. Core Image's lens correction makes none (its corrected decode over its uncorrected
    ///   one is 1.00 ± 0.01 to the corners, Canon and Nikon), and no sample's camera JPEG was made with it either,
    ///   so nothing here verifies Adobe's gain; the maths is written and read back on a flat field (`all`).
    /// - chromatic aberration: left off. No sample's lens has a model of it in its RAW profile (786 of Adobe's
    ///   2,800 RAW profiles do), and Core Image's decode shows no fringe to compare with.
    struct Terms: Equatable, Sendable {
        var distortion = true, vignetting = false, chromaticAberration = false, piecewise = true
        /// Every term the model has, for the checks.
        static let all = Terms(vignetting: true, chromaticAberration: true)
    }

    /// `entries` (one variant's) made into a `LensProfile` for `target`: each model's entries weighted across focal
    /// length (linear), focus distance (linear in 1/d) and aperture (linear in its APEX value), two on either side of
    /// the frame's in each, nearest beyond the ends; each entry's curves sampled at the frame's radii; the curves
    /// blended by the weights. Fisheye entries are not used (the model is rectilinear). Nil: nothing to correct.
    static func profile(_ variant: Variant, target: Target, terms: Terms = Terms()) -> LensProfile? {
        let rect = variant.entries.filter { !$0.fisheye && $0.geometry != nil }
        guard !rect.isEmpty else { return nil }
        let cam = variant.camera
        var p = LensProfile(source: .file)
        // The centre: the perspective model's at the entry nearest the frame (they differ by a few thousandths).
        let lead = weights(rect, target: target, use: { _ in true }).max { $0.1 < $1.1 }?.0 ?? rect[0]
        let cx = lead.geometry?.cx ?? 0.5, cy = lead.geometry?.cy ?? 0.5
        p.centre = CGPoint(x: cx, y: cy)
        let w = target.width, h = target.height
        // The frame's farthest corner from the centre, over its half-diagonal; and that half-diagonal in mm.
        let norm = hypot(max(cx, 1 - cx) * w, max(cy, 1 - cy) * h) / (0.5 * hypot(w, h))
        let sensor = target.sensorFactor ?? cam.sensorFactor ?? 1
        let halfDiagonal = 0.5 * fullFrameDiagonal / sensor
        // The profile camera's longer side in mm.
        let pw = cam.imageWidth ?? w, ph = cam.imageLength ?? h
        let longSide = fullFrameDiagonal / (cam.sensorFactor ?? sensor) * max(pw, ph) / hypot(pw, ph)
        /// ρ per unit of the frame's r, for a model whose focal length is `fx` (over Dmax) or, without one, the entry's.
        func scale(_ fx: Double?, _ e: Entry) -> Double? {
            let fmm = fx.map { $0 * longSide } ?? e.focal
            guard let fmm, fmm > 0 else { return nil }
            return norm * halfDiagonal / fmm
        }
        func poly(_ k: [Double], _ q: Double) -> Double {
            var v = 1.0, t = q
            for c in k.prefix(3) { v += c * t; t *= q }
            return v
        }
        func distortion(_ e: Entry) -> ((Double) -> Double)? {
            guard let g = e.geometry, !g.k.isEmpty, let s = scale(g.fx, e) else { return nil }
            return { r in poly(g.k, (s * r) * (s * r)) }
        }
        let radii = LensProfile.Radial.sampled { $0 }.radii
        func blend(_ use: (Entry) -> Bool, _ curve: (Entry) -> ((Double) -> Double)?) -> LensProfile.Radial? {
            let ws = weights(rect, target: target, use: { use($0) && curve($0) != nil })
            guard !ws.isEmpty else { return nil }
            var values = [Double](repeating: 0, count: radii.count)
            for (e, wgt) in ws { let f = curve(e)!; for i in radii.indices { values[i] += wgt * f(radii[i]) } }
            return LensProfile.Radial(radii: radii, values: values)
        }
        if terms.distortion { p.distortion = blend({ _ in true }, distortion) }
        if terms.vignetting {
            p.vignetting = blend({ $0.vignette != nil }) { e in
                guard let v = e.vignette, let s = scale(v.fx ?? e.geometry?.fx, e) else { return nil }
                if terms.piecewise, v.piecewise.count >= 2 {
                    let knots = LensProfile.Radial(radii: v.piecewise.map { $0[0] }, values: v.piecewise.map { $0[1] })
                    return { r in 1 / max(knots.at(s * r), 0.05) }
                }
                guard !v.alpha.isEmpty else { return nil }
                return { r in 1 / max(poly(v.alpha, (s * r) * (s * r)), 0.05) }
            }
        }
        if terms.chromaticAberration {
            // Red's and blue's source radius over green's, at green's distorted radius.
            func aberration(_ pick: @escaping (Entry) -> Geometry?) -> (Entry) -> ((Double) -> Double)? {
                { e in
                    guard let c = pick(e), let s = scale(c.fx ?? e.geometry?.fx, e) else { return nil }
                    let d = distortion(e) ?? { _ in 1 }
                    let sf = c.scale ?? 1
                    return { r in let rd = s * r * d(r); return sf * poly(c.k, rd * rd) }
                }
            }
            p.redScale = blend({ $0.red != nil }, aberration { $0.red })
            p.blueScale = blend({ $0.blue != nil }, aberration { $0.blue })
            if let r = p.redScale, r.values.allSatisfy({ abs($0 - 1) < 1e-7 }) { p.redScale = nil }
            if let b = p.blueScale, b.values.allSatisfy({ abs($0 - 1) < 1e-7 }) { p.blueScale = nil }
        }
        return p.corrects ? p : nil
    }

    /// Each entry's weight for `target`: focal length first, then focus distance, then aperture, each a two-point
    /// bracket over the values the remaining entries have. Entries not `use`d weigh nothing.
    static func weights(_ entries: [Entry], target: Target, use: (Entry) -> Bool) -> [(Entry, Double)] {
        let pool = entries.filter(use)
        guard !pool.isEmpty else { return [] }
        /// The two values bracketing `x` among `values` (by `key`), and the second's share; nearest beyond the ends.
        func bracket(_ values: [Double], _ x: Double?, key: (Double) -> Double) -> [(Double, Double)] {
            let u = Array(Set(values)).sorted { key($0) < key($1) }
            guard let x, u.count > 1 else {
                // Unknown: the largest (focus at infinity; the widest focal and aperture are as good as any).
                return [(u.last ?? 0, 1)]
            }
            let k = key(x)
            if k <= key(u[0]) { return [(u[0], 1)] }
            if k >= key(u[u.count - 1]) { return [(u[u.count - 1], 1)] }
            let hi = u.firstIndex { key($0) >= k }!, lo = hi - 1
            let t = (k - key(u[lo])) / (key(u[hi]) - key(u[lo]))
            return [(u[lo], 1 - t), (u[hi], t)]
        }
        var out: [(Entry, Double)] = []
        for (f, wf) in bracket(pool.map { $0.focal ?? 0 }, target.focal, key: { $0 }) where wf > 0 {
            let atF = pool.filter { ($0.focal ?? 0) == f }
            for (d, wd) in bracket(atF.map { $0.distance ?? 10000 }, target.distance, key: { -1 / max($0, 1e-3) }) where wd > 0 {
                let atD = atF.filter { ($0.distance ?? 10000) == d }
                for (a, wa) in bracket(atD.map { $0.aperture ?? 0 }, target.aperture, key: { $0 }) where wa > 0 {
                    let leaves = atD.filter { ($0.aperture ?? 0) == a }
                    for e in leaves { out.append((e, wf * wd * wa / Double(leaves.count))) }
                }
            }
        }
        return out
    }
}
