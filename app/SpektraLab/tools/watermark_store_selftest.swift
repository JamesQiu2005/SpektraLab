//  watermark_store_selftest.swift — the watermark library (`Services/WatermarkStore.swift`), checked on this Mac, with
//  three rules beside the PNG check: the same bytes twice are one mark, a file past 50 MB is refused from its header, and no folder is made for a library that
//  never had a mark.
//
//      python3 tools/gate.py selftest --only watermark_store_selftest   # the checks, then their own check
//
//  PRD-8 §8's first line and RFC-067 §6: the PNG check refuses a JPEG renamed .png, an RGB PNG, an
//  all-opaque RGBA PNG and a 9000 px PNG, and takes an RGBA PNG with transparency. Then what the library
//  keeps: the file as given, its index (and the index rebuilt from the folder when it cannot be read),
//  newest first, rename, delete, the thumbnail, and the renderers' bitmap (sRGB, premultiplied, resampled
//  to the width asked for, nothing for a deleted mark).
//
//  The fixtures are drawn here, not committed: small pictures made with CoreGraphics and written with
//  ImageIO, the 9000 px one 9000 × 60.
//
//  AGENTS.md: a check that cannot fire is not a check. `--self-test` runs the same checks with one rule
//  broken at a time and requires each run to fail.

import CoreGraphics
import Foundation
import ImageIO

/// The rules under test, so a broken one can be put in their place.
struct Rules {
    var name = "the app's"
    var validate: (Data) -> Result<WatermarkStore.Checked, WatermarkRefusal> = { WatermarkStore.validate($0) }
    /// Whether an add of bytes the library has names the mark that has them.
    var dedupes = true

    static var broken: [Rules] {
        [
            Rules(name: "the extension trusted, not the signature", validate: { data in
                let r = WatermarkStore.validate(data)
                if case .failure(.notPNG) = r { return .success(.init(w: 1, h: 1)) }
                return r
            }),
            Rules(name: "no look at the alpha channel", validate: { data in
                let r = WatermarkStore.validate(data)
                if case .failure(.noAlphaChannel) = r { return .success(.init(w: 1, h: 1)) }
                return r
            }),
            Rules(name: "an alpha channel taken as transparency", validate: { data in
                let r = WatermarkStore.validate(data)
                if case .failure(.allOpaque) = r { return .success(.init(w: 1, h: 1)) }
                return r
            }),
            Rules(name: "no size limit", validate: { data in
                let r = WatermarkStore.validate(data)
                if case .failure(.tooLarge) = r { return .success(.init(w: 1, h: 1)) }
                return r
            }),
            Rules(name: "the same bytes kept twice", dedupes: false),
        ]
    }
}

// MARK: - fixtures

enum Fixture {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A picture `w` × `h`: a white bar on a ground that is clear (`transparent`), black (opaque RGBA) or
    /// black with no alpha channel (`alpha` false).
    static func picture(_ w: Int, _ h: Int, alpha: Bool, transparent: Bool) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: info)!
        if !transparent {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: max(1, w / 2), height: max(1, h / 2)))
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage, as type: String, options: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }

    static var jpeg: Data { encode(picture(64, 32, alpha: false, transparent: false), as: "public.jpeg") }
    static var rgbPNG: Data { encode(picture(64, 32, alpha: false, transparent: false), as: "public.png") }
    static var opaqueRGBA: Data { encode(picture(64, 32, alpha: true, transparent: false), as: "public.png") }
    static var clearRGBA: Data { encode(picture(120, 40, alpha: true, transparent: true), as: "public.png") }
    static var big: Data { encode(picture(9000, 60, alpha: true, transparent: true), as: "public.png") }
    /// A mark 600 px wide: its thumbnail is resampled to 256.
    static var wide: Data { encode(picture(600, 200, alpha: true, transparent: true), as: "public.png") }
}

// MARK: - the checks

