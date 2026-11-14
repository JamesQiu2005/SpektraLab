//  subject_find.swift — `SubjectFinder` on real photographs, for a person to look at and for the numbers (PRD-E §5.3,
//  RFC-052 §9, M1c). No app launch: the app's own finder, rendition and files, compiled with this driver.
//
//      tools/subject_find.sh [files…]            # the table: three rounds, interleaved, a process a request
//      tools/subject_find.sh --sizes [files…]    # the rendition's long edge: 1024 … 4096 against 4096's mask
//
//  Writes under build/masks-check/found/<photograph>/: the rendition (`source.png`), each mask (`subject.png`,
//  `person-<n>.png`, `people.png`), each over the rendition in red (`*-over.png`) and each person's menu square
//  (`thumb-<n>.png`, 112 px: 4 × the menu's 28). Each photograph is copied into build/masks-check/fixtures first:
//  a checkout file is never opened in place.
//
//  **A process a request** (`--one`): so the peak footprint (`TASK_VM_INFO.ledger_phys_footprint_peak`, what
//  `footprint` reads — not RSS, which cannot see the GPU's pages; `rfc020-measurement-traps`) is that request's, and
//  the first call in it is a launch's first (the model's load), timed apart from the warm call after it. The order of
//  photographs and requests turns each round (trap 17: this Mac drifts); the load average is printed with each round.

import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO

/// `RawProxy.fileName`'s word (`DevelopedPicture.swift`), which this driver never names a proxy with.
enum DevelopStamp { static let decoder = "decode.1" }

@main struct SubjectFind {
    static let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

    static func footprint() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    static func load() -> String {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? String(format: "%.2f %.2f %.2f", l[0], l[1], l[2]) : "?"
    }

