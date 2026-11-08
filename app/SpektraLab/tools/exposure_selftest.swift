import Foundation
import SwiftUI

// Stock's display color is irrelevant to exposure; the app supplies this initializer in Theme.
extension Color { init(hexString: String) { self = .gray } }

@main
enum ExposureSelftest {
    static func main() throws {
        var failures: [String] = []
        func expect(_ value: Bool, _ label: String) { if !value { failures.append(label) } }
        expect(!FrameEdit.default.params.autoExposure, "new frames preserve source exposure instead of normalizing")
        var explicit = FilmParams.default
        AEMethod.metered(.balanced).apply(to: &explicit)
        expect(explicit.autoExposure && explicit.autoExposureMethod == "balanced", "Balanced remains an explicit normalization choice")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FrameEdit.default)) as! [String: Any]
        old["schemaVersion"] = 4
        var oldParams = old["params"] as! [String: Any]
        oldParams["autoExposure"] = true
        oldParams["autoExposureMethod"] = "balanced"
        old["params"] = oldParams
        var oldDecode = old["decode"] as! [String: Any]
        oldDecode.removeValue(forKey: "rawExposureTreatment")
        old["decode"] = oldDecode
        let read = try JSONDecoder().decode(FrameEdit.self, from: JSONSerialization.data(withJSONObject: old))
        expect(read.params.autoExposure && read.params.autoExposureMethod == "balanced", "old Balanced edits retain exposure behavior")
        expect(read.decode.rawExposureTreatment == .legacy, "old decoder treatment is explicitly legacy")
        expect(read.decode.pixelsKey == "As Shot", "legacy source key stays unchanged")
        let fresh = DecodeSettings()
        expect(fresh.rawExposureTreatment == .sourceReferencePlusOne && fresh.pixelsKey != read.decode.pixelsKey,
               "new RAW preparation has a separate canvas/export/card source key")
        var readback = fresh
        readback.temperature = 4700; readback.tint = 12
        expect(readback.pixelsKey == fresh.pixelsKey, "As Shot WB readback does not invalidate decoded source")
        readback.lensCorrection = true
        expect(readback.pixelsKey != fresh.pixelsKey, "actual pixel settings do invalidate the source")
        AEMethod.custom.apply(to: &explicit)
        expect(!explicit.autoExposure && explicit.autoExposureMethod == "balanced", "Source exposure keeps optional Balanced choice")
        expect(AEMethod.of(explicit).title == "Source exposure", "the no-AE default is clearly named")
        let roundTrip = try JSONDecoder().decode(FrameEdit.self, from: JSONEncoder().encode(read))
        expect(roundTrip == read, "legacy flags and decoder version round-trip unchanged")
        var nilMethod = oldParams; nilMethod.removeValue(forKey: "autoExposureMethod")
        old["params"] = nilMethod
        let nilRead = try JSONDecoder().decode(FrameEdit.self, from: JSONSerialization.data(withJSONObject: old))
        expect(nilRead.params.autoExposure && nilRead.params.autoExposureMethod == nil, "old center-weighted nil-method remains legacy")

        let sourceHole = HalfFramePair.Hole(path: "source.dng", frame: UUID(), sourceEdit: .default, sourceGeometry: .default)
        var pair = HalfFramePair()
        pair.left = sourceHole; pair.right = sourceHole
        expect(!sourceHole.autoExposure && !pair.startingLook(.default).params.autoExposure,
               "a new Source-only pair does not silently normalize either hole")
        var balancedEdit = FrameEdit.default
        AEMethod.metered(.balanced).apply(to: &balancedEdit.params)
        pair.right = HalfFramePair.Hole(path: "balanced.dng", frame: UUID(), sourceEdit: balancedEdit, sourceGeometry: .default)
        expect(pair.left?.autoExposure == false && pair.right?.autoExposure == true
               && pair.startingLook(.default).params.autoExposure,
               "a mixed new pair enables Balanced only for its chosen hole")
        let oldPair = try JSONDecoder().decode(HalfFramePair.self,
            from: Data(#"{"left":{"path":"old.dng","autoExposure":true},"right":{"path":"manual.dng","autoExposure":false}}"#.utf8))
        let savedPair = try JSONDecoder().decode(HalfFramePair.self, from: JSONEncoder().encode(oldPair))
        expect(savedPair == oldPair && savedPair.left?.autoExposure == true && savedPair.right?.autoExposure == false
               && savedPair.left?.decode.rawExposureTreatment == .legacy,
               "loaded pair keeps its saved mixed meter switches and legacy source")
        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("Exposure defaults and old Balanced compatibility passed")
    }
}
