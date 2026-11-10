//  hdr_selftest.swift — Enable HDR on the Mac (HDR port, 2026-11-06, PRD/HDR-PORT-PLAN-2026-11-06.md D3, D5, D6),
//  checked on this Mac without the app:
//
//  - **the per-frame state** (D5): `FrameEdit.hdrChoice` written only once chosen — an edit that never chose is
//    the same JSON, byte for byte, as before the field existed, whatever the default is — and `hdr` following
//    Settings' default until it is chosen;
//  - **a print's SDR picture is not moved by the switch** (D3) as far as the app's side can move it: the only
//    fields Enable HDR adds to a wire (`HDRGain.sdrWire`, which `FrameEdit.engineWire` merges) are none for a
//    print, a negative scanned, a frame with its film off — so its wire, its stamp and its develop are the
//    same; a slide's are the stretch and its one grain seed. (The develop itself, on the engine, is held to
//    the bit by `--develop-check`'s HDR steps, and the engine's own bypass by engine/tests/hdr_bypass_checks.py.)
//  - **a field the wire carries only sometimes goes back to its rest** (`FilmParams.step`, `sometimesSent`):
//    a slide's Enable HDR turned off sends the stretch off, not nothing;
//  - **Copy Settings' HDR group**: offered where a screen shows HDR, before the enlarger's, never ticked by
//    default, carrying the source's choice and nothing else;
//  - **the engine's answer** (`HDRSessionCurve.parse`) on a reply this Mac's engine gave for Portra 400 on
//    Portra Endura (tools/engine_replies/hdr_curve_reply.json), and its refusals of a reply that is not one;
//  - **the look** (`HDRLook.of`): only with the switch on, the film applied, a screen that shows HDR and a curve;
//    its weight (ISO 21496-1's, BaseHeadroom 0);
//  - **the kernels on this Mac's GPU** (`HDRRendition`, `hg_apply` / `hg_apply_pq`): at weight 0 the
//    picture is the SDR picture in linear light; on flat fields the gain is the Swift reference's
//    (`HDRRendition.reference`); below the knee nothing is lifted; the page's PQ picture says its headroom H^w.
//
//      tools/selftest.sh     (or alone: see the swiftc line there)

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
extension Color { init(hexString: String) { self = .gray } }

