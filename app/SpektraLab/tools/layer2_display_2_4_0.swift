//  layer2_display_2_4_0.swift — the 2.4.0 side of `tools/hdr_latch_selftest.sh --self-test`: `Layer2Live.display(maxPixel:)`
//  as 2.4.0 shipped it (one `displayPixel`, the last to say wins), with `Sources/Engine/Layer2DisplaySizes.swift`'s API.
//  Compiled in place of that file, never beside it.

struct Layer2DisplaySizes: Equatable {
    private var only: Int?
    var maxPixel: Int? { only }
    mutating func set(_ holder: String, maxPixel: Int?) { only = maxPixel }
    mutating func pin(_ maxPixel: Int?) { only = maxPixel }
    mutating func removeAll() { only = nil }
}
