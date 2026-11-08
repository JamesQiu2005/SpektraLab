// language_selftest.swift -- the app's language: which of the four a host's list asks for, what a
// launch settles on, and how a sentence's arguments are put in place (Sources/Model/Localization.swift).
// Compiled and run by tools/selftest.sh on a Mac, where there is no bundle: every lookup is English.
import Foundation

@main
struct LanguageSelfTest {
    static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1; print("FAILED  \(what)") }
    }

    static func main() {
        // The host's list, once, at the first launch.
        let asks: [([String], AppLanguage)] = [
            (["zh-Hans-CN"], .simplified), (["zh-Hans"], .simplified), (["zh-CN"], .simplified), (["zh-SG"], .simplified),
            (["zh-Hans-US", "en-US"], .simplified), (["zh-Hans-HK"], .simplified), (["zh"], .simplified),
            (["zh-Hant-TW"], .traditional), (["zh-Hant"], .traditional), (["zh-TW"], .traditional), (["zh-HK"], .traditional),
            (["zh-MO"], .traditional), (["zh-Hant-CN"], .traditional), (["zh_Hant_HK"], .traditional), (["yue-Hant-HK"], .traditional),
            (["yue-Hans-CN"], .simplified),
            (["en-US"], .english), (["en-GB", "zh-Hans-CN"], .english), (["fr-FR", "de-DE"], .english),
            (["ja-JP"], .japanese), (["ja"], .japanese), (["ja-Jpan-JP"], .japanese), (["fr-FR", "ja-JP", "en-US"], .japanese),
            (["en-JP", "ja-JP"], .english),
            ([], .english),
            // The first of the app's own languages in the list decides: a host in Japanese that also reads Chinese
            // is Japanese (since 2026-10-22; Traditional before), one in Chinese that also reads Japanese is Chinese.
            (["ja-JP", "zh-Hant-TW", "en-US"], .japanese), (["zh-Hant-TW", "ja-JP"], .traditional),
        ]
        for (list, want) in asks {
            expect(AppLanguage.derived(from: list) == want, "\(list) asks for \(want.rawValue), not \(AppLanguage.derived(from: list).rawValue)")
        }
        expect(AppLanguage.allCases.map(\.ownName) == ["English", "简体中文", "繁體中文", "日本語"], "each language is named in itself")
        // Japanese is not Chinese: until 2026-10-22 `isChinese` was `self != .english`.
        expect(AppLanguage.allCases.filter(\.isChinese) == [.simplified, .traditional], "only the two Chinese are Chinese")
        expect(AppLanguage.allCases.filter(\.writesDatesWithYearFirst) == [.simplified, .traditional, .japanese],
               "Chinese and Japanese write a date year first")
        expect(AppLanguage.japanese.privacyPolicyURL.absoluteString == "https://spektralab.app/privacy/"
               && AppLanguage.english.privacyPolicyURL.absoluteString == "https://spektralab.app/privacy/",
               "Japanese is sent to the English privacy policy: there is no Japanese page")
        expect(AppLanguage.simplified.privacyPolicyURL.absoluteString == "https://spektralab.app/privacy/zh-hans/"
               && AppLanguage.traditional.privacyPolicyURL == AppLanguage.simplified.privacyPolicyURL,
               "both Chinese are sent to the Chinese privacy policy")

        // A launch. Each on defaults of its own.
        var suite = ""
        func fresh() -> UserDefaults {
            suite = "language-selftest-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            d.removePersistentDomain(forName: suite)
            return d
        }
        // What these defaults hold themselves: a plain read falls through to this Mac's own list.
        func own(_ d: UserDefaults, _ key: String) -> Any? { d.persistentDomain(forName: suite)?[key] }
        func kept(_ d: UserDefaults) -> String? { own(d, Language.storedKey) as? String }
        func system(_ d: UserDefaults) -> [String]? { own(d, Language.systemKey) as? [String] }
        let language = Language.shared

        var d = fresh()
        language.start(arguments: ["app"], defaults: d, preferred: ["zh-Hant-TW", "en"])
        expect(language.current == .traditional, "a first launch on a phone in Traditional Chinese is Traditional")
        expect(kept(d) == "zh-Hant" && system(d) == ["zh-Hant"], "and the choice is kept, for the app and for the system's own pieces")

        language.choose(.english)
        expect(language.current == .english && kept(d) == "en" && system(d) == ["en"], "a choice in Settings is at once, and kept")
        // The next launch: the host still says Chinese, the user said English. `preferred` is what the operating system
        // reports once `AppleLanguages` holds the app's own list.
        language.start(arguments: ["app"], defaults: d, preferred: ["en"])
        expect(language.current == .english, "the user's choice stands at the next launch")
        // the operating system's Settings › SpektraLab › Language writes the same key with its own tags.
        d.set(["zh-Hans-CN", "en-CN"], forKey: Language.systemKey)
        language.start(arguments: ["app"], defaults: d, preferred: ["zh-Hans-CN", "en-CN"])
        expect(language.current == .simplified && kept(d) == "zh-Hans", "a language chosen in iOS's own Settings since is the later word")
        expect(system(d) == ["zh-Hans"], "and is written back as the app writes it")

        d = fresh()
        language.start(arguments: ["app", "--snapshot", "/tmp/x"], defaults: d, preferred: ["zh-Hans-CN"])
        expect(language.current == .english, "a check's launch is English on a Mac set to Chinese")
        expect(kept(d) == nil && system(d) == nil, "and keeps nothing")
        language.start(arguments: ["app", "--snapshot", "/tmp/x", "--language", "zh-Hant"], defaults: d, preferred: ["en"])
        expect(language.current == .traditional && kept(d) == nil, "unless it names a language, which is not kept either")
        language.choose(.simplified)
        expect(kept(d) == nil && system(d) == nil, "a change of language in a check's launch is not kept")
        language.start(arguments: ["app", "-NSDocumentRevisionsDebugMode", "YES"], defaults: d, preferred: ["zh-Hans-CN"])
        expect(language.current == .simplified, "Xcode's own single-dash arguments are not a check's")

        // Sentences. Here every lookup is English: there is no table.
        language.start(arguments: ["app", "--check"], defaults: d, preferred: [])
        let n = 3, name = "Porta 400"
        expect(L("Settings") == "Settings", "a plain sentence is itself")
        expect(L("\(n) frames") == "3 frames", "an argument is put in place")
        expect(L("\(name) is a slide: " + "it is scanned.") == "Porta 400 is a slide: it is scanned.", "a sentence over two lines is one")
        expect(L("100% of \(n)") == "100% of 3", "a per-cent sign in a sentence with an argument is a per-cent sign")
        expect(L("100% sure") == "100% sure", "and in a plain one")
        expect(L("Level", as: "a pair") == "Level", "a word with a sense is the word, in English")
        expect(L(shown: "Waiting its turn") == "Waiting its turn", "a sentence made elsewhere is shown as it is")
        expect(LText.filled("第 %2$@ 张，共 %1$@ 张", ["9", "4"]) == "第 4 张，共 9 张", "a translation orders its arguments by position")
        expect(LText.filled("%@ 张，%@%%", ["4", "50"]) == "4 张，50%", "or takes them in order")
        expect(LText.filled("%3$@ and %@", ["a"]) == " and a", "an argument a translation asks for and the sentence lacks is nothing, not a crash")
        expect(Fmt.dayName(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 0)) == "Today", "the pages' dates are English here")

        // A launch in Japanese: its dates are written its own way, whatever the table (none here).
        d = fresh()
        language.start(arguments: ["app"], defaults: d, preferred: ["ja-JP", "en-JP"])
        expect(language.current == .japanese && kept(d) == "ja" && system(d) == ["ja"],
               "a first launch on a phone in Japanese is Japanese, and kept as `ja`")
        d = fresh()
        language.start(arguments: ["app", "--check", "--language", "ja"], defaults: d, preferred: ["en"])
        expect(language.current == .japanese && kept(d) == nil, "a check's launch may name Japanese, which is not kept")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = utc.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!
        expect(Fmt.dayMonth(day) == "9月28日", "a Japanese date is month and day with 月 日, not \(Fmt.dayMonth(day))")
        expect(Fmt.dayName(day, now: utc.date(byAdding: .day, value: 5, to: day)!) == "月曜日",
               "and its weekday is Japanese, not \(Fmt.dayName(day, now: utc.date(byAdding: .day, value: 5, to: day)!))")
        language.start(arguments: ["app", "--check"], defaults: d, preferred: [])

        print("language checks: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
