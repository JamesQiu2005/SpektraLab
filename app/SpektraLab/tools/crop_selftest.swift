//  crop_selftest.swift — the crop page's arithmetic (2026-10-20), checked on this Mac.
//
//      tools/selftest.sh                # with the other checks
//      tools/selftest.sh --self-test    # the checks' own check: each broken rule must be caught
//
//  What the new Crop page rests on, none of which a screenshot can show:
//
//  - **The records.** Develop's crop (`FrameEdit.geometry`) and Edit's
//    (`FrameEdit.printCrop`) are two fields; an edit written before either
//    perspective or Edit's crop opens with none, and one without them is the
//    same JSON as before (the schema stays 5).
//  - **The perspective** (`Keystone`): the identity at 0, its two maps each
//    other's inverse, the frame's middle kept, the corrected frame inside the
//    re-projected picture, and Vertical widening the top.
//  - **The host's re-projection** (`HostCut.image`): every pixel of the
//    corrected picture is the source's pixel the keystone says it is — a
//    picture whose every pixel says where it came from, put through Core Image.
//  - **The guides' Apply** (`CropGuides`): two horizontals, two verticals
//    or a rectangle's four corners, laid on what a known perspective and
//    straighten made of them, give that perspective and straighten back —
//    the other perspective held where it was.
//  - **Edit's crop of a file** (`FinishedCut`) and its size in the export's
//    plan (`ExportPlan`): the cut is the size the plan said, every pixel from
//    where the map says.
//  - **The camera's crop** (`CameraCrop`, 2026-11-05): DNG 1.6's DefaultUserCrop
//    as ImageIO reads it, put through the file's orientation — every one of
//    EXIF's eight held against Core Image's own `oriented(forExifOrientation:)`
//    on a picture whose pixels say where they were stored — and the four Leica
//    Q3 files' numbers, as a new frame's crop and its locked ratio.
//    `CAMERA_CROP_DNGS=<dir>` also reads the four files themselves (a copy:
//    never the owner's folder); without it that part says it skipped.
//  - **The hook** (round 2): the one helper a new frame's crop is made through
//    (`CameraCrop.newFrameGeometry`), on synthetic headers with an off-centre
//    crop on an upright file, so a turned and an unturned crop differ; that
//    ImportService.swift's probe and frame go through it (read from the file:
//    `CROP_IMPORT_SERVICE=<a copy>` points it at another); the launch's catch-up
//    of a frame made before the crop was read (`owing`, `caughtUp`); and the
//    Mac cell's test for a preview the camera already cut (`previewIsCut`).
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` puts a
//  broken rule in place of each, one at a time, and requires the run to fail.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct Rules {
    var name = "the app's"
    var keystone: (Double, Double, CGSize) -> Keystone = { Keystone.make(vertical: $0, horizontal: $1, size: $2) }
    var corrected: (CIImage, Geometry) -> CIImage = { HostCut.image($0, by: $1) }
    var solve: (CropGuides.Mode, [CGPoint], Geometry, CGSize) -> (vertical: Double, horizontal: Double, angle: Double)? = {
        CropGuides.solve($0, points: $1, geometry: $2, imageSize: $3)
    }
    var finishedCut: (CGImage, Geometry) throws -> CGImage = { try FinishedCut.image($0, by: $1) }
    var plan: (ExportPlan.Ask) -> ExportPlan = { ExportPlan.make($0) }
    var wireFormat: (FrameEdit, PixelSize, Bool) -> Double = { $0.wireFilmFormatMM(photo: $1, cropIsFrame: $2) }
    var encode: (FrameEdit) throws -> Data = { e in
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; return try enc.encode(e)
    }
    var cameraCrop: ([CFString: Any]) -> CropRect? = { CameraCrop.read($0) }
    var cameraGeometry: (CropRect, CGSize) -> Geometry = { CameraCrop.geometry($0, in: $1) }
    /// The hook every new frame's crop goes through (`ImportService.probe`, then `frame`).
    var newFrameGeometry: ([CFString: Any], PixelSize) -> Geometry = { CameraCrop.newFrameGeometry(properties: $0, size: $1) }
    /// ImportService.swift as it is: that its probe and its frame go through the hook.
    var importSource: () -> String? = { try? String(contentsOf: importServiceURL, encoding: .utf8) }
    /// LibraryPersistence.swift and AppServices.swift as they are: the marker is saved and loaded, and the
    /// launch catches up (2026-11-05: without either, a frame Reset to the whole picture is cut again at
    /// every launch, and every other check here stays green).
    var persistenceSource: () -> String? = { try? String(contentsOf: sourceURL("Services/LibraryPersistence.swift"), encoding: .utf8) }
    var appModelSource: () -> String? = { try? String(contentsOf: sourceURL("App/AppServices.swift"), encoding: .utf8) }
    var owing: (String, Bool, Bool, Bool?, FrameEdit) -> CameraCrop.Owing = {
        CameraCrop.owing(fileName: $0, isPair: $1, isDemo: $2, read: $3, edit: $4)
    }
    var caughtUp: (FrameEdit, CameraCrop.Reading?, PixelSize) -> (geometry: Geometry, read: Bool) = {
        CameraCrop.caughtUp($0, reading: $1, size: $2)
    }
    var reading: ([CFString: Any]) -> CameraCrop.Reading = { CameraCrop.reading($0) }
    var previewIsCut: (Int, Int, CameraCrop.Reading) -> Bool = { CameraCrop.previewIsCut(width: $0, height: $1, $2) }
    /// The Mac crop page's scroll zoom (`Geometry.zoomed`).
    var zoom: (Geometry, CGFloat, CGPoint, CGSize) -> Geometry = { $0.zoomed(by: $1, about: $2, in: $3) }
    /// The long edge a preview develop decodes the photo at for its crop (`Geometry.previewDecodeLongEdge`).
    var previewDecode: (Geometry, Int, PixelSize) -> Int = { Geometry.previewDecodeLongEdge($0, preview: $1, original: $2) }
}

/// `Sources/Features/Import/ImportService.swift`, found from this file; `CROP_IMPORT_SERVICE` names another
/// (a copy of an earlier one, to see this check go red on it).
let importServiceURL: URL = ProcessInfo.processInfo.environment["CROP_IMPORT_SERVICE"].map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Features/Import/ImportService.swift")

/// A file under `Sources/`, found from this file.
func sourceURL(_ path: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/" + path)
}

/// `text` with its `//` comments taken out, so a line commented out no longer counts as there.
func uncommented(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
        if let r = line.range(of: "//") { return line[..<r.lowerBound] }
        return line
    }.joined(separator: "\n")
}

final class Checks {
    let rules: Rules
    var failed: [String] = []
    var passed = 0
    init(_ rules: Rules) { self.rules = rules }
    func expect(_ ok: Bool, _ what: String) { if ok { passed += 1 } else { failed.append(what) } }
}

let size = CGSize(width: 3000, height: 2000)

func near(_ a: CGPoint, _ b: CGPoint, _ tol: Double) -> Bool { hypot(Double(a.x - b.x), Double(a.y - b.y)) <= tol }

