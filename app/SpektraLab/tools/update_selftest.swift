// update_selftest.swift -- Check for Updates' own arithmetic (Services/UpdateCheck.swift): which release is
// newer, and what a manifest must hold. No network: the manifest is the one the website publishes, here.
import Foundation

@main
struct UpdateSelfTest {
    @MainActor static func main() {
        var passed = 0, failed = 0
        func expect(_ ok: Bool, _ what: String) { if ok { passed += 1 } else { failed += 1; print("  FAIL  \(what)") } }
        func r(_ v: String, _ b: String? = nil) -> UpdateCheck.Release {
            .init(version: v, build: b, url: URL(string: "https://example.invalid/x.dmg")!, notes: nil, sha256: nil)
        }
        expect(UpdateCheck.isNewer(r("2.2.1"), than: "2.2.0", build: "1"), "2.2.1 is newer than 2.2.0")
        expect(!UpdateCheck.isNewer(r("2.2.0"), than: "2.2.0", build: "1"), "the same version is not newer")
        expect(!UpdateCheck.isNewer(r("2.1.9"), than: "2.2.0", build: "1"), "an older one is not newer")
        expect(UpdateCheck.isNewer(r("2.10.0"), than: "2.9.9", build: "1"), "compared number by number, not as text")
        expect(UpdateCheck.isNewer(r("3"), than: "2.9.9", build: "1"), "a missing part is 0")
        expect(UpdateCheck.isNewer(r("2.2.0", "202611090000"), than: "2.2.0", build: "202611082150"), "the same version, a later build")
        expect(!UpdateCheck.isNewer(r("2.2.0", "1"), than: "2.2.0", build: "202611082150"), "the same version, an earlier build")
        let manifest = #"{"version":"2.2.1","build":"202611090000","url":"https://github.com/JamesQiu2005/SpektraLab/releases/download/spektralab-v2.2.1/SpektraLab-2.2.1-universal.dmg","notes":"https://github.com/JamesQiu2005/SpektraLab/releases/tag/spektralab-v2.2.1","sha256":"00","minimum_macos":"15.0"}"#
        let parsed = try? UpdateCheck.parse(Data(manifest.utf8))
        expect(parsed?.version == "2.2.1" && parsed?.notes != nil && parsed?.url.lastPathComponent == "SpektraLab-2.2.1-universal.dmg",
               "the website's manifest reads")
        expect((try? UpdateCheck.parse(Data(#"{"version":"2.2.1","url":"http://insecure.example/x.dmg"}"#.utf8))) == nil,
               "a download that is not https is refused")
        expect((try? UpdateCheck.parse(Data(#"{"url":"https://a.example/x.dmg"}"#.utf8))) == nil, "a manifest with no version is refused")
        print("update checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
