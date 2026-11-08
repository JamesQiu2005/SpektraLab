//  Localization.swift — the app's language, and the one lookup every page's words go through.
//
//  Four languages, chosen in Settings › Language: English, 简体中文, 繁體中文, 日本語. There is no
//  "follow the system": the first launch takes the host's own preferred language once, and from
//  then on the choice is the user's (`Language.start`).
//
//  The pages write their words as plain `String`s — `DrawnText`, `Text`, a row's label, a note a
//  model builds — so SwiftUI's own lookup of a `LocalizedStringKey` never sees them. `L("…")` is
//  that lookup: the English sentence is the key and the fallback, and the chosen language's table
//  (`Localizable.xcstrings`, compiled by Xcode into `zh-Hans.lproj`, `zh-Hant.lproj` and `ja.lproj`) gives its
//  translation. An interpolation is an argument: `L("\(n) frames")` looks up `%@ frames`, and a
//  translation orders its arguments by position (`%1$@`, `%2$@`). A word with two senses names the
//  one it is: `L("Level", as: "a pair")`.
//
//  **English never reads a table.** In English `L` returns what the literal would have been,
//  byte for byte, which is what the checks hold: the self-tests compile this file on a Mac with no
//  bundle at all, and a launch with a `--` argument (a snapshot, a tour, a harness) is English
//  unless it says `--language zh-Hans`, `zh-Hant` or `ja`.
//
//  **The log is English.** A word that is both shown and written to a record is looked up where
//  it is shown (`L(shown:)`), never where it is made. `LOCALIZATION.md` has the rules and the words.

import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// One of the app's four languages. The raw value is the `.lproj`'s name and what
/// `AppleLanguages` is given.
enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplified = "zh-Hans"
    case traditional = "zh-Hant"
    /// Japanese, since 2026-10-22. It is not Chinese: `isChinese` is false for it, and each place
    /// that asked "Chinese or not" says what Japanese gets (LOCALIZATION.md).
    case japanese = "ja"

    /// The language's name in itself: what its row in Settings says, in every language.
    var ownName: String {
        switch self {
        case .english: "English"
        case .simplified: "简体中文"
        case .traditional: "繁體中文"
        case .japanese: "日本語"
        }
    }

    /// What the system's own formatters are given (`\.locale`). Chinese is given its script
    /// only, Japanese its language only, so the host's region still orders what the region orders.
    var locale: Locale { Locale(identifier: rawValue) }

    /// Simplified or Traditional Chinese, and nothing else: Japanese is not Chinese. Said outright,
    /// since until 2026-10-22 it was `self != .english`, which a fourth language would have fallen into.
    var isChinese: Bool { self == .simplified || self == .traditional }

    /// Whether dates are written year first, with 年 月 日 ("2026年9月28日"): Chinese and Japanese both.
    var writesDatesWithYearFirst: Bool { self != .english }

    /// Where the privacy policy is published for this language (`legal/`, served by `site/`). The
    /// policy is in English and Simplified Chinese only: Traditional is sent to the Simplified page,
    /// Japanese to the English one (2026-10-22: there is no Japanese policy). A switch, so that a
    /// language added later has to say which.
    var privacyPolicyURL: URL {
        switch self {
        case .english, .japanese: URL(string: "https://spektralab.app/privacy/")!
        case .simplified, .traditional: URL(string: "https://spektralab.app/privacy/zh-hans/")!
        }
    }

    /// The language a host's preferred languages ask for: the first of them that is English,
    /// Chinese or Japanese decides. A Chinese with no script named is read by its region — Taiwan,
    /// Hong Kong and Macau write Traditional; anywhere else Simplified. Any other language is English.
    static func derived(from preferred: [String]) -> AppLanguage {
        for tag in preferred {
            let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map { $0.lowercased() }
            guard let language = parts.first else { continue }
            if language == "en" { return .english }
            if language == "ja" { return .japanese }
            // `yue` (Cantonese) and the other Chinese languages the system lists are read as Chinese.
            guard ["zh", "yue", "wuu", "cmn"].contains(language) else { continue }
            if parts.contains("hant") { return .traditional }
            if parts.contains("hans") { return .simplified }
            if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return .traditional }
            return language == "yue" ? .traditional : .simplified
        }
        return .english
    }
}

/// The language the app is in. One instance; every lookup reads it, and a page that looked a
/// word up while it was drawn is drawn again when it changes (Observation).
@Observable
final class Language: @unchecked Sendable {
    static let shared = Language()

    static let storedKey = "settings.language"
    /// The system's own key: what the operating system reads at the next launch for its own pieces — a permission
    /// alert, the Photos picker, the share sheet, the usage descriptions.
    static let systemKey = "AppleLanguages"

    /// Set on the main thread; read from anywhere a sentence is made. The lock is for the
    /// table, which a develop's status line can ask for off the main thread.
    private(set) var current: AppLanguage = .english
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var tables: [AppLanguage: [String: String]] = [:]
    /// Where the choice is kept. Nil for a check's launch: nothing it shows is the user's choice.
    @ObservationIgnored private var defaults: UserDefaults?