func records(_ c: Checks) {
    // An edit as the build before this one wrote it: no perspective, no Edit crop.
    var old = FrameEdit()
    old.geometry.crop = CropRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9)
    old.geometry.angle = 2.5
    guard let before = try? c.rules.encode(old), let text = String(data: before, encoding: .utf8) else {
        c.expect(false, "an edit is written"); return
    }
    c.expect(!text.contains("printCrop") && !text.contains("\"vertical\"") && !text.contains("\"horizontal\""),
             "an edit with no perspective and no Edit crop is written as before")
    c.expect(text.contains("\"schemaVersion\":5"), "and its schema is still 5 (a preset of 5 still loads)")
    // Without the new keys at all, it reads with none.
    if let read = try? JSONDecoder().decode(FrameEdit.self, from: before) {
        c.expect(read.printCrop == .default && !read.geometry.hasPerspective && read.geometry.angle == 2.5,
                 "an old edit opens with no Edit crop and no perspective, its crop kept")
    } else { c.expect(false, "an old edit opens") }
    // Both crops, written and read back, apart.
    var both = old
    both.geometry = both.geometry.perspective(vertical: 7.5, horizontal: -3)
    both.printCrop.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
    both.printCrop.quarterTurns = 1
    both.printCrop.aspect = .free
    if let data = try? c.rules.encode(both), let read = try? JSONDecoder().decode(FrameEdit.self, from: data) {
        c.expect(read.geometry == both.geometry && read.printCrop == both.printCrop,
                 "Develop's crop with its perspective and Edit's crop are each written and read back as they were")
        c.expect(read.printCrop != read.geometry, "and they are two records")
    } else { c.expect(false, "both crops are written and read") }
    // The page's ↺ on Edit's Crop tool resets Edit's crop, not Develop's.
    let reset = both.resetting(.crop)
    c.expect(reset.printCrop == .default && reset.geometry == both.geometry, "Edit's ↺ resets Edit's crop and leaves Develop's")
}

func keystone(_ c: Checks) {
    let none = c.rules.keystone(0, 0, size)
    c.expect(none.isIdentity, "no perspective is the identity")
    let k = c.rules.keystone(12, -6, size)
    var round = true
    for p in [CGPoint(x: 10, y: 20), CGPoint(x: 1500, y: 1000), CGPoint(x: 2900, y: 1900)] {
        round = round && near(k.source(k.corrected(p)), p, 1e-6)
    }
    c.expect(round, "the keystone's two maps are each other's inverse")
    c.expect(near(k.corrected(CGPoint(x: 1500, y: 1000)), CGPoint(x: 1500, y: 1000), 1e-6), "the frame's middle stays the middle")
    var inside = true
    for q in [CGPoint(x: 0, y: 0), CGPoint(x: 3000, y: 0), CGPoint(x: 3000, y: 2000), CGPoint(x: 0, y: 2000)] {
        let s = k.source(q)
        inside = inside && s.x >= -1e-3 && s.y >= -1e-3 && s.x <= 3000 + 1e-3 && s.y <= 2000 + 1e-3
    }
    c.expect(inside && k.fill < 1, "the corrected frame lies inside the re-projected picture, zoomed in to it")
    let v = c.rules.keystone(10, 0, size)
    let top = hypot(Double(v.corrected(CGPoint(x: 3000, y: 0)).x - v.corrected(CGPoint(x: 0, y: 0)).x), 0)
    let bottom = hypot(Double(v.corrected(CGPoint(x: 3000, y: 2000)).x - v.corrected(CGPoint(x: 0, y: 2000)).x), 0)
    c.expect(top > bottom * 1.05, "Vertical widens the top (what lines converging upward want)")
}

/// A picture whose every pixel says where it is: red its column, green its row.
func ramp(_ w: Int, _ h: Int) -> CIImage {
    var px = [Float](repeating: 1, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        px[i] = (Float(x) + 0.5) / Float(w); px[i + 1] = (Float(y) + 0.5) / Float(h); px[i + 2] = 0.5
    } }
    let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
    // Top row first, as a decode is (`host_cut_selftest.swift`'s picture).
    return CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
}

func hostCut(_ c: Checks) {
    let w = 300, h = 200
    let picture = ramp(w, h)
    var g = Geometry().perspective(vertical: 9, horizontal: -5)
    let out = c.rules.corrected(picture, g.perspectiveOnly)
    c.expect(out.extent.integral == CGRect(x: 0, y: 0, width: w, height: h), "a perspective alone keeps the picture's size")
    let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
    var rgba = [Float](repeating: 0, count: w * h * 4)
    rgba.withUnsafeMutableBytes { buf in
        ctx.render(out, toBitmap: buf.baseAddress!, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                   format: .RGBAf, colorSpace: nil)
    }
    let k = g.keystone(in: CGSize(width: w, height: h))
    var worst = 0.0
    for (x, y) in [(20, 20), (150, 100), (280, 30), (40, 180), (260, 170), (100, 60)] {
        // Read back top row first.
        let i = (y * w + x) * 4
        let seen = CGPoint(x: Double(rgba[i]) * Double(w), y: Double(rgba[i + 1]) * Double(h))
        let want = k.source(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
        worst = max(worst, hypot(Double(seen.x - want.x), Double(seen.y - want.y)))
        if ProcessInfo.processInfo.environment["CROP_DEBUG"] != nil { print("  at", x, y, "seen", seen, "want", want) }
    }
    c.expect(worst < 0.75, String(format: "every pixel of the host's re-projection is the source's pixel the keystone names (worst %.2f px)", worst))
    // And a whole cut through it: the size the map gives.
    g.crop = CropRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)
    g.quarterTurns = 1
    let cut = c.rules.corrected(picture, g)
    c.expect(cut.extent.integral.size == g.outputSize(for: CGSize(width: w, height: h)), "a cut through a perspective is the crop's size")
}

func guides(_ c: Checks) {
    // Lines the camera saw level or upright, under a known perspective and
    // straighten, taken back to the source; Apply must give the truth back.
    func laid(_ seen: [CGPoint], _ v: Double, _ h: Double, _ a: Double) -> [CGPoint] {
        let k = Keystone.make(vertical: v, horizontal: h, size: size)
        let r = a * .pi / 180
        return seen.map { p in
            let q = CGPoint(x: Double(p.x) * cos(r) - Double(p.y) * sin(r), y: Double(p.x) * sin(r) + Double(p.y) * cos(r))
            let s = k.source(q)
            return CGPoint(x: s.x / size.width, y: s.y / size.height)
        }
    }
    func check(_ mode: CropGuides.Mode, _ seen: [CGPoint], truth: (v: Double, h: Double, a: Double), from g: Geometry, _ what: String) {
        guard let got = c.rules.solve(mode, laid(seen, truth.v, truth.h, truth.a), g, size) else {
            c.expect(false, "\(what): the points solve"); return
        }
        c.expect(abs(got.vertical - truth.v) < 0.1 && abs(got.horizontal - truth.h) < 0.1 && abs(got.angle - truth.a) < 0.1,
                 String(format: "\(what) (%.2f, %.2f, %.2f)", got.vertical, got.horizontal, got.angle))
    }
    // Two horizontals: Horizontal and the straighten; Vertical held at what it was.
    check(.horizontals, [CGPoint(x: 600, y: 600), CGPoint(x: 2400, y: 600), CGPoint(x: 600, y: 1400), CGPoint(x: 2400, y: 1400)],
          truth: (3, -7, 2.5), from: Geometry().perspective(vertical: 3, horizontal: 0),
          "two horizontals give back Horizontal and the straighten, Vertical held")
    // Two verticals, laid bottom to top (whichever way round, the same line).
    check(.verticals, [CGPoint(x: 800, y: 1700), CGPoint(x: 800, y: 300), CGPoint(x: 2200, y: 1700), CGPoint(x: 2200, y: 300)],
          truth: (9, 0, -1.5), from: Geometry(),
          "two verticals give back Vertical and the straighten")
    // A rectangle: all three.
    check(.rectangle, [CGPoint(x: 900, y: 500), CGPoint(x: 2100, y: 500), CGPoint(x: 2100, y: 1500), CGPoint(x: 900, y: 1500)],
          truth: (8, -4, 2), from: Geometry(),
          "a rectangle's corners give back the perspective and straighten")
}

