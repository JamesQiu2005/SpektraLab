//  LocalLayers.swift — a photograph's mask layers (PRD-E, RFC-052 §2, §4.1, §8.1): the model, Foundation only.
//
//  **A layer is a field of offsets to a control** (RFC-052 §2.1): a mask in the photograph's own source space S
//  (after EXIF orientation and the decoder's lens correction, before any cut; origin top-left, x right, y down,
//  (0, 0)–(1, 1) the picture's corners), a stage that says *when* (场景, before the film; 成片, on the finished
//  picture), and the amounts by which it moves that stage's controls. k(x) = on · opacity · m(x); the stage's
//  arithmetic runs once with c₀ + Σ kᵢ Δcᵢ. So a mask that covers everything is the whole picture's control moved
//  by Δc, and k = 0 is c₀ + 0, which is c₀ in float: nothing outside every mask is computed differently.
//
//  What this file is not: the bake (`MaskBaker`, which reads `foldOrder`), the wire (`SceneLayerWire`), Edit's local
//  kernels (part B), the panel (M1). It is the value the edit, Undo, Copy Settings and the history see as one edit.
//
//  **Where it is kept.** One optional value of `FrameEdit` (`layers`), absent when there is no layer, so an edit
//  without layers is today's JSON byte for byte; but in the library it is written to a record of its own beside
//  `library.json`, which a 2.3.x build neither reads nor rewrites (`LayerShelf`, RFC-052 §8.1): its `FrameEdit` coder
//  reads the keys it knows and writes only those, and would drop this value at its next write.
//
//  **Units.** Points are in S, normalised. Distances (a brush's radius, a feather, a radial's semi-axes) are metric:
//  units of the source's long edge, `p = (x · W/L, y · H/L)` — a circle is a circle on any aspect, and a radius
//  means the same at every size and on every tier (RFC-052 §3).
//
//  **Strokes are kept packed** (RFC-052 §8.2): a stroke's points are 16-bit coordinates in S, two `UInt16` a point,
//  little-endian, written as one base64 string. 1/65,535 of the picture is 0.06 px of a 4096 px plane, under any
//  sampling the plane can show; a stroke of 200 points is 800 bytes and about 1.1 kB of JSON.
//
//  Every key is spelt out as a literal (`CodingKeys`), as every type that reaches a file is (`persisted_check`).

import Foundation

/// A photograph's mask layers: at most `perStage` of each stage, in the panel's order (newest last). Layers of one
/// stage commute (a sum has no order, RFC-052 §2.1); the order is for reading.
struct LocalLayers: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case version = "version", items = "items" }
    /// The model's version, written with it. A record of a later version is read where it decodes, and kept as it
    /// was where it does not (`LayerShelf`).
    static let currentVersion = 1
    /// PRD-E §9 decision 8: 8 a stage on a photograph, 16 in all. The engine's node takes 8 (`spk_set_scene_layers`).
    static let perStage = 8

    var version = LocalLayers.currentVersion
    var items: [LocalLayer] = []

    init(items: [LocalLayer] = []) { self.items = items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        items = try c.decodeIfPresent([LocalLayer].self, forKey: .items) ?? []
    }

    /// A stage's layers, in the panel's order.
    func of(_ stage: LayerStage) -> [LocalLayer] { items.filter { $0.stage == stage } }
    /// Whether another layer of `stage` may be made (`perStage`).
    func canAdd(_ stage: LayerStage) -> Bool { of(stage).count < Self.perStage }

    /// The layers whose arithmetic can move a pixel of `stage`: on, opacity above 0, a delta that is not zero, and
    /// at least one part on. What the wire and the kernels are handed; with none the stage is today's, to the bit
    /// (RFC-052 §10.2: no layers, all off, opacity 0, zero deltas). A mask that is zero everywhere still counts:
    /// that it is zero is the bake's to know, and the node takes k = 0 as no change (`scene_layers.metal`).
    func active(_ stage: LayerStage) -> [LocalLayer] { of(stage).filter { $0.acts } }

    /// Nil where nothing is kept: an edit with no layer is written without the key.
    var kept: LocalLayers? { items.isEmpty ? nil : self }

    subscript(id: UUID) -> LocalLayer? {
        get { items.first { $0.id == id } }
        set {
            guard let i = items.firstIndex(where: { $0.id == id }) else { if let newValue { items.append(newValue) }; return }
            if let newValue { items[i] = newValue } else { items.remove(at: i) }
        }
    }
}

