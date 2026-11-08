import Foundation

@main struct StripSourceSelftest {
    static func main() {
        let source = StripSource(), pixels = NSObject()
        var passed = 0
        func expect(_ ok: Bool, _ name: String) {
            guard ok else { print("FAIL: \(name)"); exit(1) }
            passed += 1
        }
        let first = source.generation
        expect(source.keep(pixels, for: "frame", bytes: 16, expectedGeneration: first), "current-generation pixels are admitted")
        expect(source.holds("frame") && source.bytes == 16, "the cache retains the admitted pixels")
        source.drop()
        expect(!source.keep(pixels, for: "frame", bytes: 16, expectedGeneration: first), "a decode started before trimming cannot refill the cache")
        expect(source.bytes == 0 && !source.holds("frame"), "stale completion leaves the trimmed cache empty")
        expect(source.keep(pixels, for: "new", bytes: 16, expectedGeneration: source.generation), "the next foreground generation can refill it")
        expect(source.take("frame") == nil && source.take("new") === pixels, "a different source cannot take those pixels")
        print("Strip source: \(passed) passed, 0 failed")
    }
}