/// A picture of 16-bit pixels whose red is its column and green its row.
func picture16(_ w: Int, _ h: Int) -> CGImage {
    var px = [UInt16](repeating: 65535, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        px[i] = UInt16(x * 100); px[i + 1] = UInt16(y * 100); px[i + 2] = 0
    } }
    let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
    return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                   space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                   provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int)? {
    guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return nil }
    let row = p + y * image.bytesPerRow
    let px = UnsafeRawPointer(row + x * image.bitsPerPixel / 8).assumingMemoryBound(to: UInt16.self)
    let little = image.bitmapInfo.contains(.byteOrder16Little) || !image.bitmapInfo.contains(.byteOrder16Big)
    func v(_ i: Int) -> Int { Int(little ? UInt16(littleEndian: px[i]) : UInt16(bigEndian: px[i])) }
    return (v(0) / 100, v(1) / 100)
}

func finished(_ c: Checks) {
    let image = picture16(60, 40)
    var g = Geometry()
    g.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    if let cut = try? c.rules.finishedCut(image, g) {
        c.expect(cut.width == 30 && cut.height == 20, "Edit's crop of a file is the size the crop says")
        let p = pixel(cut, 0, 0)
        c.expect(p.map { $0 == (15, 10) } ?? false, "and its first pixel is the picture's at the crop's corner (\(String(describing: p)))")
    } else { c.expect(false, "Edit's crop of a file is made") }
    g.quarterTurns = 1
    if let cut = try? c.rules.finishedCut(image, g) {
        c.expect(cut.width == 20 && cut.height == 30, "turned a quarter, its sides swap")
        // Turned clockwise: the output's top-left is the crop's bottom-left.
        let p = pixel(cut, 0, 0)
        c.expect(p.map { $0 == (15, 29) } ?? false, "and turned the right way (\(String(describing: p)))")
    } else { c.expect(false, "a turned Edit crop is made") }

    // The export's plan sizes the file after Edit's crop.
    var ask = ExportPlan.Ask(source: PixelSize(width: 4000, height: 3000), photo: .default, filmFormatMM: 36, size: .full,
                             capMegapixels: 200)
    ask.printCrop.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
    let plan = c.rules.plan(ask)
    c.expect(plan.output == PixelSize(width: 2000, height: 3000) && plan.printCrop != nil,
             "an export's file is the finished picture after Edit's crop (\(plan.output.width) x \(plan.output.height))")
    var keystoned = ExportPlan.Ask(source: PixelSize(width: 4000, height: 3000), photo: Geometry().perspective(vertical: 6, horizontal: 0),
                                   filmFormatMM: 36, size: .full, capMegapixels: 200)
    keystoned.photo.crop = CropRect(x: 0.4, y: 0.4, width: 0.001, height: 0.001)   // too small for the format to follow
    let small = c.rules.plan(keystoned)
    c.expect(!small.engineCuts || small.cut == keystoned.photo.perspectiveOnly,
             "where the engine cuts an export itself, the host still re-projects it first")
}

/// **Crop re-maps the frame** (Settings; v1.3.3's, restored 2026-10-26). The engine
/// develops the whole source and lays the film's millimetres across the
/// source's long edge (`film_prefix`: "the pitch is the pre-crop long edge's"),
/// so "the crop is a 135 frame" has to be said as "the source is 36 mm × this".
func cropIsFrame(_ c: Checks) {
    let photo = PixelSize(width: 6000, height: 4000)
    var e = FrameEdit.default                  // 135, Side Short, 24 mm: 36 on a 3:2
    e.params.filmFrame = "135"; e.params.filmSide = "short"; e.params.sideLengthMM = 24; e.params.filmFormatMM = 36
    func sent(_ g: (inout FrameEdit) -> Void, _ on: Bool) -> Double { var x = e; g(&x); return c.rules.wireFormat(x, photo, on) }
    let half: (inout FrameEdit) -> Void = { $0.geometry.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
    let square: (inout FrameEdit) -> Void = { $0.geometry.crop = CropRect(x: 1.0 / 6, y: 0, width: 4000.0 / 6000, height: 1) }
    let tiny: (inout FrameEdit) -> Void = { $0.geometry.crop = CropRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1) }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    c.expect(near(sent({ _ in }, false), 36) && near(sent({ _ in }, true), 36), "no crop sends the frame's 36 mm in either mode")
    c.expect(near(sent(half, false), 36), "off, a half-size crop sends the frame's 36 mm (\(sent(half, false)))")
    c.expect(near(sent(half, true), 72), "on, a half-size crop at the same 3:2 sends 72 mm, twice the frame (\(sent(half, true)))")
    c.expect(near(sent(square, true), 36), "on, a full-height 1:1 out of 3:2 is a 24 x 24 of the same negative: 36 mm, v1's number (\(sent(square, true)))")
    var long = e; long.params.filmSide = "long"; long.params.sideLengthMM = 36; square(&long)
    c.expect(near(c.rules.wireFormat(long, photo, true), 54), "on, Side Long 36 on a full-height 1:1 makes the square 36 mm: 54 across the source")
    c.expect(near(sent(tiny, true), 200), "on, the engine's 200 mm is the ceiling (\(sent(tiny, true)))")
    var turned = e; half(&turned); turned.geometry.quarterTurns = 1
    c.expect(near(c.rules.wireFormat(turned, photo, true), 72), "a quarter turn does not change the crop's size on the film")
    var edged = e; half(&edged); edged.filmEdge.active = true
    c.expect(near(c.rules.wireFormat(edged, photo, true), 36), "under a film edge the crop is the gate's placement, and the gate sizes the film")
    // The export: the host cuts, and the format follows the cut down to the crop's own 36 mm --
    // the same micrometres a pixel the develop page was sent.
    var cut = e; half(&cut)
    let sentMM = c.rules.wireFormat(cut, photo, true)
    let plan = c.rules.plan(ExportPlan.Ask(source: photo, photo: cut.geometry, filmFormatMM: sentMM, size: .full, capMegapixels: 200))
    let pitch = (plan.filmFormatMM ?? sentMM) / Double(plan.frame.longEdge)
    c.expect(abs(pitch - sentMM / Double(photo.longEdge)) < 1e-9 && near(plan.filmFormatMM ?? 0, 36),
             "an export of the crop is at the develop page's pitch (\(plan.filmFormatMM ?? -1) mm across \(plan.frame.longEdge) px)")
}