/// When a layer acts (RFC-052 §2, PRD-E §2): before the film, or on the finished picture. 放大机, the enlarger, is
/// the third (RFC-052 §12, M3): its case is here so a record that names it reads, but nothing applies it yet.
enum LayerStage: String, Codable, CaseIterable, Sendable {
    case scene = "scene"
    case finished = "finished"
    /// Reserved (RFC-052 §12): read and kept, applied by nothing in M1.
    case enlarger = "enlarger"
}

/// The decode geometry a layer's mask was made on (RFC-052 §8.1): whether 镜头校正 was on, and — where the app
/// corrects the lens itself (a Sony ARW, 2.4.0) — whose correction it was (`lens`, `LensCorrection.word`; nil where
/// Core Image's or nobody's, and in every record written before the field). When the edit's differs the interface
/// marks the layer (MASKS-SPEC drawing 14); nothing is moved for it. A Sony mask made with 镜头校正 on before 2.4.0
/// was made on a picture nobody corrected: its nil `lens` against today's word marks it.
struct MaskMadeOn: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey { case lensCorrection = "lensCorrection", lens = "lens" }
    var lensCorrection = false
    var lens: String? = nil

    init(lensCorrection: Bool = false, lensWord: String = "") {
        self.lensCorrection = lensCorrection
        lens = lensCorrection && !lensWord.isEmpty ? lensWord : nil
    }

    /// Whether a mask made on this geometry sits on the decode `lensCorrection` and `lensWord` make today.
    func matches(lensCorrection on: Bool, lensWord: String) -> Bool {
        lensCorrection == on && (!on || (lens ?? "") == lensWord)
    }
}

/// One mask layer.
struct LocalLayer: Codable, Equatable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id = "id", name = "name", stage = "stage", on = "on", opacity = "opacity", feather = "feather",
            invert = "invert", madeOn = "madeOn", parts = "parts", scene = "scene", finished = "finished"
    }
    var id = UUID()
    /// As a person named it, or as it was made (主体 1, 渐变 1, 画笔 1: PRD-E §9's smaller defaults).
    var name = ""
    var stage: LayerStage = .scene
    /// The eye.
    var on = true
    /// 不透明度, 0…1: multiplies once, at the end (RFC-052 §4.3).
    var opacity = 1.0
    /// 羽化: the folded mask's Gaussian σ, metric (RFC-052 §4.2). 0 is none.
    var feather = 0.0
    /// 反相, after the feather and before the zero outside S.
    var invert = false
    var madeOn = MaskMadeOn()
    /// Folded in list order from m = 0 (RFC-052 §4.2). A part switched off is left out of the fold.
    var parts: [MaskPart] = []
    /// The 场景 stage's deltas; nil on a layer of another stage. Switching the stage starts the other stage's at
    /// zero (PRD-E §4 flow 7): a stop of light on the film and a stop on the print are never converted silently.
    var scene: SceneDeltas? = nil
    /// The 成片 stage's deltas (RFC-052 §7); nil on a layer of another stage.
    var finished: FinishedDeltas? = nil

    init(id: UUID = UUID(), name: String = "", stage: LayerStage = .scene, parts: [MaskPart] = []) {
        self.id = id; self.name = name; self.stage = stage; self.parts = parts
        switch stage {
        case .scene: scene = SceneDeltas()
        case .finished: finished = FinishedDeltas()
        case .enlarger: break
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        stage = try c.decode(LayerStage.self, forKey: .stage)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        madeOn = try c.decodeIfPresent(MaskMadeOn.self, forKey: .madeOn) ?? MaskMadeOn()
        parts = try c.decodeIfPresent([MaskPart].self, forKey: .parts) ?? []
        scene = try c.decodeIfPresent(SceneDeltas.self, forKey: .scene)
        finished = try c.decodeIfPresent(FinishedDeltas.self, forKey: .finished)
    }

    /// on · opacity, clamped to [0, 1]: the engine's `coverage`.
    var coverage: Double { on ? min(max(opacity, 0), 1) : 0 }

    /// The parts the fold reads, in order.
    var foldOrder: [MaskPart] { parts.filter(\.on) }

    /// Whether this layer can move a pixel of its stage (`LocalLayers.active`).
    var acts: Bool {
        guard coverage > 0, !foldOrder.isEmpty || invert else { return false }
        switch stage {
        case .scene: return scene.map { !$0.isZero } ?? false
        case .finished: return finished.map { !$0.isZero } ?? false
        case .enlarger: return false
        }
    }

    /// The layer moved to another stage: the mask, the name and the opacity kept, the other stage's deltas at zero
    /// (PRD-E §9 decision 2).
    func moved(to stage: LayerStage) -> LocalLayer {
        var l = self
        guard stage != self.stage else { return l }
        l.stage = stage
        l.scene = stage == .scene ? SceneDeltas() : nil
        l.finished = stage == .finished ? FinishedDeltas() : nil
        return l
    }
}

