// A layers.json entry for a Release capture: one 径向渐变 layer (场景, 曝光 +1) on the frame named, encoded by the app's
// own model types.
import Foundation
@main struct SeedLayers {
    static func main() throws {
        let frame = CommandLine.arguments[1]
        var layer = LocalLayer(name: "Gradient 1", stage: .scene, parts: [.radial(MaskRadial(centre: MaskPoint(0.5, 0.45), rx: 0.18, ry: 0.24))])
        layer.scene = SceneDeltas(exposure: 1)
        let layers = LocalLayers(items: [layer])
        let enc = JSONEncoder()
        let item = try JSONSerialization.jsonObject(with: enc.encode(layers))
        let record: [String: Any] = ["version": 1, "frames": [frame: item]]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: record))
    }
}