/// The properties ImageIO reads off a DNG, as far as the camera's crop goes: `{DNG}`'s
/// DefaultUserCrop (top, left, bottom, right, of the stored picture) and the orientation.
func dngProperties(_ crop: [Double], orientation: Int) -> [CFString: Any] {
    [kCGImagePropertyDNGDictionary: [kCGImagePropertyDNGDefaultUserCrop: crop.map { NSNumber(value: $0) }] as [CFString: Any],
     kCGImagePropertyOrientation: NSNumber(value: orientation)]
}

/// The four Leica Q3 DNGs of 2026-11-05 (the owner's 裁切测试), as ImageIO read them on this Mac: each
/// 9520 x 6336 as stored, its DefaultUserCrop, its orientation, the picture's size as `CIRAWFilter`
/// hands it over (turned), and the crop that picture should open with -- worked by hand from the tag
/// (Orientation 6: the stored top edge is the right-hand side, the stored left edge the top).
struct Q3 {
    let file: String, crop: [Double], orientation: Int, size: CGSize
    let want: CropRect, aspect: CropAspect
}
let q3: [Q3] = [
    // The 35 mm frame line: 7,616 x 5,088 of 9,520 x 6,336.
    Q3(file: "L1026319.DNG", crop: [0.09848485, 0.1, 0.9015151, 0.9], orientation: 1, size: CGSize(width: 9520, height: 6336),
       want: CropRect(x: 0.1, y: 0.09848485, width: 0.8, height: 0.9015151 - 0.09848485), aspect: .r3x2),
    // 50 mm: 5,328 x 3,552.
    Q3(file: "L1026321.DNG", crop: [0.219697, 0.2201681, 0.780303, 0.7798319], orientation: 1, size: CGSize(width: 9520, height: 6336),
       want: CropRect(x: 0.2201681, y: 0.219697, width: 0.7798319 - 0.2201681, height: 0.780303 - 0.219697), aspect: .r3x2),
    // 75 mm, held upright: 2,384 x 3,568 of the turned 6,336 x 9,520.
    Q3(file: "L1026367.DNG", crop: [0.3118687, 0.3126051, 0.6881313, 0.687395], orientation: 6, size: CGSize(width: 6336, height: 9520),
       want: CropRect(x: 1 - 0.6881313, y: 0.3126051, width: 0.6881313 - 0.3118687, height: 0.687395 - 0.3126051), aspect: .r2x3),
    Q3(file: "L1026368.DNG", crop: [0.3118687, 0.3126051, 0.6881313, 0.687395], orientation: 6, size: CGSize(width: 6336, height: 9520),
       want: CropRect(x: 1 - 0.6881313, y: 0.3126051, width: 0.6881313 - 0.3118687, height: 0.687395 - 0.3126051), aspect: .r2x3),
]

func nearRect(_ a: CropRect?, _ b: CropRect, _ tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
}

func cameraCrop(_ c: Checks) {
    // The tag's numbers, through the orientation, for each of the four files.
    for f in q3 {
        let got = c.rules.cameraCrop(dngProperties(f.crop, orientation: f.orientation))
        c.expect(nearRect(got, f.want), "\(f.file): the camera's crop is \(f.want), turned as the file is (\(String(describing: got)))")
        guard let got else { continue }
        let g = c.rules.cameraGeometry(got, f.size)
        c.expect(g.aspect == f.aspect, "\(f.file): a new frame's crop is locked to \(f.aspect.rawValue) (\(g.aspect.rawValue))")
        let px = { (r: CropRect) in (r.width * f.size.width, r.height * f.size.height) }
        let (w0, h0) = px(got), (w1, h1) = px(g.crop)
        let ratio = f.aspect.fixedRatio ?? 0
        c.expect(abs(w1 / h1 - ratio) < 1e-6, "\(f.file): and is that ratio exactly (\(w1 / h1))")
        c.expect(abs(w1 * h1 / (w0 * h0) - 1) < 1e-6 && near(g.centre, CGPoint(x: got.x + got.width / 2, y: got.y + got.height / 2), 1e-9),
                 "\(f.file): about the camera's centre, its area kept")
        c.expect(abs(w1 - w0) < 0.005 * w0 && abs(h1 - h0) < 0.005 * h0, "\(f.file): within half a percent of the camera's rectangle")
        c.expect(g.fits(in: f.size) && g.angle == 0 && g.quarterTurns == 0 && !g.flipH && !g.flipV && !g.hasPerspective,
                 "\(f.file): a crop and nothing else, inside the picture")
        c.expect(g.intendedSize.map { abs($0.width - g.crop.width) < 1e-12 && abs($0.height - g.crop.height) < 1e-12 } ?? false,
                 "\(f.file): its size remembered, so a straighten does not grow it to the largest fit")
    }
    // No crop, a crop of the whole picture, and numbers no camera means.
    c.expect(c.rules.cameraCrop([kCGImagePropertyOrientation: NSNumber(value: 1)]) == nil, "a file with no DefaultUserCrop has no camera crop")
    c.expect(c.rules.cameraCrop(dngProperties([0, 0, 1, 1], orientation: 6)) == nil, "a DefaultUserCrop of the whole picture is no crop")
    c.expect(c.rules.cameraCrop(dngProperties([0.6, 0.1, 0.4, 0.9], orientation: 1)) == nil, "a crop whose bottom is above its top is none")
    c.expect(c.rules.cameraCrop(dngProperties([0.1, 0.1, 0.9], orientation: 1)) == nil, "three numbers are not a crop")
    // A crop of no picker ratio stays free, exactly the camera's.
    let odd = CropRect(x: 0.1, y: 0.2, width: 0.7, height: 0.3)
    let free = c.rules.cameraGeometry(odd, CGSize(width: 3000, height: 2000))
    c.expect(free.aspect == .free && nearRect(free.crop, odd, 1e-12) && free.intendedSize != nil,
             "a crop of no picker ratio is free and exactly the camera's (\(free.aspect.rawValue), \(free.crop))")

    // Every orientation, against Core Image's own turn of a picture whose every pixel says where it was
    // stored: the corner pixels of the crop as turned are the corner pixels of the stored crop.
    let w = 40, h = 30
    let stored = ramp(w, h)   // top row first, as a decode is
    let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
    // top 3 px, left 8, bottom 15, right 36: on pixel edges, and no symmetry to hide a wrong turn in.
    let tag = [3.0 / 30, 8.0 / 40, 15.0 / 30, 36.0 / 40]
    let storedCorners = [CGPoint(x: 8.5, y: 3.5), CGPoint(x: 35.5, y: 3.5), CGPoint(x: 8.5, y: 14.5), CGPoint(x: 35.5, y: 14.5)]
    for o in 1...8 {
        var shown = stored.oriented(forExifOrientation: Int32(o))
        shown = shown.transformed(by: CGAffineTransform(translationX: -shown.extent.minX, y: -shown.extent.minY))
        let ow = Int(shown.extent.width), oh = Int(shown.extent.height)
        var rgba = [Float](repeating: 0, count: ow * oh * 4)
        rgba.withUnsafeMutableBytes { buf in
            ctx.render(shown, toBitmap: buf.baseAddress!, rowBytes: ow * 16, bounds: CGRect(x: 0, y: 0, width: ow, height: oh),
                       format: .RGBAf, colorSpace: nil)
        }
        guard let r = c.rules.cameraCrop(dngProperties(tag, orientation: o)) else { c.expect(false, "orientation \(o): a crop is read"); continue }
        let x0 = r.x * Double(ow), y0 = r.y * Double(oh), x1 = x0 + r.width * Double(ow), y1 = y0 + r.height * Double(oh)
        var found: [CGPoint] = []
        for (u, v) in [(x0 + 0.5, y0 + 0.5), (x1 - 0.5, y0 + 0.5), (x0 + 0.5, y1 - 0.5), (x1 - 0.5, y1 - 0.5)] {
            let x = Int(u.rounded(.down)), y = Int(v.rounded(.down))
            guard x >= 0, y >= 0, x < ow, y < oh else { found.append(CGPoint(x: -99, y: -99)); continue }
            let i = (y * ow + x) * 4
            found.append(CGPoint(x: Double(rgba[i]) * Double(w), y: Double(rgba[i + 1]) * Double(h)))
        }
        let matched = storedCorners.allSatisfy { s in found.contains { near($0, s, 0.25) } }
        c.expect(matched && ow == (o >= 5 ? h : w), "orientation \(o): the crop as turned is the stored crop as Core Image turns it (\(found))")
    }

    // The four files themselves, where a copy of them is named: what ImageIO reads off each.
    if let dir = ProcessInfo.processInfo.environment["CAMERA_CROP_DNGS"] {
        for f in q3 {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(f.file)
            guard FileManager.default.fileExists(atPath: url.path) else { c.expect(false, "\(f.file) is in \(dir)"); continue }
            let read = CameraCrop.read(url)
            c.expect(nearRect(read, f.want, 1e-6), "\(f.file) read off the file: \(String(describing: read))")
            let whole = CameraCrop.reading(url)?.aspect
            c.expect(whole.map { abs($0 - f.size.width / f.size.height) < 1e-9 } ?? false,
                     "\(f.file): the whole picture's shape, turned, off the file (\(String(describing: whole)))")
        }
    } else if c.rules.name == "the app's" {
        print("  (camera crop: the four Q3 files themselves not read -- CAMERA_CROP_DNGS unset; their numbers were checked)")
    }
}