/// A 场景 layer's controls (RFC-052 §6.1): 曝光 in stops, 色温 and 色调 on the slider's −100…100.
struct SceneDeltas: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey { case exposure = "exposure", temperature = "temperature", tint = "tint" }
    var exposure = 0.0
    var temperature = 0.0
    var tint = 0.0
    var isZero: Bool { exposure == 0 && temperature == 0 && tint == 0 }
    /// Whether it needs the cone matrices: a colour delta (RFC-052 §6.1's flag).
    var isColour: Bool { temperature != 0 || tint != 0 }

    init(exposure: Double = 0, temperature: Double = 0, tint: Double = 0) {
        self.exposure = exposure; self.temperature = temperature; self.tint = tint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
    }
}

/// A 成片 layer's controls: the scalar fields of `Adjustments` (RFC-052 §7), in the slider's own units, named as
/// `Adjustments` names them. Part B's local kernels add c₀ + Σ k Δc in these units and then make the kernel's
/// numbers as `Layer2Uniforms` does — never interpolating the kernel's numbers.
struct FinishedDeltas: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case exposure = "exposure", contrast = "contrast", brightness = "brightness", highlights = "highlights",
            shadows = "shadows", blackPoint = "blackPoint", whitePoint = "whitePoint", saturation = "saturation",
            vibrance = "vibrance", temperature = "temperature", tint = "tint"
    }
    var exposure = 0.0
    var contrast = 0.0
    var brightness = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var blackPoint = 0.0
    var whitePoint = 0.0
    var saturation = 0.0
    var vibrance = 0.0
    var temperature = 0.0
    var tint = 0.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        exposure = try v(.exposure); contrast = try v(.contrast); brightness = try v(.brightness)
        highlights = try v(.highlights); shadows = try v(.shadows); blackPoint = try v(.blackPoint)
        whitePoint = try v(.whitePoint); saturation = try v(.saturation); vibrance = try v(.vibrance)
        temperature = try v(.temperature); tint = try v(.tint)
    }

    /// Every control in a fixed order: what part B's block carries per layer.
    var values: [Double] {
        [exposure, contrast, brightness, highlights, shadows, blackPoint, whitePoint, saturation, vibrance, temperature, tint]
    }
    var isZero: Bool { values.allSatisfy { $0 == 0 } }
}

// MARK: parts

