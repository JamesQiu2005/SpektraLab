import Foundation
import SwiftUI
extension Color { init(hexString: String) { self = .gray } }

@main struct V2Selftest {
    @MainActor static func main() throws {
        var passed = 0, failed = 0
        func expect(_ yes: Bool, _ name: String) {
            if yes { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        let legacy = CommandLine.arguments.contains("--legacy")
        var source = FrameEdit(), target = FrameEdit()
        source.params.exposureCompensationEV = 2; source.params.printBrightnessStops = 1.5
        source.params.effects.grain = 1.6; source.params.effects.halation = 2
        source.params.antihalationRemoved = true
        source.params.effects.couplers = 0.4; source.params.effects.scatter = 0.3
        source.params.effects.glare = 5; source.params.preflashExposure = 0.02
        source.params.yFilterShift = 0.5; source.params.mFilterShift = -0.3
        source.decode.whiteBalance = .custom; source.decode.temperature = 7000; source.decode.tint = 30
        source.decode.lensCorrection = true
        source.geometry.angle = 2
        source.adjustments.exposure = 1; source.adjustments.temperature = 10
        source.adjustments.colorBalance.master.hue = 20; source.adjustments.colorBalance.master.saturation = 0.4
        source.adjustments.curves.red.insert(CGPoint(x: 0.4, y: 0.5))
        source.params.contrastMask.active = true
        source.params.sceneLatitude.highlightPullBack = 1
        source.frameSeed = 998; source.solvedEV = 4
        source.filmEdge.active = true; source.dateBack.active = true
        target.params.printBrightnessStops = -1
        target.params.effects.couplers = 0.8; target.frameSeed = 333
        target.decode.temperature = 4500; target.decode.tint = -12
        target.decode.lensCorrection = false
        target.geometry.angle = 3; target.solvedEV = -2
        func paste(_ groups: Set<ClipboardGroup>) -> FrameEdit { SettingsClip(groups: groups, settings: source, sourceName: "/private/source.dng").applied(to: target, picture: PixelSize(width: 6000, height: 4000)) }
        let exposure = paste([legacy ? .exposure : .filmExposure])
        expect(exposure.params.exposureCompensationEV == 2, "film exposure travels")
        expect(exposure.params.printBrightnessStops == target.params.printBrightnessStops, "film exposure excludes enlarger brightness")
        let format = paste([legacy ? .filmEffects : .format])
        expect(format.params.effects.grain == 1.6 && format.params.effects.halation == 2, "format owns grain/halation")
        expect(format.params.antihalationRemoved, "Format transfers the independent backing-layer state")
        expect(!source.resetting(.format).params.antihalationRemoved, "Format reset restores the backing layer")
        expect(paste([.light]).params.antihalationRemoved == target.params.antihalationRemoved, "Light cannot change the backing layer")
        var oldParams = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source.params)) as! [String: Any]
        oldParams.removeValue(forKey: "antihalationRemoved")
        let migrated = try JSONDecoder().decode(FilmParams.self, from: JSONSerialization.data(withJSONObject: oldParams))
        expect(!migrated.antihalationRemoved, "old saved parameters retain their own backing layer")
        let removal = source.params.wire.first { $0.name == "antihalation_removed" }
        expect(removal?.value == .bool(true) && removal?.layer == .shoot, "backing-layer change is an independent shoot wire field")
        expect(format.params.effects.couplers == target.params.effects.couplers, "format excludes couplers")
        expect(format.params.effects.glare == target.params.effects.glare && format.params.effects.scatter == target.params.effects.scatter, "format excludes hidden effects")
        let decode = paste([.decode])
        expect(decode.decode.temperature == 7000 && decode.decode.tint == 30, "custom decode travels")
        expect(decode.decode.lensCorrection == target.decode.lensCorrection && decode.geometry == target.geometry, "decode excludes lens and crop")
        source.decode.whiteBalance = .asShot
        let asShot = paste([.decode])
        expect(asShot.decode.temperature == 4500 && asShot.decode.tint == -12, "As Shot preserves target camera numbers")
        let enlarge = paste([.enlarger])
        expect(enlarge.params.printBrightnessStops == 1.5 && enlarge.params.exposureCompensationEV == 0, "enlarger excludes film exposure")
        let light = paste([.light])
        expect(light.params == target.params && light.decode == target.decode && light.geometry == target.geometry, "Layer 2-only apply has no engine fields")
        expect(light.adjustments.temperature == target.adjustments.temperature, "Light excludes Colour")
        var enlargerReset = source
        if legacy { enlargerReset.resetDevelop() } else { enlargerReset = source.resetting(.enlarger) }
        expect(enlargerReset.params.printBrightnessStops == 0, "Enlarger reset clears brightness")
        expect(enlargerReset.params.exposureCompensationEV == source.params.exposureCompensationEV && enlargerReset.geometry == source.geometry,
               "Enlarger reset excludes film exposure and crop; old broad reset fails")
        let formatReset = source.resetting(.format)
        expect(formatReset.filmEdge == source.filmEdge && formatReset.dateBack == source.dateBack && formatReset.geometry == source.geometry, "Format reset preserves nested edge/date and crop")
        expect(formatReset.params.effects.couplers == source.params.effects.couplers && formatReset.params.effects.glare == source.params.effects.glare, "Format reset preserves hidden effects and couplers")
        let lightReset = source.resetting(.light)
        expect(lightReset.adjustments.isNeutral(.light) && lightReset.adjustments.curves == source.adjustments.curves && lightReset.adjustments.colorBalance == source.adjustments.colorBalance, "Light reset excludes Curve/Colour/Master")
        expect(source.resetting(.decode).decode.whiteBalance == .asShot, "decode resets to source As Shot")
        expect(source.resetting(.preflash).params.effects == source.params.effects, "preflash reset preserves every effect")
        expect(source.resetting(.couplers).params.effects.scatter == source.params.effects.scatter, "coupler reset excludes scatter")
        // Edit › EngineRouter's Effects tile (2026-10-22): every effect back to the film's own, and nothing else.
        var effectsMoved = source
        effectsMoved.params.effects.grain = 1.7; effectsMoved.params.effects.grainLayered = false
        effectsMoved.params.effects.halation = 2.5; effectsMoved.params.effects.scatter = 0.4
        effectsMoved.params.effects.glare = 12; effectsMoved.params.effects.couplers = 0.5
        let effectsReset = effectsMoved.resetting(.effects)
        expect(effectsReset.params.effects == FilmParams.default.effects, "Effects reset puts back every effect")
        var effectsOnly = effectsReset; effectsOnly.params.effects = effectsMoved.params.effects
        expect(effectsOnly == effectsMoved, "Effects reset leaves everything but the effects")
        expect(source.resetting(.crop).filmEdge == source.filmEdge && source.resetting(.crop).adjustments == source.adjustments, "crop reset preserves edge and grade")
        expect(source.resetting(.dateBack).filmEdge == source.filmEdge, "Date Back reset excludes edge")
        for scope in PageResetScope.allCases {
            let reset = source.resetting(scope)
            expect(reset.resetting(scope) == reset, "\(scope) reset is idempotent")
            expect(reset.frameSeed == source.frameSeed && reset.decoder == source.decoder, "\(scope) reset preserves identity")
        }
        let plot = CGSize(width: 360, height: 160)
        var pointCurve = Curve.identity
        pointCurve.insert(CGPoint(x: 0.5, y: 0.5))
        expect(pointCurve.fingerIndex(near: CGPoint(x: 0.5 + 21 / 360, y: 0.5), in: plot) == 1, "point hit at 21 pt")
        expect(pointCurve.fingerIndex(near: CGPoint(x: 0.5 + 30 / 360, y: 0.5), in: plot) == nil, "wide plot does not stretch hit tolerance")
        expect(pointCurve.fingerIndex(near: CGPoint(x: 0.5, y: 0.5 + 21 / 160), in: plot) == 1, "same vertical hit radius")
        let canonical: Set<ClipboardGroup> = [.filmAndPaper, .filmExposure, .format, .enlarger, .scenePlacement, .decode, .couplers, .preflash, .light, .curve, .colour]
        let clean = SettingsClip(groups: canonical, settings: source, sourceName: "/private/source.dng").transferable
        expect(clean.settings.frameSeed == FrameEdit.default.frameSeed && clean.settings.solvedEV == nil && clean.settings.geometry.isIdentity, "preset excludes seed/solve/crop")
        expect(clean.sourceName.isEmpty && !clean.settings.decode.lensCorrection, "preset excludes source name and lens")
        expect(!ClipboardGroup.defaultSelection.contains(.filmEdgeAndDateBack), "edge/date opt-in")
        expect(!ClipboardGroup.offered.contains(.exposure) && !ClipboardGroup.offered.contains(.filmEffects), "new UI omits aggregate legacy groups")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spk-presets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("looks.json")
        let store = PresetStore(url: url)
        expect(store.save(name: "First", clip: clean), "atomic first save")
        expect(!store.save(name: "first", clip: clean), "duplicate name rejected")
        expect(store.presets.count == 1, "collision preserves record")
        let loaded = PresetStore(url: url)
        expect(loaded.presets == store.presets, "restart reads identical preset")
        let id = loaded.presets[0].id
        expect(loaded.rename(id, to: "Renamed"), "rename preserves stable ID")
        loaded.delete(id); expect(loaded.presets.isEmpty && loaded.canRestore, "delete has local recovery")
        loaded.restoreDeleted(); expect(loaded.presets.first?.id == id, "undo delete restores identity")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        raw["future"] = "retained"
        var records = raw["presets"] as! [[String: Any]]
        records[0]["futureField"] = 42; raw["presets"] = records
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        let withExtra = PresetStore(url: url)
        expect(withExtra.rename(id, to: "Extra"), "known store with unknown fields remains editable")
        withExtra.delete(id); withExtra.restoreDeleted()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        expect(after["future"] as? String == "retained" && (after["presets"] as? [[String: Any]])?.first?["futureField"] as? Int == 42, "unknown JSON fields survive writes")
        let blocked = folder.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let failedWrite = PresetStore(url: blocked.appendingPathComponent("looks.json"))
        expect(!failedWrite.save(name: "fail", clip: clean) && failedWrite.presets.isEmpty, "failed atomic write does not publish a record")
        expect(try Data(contentsOf: blocked) == Data("keep".utf8), "failed write leaves existing data intact")
        let bad = Data("{broken".utf8); try bad.write(to: url)
        let broken = PresetStore(url: url)
        expect(!broken.canWrite && !broken.save(name: "bad", clip: clean), "corrupt store refuses writes")
        expect(try Data(contentsOf: url) == bad, "corruption is never overwritten")
        raw["version"] = 999; let future = try JSONSerialization.data(withJSONObject: raw); try future.write(to: url)
        let unknown = PresetStore(url: url)
        expect(!unknown.canWrite && !unknown.save(name: "future", clip: clean), "unknown version refuses writes")
        expect(try Data(contentsOf: url) == future, "future version remains intact")
        print("V2: \(passed) passed, \(failed) failed; legacy=\(legacy)")
        exit(failed == 0 ? 0 : 1)
    }
}