    /// The launch: which language this run is in.
    ///
    /// - A launch with a `--` argument is a check's (a snapshot, a tour, a harness): English,
    ///   whatever the Mac or the simulator is set to, unless `--language <code>` names another.
    ///   Nothing is read from what was kept, and nothing is kept.
    /// - Otherwise the kept choice — unless the system's list has been changed under it since
    ///   (the operating system's own Settings › SpektraLab › Language writes the same `AppleLanguages`): then the
    ///   system's is the later word, and is taken.
    /// - Nothing kept: the host's preferred language, once, and kept from then on.
    func start(arguments: [String] = CommandLine.arguments, defaults: UserDefaults = .standard,
               preferred: [String] = Locale.preferredLanguages) {
        self.defaults = nil
        if let i = arguments.firstIndex(of: "--language"), i + 1 < arguments.count,
           let named = AppLanguage(rawValue: arguments[i + 1]) {
            current = named
            return
        }
        if arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
            current = .english
            return
        }
        self.defaults = defaults
        let asked = AppLanguage.derived(from: preferred)
        if let kept = defaults.string(forKey: Self.storedKey).flatMap(AppLanguage.init(rawValue:)) {
            // What this app wrote for the system is `[kept.rawValue]`; anything else there now
            // was written by the operating system's Settings after it.
            let ours = (defaults.array(forKey: Self.systemKey) as? [String]) == [kept.rawValue]
            current = ours ? kept : asked
        } else {
            current = asked
        }
        keep()
    }

    /// The user's choice in Settings: at once for every page, and kept.
    func choose(_ language: AppLanguage) {
        guard language != current else { return }
        current = language
        keep()
    }

    private func keep() {
        defaults?.set(current.rawValue, forKey: Self.storedKey)
        defaults?.set([current.rawValue], forKey: Self.systemKey)
    }

    /// The translation of `key` in the language the app is in, or nil: English has none, and a
    /// key the table lacks falls back to its English.
    fileprivate func translation(of key: String) -> String? {
        let language = current
        guard language != .english else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if tables[language] == nil { tables[language] = Self.table(language) }
        return tables[language]?[key]
    }

    /// The compiled table of one language, from the app's bundle. Empty where there is none
    /// (a self-test on a Mac).
    private static func table(_ language: AppLanguage) -> [String: String] {
        guard let folder = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"),
              let data = try? Data(contentsOf: folder.appendingPathComponent("Localizable.strings")),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return table
    }
}

/// A sentence as the sources write it: a literal, whose interpolations are its arguments.
/// `"\(n) frames"` is the key `%@ frames` with one argument; a plain literal is its own key.
struct LText: ExpressibleByStringInterpolation {
    var key: String
    var arguments: [String]
    /// Whether `key` is a format: only then is `%%` a per-cent sign.
    var isFormat: Bool

    init(stringLiteral value: String) { key = value; arguments = []; isFormat = false }

    init(stringInterpolation s: StringInterpolation) { key = s.key; arguments = s.arguments; isFormat = true }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append("\(value)")
        }
    }

    /// A sentence written over two lines of source: `L("…" + "…")` is one key.
    static func + (a: LText, b: LText) -> LText {
        guard a.isFormat || b.isFormat else { return LText(stringLiteral: a.key + b.key) }
        func escaped(_ t: LText) -> String { t.isFormat ? t.key : t.key.replacingOccurrences(of: "%", with: "%%") }
        var joined = LText(stringLiteral: escaped(a) + escaped(b))
        joined.arguments = a.arguments + b.arguments
        joined.isFormat = true
        return joined
    }

    /// `template` with the arguments in place: `%@` takes the next, `%2$@` the second, `%%` is `%`.
    static func filled(_ template: String, _ arguments: [String]) -> String {
        var out = ""
        var next = 0
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            guard c == "%" else { out.append(c); i = template.index(after: i); continue }
            var j = template.index(after: i)
            var digits = ""
            while j < template.endIndex, template[j].isASCII, template[j].isNumber { digits.append(template[j]); j = template.index(after: j) }
            if j < template.endIndex, template[j] == "%", digits.isEmpty {
                out.append("%"); i = template.index(after: j); continue
            }
            if j < template.endIndex, template[j] == "$", let n = Int(digits),
               template.index(after: j) < template.endIndex, template[template.index(after: j)] == "@" {
                if n >= 1, n <= arguments.count { out += arguments[n - 1] }
                i = template.index(j, offsetBy: 2); continue
            }
            if j < template.endIndex, template[j] == "@", digits.isEmpty {
                if next < arguments.count { out += arguments[next] }
                next += 1
                i = template.index(after: j); continue
            }
            out.append(c); i = template.index(after: i)
        }
        return out
    }
}

/// The sentence in the app's language. English is the literal itself.
func L(_ text: LText) -> String {
    let template = Language.shared.translation(of: text.key) ?? text.key
    return text.isFormat ? LText.filled(template, text.arguments) : template
}

/// One English word that is two things in the app — *Original* is a file, a picture and a shape —
/// says which it is: `L("Original", as: "the file")` is the key `Original {the file}`, and English
/// is still the word alone.
func L(_ text: LText, as sense: String) -> String {
    guard let template = Language.shared.translation(of: text.key + " {" + sense + "}") else { return L(text) }
    return text.isFormat ? LText.filled(template, text.arguments) : template
}

/// A sentence that was made in English somewhere that also writes it to the log, or that a check
/// compares: looked up here, where it is shown. A sentence the table lacks is shown as it is.
func L(shown english: String) -> String {
    Language.shared.translation(of: english) ?? english
}