/// One part of a mask (RFC-052 §4.1), joined to what comes before it (§4.2).
struct MaskPart: Codable, Equatable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case id = "id", join = "join", on = "on", kind = "kind", linear = "linear", radial = "radial", brush = "brush",
            found = "found", asset = "asset"
    }
    /// 加 · 减去 · 相交.
    enum Join: String, Codable, CaseIterable, Sendable {
        case add = "add", subtract = "subtract", intersect = "intersect"
    }
    enum Kind: String, Codable, CaseIterable, Sendable {
        case linear = "linear", radial = "radial", brush = "brush", found = "found"
    }
    var id = UUID()
    var join: Join = .add
    var on = true
    var kind: Kind
    /// Each kind's own fields; the one `kind` names is set, the others nil.
    var linear: MaskLinear? = nil
    var radial: MaskRadial? = nil
    var brush: BrushStrokes? = nil
    var found: FoundMask? = nil
    /// A found mask's picture: the content hash of its immutable file (`Masks/<photograph>/<hash>`, RFC-052 §8.2).
    /// Nil for every other kind.
    var asset: String? = nil

    static func linear(_ g: MaskLinear, join: Join = .add) -> MaskPart { MaskPart(join: join, kind: .linear, linear: g) }
    static func radial(_ g: MaskRadial, join: Join = .add) -> MaskPart { MaskPart(join: join, kind: .radial, radial: g) }
    static func brush(_ b: BrushStrokes, join: Join = .add) -> MaskPart { MaskPart(join: join, kind: .brush, brush: b) }
    static func found(_ f: FoundMask, asset: String, join: Join = .add) -> MaskPart {
        MaskPart(join: join, kind: .found, found: f, asset: asset)
    }

    init(id: UUID = UUID(), join: Join = .add, on: Bool = true, kind: Kind, linear: MaskLinear? = nil,
         radial: MaskRadial? = nil, brush: BrushStrokes? = nil, found: FoundMask? = nil, asset: String? = nil) {
        self.id = id; self.join = join; self.on = on; self.kind = kind
        self.linear = linear; self.radial = radial; self.brush = brush; self.found = found; self.asset = asset
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        join = try c.decodeIfPresent(Join.self, forKey: .join) ?? .add
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
        kind = try c.decode(Kind.self, forKey: .kind)
        linear = try c.decodeIfPresent(MaskLinear.self, forKey: .linear)
        radial = try c.decodeIfPresent(MaskRadial.self, forKey: .radial)
        brush = try c.decodeIfPresent(BrushStrokes.self, forKey: .brush)
        found = try c.decodeIfPresent(FoundMask.self, forKey: .found)
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(join, forKey: .join)
        try c.encode(on, forKey: .on)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(linear, forKey: .linear)
        try c.encodeIfPresent(radial, forKey: .radial)
        try c.encodeIfPresent(brush, forKey: .brush)
        try c.encodeIfPresent(found, forKey: .found)
        try c.encodeIfPresent(asset, forKey: .asset)
    }
}

/// A point in S, normalised.
struct MaskPoint: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey { case x = "x", y = "y" }
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 线性渐变: full at `a`, none at `b`, both in S; t = (p − a)·(b − a)/‖b − a‖² in metric coordinates,
/// c = 1 − s(clamp(t, 0, 1)), s the smoothstep (RFC-052 §4.1). `a` = `b` is a step at the line through `a`
/// normal to nothing, so it is taken as no gradient: the baker writes 0 (said, not hidden).
struct MaskLinear: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey { case a = "a", b = "b" }
    var a: MaskPoint
    var b: MaskPoint
}

/// 径向渐变: inside is the mask. Centre in S; semi-axes metric; `angle` in degrees, clockwise (y down); `feather`
/// f ∈ [0, 1]: d = ‖R(−θ)(p − centre)/(rx, ry)‖, c = 1 − smoothstep(1 − f, 1, d), and f = 0 is a step at d = 1,
/// taken by a branch (RFC-052 §4.1).
struct MaskRadial: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey { case centre = "centre", rx = "rx", ry = "ry", angle = "angle", feather = "feather" }
    var centre: MaskPoint
    var rx: Double
    var ry: Double
    var angle = 0.0
    var feather = 0.5
}