@main struct HDRSelftest {
    @MainActor static func main() throws {
        var passed = 0, failed = 0
        func expect(_ yes: Bool, _ name: String) {
            if yes { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let here = FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/StockCatalog.json").path)
            ? root : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let catalog = StockCatalog(contentsOf: here.appendingPathComponent("Resources/StockCatalog.json")) else {
            print("hdr checks: no catalogue at Resources/StockCatalog.json"); exit(1)
        }

        // MARK: the per-frame state (D5)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        func json(_ e: FrameEdit) -> String { String(data: try! encoder.encode(e), encoding: .utf8)! }
        func decoded(_ s: String) -> FrameEdit { try! JSONDecoder().decode(FrameEdit.self, from: Data(s.utf8)) }
        FrameEdit.hdrByDefault = false
        let never = FrameEdit()
        let before = json(never)
        expect(!before.contains("\"hdr\""), "an edit that never chose writes no hdr key")
        expect(decoded(before).hdrChoice == nil && !decoded(before).hdr, "an edit from before the field reads as never chosen, off")
        FrameEdit.hdrByDefault = true
        expect(never.hdr, "a frame that never chose follows Enable HDR by Default (on)")
        expect(json(never) == before, "and is the same JSON, byte for byte, whatever the default")
        var on = FrameEdit(); on.hdr = true
        var off = FrameEdit(); off.hdr = false
        expect(json(on).contains("\"hdr\":true") && decoded(json(on)).hdrChoice == true, "on is written and read back")
        expect(json(off).contains("\"hdr\":false") && decoded(json(off)).hdrChoice == false && !decoded(json(off)).hdr,
               "off, once chosen, is written and holds against a default that is on")
        expect(on != never && off != never, "a choice is a change of the edit")
        FrameEdit.hdrByDefault = false
        expect(!never.hdr && on.hdr, "the default off: the frame that chose on stays on")

        // MARK: a print's picture is not the switch's (D3), a slide's is
        func edit(film: String, paper: String? = nil, hdr: Bool?) -> FrameEdit {
            var e = FrameEdit()
            e.params.load(film: film, catalog: catalog)
            if let paper { e.params.printStock = paper }
            e.hdrChoice = hdr
            return e
        }
        let printed = edit(film: "kodak_portra_400", paper: "kodak_portra_endura", hdr: true)
        expect(!catalog.isSlide(printed.params.filmStock), "Portra 400 is a negative in the catalogue")
        expect(HDRGain.sdrWire(for: printed, catalog: catalog).isEmpty, "a print with Enable HDR on adds nothing to its wire")
        expect(!HDRGain.isSlide(printed, catalog: catalog), "and is no slide")
        var scanned = printed; scanned.params.scanFilm = true
        expect(HDRGain.sdrWire(for: scanned, catalog: catalog).isEmpty, "a negative scanned: nothing either (the curve's)")
        let slideID = catalog.films.first(where: \.isPositive)?.id ?? "fujifilm_provia_100f"
        let slideOn = edit(film: slideID, hdr: true), slideOff = edit(film: slideID, hdr: nil)
        let wire = HDRGain.sdrWire(for: slideOn, catalog: catalog)
        expect(wire["scan_hdr_stretch"] == .bool(true), "a slide with Enable HDR on is developed stretched (\(slideID))")
        expect(wire["grain_seed"] == .double(Double(HDRGain.grainSeed(slideOn))) && HDRGain.grainSeed(slideOn) >= 1,
               "with its one grain seed, never 0")
        expect(wire["scan_hdr_headroom"] == nil && wire["scan_hdr_output_scale"] == nil, "the SDR develop never carries the rendition's fields")
        expect(HDRGain.sdrWire(for: slideOff, catalog: catalog).isEmpty, "a slide with it off: today's wire")
        var slideFilmOff = slideOn; slideFilmOff.setAppliesFilm(false)
        expect(HDRGain.sdrWire(for: slideFilmOff, catalog: catalog).isEmpty, "a slide with its film off: nothing (no engine runs)")
        let r = HDRGain.rendition(for: slideOn, headroom: 4)
        expect(r.delta["scan_hdr_headroom"] == .double(4) && r.delta["scan_hdr_output_scale"] == .double(0.25)
               && r.delta["scan_hdr_stretch"] == .bool(false), "the second rendition: H 4, scaled 1/4, the stretch off")
        expect(r.restore["scan_hdr_headroom"] == .double(0) && r.restore["scan_hdr_output_scale"] == .double(1),
               "and the session put back to the SDR develop's after it")
        // An export's map (`HDRGain.export`): a slide's second rendition, unless Layer 2 edited it — then the curve's
        // over the edited picture, as its canvas draws (the 2026-11-06 review: the ratio lifted what the edit put down).
        let plainSlide = HDRGain.export(for: slideOn, format: .jpeg, catalog: catalog)
        var editedSlide = slideOn; editedSlide.adjustments.exposure = -2
        let edited = HDRGain.export(for: editedSlide, format: .jpeg, catalog: catalog)
        expect(plainSlide.map && plainSlide.slideHeadroom == 4, "a slide's export: a map of its second rendition at H 4")
        expect(editedSlide.adjustments.isActive && edited.map && edited.slideHeadroom == nil,
               "a slide edited in Layer 2: a map of its curve over the edited picture, no second rendition")
        let printedExport = HDRGain.export(for: printed, format: .heif, catalog: catalog)
        expect(printedExport.map && printedExport.slideHeadroom == nil && !HDRGain.export(for: printed, format: .png, catalog: catalog).map,
               "a print's: the curve's, JPEG and HEIF only")

        // MARK: a field the wire carries only sometimes goes back to its rest
        var applied: [String: ParamValue] = ["film_stock": .string(slideID), "scan_hdr_stretch": .bool(true), "grain_seed": .double(7)]
        let now: [String: ParamValue] = ["film_stock": .string(slideID)]
        let delta = FilmParams.step(from: &applied, to: now)
        expect(delta["scan_hdr_stretch"] == .bool(false) && delta["grain_seed"] == .double(0),
               "Enable HDR off a slide sends the stretch off and a fresh grain (\(delta))")
        expect(delta.count == 2, "and nothing else")
        expect(FilmParams.step(from: &applied, to: now).isEmpty, "and only once")
        var never2: [String: ParamValue] = ["film_stock": .string(slideID)]
        expect(FilmParams.step(from: &never2, to: now).isEmpty, "a session never told them is sent nothing")
        var stock: [String: ParamValue] = ["film_stock": .string(slideID), "scan_hdr_stretch": .bool(true), "grain_seed": .double(7)]
        let toNegative: [String: ParamValue] = ["film_stock": .string("kodak_portra_400"), "print_stock": .string("kodak_portra_endura")]
        let d2 = FilmParams.step(from: &stock, to: toNegative)
        expect(d2["scan_hdr_stretch"] == .bool(false) && d2["grain_seed"] == .double(0) && d2["film_stock"] != nil,
               "a stock change away from the slide sends them too, before applied is cut back")

        // MARK: Copy Settings' HDR group
        FeatureFlags.screenShowsHDR = true
        let offered = ClipboardGroup.offered
        if let h = offered.firstIndex(of: .hdr), let e = offered.firstIndex(of: .filmEdgeAndDateBack), let n = offered.firstIndex(of: .enlarger) {
            expect(e < h && h < n, "HDR is offered after the film edge and before the enlarger")
        } else { expect(false, "HDR, the film edge and the enlarger are all offered") }
        expect(offered.suffix(3) == [.light, .curve, .colour], "Edit's three stay last")
        expect(!ClipboardGroup.defaultSelection.contains(.hdr), "HDR is not ticked when the sheet opens")
        // PRD-B (2026-11-09): the group is 解码's 高动态范围, offered on every Mac (its controls greyed, not hidden).
        FeatureFlags.screenShowsHDR = false
        expect(ClipboardGroup.offered.contains(.hdr), "no screen shows HDR: the group is still offered (greyed controls, PRD-B)")
        FeatureFlags.screenShowsHDR = true
        expect(ClipboardGroup.hdr.summary(of: on) == "HDR 2.0 EV" && ClipboardGroup.hdr.summary(of: off) == "HDR off",
               "its line says the HDR and its peak, or HDR off: \(ClipboardGroup.hdr.summary(of: on))")
        var edrOn = off; edrOn.params.extendedDynamicRange = true; edrOn.hdrPeak = 3
        expect(ClipboardGroup.hdr.summary(of: edrOn).hasPrefix("EDR"), "and EDR first where the print keeps it")
        // The peak: written only once moved, read back, clamped; 2 stops (H 4) is today's.
        let plainJSON = (try? JSONEncoder().encode(FrameEdit())).map { String(decoding: $0, as: UTF8.self) } ?? ""
        expect(!plainJSON.contains("hdrPeak") && FrameEdit().hdrHeadroom == 4, "an edit that never moved the peak writes no hdrPeak, and its H is 4")
        var peaked = FrameEdit(); peaked.hdrPeak = 3
        let peakedBack = (try? JSONEncoder().encode(peaked)).flatMap { try? JSONDecoder().decode(FrameEdit.self, from: $0) }
        expect(peakedBack?.hdrPeakStops == 3 && peakedBack?.hdrHeadroom == 8, "a peak of 3 stops is kept and is H 8")
        peaked.hdrPeak = 2
        expect(peaked.hdrPeakStops == nil, "moved back to 2 stops, the edit is the default again")
        peaked.hdrPeak = 9
        expect(peaked.hdrPeak == FrameEdit.peakStopsRange.upperBound, "held to the range")
        expect(HDRSessionCurve.request(for: edrOn) == HDRSessionCurve.request(headroom: 8), "the curve is asked at the frame's own H")
        let pastedAll = SettingsClip(groups: [.hdr], settings: edrOn, sourceName: "x").applied(to: FrameEdit(), picture: PixelSize(width: 3, height: 2))
        expect(pastedAll.params.extendedDynamicRange && pastedAll.hdrPeakStops == 3, "the group carries EDR and the peak with the switch")
        let pairOnly = SettingsClip(groups: [.filmAndPaper], settings: edrOn, sourceName: "x").applied(to: FrameEdit(), picture: PixelSize(width: 3, height: 2))
        expect(!pairOnly.params.extendedDynamicRange && pairOnly.hdrPeakStops == nil, "Film & Paper no longer carries EDR")
        let target = FrameEdit()
        let pastedHDR = SettingsClip(groups: [.hdr], settings: on, sourceName: "x").applied(to: target, picture: PixelSize(width: 3, height: 2))
        expect(pastedHDR.hdrChoice == true, "pasting HDR carries the source's choice")
        let others = SettingsClip(groups: [.filmAndPaper, .filmExposure, .light], settings: on, sourceName: "x")
            .applied(to: target, picture: PixelSize(width: 3, height: 2))
        expect(others.hdrChoice == nil, "pasting anything else leaves the target's never-chosen alone")
        FrameEdit.hdrByDefault = true
        let followed = SettingsClip(groups: [.hdr], settings: never, sourceName: "x").applied(to: off, picture: PixelSize(width: 3, height: 2))
        expect(followed.hdrChoice == true, "a source that follows the default pastes what it shows")
        FrameEdit.hdrByDefault = false

        // MARK: the engine's answer
        let replyURL = here.appendingPathComponent("tools/engine_replies/hdr_curve_reply.json")
        let replyText = (try? String(contentsOf: replyURL, encoding: .utf8)) ?? ""
        expect(!replyText.isEmpty, "the engine's reply is kept (\(replyURL.path))")
        var session: HDRSessionCurve?
        do { session = try HDRSessionCurve.parse(replyText) } catch { expect(false, "the engine's reply parses: \(error)") }
        if let s = session {
            expect(s.curve.log2Gain.count == 256 && s.tables.ks.count == 256 && s.tables.slope.count == 256, "256 samples each")
            expect(abs(s.curve.headroom - 4) < 1e-12 && abs(s.tables.top - 2) < 1e-12, "H 4, top log2 H")
            expect(s.curve.log2Gain.first == 0 && abs((s.curve.log2Gain.last ?? 0) - 2) < 1e-12, "0 at the foot, log2 H at white")
            expect(zip(s.curve.log2Gain, s.curve.log2Gain.dropFirst()).allSatisfy { $1 >= $0 - 1e-12 }, "monotone")
            expect(s.tables.kappa == 1 && s.tables.rhoMax == 2 && s.tables.tau == 0.1, "κ 1, ρmax 2, τ 0.10)")
            expect(s.kneeEV.isFinite && s.kneeEV > 0 && !s.scan, "the knee is past mid-grey; a print, not a scan")
            expect((try? HDRSessionCurve.parse(replyText))?.curve.name == s.curve.name && s.curve.name.hasPrefix("session "),
                   "the same reply is the same look's name (\(s.curve.name))")
        }
        func refused(_ change: (inout [String: Any]) -> Void) -> Bool {
            guard var o = (try? JSONSerialization.jsonObject(with: Data(replyText.utf8))) as? [String: Any] else { return false }
            change(&o)
            let t = String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
            return (try? HDRSessionCurve.parse(t)) == nil
        }
        expect(refused { $0["top"] = 1.9 }, "a top that is not log2 H is refused")
        expect(refused { $0["log2_gain"] = Array(repeating: 0, count: 255) }, "255 samples are refused")
        expect(refused { var g = $0["log2_gain"] as! [Double]; g[100] = 3; $0["log2_gain"] = g }, "a gain over log2 H is refused")
        expect(refused { $0["ks"] = nil }, "no tables, no curve")
        expect((try? HDRSessionCurve.parse("not json")) == nil, "not JSON is refused")
        expect(HDRSessionCurve.request() == "{\"headroom\":4.000000}", "the request is H 4 and nothing else (no clip_ev this round)")
        expect(HDRSessionCurve.request(clipEV: 2.5).contains("\"clip_ev\":2.500000"), "the clip_ev hook writes the key when given")

        // MARK: the look
        guard let s = session else { print("hdr checks: \(passed) passed, \(failed + 1) failed"); exit(1) }
        let answer = HDRSessionCurve.Answer.curve(s)
        expect(HDRLook.of(on, answer) != nil, "the switch on, a curve, a screen that shows HDR: a look")
        expect(HDRLook.of(off, answer) == nil && HDRLook.of(never, answer) == nil, "off, or never chosen under an off default: none")
        expect(HDRLook.of(on, .refused("a Digital Intermediate")) == nil && HDRLook.of(on, nil) == nil, "refused, or not yet said: none")
        var onFilmOff = on; onFilmOff.setAppliesFilm(false)
        expect(HDRLook.of(onFilmOff, answer) == nil, "the film off: none")
        // The latch (`HDRLook.keeps`, the 2026-11-06 review): a curve one Couplers step on (its tables 0.01–0.03 stop
        // apart) is another look — the kernels make its rendition again — yet the last rendition stays on screen
        // meanwhile; with no look, or none made yet, nothing is held.
        var moved = s
        moved.curve.log2Gain = s.curve.log2Gain.enumerated().map { i, g in i > 0 && i < 255 ? min(g + 0.012 * Double(i) / 255, s.tables.top) : g }
        moved.curve.name = "session " + HDRSessionCurve.digest(moved.curve.log2Gain, s.tables.ks.map(Double.init), s.tables.slope.map(Double.init))
        let a = HDRLook(s), b = HDRLook(moved)
        expect(a != b, "a curve that moved with the edit is another look (\(a.curve.name) → \(b.curve.name))")
        expect(HDRLook.keeps(a, for: b), "and the rendition of the last one stays on screen until its own is made")
        expect(!HDRLook.keeps(nil, for: b) && !HDRLook.keeps(a, for: nil), "nothing made yet, or HDR gone: nothing held")
        FeatureFlags.screenShowsHDR = false
        expect(HDRLook.of(on, answer) == nil, "no screen shows HDR: none")
        FeatureFlags.screenShowsHDR = true
        expect(on.hdrAvailable(answer) && !on.hdrAvailable(.refused("x")) && !onFilmOff.hdrAvailable(answer), "the switch is greyed where it would do nothing")
        let look = HDRLook(s)
        expect(look.weight(headroom: 1) == 0 && abs(look.weight(headroom: 4) - 1) < 1e-12 && abs(look.weight(headroom: 2) - 0.5) < 1e-12
               && look.weight(headroom: 16) == 1, "the screen's share: log2 h / log2 H, held to 0 … 1")

        // MARK: the kernels on this Mac's GPU
        /// A picture of flat fields, 16-bit Display P3: `levels` columns, each a grey (or a colour) of its own.
        func fields(_ levels: [SIMD3<UInt16>], w: Int = 32, h: Int = 32) -> CGImage {
            let width = w * levels.count
            var px = [UInt16](repeating: 65535, count: width * h * 4)
            for y in 0..<h { for x in 0..<width { let c = levels[x / w]; let i = (y * width + x) * 4; px[i] = c.x; px[i + 1] = c.y; px[i + 2] = c.z } }
            let data = Data(bytes: px, count: px.count * 2) as CFData
            return CGImage(width: width, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                           space: CGColorSpace(name: CGColorSpace.displayP3)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                           provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        /// The linear half floats of a rendition, RGBA.
        func halves(_ img: CGImage) -> [Float] {
            guard let d = img.dataProvider?.data, let p = CFDataGetBytePtr(d) else { return [] }
            let n = img.width * img.height * 4
            return (0..<n).map { i in HDRMath.half(UInt16(p[2 * i]) | UInt16(p[2 * i + 1]) << 8) }
        }
        let greys: [UInt16] = [6000, 20000, 34000, 46000, 55000, 61000, 65535]
        let flat = fields(greys.map { SIMD3($0, $0, $0) } + [SIMD3(60000, 30000, 12000), SIMD3(15000, 50000, 62000)])
        do {
            let zero = halves(try HDRRendition.make(flat, look: look, weight: 0))
            var worst0 = 0.0
            for (k, g) in (greys.map { SIMD3($0, $0, $0) } + [SIMD3(60000, 30000, 12000), SIMD3(15000, 50000, 62000)]).enumerated() {
                let x = k * 32 + 16, y = 16, i = (y * flat.width + x) * 4
                let want = [g.x, g.y, g.z].map { HDRMath.decode(Double($0) / 65535) }
                for c in 0..<3 { worst0 = max(worst0, abs(Double(zero[i + c]) - want[c]) / max(want[c], 1e-3)) }
            }
            expect(worst0 < 2e-3, "weight 0 is the SDR picture in linear light (worst \(worst0), a half float's step)")
            let full = halves(try HDRRendition.make(flat, look: look, weight: 1))
            var worst1 = 0.0, lifted = 0, last = -1.0
            for (k, g) in greys.enumerated() {
                let x = k * 32 + 16, y = 16, i = (y * flat.width + x) * 4
                let u8 = UInt8((Double(g) / 65535 * 255).rounded())
                // The reference reads 8 bits; the kernel 16: compare against the 16-bit pixel's own gain.
                let lin = HDRMath.decode(Double(g) / 65535)
                let l2 = HDRGrainGain.l2y(HDRMath.luminance(lin, lin, lin))
                let want = lin * exp2(HDRGrainGain.log2Gain(l2y: l2, local: l2, tables: look.tables))
                worst1 = max(worst1, abs(Double(full[i]) - want) / want)
                if Double(full[i]) > lin * 1.01 { lifted += 1 }
                expect(Double(full[i]) >= last, "brighter in, brighter out (grey \(u8))")
                last = Double(full[i])
            }
            expect(worst1 < 3e-3, "on flat fields the gain is the Swift reference's (worst \(worst1))")
            expect(lifted >= 1 && lifted < greys.count, "the highlights are lifted and the mid-tones are not (\(lifted) of \(greys.count))")
            let dark = (0 * 32 + 16 + 16 * flat.width) * 4
            expect(abs(Double(full[dark]) - HDRMath.decode(6000.0 / 65535)) < 1e-4, "below the knee nothing is lifted")
            let top = (6 * 32 + 16 + 16 * flat.width) * 4
            expect(abs(Double(full[top]) - 4) < 0.05, "SDR white goes to H (\(full[top]))")
            let pq = try HDRRendition.make(flat, look: look, weight: 0.5, display: true)
            expect(pq.bitsPerComponent == 16 && pq.colorSpace.map(CGColorSpaceUsesITUR_2100TF) == true, "the page's picture is 16-bit, PQ")
            if #available(macOS 15.0, *) {
                expect(abs(Double(pq.contentHeadroom) - 2) < 1e-3, "and says its headroom, H^w = 4^0.5 (\(pq.contentHeadroom))")
            }
        } catch {
            expect(false, "the kernels ran: \(error)")
        }

        print("hdr checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