    static func isRAW(_ url: URL) -> Bool { !["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains(url.pathExtension.lowercased()) }

    // MARK: pictures for a person

    static func png(_ image: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, image, nil)
        CGImageDestinationFinalize(d)
    }

    static func grey(_ p: FoundPicture) -> CGImage {
        CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: p.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: CGDataProvider(data: Data(p.bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The rendition with the mask (resampled to it) laid over in red at its coverage.
    static func over(_ source: CGImage, _ p: FoundPicture) -> CGImage {
        let w = source.width, h = source.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let m = Double(sample(p, s: (Double(x) + 0.5) / Double(w), t: (Double(y) + 0.5) / Double(h))) / 255 * 0.6
                let i = (y * w + x) * 4
                px[i] = UInt8(Double(px[i]) * (1 - m) + 255 * m)
                px[i + 1] = UInt8(Double(px[i + 1]) * (1 - m))
                px[i + 2] = UInt8(Double(px[i + 2]) * (1 - m))
            }
        }
        return ctx.makeImage()!
    }

    /// Bilinear between texel centres, clamped: `mask_found`'s rule, in double.
    static func sample(_ p: FoundPicture, s: Double, t: Double) -> Double {
        let x = min(max(s * Double(p.width) - 0.5, 0), Double(p.width - 1)), y = min(max(t * Double(p.height) - 0.5, 0), Double(p.height - 1))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, p.width - 1), y1 = min(y0 + 1, p.height - 1)
        let tx = x - Double(x0), ty = y - Double(y0)
        func v(_ a: Int, _ b: Int) -> Double { Double(p.bytes[b * p.width + a]) }
        let top = v(x0, y0) + (v(x1, y0) - v(x0, y0)) * tx, bot = v(x0, y1) + (v(x1, y1) - v(x0, y1)) * tx
        return top + (bot - top) * ty
    }

    static func thumb(_ source: CGImage, _ r: MaskRect) -> CGImage? {
        let crop = CGRect(x: r.x * Double(source.width), y: r.y * Double(source.height), width: r.width * Double(source.width),
                          height: r.height * Double(source.height)).integral
        guard let part = source.cropping(to: crop) else { return nil }
        let ctx = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 448, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: 112, height: 112))
        return ctx.makeImage()
    }

    // MARK: one request in its own process

    /// `--one <file> <subject|persons|people> <edge> <out dir|-> <raw out|->`: the rendition, the request twice (the
    /// launch's first, then warm), one JSON line.
    static func one(_ a: [String]) async throws {
        let url = URL(fileURLWithPath: a[0]), what = a[1], edge = Int(a[2])!, out = a[3] == "-" ? nil : URL(fileURLWithPath: a[3])
        let rawOut = a[4] == "-" ? nil : URL(fileURLWithPath: a[4])
        let base = footprint().now
        let finder = SubjectFinder(files: FoundMaskFiles(folder: nil), renditionLongEdge: edge)
        var source = FindSource(frame: UUID(), url: url, isRAW: isRAW(url), decode: DecodeSettings())
        source.decode.lensCorrection = false
        let t0 = Date()
        let (rendition, fingerprint) = try await finder.rendition(source)
        let tRend = Date().timeIntervalSince(t0)
        let afterRendition = footprint()
        var times: [Double] = [], pics: [[FoundPicture]] = [], boxes: [[MaskRect]] = []
        for _ in 0..<2 {
            let t = Date()
            switch what {
            case "subject":
                let r = try await finder.detector.subject(rendition)
                pics.append(r.map { [SubjectFinder.capped($0)] } ?? []); boxes.append([])
            case "persons":
                let ps = try await finder.detector.persons(rendition).map { SubjectFinder.capped($0) }
                let kept = ps.filter { SubjectFinder.box($0) != nil }
                pics.append(kept)
                boxes.append(kept.map { SubjectFinder.square(SubjectFinder.box($0)!, in: PixelSize(width: rendition.width, height: rendition.height)) })
            default:
                let p = try await finder.detector.people(rendition)
                pics.append(p.map { [SubjectFinder.capped($0)] } ?? []); boxes.append([])
            }
            times.append(Date().timeIntervalSince(t))
        }
        let fp = footprint()
        let same = pics[0].count == pics[1].count && zip(pics[0], pics[1]).allSatisfy { $0.bytes == $1.bytes }
        if let out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            if what == "subject" { png(rendition, out.appendingPathComponent("source.png")) }
            for (i, p) in pics[0].enumerated() {
                let name = what == "subject" ? "subject" : what == "persons" ? "person-\(i + 1)" : "people"
                png(grey(p), out.appendingPathComponent("\(name).png"))
                png(over(rendition, p), out.appendingPathComponent("\(name)-over.png"))
                if what == "persons", let t = thumb(rendition, boxes[0][i]) { png(t, out.appendingPathComponent("thumb-\(i + 1).png")) }
            }
        }
        if let rawOut, let p = pics[0].first {
            var d = Data()
            withUnsafeBytes(of: UInt32(p.width)) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(p.height)) { d.append(contentsOf: $0) }
            d.append(contentsOf: p.bytes)
            try d.write(to: rawOut)
        }
        let sizes = pics[0].map { "\($0.width)x\($0.height)" }.joined(separator: ",")
        // What each would take as a kept file (`FoundMaskFiles.encode`), and a name for the bytes, to hold the rounds'
        // processes to each other (a model loaded again, the same answer?).
        let kept = pics[0].map { p in FoundMaskFiles.encode(p, FoundMask(what: .subject, width: p.width, height: p.height))! }
        let fileKB = kept.map { Double($0.data.count) / 1024 }
        let maskNames = kept.map(\.asset).joined(separator: ",")
        let line: [String: Any] = ["rendition": "\(rendition.width)x\(rendition.height)", "renditionSec": tRend, "cold": times[0], "warm": times[1],
                                   "baseMB": base, "afterRenditionMB": afterRendition.now, "peakMB": fp.peak, "nowMB": fp.now,
                                   "count": pics[0].count, "sizes": sizes, "sameBytesTwice": same, "fingerprint": fingerprint,
                                   "fileKB": fileKB.max() ?? 0, "masks": maskNames]
        print(String(data: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
    }

    static func run(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["--one"] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
              let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        return j
    }

    static func median(_ v: [Double]) -> Double { v.isEmpty ? .nan : v.sorted()[v.count / 2] }

    // MARK: main

    static func main() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--one" { try await one(Array(args.dropFirst())); return }
        let sizes = args.first == "--sizes"
        if sizes { args.removeFirst() }
        let root = here.deletingLastPathComponent()   // build/
        let fixtures = root.appendingPathComponent("masks-check/fixtures"), found = root.appendingPathComponent("masks-check/found")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        var files: [URL] = []
        for a in args {
            let from = URL(fileURLWithPath: a), to = fixtures.appendingPathComponent(from.lastPathComponent)
            if !FileManager.default.fileExists(atPath: to.path) { try FileManager.default.copyItem(at: from, to: to) }
            files.append(to)
        }
        print("this Mac: \(ProcessInfo.processInfo.operatingSystemVersionString), \(ProcessInfo.processInfo.physicalMemory >> 30) GB, \(ProcessInfo.processInfo.activeProcessorCount) cores")
        if sizes { try sizeTable(files); return }
        let requests = ["subject", "persons", "people"]
        var rows: [String: [[String: Any]]] = [:]
        for round in 0..<3 {
            print("round \(round + 1), load \(load())")
            // Turn the order each round: photographs one way, requests the other.
            let fs = round % 2 == 0 ? files : files.reversed()
            for (i, f) in fs.enumerated() {
                let k = (i + round) % 3
                let rs: [String] = (0..<3).map { requests[(k + $0) % 3] }
                for r in rs {
                    let stem = f.deletingPathExtension().lastPathComponent
                    let out = round == 0 ? found.appendingPathComponent(stem).path : "-"
                    guard let j = run([f.path, r, "\(SubjectFinder.renditionLongEdge)", out, "-"]) else { print("  \(stem) \(r): failed"); continue }
                    rows["\(stem)|\(r)", default: []].append(j)
                }
            }
        }
        print("\n| photograph | request | rendition | returned | n | first call s | warm s | rendition s | peak footprint MB | file kB | same bytes twice | same bytes across rounds |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            for r in requests {
                guard let js = rows["\(stem)|\(r)"], let first = js.first else { continue }
                func d(_ k: String) -> [Double] { js.compactMap { $0[k] as? Double } }
                let across = Set(js.compactMap { $0["masks"] as? String }).count == 1 && Set(js.compactMap { $0["fingerprint"] as? String }).count == 1
                print(String(format: "| %@ | %@ | %@ | %@ | %d | %.3f | %.3f | %.3f | %.0f | %.0f | %@ | %@ |", stem, r, first["rendition"] as! String,
                             (first["sizes"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "none", first["count"] as? Int ?? 0,
                             median(d("cold")), median(d("warm")), median(d("renditionSec")), median(d("peakMB")), first["fileKB"] as? Double ?? 0,
                             (js.allSatisfy { ($0["sameBytesTwice"] as? Bool) == true } ? "yes" : "NO"), across ? "yes" : "NO"))
            }
        }
        print("\nmedians of 3 rounds; PNGs under \(found.path)")
    }

    /// The rendition's long edge: each edge's subject mask against 4096's, on 4096's grid (bilinear), and its cost.
    static func sizeTable(_ files: [URL]) throws {
        let edges = [1024, 1536, 2048, 3072, 4096]
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("subject-find-\(getpid())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        print("| photograph | request | edge | mask | mean abs diff vs 4096 | IoU@½ vs 4096 | first s | warm s | rendition s | peak MB |")
        print("|---|---|---|---|---|---|---|---|---|---|")
        func readRaw(_ u: URL) -> FoundPicture? {
            guard let d = try? Data(contentsOf: u), d.count > 8 else { return nil }
            let w = Int(d.subdata(in: 0..<4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            let h = Int(d.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            return FoundPicture(width: w, height: h, bytes: [UInt8](d.subdata(in: 8..<d.count)))
        }
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            for r in ["subject", "persons"] {
                var res: [Int: ([String: Any], FoundPicture?)] = [:]
                for e in edges.reversed() {
                    let raw = scratch.appendingPathComponent("\(stem)-\(r)-\(e).raw")
                    guard let j = run([f.path, r, "\(e)", "-", raw.path]) else { continue }
                    res[e] = (j, readRaw(raw))
                }
                guard let ref = res[4096]?.1 else { print("| \(stem) | \(r) | — | none found at 4096 | | | | | | |"); continue }
                for e in edges {
                    guard let (j, p) = res[e] else { continue }
                    var diff = 0.0, inter = 0, uni = 0
                    if let p {
                        // On a coarser grid of the reference's (every 4th texel): the masks are smooth at that scale.
                        var n = 0
                        for y in stride(from: 0, to: ref.height, by: 4) {
                            for x in stride(from: 0, to: ref.width, by: 4) {
                                let s = (Double(x) + 0.5) / Double(ref.width), t = (Double(y) + 0.5) / Double(ref.height)
                                let a = sample(p, s: s, t: t) / 255, b = Double(ref.bytes[y * ref.width + x]) / 255
                                diff += abs(a - b); n += 1
                                if a >= 0.5 && b >= 0.5 { inter += 1 }
                                if a >= 0.5 || b >= 0.5 { uni += 1 }
                            }
                        }
                        diff /= Double(max(n, 1))
                    }
                    print(String(format: "| %@ | %@ | %d | %@ | %.4f | %.4f | %.3f | %.3f | %.3f | %.0f |", stem, r, e, p.map { "\($0.width)x\($0.height)" } ?? "none",
                                 diff, uni > 0 ? Double(inter) / Double(uni) : 0, j["cold"] as? Double ?? 0, j["warm"] as? Double ?? 0,
                                 j["renditionSec"] as? Double ?? 0, j["peakMB"] as? Double ?? 0))
                }
            }
        }
    }
}