/// 画笔: its strokes in the order they were drawn (RFC-052 §4.1). Drawn into one 16-bit plane at the canonical
/// size; that plane's value is the part's coverage.
struct BrushStrokes: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey { case strokes = "strokes" }
    var strokes: [BrushStroke] = []
}

/// One stroke: one step of Undo. A run of dabs at 0.1 r along its points (the baker lays them).
struct BrushStroke: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case radius = "radius", hardness = "hardness", flow = "flow", erase = "erase", points = "points"
    }
    /// Metric.
    var radius: Double
    /// h ∈ [0, 1]: α(ρ) = α₀ (1 − smoothstep(h, 1, ρ)); 1 is a hard edge, a step at ρ = 1 by a branch.
    var hardness: Double
    /// F ∈ (0, 1]: one pass of a hard brush leaves exactly F on its centre line (α₀ = 1 − (1 − F)^(1/20)).
    var flow: Double
    /// 橡皮: v ← v(1 − α) in place of v ← v + α(1 − v).
    var erase = false
    /// The points, packed (`pack`): 16-bit x then y, little-endian, base64 in JSON.
    var points: Data

    init(radius: Double, hardness: Double, flow: Double, erase: Bool = false, points: [MaskPoint]) {
        self.radius = radius; self.hardness = hardness; self.flow = flow; self.erase = erase
        self.points = Self.pack(points)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = try c.decode(Double.self, forKey: .radius)
        hardness = try c.decodeIfPresent(Double.self, forKey: .hardness) ?? 1
        flow = try c.decodeIfPresent(Double.self, forKey: .flow) ?? 1
        erase = try c.decodeIfPresent(Bool.self, forKey: .erase) ?? false
        points = try c.decode(Data.self, forKey: .points)
    }

    /// Points in S → 16-bit each, clamped to the picture (a stroke that leaves it is cut at its edge: outside S a
    /// mask is 0 anyway, RFC-052 §3).
    static func pack(_ points: [MaskPoint]) -> Data {
        var out = Data(capacity: points.count * 4)
        func q(_ v: Double) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
        for p in points {
            for v in [q(p.x), q(p.y)] { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        }
        return out
    }

    static func unpack(_ data: Data) -> [MaskPoint] {
        let bytes = [UInt8](data)
        var out: [MaskPoint] = []
        out.reserveCapacity(bytes.count / 4)
        var i = 0
        while i + 3 < bytes.count {
            let x = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            let y = UInt16(bytes[i + 2]) | UInt16(bytes[i + 3]) << 8
            out.append(MaskPoint(Double(x) / 65535, Double(y) / 65535))
            i += 4
        }
        return out
    }

    var unpacked: [MaskPoint] { Self.unpack(points) }
}

/// 主体, 人 n, 全部人物 (RFC-052 §5, §9): an immutable 8-bit picture in S, named by `MaskPart.asset`, and how it was
/// made. 背景 is the same asset with `invert` set: c_bg = 1 − c_subject from one picture, so the two never overlap
/// and never leave a gap (RFC-052 §4.2). Found in M1 (`SubjectFinder`); the type's place is kept here so a record
/// that holds one reads, and the baker can bake one from a picture it is handed (`MaskBaker.FoundPicture`).
struct FoundMask: Codable, Equatable, Hashable, Sendable {
    enum CodingKeys: String, CodingKey {
        case what = "what", instance = "instance", invert = "invert", width = "width", height = "height",
            detector = "detector", revision = "revision", system = "system", fingerprint = "fingerprint",
            decodeGeometry = "decodeGeometry"
    }
    enum What: String, Codable, CaseIterable, Sendable {
        case subject = "subject", person = "person", people = "people"
    }
    var what: What = .subject
    /// Which person, for `.person`; 0 otherwise.
    var instance = 0
    /// 背景: the asset inverted, before the join.
    var invert = false
    /// The picture's size as the detector returned it (capped at L_c).
    var width: Int
    var height: Int
    // Provenance (RFC-052 §5): an asset is never recomputed by an upgrade.
    var detector = ""
    var revision = 0
    var system = ""
    var fingerprint = ""
    var decodeGeometry = ""
}