/// A DNG's properties as ImageIO hands them over (`dngProperties`), with the stored picture's size: the
/// first image's pixels and DefaultCropSize, as the Q3's carry them.
func dngProperties(_ crop: [Double], orientation: Int, stored: (w: Int, h: Int)) -> [CFString: Any] {
    [kCGImagePropertyDNGDictionary: [kCGImagePropertyDNGDefaultUserCrop: crop.map { String($0) },
                                     kCGImagePropertyDNGDefaultCropSize: [NSNumber(value: stored.w), NSNumber(value: stored.h)]] as [CFString: Any],
     kCGImagePropertyOrientation: NSNumber(value: orientation),
     kCGImagePropertyPixelWidth: NSNumber(value: stored.w + 8), kCGImagePropertyPixelHeight: NSNumber(value: stored.h + 8)]
}

/// The hook (2026-11-05, round 2): a new frame's crop from its header, the way `ImportService` makes it;
/// the catch-up of a frame made before the camera's crop was read; the cell's cut of a preview.
func cameraCropHook(_ c: Checks) {
    // An upright DNG (Orientation 6) whose crop is 2:3 once turned and sits off-centre, so the turned and
    // the unturned rectangles differ: stored 6000 x 4000, tag top .1 left .15 bottom .6 right .65; turned,
    // x = 1 - bottom = .4, y = left = .15, .5 x .5 of the 4000 x 6000 picture: 2000 x 3000, 2:3.
    let upright = dngProperties([0.1, 0.15, 0.6, 0.65], orientation: 6, stored: (6000, 4000))
    let size = PixelSize(width: 4000, height: 6000)    // the probe's: the decoder's, turned
    let g = c.rules.newFrameGeometry(upright, size)
    let want = CropRect(x: 0.4, y: 0.15, width: 0.5, height: 0.5)
    c.expect(nearRect(g.crop, want, 1e-9), "a new upright DNG frame opens on the camera's crop, turned as the file is (\(g.crop))")
    c.expect(g.aspect == .r2x3 && g.intendedSize != nil, "its 2:3 locked and its size remembered (\(g.aspect.rawValue))")
    c.expect(g.angle == 0 && g.quarterTurns == 0 && !g.flipH && !g.flipV && !g.hasPerspective, "and nothing but the crop")
    // Free, off-centre, no ratio: 1600 x 3600 of 4000 x 6000.
    let odd = c.rules.newFrameGeometry(dngProperties([0.05, 0.1, 0.45, 0.7], orientation: 6, stored: (6000, 4000)), size)
    c.expect(nearRect(odd.crop, CropRect(x: 0.55, y: 0.1, width: 0.4, height: 0.6), 1e-9) && odd.aspect == .free,
             "a crop of no ratio is exactly the camera's, turned (\(odd.crop), \(odd.aspect.rawValue))")
    c.expect(c.rules.newFrameGeometry([kCGImagePropertyOrientation: NSNumber(value: 6)], size) == .default,
             "a file with no camera crop makes a frame with no crop")
    c.expect(c.rules.newFrameGeometry(dngProperties([0, 0, 1, 1], orientation: 1, stored: (6000, 4000)), PixelSize(width: 6000, height: 4000)) == .default,
             "a camera crop of the whole picture makes a frame with no crop")

    // ImportService goes through it: the probe makes the geometry from the header, the frame takes it.
    if let text = c.rules.importSource() {
        c.expect(text.contains("geometry: CameraCrop.newFrameGeometry(properties: props, size: size)"),
                 "ImportService.probe makes a new frame's crop through CameraCrop.newFrameGeometry (\(importServiceURL.lastPathComponent))")
        c.expect(text.contains("edit.geometry = p.geometry"), "ImportService.frame takes the probe's crop as the new frame's")
    } else { c.expect(false, "ImportService.swift is read (\(importServiceURL.path))") }

    // The catch-up's marker survives a save and a load, and the launch runs the catch-up.
    if let text = c.rules.persistenceSource().map(uncommented) {
        c.expect(text.contains("cameraCropRead = f.cameraCropRead"), "a saved frame keeps its camera-crop marker (StoredFrame.init)")
        c.expect(text.contains("cameraCropRead: cameraCropRead)"), "a loaded frame gets its camera-crop marker back (StoredFrame.frame)")
        c.expect(text.contains("var cameraCropRead: Bool? = nil"), "a library saved before the marker still loads (an optional key)")
    } else { c.expect(false, "LibraryPersistence.swift is read") }
    if let text = c.rules.appModelSource().map(uncommented) {
        // The declaration and at least one call (the declaration's own text holds the call's).
        c.expect(text.contains("func holdCameraCrops()") && text.components(separatedBy: "holdCameraCrops()").count - 1 >= 2,
                 "the launch catches up the frames made before the camera's crop was read (AppServices.holdCameraCrops)")
    } else { c.expect(false, "AppServices.swift is read") }

    // The whole picture's shape, turned: DefaultCropSize before the first image's pixels.
    let r = c.rules.reading(upright)
    c.expect(r.aspect.map { abs($0 - 4000.0 / 6000) < 1e-12 } ?? false && nearRect(r.crop, want, 1e-9),
             "a header's reading: the crop and the whole picture's shape, turned (\(String(describing: r.aspect)))")

    // The catch-up of a frame made before the crop was read (2.1.3's frames of the Q3's DNGs).
    let made = FrameEdit.default
    var drawn = made; drawn.geometry.crop = CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
    var straightened = made; straightened.geometry.angle = 1.5
    var finishedCrop = made; finishedCrop.printCrop.crop = CropRect(x: 0, y: 0, width: 0.5, height: 1)
    var edged = made; edged.filmEdge.active = true
    c.expect(c.rules.owing("L1026319.DNG", false, false, nil, made) == .read, "a DNG frame of 2.1.3, its crops as made, is read")
    c.expect(c.rules.owing("l1026319.dng", false, false, nil, made) == .read, "whatever the extension's case")
    c.expect(c.rules.owing("L1026319.DNG", false, false, true, made) == .nothing, "once read, never again: a Reset to the whole picture stays")
    c.expect(c.rules.owing("L1026319.DNG", false, false, nil, drawn) == .settled, "a frame whose crop was drawn keeps it")
    c.expect(c.rules.owing("L1026319.DNG", false, false, nil, straightened) == .settled, "and one straightened")
    c.expect(c.rules.owing("L1026319.DNG", false, false, nil, finishedCrop) == .settled, "and one with Edit's crop")
    c.expect(c.rules.owing("L1026319.DNG", false, false, nil, edged) == .settled, "and one in a film edge, whose framing sits over the crop")
    c.expect(c.rules.owing("DSC0001.NEF", false, false, nil, made) == .nothing, "a file that is not a DNG is owed nothing")
    c.expect(c.rules.owing("Half-Frame Pair 1", true, false, nil, made) == .nothing && c.rules.owing("demo.dng", false, true, nil, made) == .nothing,
             "nor a pair nor a demo frame")
    let away = c.rules.caughtUp(made, nil, size)
    c.expect(!away.read && away.geometry == .default, "a file that cannot be read now stays owed, not taken for one with no crop")
    let none = c.rules.caughtUp(made, .uncropped, size)
    c.expect(none.read && none.geometry == .default, "one read with no crop is read, and keeps no crop")
    let caught = c.rules.caughtUp(made, r, size)
    c.expect(caught.read && nearRect(caught.geometry.crop, want, 1e-9) && caught.geometry.aspect == .r2x3,
             "one read with a crop takes it, as a new frame would (\(caught.geometry.crop))")
    c.expect(caught.geometry == g, "the very geometry a new frame of the file makes")

    // The cell's cut: a preview already cut to the crop is not cut again; a whole one is.
    let square = CameraCrop.Reading(crop: CropRect(x: 0.2, y: 0.2, width: 0.4, height: 0.6), aspect: 1.5)   // a 1:1 crop of 3:2
    c.expect(c.rules.previewIsCut(512, 512, square), "a 1:1 preview of a 1:1 camera crop is the crop already")
    c.expect(!c.rules.previewIsCut(512, 341, square), "a 3:2 preview of it is the whole picture, to be cut")
    let q3 = CameraCrop.Reading(crop: CropRect(x: 0.1, y: 0.0985, width: 0.8, height: 0.803), aspect: 9520.0 / 6336)
    c.expect(!c.rules.previewIsCut(512, 341, q3), "a crop of the whole picture's own shape (the Q3's 35 mm) is cut")
}

