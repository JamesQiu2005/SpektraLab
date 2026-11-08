//  film_geometry_dump.swift — the app's film layout, written out to be held against the engine.
//
//      build/tools/film_geometry_dump <cases.json> <out dir> [StockCatalog.json]
//
//  Reads a list of cases (what the engine was told: format, view, gate, seeds,
//  the frame's size, the stock, the edge's words — or none, and then they are
//  the app's own for that stock, `Stock.edgeText` — and the date), lays each out with
//  the app's own `FilmLayout`, and writes for each
//
//    <id>.json   the canvas, the gate's corners on it, the DX codes, the name,
//                and `wire`: the fields the app sends the engine for this
//                case (`FilmEdgeSettings.wire`, `DateBackSettings.wire`), so
//                the engine is driven by the app's own words
//    <id>.png    the marks as a mask at the canvas's own size, 8-bit grey:
//                64 the gate's opening, 128 the edge print, 192 the date,
//                255 the perforations, 0 everything else
//    <id>.gray   the same mask as bare bytes, row after row (for a reader
//                with no PNG decoder)
//
//  `tools/film_edge_parity.py` renders the same cases with the real engine and
//  compares. Compiled by that script with the app's own sources, on the Mac:
//  the layout has no UIKit in it.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Case: Decodable {
    var id: String
    var format: String
    var mode: String?
    var gate: String?
    var holes: String?
    var camera_seed: Int?
    var frame_seed: Int?
    var frame_number: Int?
    var frame_w: Int
    var frame_h: Int
    var stock: String
    var edge_text: String?
    var f_number: Double?
    var date: DateCase?

    struct DateCase: Decodable {
        var text: String
        var style: String?
        var placement: String?
        var corner: String?
        var inset_x: Double?
        var inset_y: Double?
        var size: Double?
        /// The data line beside a date face (`date_imprint_data_text`).
        var data_text: String?
    }
}

