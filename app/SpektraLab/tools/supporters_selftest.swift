// supporters_selftest.swift -- Settings › General › About › Supporters (Sources/Model/Supporters.swift):
// the shipped Resources/Supporters.json decodes, and the page lists every entry of it with its note, in
// the file's order; then the same of a fixture of three made here (one with no note, one with a long note
// of several lines, one in Chinese), which never goes into the shipped file. Compiled and run by
// tools/selftest.sh; `--self-test` breaks the page's listing and fails unless the check notices.
import Foundation

@main
struct SupportersSelfTest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1; print("FAILED  \(what)") }
    }

    /// The page lists `supporters` in order, each name and note as written; a note of nothing is no note.
    static func lists(_ page: SupportersPage, _ supporters: [Supporter], _ what: String) {
        expect(page.entries.count == supporters.count, "\(what): \(page.entries.count) entries for \(supporters.count) supporters")
        for (i, (entry, s)) in zip(page.entries, supporters).enumerated() {
            expect(entry.name == s.name, "\(what) #\(i): the name is \(entry.name), not \(s.name)")
            let note = s.note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            expect(entry.note == note, "\(what) #\(i) (\(s.name)): the note is \(entry.note ?? "none"), not \(note ?? "none")")
        }
        expect(Set(page.entries.map(\.id)).count == page.entries.count, "\(what): every entry has its own id")
    }

    static func main() {
        let breaking = CommandLine.arguments.contains("--self-test")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

        // The shipped file: it decodes (the app's `try?` would list nobody, silently), and the page lists it.
        let url = root.appendingPathComponent("Resources/Supporters.json")
        do {
            let shipped = try Supporter.decode(Data(contentsOf: url))
            lists(SupportersPage(shipped), shipped, "Resources/Supporters.json")
            print("supporters: the shipped file lists \(shipped.count)")
        } catch {
            expect(false, "Resources/Supporters.json does not decode: \(error)")
        }

        // Three made here: no note, a long note of several lines, a name and a note in Chinese.
        let long = "I shot Portra for twenty years and stopped when it got too dear. This brought the look back, and the way it falls "
            + "off in the shadows is the thing I missed most.\n\nKeep the paper profiles honest.\nAnd thank you for the black-and-white ones too: "
            + "Tri-X printed on Multigrade is how I learned, in a school darkroom that smelled of fixer, a very long time ago."
        let fixture = Data("""
        [
          {"name": "Anonymous"},
          {"name": "Margaret H.", "note": \(String(data: try! JSONEncoder().encode(long), encoding: .utf8)!)},
          {"name": "胶片老王", "note": "终于在 Mac 上找到了暗房的感觉。谢谢！"}
        ]
        """.utf8)
        guard let made = try? Supporter.decode(fixture) else {
            expect(false, "the fixture does not decode")
            return finish()
        }
        expect(made.count == 3 && made[0].note == nil && made[2].name == "胶片老王", "the fixture decodes as written")
        var page = SupportersPage(made)
        if breaking { page = SupportersPage(Array(made.dropLast()) + [Supporter(name: "胶片老王", note: nil)]) }
        lists(page, made, "the fixture")
        expect(page.entries.first?.note == nil, "no note draws no note")
        expect(page.entries.count > 1 && page.entries[1].note == long && page.entries[1].note?.contains("\n\n") == true,
               "a long note is held in full, every line end kept")
        expect(page.entries.count > 2 && page.entries[2].note == "终于在 Mac 上找到了暗房的感觉。谢谢！", "a note in Chinese is as written")
        let blank = SupportersPage([Supporter(name: "Anonymous", note: "  \n "), Supporter(name: "Anonymous", note: nil)])
        expect(blank.entries.map(\.note) == [nil, nil], "a note of spaces and line ends is no note")
        expect(Set(blank.entries.map(\.id)).count == 2, "two may choose the same name")
        // The thanks is a sentence of the page's own (English with no bundle), never empty.
        expect(page.thanks.hasPrefix("SpektraLab for the Mac is free and open source."), "the thanks: \(page.thanks)")
        // Nobody listed: the thanks alone.
        let none = try? Supporter.decode(Data("[]".utf8))
        expect(none == [] && SupportersPage([]).entries.isEmpty, "an empty list decodes and lists nobody")
        // What is never shown is never held: the page knows a name and a note and nothing else.
        let extra = try? Supporter.decode(Data(#"[{"name": "A", "note": "n", "amount": 9.9, "email": "a@b.c"}]"#.utf8))
        expect(extra == [Supporter(name: "A", note: "n")], "anything else in the file is not read")
        finish(breaking: breaking)
    }

    static func finish(breaking: Bool = false) {
        if breaking {
            // The broken page must have been caught.
            print(failed > 0 ? "supporters self-test: the broken listing was caught (\(failed))" : "supporters self-test: NOT caught")
            exit(failed > 0 ? 0 : 1)
        }
        print("supporters: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