@MainActor
func run(_ rules: Rules, quiet: Bool) -> (passed: Int, failed: [String]) {
    var passed = 0
    var failed: [String] = []
    func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed.append(what); if !quiet { print("  FAIL  \(what)") } }
    }
    func refused(_ data: Data, _ want: WatermarkRefusal) -> Bool {
        if case .failure(let r) = rules.validate(data) { return r == want }
        return false
    }
    func isTooLarge(_ data: Data) -> Bool {
        if case .failure(.tooLarge(let side, _)) = rules.validate(data) { return side == 9000 }
        return false
    }

    // The four refusals, in RFC-067 §2's order, and the one accept.
    let jpeg = Fixture.jpeg
    expect(jpeg.prefix(2) == Data([0xFF, 0xD8]), "the JPEG fixture is a JPEG")
    expect(refused(jpeg, .notPNG), "a JPEG renamed .png is refused as not a PNG (the content, not the name)")
    expect(refused(Data("not a picture".utf8), .notPNG), "text is refused as not a PNG")
    expect(refused(Data(WatermarkStore.pngSignature + [0, 0, 0, 0]), .unreadable), "a PNG's signature over nothing is refused unread")
    expect(refused(Fixture.rgbPNG, .noAlphaChannel), "an RGB PNG is refused: no alpha channel")
    expect(refused(Fixture.opaqueRGBA, .allOpaque), "an RGBA PNG with every pixel opaque is refused")
    if case .success(let c) = rules.validate(Fixture.clearRGBA) {
        expect(c.w == 120 && c.h == 40, "an RGBA PNG with transparency is taken, at its size (\(c.w) × \(c.h))")
    } else {
        expect(false, "an RGBA PNG with transparency is taken")
    }
    expect(isTooLarge(Fixture.big), "a 9000 px PNG is refused for its size, which the refusal carries")
    // The messages (`s6`): the rule, and for an opaque picture the second line.
    expect(WatermarkRefusal.notPNG.message == "Only a PNG with a transparent background.", "a non-PNG's message is the rule alone")
    expect(WatermarkRefusal.allOpaque.message == "Only a PNG with a transparent background.\nThis image has no transparent area.",
           "an opaque PNG's message says it has no transparent part")
    expect(WatermarkRefusal.tooLarge(longSide: 9000, bytes: 1).message.contains("9,000"), "the size refusal says the size")

    // The library on disk.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wm-selftest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Watermarks"), caches = root.appendingPathComponent("Caches")
    let store = WatermarkStore(folder: folder, caches: caches)
    expect(store.marks.isEmpty, "a new library is empty")
    expect(!FileManager.default.fileExists(atPath: folder.path), "a library that never had a mark makes no folder")
    if case .failure(.allOpaque) = store.addNow(Fixture.opaqueRGBA, name: "opaque") {} else { expect(false, "the store refuses what the check refuses") }
    expect(store.marks.isEmpty, "a refused picture leaves nothing")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let clear = Fixture.clearRGBA
    guard case .success(.new(let first)) = store.addNow(clear, name: "  签名 ", added: t0),
          case .success(.new(let second)) = store.addNow(Fixture.wide, name: nil, added: t0.addingTimeInterval(60)) else {
        expect(false, "two marks are kept")
        return (passed, failed)
    }
    expect(first.name == "签名", "a name is kept trimmed")
    expect(second.name == "Watermark 2", "no name: Watermark N (\(second.name))")
    expect(store.marks.map(\.id) == [second.id, first.id], "newest first")
    expect((try? Data(contentsOf: store.fileURL(first.id))) == clear, "the user's bytes are kept as given")
    expect(first.sha256 == WatermarkStore.sha256(clear) && first.sha256.count == 64, "the file's SHA-256 is in the index")
    expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("index.json").path), "index.json is written")
    expect(FileManager.default.fileExists(atPath: store.thumbnailURL(second.id).path), "the thumbnail is in the caches")
    if let thumb = store.thumbnails[second.id] {
        expect(thumb.width == 256 && thumb.height == 85, "a 600 px mark's thumbnail is 256 px on its long side (\(thumb.width) × \(thumb.height))")
    } else { expect(false, "the thumbnail is held") }

    // The same bytes again (never a second copy): the mark that has them, nothing new kept.
    let before = store.marks
    let twice: Result<WatermarkAdded, WatermarkRefusal> = rules.dedupes ? store.addNow(clear, name: "again")
        : { let id = UUID(); _ = try? clear.write(to: store.fileURL(id)); return .success(.new(WatermarkMark(id: id, name: "again", added: Date(), w: 1, h: 1, sha256: ""))) }()
    if case .success(.existing(let m)) = twice { expect(m.id == first.id, "the same bytes added again name the mark that has them") }
    else { expect(false, "the same bytes added again are not a second mark") }
    expect(store.marks == before, "and the library is as it was")
    let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".png") }
    expect(pngs.count == 2, "and no second file is kept (\(pngs.count) PNGs)")
    if !rules.dedupes { for p in pngs where p != first.id.uuidString + ".png" && p != second.id.uuidString + ".png" { try? FileManager.default.removeItem(at: folder.appendingPathComponent(p)) } }

    // A file past the limit is refused from its first bytes and its header, not read whole.
    let huge = root.appendingPathComponent("huge.png")
    var big = Fixture.clearRGBA
    big.append(Data(count: WatermarkStore.maxBytes + 1 - big.count + 16))
    try? big.write(to: huge)
    if case .failure(.tooLarge(let side, let bytes)) = WatermarkStore.read(huge) {
        expect(side == 120 && bytes > WatermarkStore.maxBytes, "a 50 MB+ PNG is refused as too large, its size said (\(side) px, \(bytes) B)")
    } else { expect(false, "a 50 MB+ PNG is refused before it is read whole") }
    var bigJPEG = Fixture.jpeg
    bigJPEG.append(Data(count: WatermarkStore.maxBytes + 1))
    try? bigJPEG.write(to: huge)
    var jpegRefused = false
    if case .failure(.notPNG) = WatermarkStore.read(huge) { jpegRefused = true }
    expect(jpegRefused, "a 50 MB+ JPEG is refused as not a PNG, unread")
    try? FileManager.default.removeItem(at: huge)
    let small = root.appendingPathComponent("small.png")
    try? clear.write(to: small)
    if case .success(let d) = WatermarkStore.read(small) { expect(d == clear, "a file within the limit is read whole") } else { expect(false, "a small PNG is read") }

    // The renderers' read.
    if let full = store.bitmap(first.id) {
        expect(full.width == 120 && full.height == 40, "the bitmap as stored is the PNG's size")
        expect(full.alphaInfo == .premultipliedLast && full.bitsPerComponent == 8, "premultiplied 8-bit RGBA")
        expect(full.colorSpace?.name == CGColorSpace.sRGB, "in sRGB")
    } else { expect(false, "the bitmap is read") }
    if let half = store.bitmap(second.id, width: 300) {
        expect(half.width == 300 && half.height == 100, "resampled to the width asked for, the aspect kept (\(half.width) × \(half.height))")
        expect(store.bitmap(second.id, width: 300) === half, "and cached by (id, sha256, width)")
    } else { expect(false, "the resampled bitmap is read") }

    // Rename.
    store.rename(first.id, to: "   ")
    expect(store.mark(first.id)?.name == "签名", "a blank name keeps the old one")
    store.rename(first.id, to: "工作室")
    expect(store.mark(first.id)?.name == "工作室", "rename")
    let again = WatermarkStore(folder: folder, caches: caches)
    expect(again.marks == store.marks, "the index read back is the library, renamed")

    // The index rebuilt from the folder.
    try? Data("{ not json".utf8).write(to: folder.appendingPathComponent("index.json"))
    let rebuilt = WatermarkStore(folder: folder, caches: caches)
    expect(Set(rebuilt.marks.map(\.id)) == [first.id, second.id], "an unreadable index is rebuilt from the files")
    expect(rebuilt.marks.first { $0.id == second.id }.map { $0.w == 600 && $0.h == 200 && $0.sha256 == second.sha256 } ?? false,
           "a rebuilt entry has the file's size and hash")
    let reread = (try? Data(contentsOf: folder.appendingPathComponent("index.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
    expect(reread?.count == 2, "and the rebuilt index is written")

    // The names the model reads, from any thread.
    expect(rebuilt.namesNow.exists(first.id) && !rebuilt.namesNow.exists(UUID()), "the library's names say which marks it has")

    // Delete.
    rebuilt.delete(first.id)
    expect(rebuilt.marks.map(\.id) == [second.id], "delete takes the entry")
    expect(!FileManager.default.fileExists(atPath: rebuilt.fileURL(first.id).path), "and the file")
    expect(!FileManager.default.fileExists(atPath: rebuilt.thumbnailURL(first.id).path), "and the thumbnail")
    expect(rebuilt.bitmap(first.id) == nil, "a deleted mark gives a renderer nothing")
    expect(WatermarkStore(folder: folder, caches: caches).marks.map(\.id) == [second.id], "and stays deleted")

    // An entry whose file is gone is dropped.
    try? FileManager.default.removeItem(at: rebuilt.fileURL(second.id))
    expect(WatermarkStore(folder: folder, caches: caches).marks.isEmpty, "an entry with no file is dropped")

    return (passed, failed)
}

@main
enum WatermarkStoreSelfTest {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            var caught = 0
            let all = Rules.broken
            for broken in all {
                let r = run(broken, quiet: true)
                if r.failed.isEmpty {
                    print("  NOT CAUGHT  \(broken.name)")
                } else {
                    caught += 1
                    print("  caught  \(broken.name) (\(r.failed.count) checks failed)")
                }
            }
            print("watermark store checks' own check: \(caught) of \(all.count) broken rules caught")
            exit(caught == all.count ? 0 : 1)
        }
        let r = run(Rules(), quiet: false)
        print("watermark store checks: \(r.passed) passed, \(r.failed.count) failed")
        exit(r.failed.isEmpty ? 0 : 1)
    }
}