@main
enum Dump {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: film_geometry_dump <cases.json> <out dir>\n".utf8))
            exit(2)
        }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // The repository's own catalogue, where there is no bundle: a case
        // with no words of its own is laid out in the words the app sends.
        let catalog = args.count >= 4 ? StockCatalog(contentsOf: URL(fileURLWithPath: args[3])) : nil
        if args.count >= 4 && catalog == nil { fail("no catalogue at \(args[3])") }
        for c in cases {
            guard let format = FilmEdgeFormat(rawValue: c.format) else { fail("\(c.id): unknown format \(c.format)") }
            var r = FilmEdgeRequest()
            r.format = format
            r.mode = FilmEdgeView(rawValue: c.mode ?? "strip") ?? .strip
            r.gate = FilmEdgeGate(rawValue: c.gate ?? "auto") ?? .auto
            r.holes = FilmEdgeHoles(rawValue: c.holes ?? "white") ?? .white
            r.cameraSeed = c.camera_seed ?? 1
            r.frameSeed = c.frame_seed ?? 1
            r.frameNumber = c.frame_number ?? 0
            r.frame = PixelSize(width: c.frame_w, height: c.frame_h)
            r.stockID = c.stock
            let appText = catalog?.stock(c.stock)?.edgeText ?? ""
            r.edgeText = c.edge_text ?? appText
            r.fNumber = c.f_number ?? 0
            if let d = c.date {
                r.date = DateRequest(text: d.text,
                                     style: DateBackFace(rawValue: d.style ?? "lcd") ?? .lcd,
                                     placement: DateBackPlacement(rawValue: d.placement ?? "frame") ?? .frame,
                                     corner: DateBackCorner(rawValue: d.corner ?? "br") ?? .br,
                                     insetXMM: d.inset_x ?? 3.0, insetYMM: d.inset_y ?? 2.4, size: d.size ?? 1.0,
                                     dataText: d.data_text ?? "")
            }
            // The engine reads the film's direction off the frame's shape; ask
            // for that turn, so the host makes no turn of its own.
            guard let first = FilmLayout.layout(r) else {
                try write(["id": c.id, "valid": false], to: out.appendingPathComponent(c.id + ".json"))
                continue
            }
            r.turn = first.vertical ? 1 : 0
            guard let g = FilmLayout.layout(r), g.extraTurns == 0 else { fail("\(c.id): the layout turned the canvas") }

            // What the app sends for this case: its own settings types, its own wire.
            var edge = FilmEdgeSettings()
            edge.active = true
            edge.format = format; edge.mode = r.mode; edge.gate = r.gate; edge.holes = r.holes
            edge.cameraSeed = r.cameraSeed; edge.frameNumber = r.frameNumber
            edge.fog = 0; edge.leaks = 0                    // a flat rebate, so the marks can be measured
            var back = DateBackSettings()
            if let d = r.date {
                back.active = true
                back.style = d.style; back.placement = d.placement; back.corner = d.corner
                back.insetXMM = d.insetXMM; back.insetYMM = d.insetYMM; back.size = d.size
                back.alsoData = !d.dataText.isEmpty
            }
            var wire: [String: Any] = [:]
            for field in edge.wire(edgeText: r.edgeText, frameSeed: r.frameSeed, fNumber: r.fNumber)
                + back.wire(text: r.date?.text ?? "", filmEdge: edge, dataText: r.date?.dataText ?? "") {
                switch field.value {
                case .bool(let b): wire[field.name] = b
                case .double(let d): wire[field.name] = d
                case .string(let s): wire[field.name] = s
                }
            }

            let m = g.filmToCanvas
            func canvas(_ s: Double, _ t: Double) -> [Double] {
                let p = CGPoint(x: s, y: t).applying(m)
                return [Double(p.x) / g.px / Double(g.canvas.width), Double(p.y) / g.px / Double(g.canvas.height)]
            }
            let s0 = g.gateS0, s1 = g.gateS0 + g.gateAlong, t0 = g.gateT0, t1 = g.gateT0 + g.gateAcross
            let report: [String: Any] = [
                "id": c.id, "valid": true,
                "canvas_w": g.canvas.width, "canvas_h": g.canvas.height, "mm_per_px": g.px, "vertical": g.vertical,
                "format": g.request.format.rawValue,
                "gate_mm": [g.gateAlong, g.gateAcross],
                "penumbra_mm": g.penumbra,
                "gate": canvas(s0, t0) + canvas(s1, t0) + canvas(s1, t1) + canvas(s0, t1),
                "gate_family": g.gateFamily.rawValue,
                "film_w": g.filmW, "perf_phase": g.perfPhase, "scan_rot": g.scanRot,
                "s_lo": g.sLo, "s_hi": g.sHi, "dx_length": g.dxCodes.isEmpty ? 0.0 : g.dxLength, "dx_turned": g.dxTurned,
                "holes": g.holes.count,
                "dx": g.dxNumber ?? -1,
                "dx_codes": g.dxCodes.map { ["s": $0.s, "frame": $0.frame, "half": $0.half] as [String: Any] },
                "name": g.printedName, "numbers": g.printedNumbers, "app_edge_text": appText,
                "edge_marks": g.edge.count, "date_marks": g.date.count,
                "wire": wire,
            ]
            try write(report, to: out.appendingPathComponent(c.id + ".json"))
            let (png, raw) = mask(g)
            try png.write(to: out.appendingPathComponent(c.id + ".png"))
            try raw.write(to: out.appendingPathComponent(c.id + ".gray"))
        }
        print("film_geometry_dump: \(cases.count) cases -> \(out.path)")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    /// The film's marks, one grey level each, at the canvas's own pixels.
    static func mask(_ g: FilmGeometry) -> (png: Data, raw: Data) {
        let w = g.canvas.width, h = g.canvas.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { fail("no bitmap of \(w) x \(h)") }
        // No antialiasing: every pixel is one mark or none, so a reader can
        // tell them apart by their level alone.
        ctx.setShouldAntialias(false)
        // canvas pixels, y down: the bitmap's origin is bottom-left
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: 1 / g.px, y: 1 / g.px)                // canvas millimetres
        let m = g.filmToCanvas
        func fill(_ path: Path, _ level: CGFloat) {
            ctx.setFillColor(gray: level / 255, alpha: 1)
            ctx.addPath(path.applying(m).cgPath)
            ctx.fillPath()
        }
        fill(g.gateOpening, 64)
        fill(g.edgeOutline, 128)
        fill(g.dateOutline, 192)
        fill(g.holesPath, 255)
        guard let image = ctx.makeImage(), let base = ctx.data else { fail("no image") }
        // The bitmap's rows may be padded: copy each at its own width.
        var raw = Data(capacity: w * h)
        for row in 0..<h { raw.append(Data(bytes: base + row * ctx.bytesPerRow, count: w)) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { fail("no png") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return (data as Data, raw)
    }
}