/// The crop page's scroll zoom (2026-11-05: the owner's mouse wheel "reaches one terrible edge point
/// where I cannot even recover"): a zoom out about any pointer grows the crop, up to the largest crop of
/// its shape the frame holds, and never shrinks it or drives it into a corner; a zoom in stops at the
/// handles' smallest; a straightened crop stays inside.
func scrollZoom(_ c: Checks) {
    let q3 = CGSize(width: 9520, height: 6336)
    let out = exp(CGFloat(-24 * 0.006))           // one line of a plain wheel, out
    // The case measured in the app: the whole frame, the pointer off-centre, one click out.
    let whole = c.rules.zoom(Geometry(), out, CGPoint(x: 0.3, y: 0.5), q3)
    c.expect(whole.crop.width >= 0.999 && whole.crop.height >= 0.999 && near(whole.centre, CGPoint(x: 0.5, y: 0.5), 1e-6),
             "a zoom out of the whole frame stays the whole frame (\(whole.crop))")
    // Every pointer on a grid, a run of clicks out from a small crop: it grows each step until it is
    // the largest of its shape, and once there stays there, whatever the pointer.
    var everyGrows = true, endsWhole = true
    for i in 0..<5 { for j in 0..<5 {
        let p = CGPoint(x: 0.1 + 0.2 * Double(i), y: 0.1 + 0.2 * Double(j))
        var g = Geometry(); g.crop = CropRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        for _ in 0..<40 {
            let n = c.rules.zoom(g, out, p, q3)
            if n.crop.width < g.crop.width - 1e-9 { everyGrows = false }
            g = n
        }
        if g.crop.width < 0.999 || g.crop.height < 0.999 { endsWhole = false }
    } }
    c.expect(everyGrows, "a zoom out never makes the crop smaller, about any pointer")
    c.expect(endsWhole, "a run of zooms out ends at the whole frame, about any pointer")
    // A locked 2:3 crop on a 3:2 frame (the camera's 75 mm crop): out about an off-centre point, it grows.
    var locked = Geometry(); locked.aspect = .r2x3
    locked.crop = CropRect(x: 0.35, y: 0.25, width: 0.4341, height: 0.65)
    let grown = c.rules.zoom(locked, out, CGPoint(x: 0.45, y: 0.45), q3)
    c.expect(grown.crop.width > locked.crop.width && grown.fits(in: q3), "a 2:3 crop zoomed out grows and fits (\(grown.crop.width))")
    // Straightened 5°: zoomed out to the end, still inside the frame.
    var tilted = Geometry(); tilted.angle = 5
    tilted = tilted.fitted(in: q3)
    var t = tilted
    for _ in 0..<30 { t = c.rules.zoom(t, out, CGPoint(x: 0.2, y: 0.8), q3) }
    // 1e-5 of 9,520 px is 0.1 px: fitted's bisection and maxScale's closed form differ in the last places.
    c.expect(t.fits(in: q3) && t.crop.width >= tilted.crop.width - 1e-5, "a straightened crop zoomed out stays inside and does not shrink (\(t.crop.width))")
    // In: stops at the handles' smallest, no smaller.
    var small = Geometry()
    for _ in 0..<200 { small = c.rules.zoom(small, 1 / out, CGPoint(x: 0.7, y: 0.3), q3) }
    c.expect(small.crop.width * q3.width >= Geometry.minSide - 1e-6 && small.crop.height * q3.height >= Geometry.minSide - 1e-6,
             "a zoom in stops at the smallest crop the handles allow")
}

/// The Mac's crop page draws the whole picture (2026-11-05, the owner: "always the original image
/// intersect with the edge of the render canvas, instead of the current zoom-in style"): for every crop
/// shape, angle, turn, flip and perspective, the picture's outline is inside the stage's room and meets
/// two of its opposite edges, the crop is on the picture, and the map does not move when the crop does.
/// The crop-fitted map (`rest`, the one `GeometryPicture` draws a finished crop with) is run through the
/// same checks as the control: it must fail them, or they cannot see the bug.
func wholePicture(_ c: Checks) {
    let room = CGRect(x: 26, y: 22, width: 1512, height: 1210)
    let q3 = CGSize(width: 9520, height: 6336)
    // The corrected frame, as the Mac's stage draws it (cut to the frame that develops).
    func outline(_ m: StageMapping, _ g: Geometry) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: q3.width, y: 0), CGPoint(x: q3.width, y: q3.height), CGPoint(x: 0, y: q3.height)].map(m.screen)
    }
    func shown(_ m: StageMapping, _ g: Geometry) -> Bool {
        let o = outline(m, g), e = 0.01
        let inside = o.allSatisfy { $0.x >= room.minX - e && $0.x <= room.maxX + e && $0.y >= room.minY - e && $0.y <= room.maxY + e }
        let xs = o.map(\.x), ys = o.map(\.y)
        let meetsX = abs(xs.min()! - room.minX) < 0.5 && abs(xs.max()! - room.maxX) < 0.5
        let meetsY = abs(ys.min()! - room.minY) < 0.5 && abs(ys.max()! - room.maxY) < 0.5
        let crop = m.corners(g, imageSize: q3).allSatisfy { $0.x >= room.minX - e && $0.x <= room.maxX + e && $0.y >= room.minY - e && $0.y <= room.maxY + e }
        return inside && (meetsX || meetsY) && crop
    }
    var cases: [Geometry] = []
    for crop in [CropRect(x: 0, y: 0, width: 1, height: 1), CropRect(x: 0.3, y: 0, width: 0.6332, height: 1),   // the owner's 6,028 × 6,336
                 CropRect(x: 0.0336, y: 0, width: 0.9329, height: 1), CropRect(x: 0.4, y: 0.4, width: 0.1, height: 0.3),
                 CropRect(x: 0.1, y: 0.45, width: 0.8, height: 0.1)] {
        for (angle, turns, flip, v) in [(0.0, 0, false, 0.0), (5.0, 0, false, 0.0), (-12.0, 1, true, 0.0), (0.0, 3, false, 8.0), (3.0, 2, true, -6.0)] {
            var g = Geometry(); g.crop = crop; g.angle = angle; g.quarterTurns = turns; g.flipH = flip; g.vertical = v
            g = g.fitted(in: q3)
            cases.append(g)
        }
    }
    var wholeOK = 0, restOK = 0
    for g in cases {
        if shown(StageMapping.whole(g, imageSize: q3, room: room, turns: g.quarterTurns), g) { wholeOK += 1 }
        if shown(StageMapping.rest(g, imageSize: q3, room: room, turns: g.quarterTurns), g) { restOK += 1 }
    }
    c.expect(wholeOK == cases.count, "the whole picture is on the stage and meets its edges in every case (\(wholeOK)/\(cases.count))")
    c.expect(restOK < cases.count / 2, "control: the crop-fitted map leaves the picture off the stage in most cases (\(restOK)/\(cases.count) shown)")
    // The map is the picture's, not the crop's: moving or resizing the crop moves nothing else.
    var a = Geometry(); a.angle = 4; a = a.fitted(in: q3)
    var b = a; b.crop = CropRect(x: 0.2, y: 0.3, width: 0.3, height: 0.3)
    c.expect(StageMapping.whole(a, imageSize: q3, room: room, turns: 0)
             == StageMapping.whole(b, imageSize: q3, room: room, turns: 0),
             "the whole-picture map does not move when the crop does")
}

/// A preview develop of a cropped photo keeps a picture near the preview's own size (2026-11-09, PRD-A A4):
/// the owner's L1026368.DNG, a Leica Q3 portrait cut to 0.376 × 0.375 by its camera's crop, kept a develop of
/// 480 × 720 px (its preview long edge, 1,920, times the cut) and showed it in a fit of 1,363 × 2,046 px. The
/// decode is the whole photo's; the engine cuts it first (`preprocess.crop_rescale`), so what the picture
/// keeps is the decode's long edge times the cut's.
func previewDecode(_ c: Checks) {
    let q3Portrait = PixelSize(width: 6336, height: 9520), q3 = PixelSize(width: 9520, height: 6336)
    func kept(_ crop: CropRect, _ original: PixelSize, preview: Int = 2560) -> (decode: Int, kept: Double) {
        var g = Geometry(); g.crop = crop
        let decode = c.rules.previewDecode(g, preview, original)
        let w = Double(original.width), h = Double(original.height)
        let cut = max(crop.width * w, crop.height * h) / max(w, h)
        return (decode, Double(decode) * cut)
    }
    let l368 = kept(CropRect(x: 0.3121, y: 0.3124, width: 0.3758, height: 0.3752), q3Portrait)
    c.expect(l368.kept >= 2560 / 2.squareRoot() && l368.kept <= 2560 * 2.squareRoot(),
             "L1026368's cut keeps a picture near the preview's size (\(Int(l368.kept)) px of 2,560; decoded at \(l368.decode))")
    let l368old = kept(CropRect(x: 0.3121, y: 0.3124, width: 0.3758, height: 0.3752), q3Portrait, preview: 1920)
    c.expect(l368old.kept >= 1920 / 2.squareRoot(), "…and at a 1,920 px preview (\(Int(l368old.kept)) px; it kept 720)")
    // The frames that were sharp keep their size, so their kept develops keep their stamps.
    c.expect(kept(CropRect(x: 0.0996, y: 0.0989, width: 0.8008, height: 0.8022), q3).decode == 2560,
             "L1026319's 0.8 cut decodes at the preview's size, as before")
    c.expect(kept(.full, q3).decode == 2560, "an uncropped photo decodes at the preview's size, as before")
    // Never past the photo, never past four times the preview.
    let tiny = kept(CropRect(x: 0.45, y: 0.45, width: 0.05, height: 0.05), q3)
    c.expect(tiny.decode <= q3.longEdge && tiny.decode <= 4 * 2560, "a tiny cut decodes at most the photo's own size (\(tiny.decode))")
    let small = PixelSize(width: 3000, height: 2000)
    c.expect(kept(CropRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), small).decode == 3000, "never past the photo's long edge")
    // A crop dragged a little does not move the decode's size (each move would open the frame again).
    let a = kept(CropRect(x: 0.3, y: 0.3, width: 0.36, height: 0.36), q3).decode
    let b = kept(CropRect(x: 0.3, y: 0.3, width: 0.40, height: 0.40), q3).decode
    c.expect(a == b, "a crop dragged from 0.36 to 0.40 keeps one decode size (\(a), \(b))")
}

func run(_ rules: Rules) -> Checks {
    let c = Checks(rules)
    records(c); keystone(c); hostCut(c); guides(c); finished(c); cropIsFrame(c); cameraCrop(c); cameraCropHook(c); scrollZoom(c); wholePicture(c)
    previewDecode(c)
    return c
}

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var broken: [Rules] = []
            var r = Rules(); r.name = "the keystone's inverse is its forward"
            r.keystone = { v, h, s in var k = Keystone.make(vertical: v, horizontal: h, size: s); k.inverse = k.forward; return k }
            broken.append(r)
            r = Rules(); r.name = "the host re-projects the wrong way"
            r.corrected = { image, g in
                var back = g; back.vertical = -g.vertical; back.horizontal = -g.horizontal
                return HostCut.image(image, by: back)
            }
            broken.append(r)
            r = Rules(); r.name = "Apply turns the wrong way"
            r.solve = { m, q, g, s in CropGuides.solve(m, points: q, geometry: g, imageSize: s).map { ($0.vertical, $0.horizontal, -$0.angle) } }
            broken.append(r)
            r = Rules(); r.name = "the guides' Apply only straightens"
            r.solve = { m, q, g, s in CropGuides.solve(m, points: q, geometry: g, imageSize: s).map { (g.vertical, g.horizontal, $0.angle) } }
            broken.append(r)
            r = Rules(); r.name = "every mode's points read as a rectangle's"
            r.solve = { _, q, g, s in CropGuides.solve(.rectangle, points: q, geometry: g, imageSize: s) }
            broken.append(r)
            r = Rules(); r.name = "Edit's crop of a file is not made"
            r.finishedCut = { image, _ in image }
            broken.append(r)
            r = Rules(); r.name = "the export's plan forgets Edit's crop"
            r.plan = { ask in var a = ask; a.printCrop = .default; return ExportPlan.make(a) }
            broken.append(r)
            r = Rules(); r.name = "the crop never re-maps the frame (2.0 before 2026-10-26)"
            r.wireFormat = { e, _, _ in e.params.filmFormatMM }
            broken.append(r)
            r = Rules(); r.name = "an edit always writes its Edit crop"
            r.encode = { e in
                let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
                var o = try JSONSerialization.jsonObject(with: try enc.encode(e)) as! [String: Any]
                o["printCrop"] = try JSONSerialization.jsonObject(with: try enc.encode(e.printCrop))
                return try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
            }
            broken.append(r)
            r = Rules(); r.name = "a preview develop decodes the whole photo at the preview's size whatever its cut (2.2.2)"
            r.previewDecode = { _, preview, _ in preview }
            broken.append(r)
            r = Rules(); r.name = "a preview develop decodes the cut at the preview's size, past the photo"
            r.previewDecode = { g, preview, _ in Int(Double(preview) / max(min(g.crop.width, g.crop.height), 0.01)) }
            broken.append(r)
            r = Rules(); r.name = "the camera's crop is never read (2.1.3)"
            r.cameraCrop = { _ in nil }
            broken.append(r)
            r = Rules(); r.name = "the camera's crop is taken in the stored frame, unturned"
            r.cameraCrop = { p in
                var q = p; q[kCGImagePropertyOrientation] = NSNumber(value: 1); return CameraCrop.read(q)
            }
            broken.append(r)
            r = Rules(); r.name = "a quarter turn read the wrong way round (6 as 8)"
            r.cameraCrop = { p in
                var q = p
                if (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6 { q[kCGImagePropertyOrientation] = NSNumber(value: 8) }
                return CameraCrop.read(q)
            }
            broken.append(r)
            r = Rules(); r.name = "the camera's crop opens free, its size forgotten"
            r.cameraGeometry = { crop, _ in var g = Geometry(); g.crop = crop; return g }
            broken.append(r)
            r = Rules(); r.name = "the hook is dropped: a new frame never opens on the camera's crop"
            r.newFrameGeometry = { _, _ in .default }
            broken.append(r)
            r = Rules(); r.name = "the hook takes the camera's crop unturned"
            r.newFrameGeometry = { p, s in var q = p; q[kCGImagePropertyOrientation] = NSNumber(value: 1); return CameraCrop.newFrameGeometry(properties: q, size: s) }
            broken.append(r)
            r = Rules(); r.name = "ImportService.frame no longer takes the hook's crop"
            r.importSource = { (try? String(contentsOf: importServiceURL, encoding: .utf8))?.replacingOccurrences(of: "edit.geometry = p.geometry", with: "") }
            broken.append(r)
            r = Rules(); r.name = "ImportService.probe reads no camera crop"
            r.importSource = { (try? String(contentsOf: importServiceURL, encoding: .utf8))?.replacingOccurrences(of: "CameraCrop.newFrameGeometry(", with: "Geometry.identity(") }
            broken.append(r)
            r = Rules(); r.name = "the crop's zoom out is not capped at the largest crop (before 2026-11-05)"
            r.zoom = { base, m, p, size in
                let cw = max(base.crop.width, 1e-9), ch = max(base.crop.height, 1e-9)
                let k = max(1 / max(m, 0.05), Geometry.minSide / size.width / cw, Geometry.minSide / size.height / ch)
                let c = base.centre
                let to = CGPoint(x: p.x + (c.x - p.x) * k, y: p.y + (c.y - p.y) * k)
                var g = base
                g.crop = CropRect(x: to.x - cw * k / 2, y: to.y - ch * k / 2, width: cw * k, height: ch * k)
                return g.moved(by: .zero, in: size).fitted(in: size)
            }
            broken.append(r)
            r = Rules(); r.name = "the marker is not saved: every launch reads the frame again"
            r.persistenceSource = { (try? String(contentsOf: sourceURL("Services/LibraryPersistence.swift"), encoding: .utf8))?.replacingOccurrences(of: "; cameraCropRead = f.cameraCropRead", with: "") }
            broken.append(r)
            r = Rules(); r.name = "the marker is not loaded"
            r.persistenceSource = { (try? String(contentsOf: sourceURL("Services/LibraryPersistence.swift"), encoding: .utf8))?.replacingOccurrences(of: ", cameraCropRead: cameraCropRead)", with: ")") }
            broken.append(r)
            r = Rules(); r.name = "the launch's catch-up is commented out"
            r.appModelSource = { (try? String(contentsOf: sourceURL("App/AppServices.swift"), encoding: .utf8))?.replacingOccurrences(of: "            holdCameraCrops()\n", with: "            // holdCameraCrops()\n") }
            broken.append(r)
            r = Rules(); r.name = "a frame made before the camera's crop is never caught up (round 1)"
            r.owing = { _, _, _, _, _ in .nothing }
            broken.append(r)
            r = Rules(); r.name = "an edited frame's crop is replaced by the camera's"
            r.owing = { name, pair, demo, read, _ in CameraCrop.owing(fileName: name, isPair: pair, isDemo: demo, read: read, edit: .default) }
            broken.append(r)
            r = Rules(); r.name = "a frame is read again after its Reset"
            r.owing = { name, pair, demo, _, edit in CameraCrop.owing(fileName: name, isPair: pair, isDemo: demo, read: nil, edit: edit) }
            broken.append(r)
            r = Rules(); r.name = "a file that cannot be read is kept as one with no crop"
            r.caughtUp = { edit, reading, size in CameraCrop.caughtUp(edit, reading: reading ?? .uncropped, size: size) }
            broken.append(r)
            r = Rules(); r.name = "a preview the camera cut is cut again"
            r.previewIsCut = { _, _, _ in false }
            broken.append(r)
            r = Rules(); r.name = "every preview of a cropped file is taken as cut"
            r.previewIsCut = { _, _, reading in reading.crop != nil }
            broken.append(r)
            var caught = 0
            for b in broken {
                let c = run(b)
                if c.failed.isEmpty { print("  NOT CAUGHT: \(b.name)") } else { caught += 1; print("  caught  \(b.name): \(c.failed.count) check(s) failed, e.g. \(c.failed[0])") }
            }
            print("crop self-test: \(caught) of \(broken.count) broken rules caught")
            exit(caught == broken.count ? 0 : 1)
        }
        let c = run(Rules())
        for f in c.failed { print("  FAIL: \(f)") }
        print("crop checks: \(c.passed) passed, \(c.failed.count) failed")
        exit(c.failed.isEmpty ? 0 : 1)
    }
}
