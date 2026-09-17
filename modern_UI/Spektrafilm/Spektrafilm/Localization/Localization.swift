//  Localization.swift — which language the interface is drawn in, and how that
//  is decided.
//
//  There is no `.xcstrings` here and there is not meant to be one. The app has
//  no strings catalog, no `.lproj` and no `NSLocalizedString` anywhere, and a
//  catalog could not do the one thing this work is for: **the language has to
//  change while the app is running**, from the Settings page, with no
//  relaunch. A catalog is resolved through `Bundle` at lookup time and a bundle
//  cannot be swapped underneath a running process; the standard answer is to
//  relaunch, which is the answer this is avoiding. `Resources/` is also a
//  folder *reference* in the project (see `Tools/gen-project.py`), so a catalog
//  dropped in there would be copied verbatim rather than compiled into the
//  bundle — it would not even work after a relaunch.
//
//  So the table is a Swift one, in `Strings.swift`, and this file is the other
//  half: the setting, its resolution, and the observable that makes a change
//  repaint the interface. The lookup itself is `L(_:)` in that file — read the
//  note there about why every call goes through this class.
//
//  Read `design/LOCALIZATION-zh-Hans.md` before adding copy. It is the spec for
//  what is translated and, just as much, for what is deliberately not.

import Foundation
import Observation

/// A language this app has copy for.
///
/// Two cases, and the small number is the point: `zh-Hant` is not one of them.
/// See `Localization.resolve` for what happens to a traditional-Chinese reader.
enum Language: String, CaseIterable, Sendable {
    case english
    case simplifiedChinese
}

/// What the Settings menu offers: the two languages, plus "whatever the system
/// says" — which is the default, and which is not the same thing as English.
enum LanguageSetting: String, CaseIterable, Sendable {
    case system, english, simplifiedChinese

    /// The menu's own label.
    ///
    /// `.english` and `.simplifiedChinese` are written **in their own
    /// language** and never in the active one. A language menu is the one menu
    /// a user reaches for *because* the current language is wrong, so
    /// "Simplified Chinese" rendered in a language its reader cannot read is
    /// the one label guaranteed not to help. Only `.system` follows the active
    /// language, because it has no language of its own to be written in.
    ///
    /// The active language is passed in rather than read from
    /// `Localization.shared` here. `PillMenu` takes a plain `(T) -> String`, so
    /// a closure that touched main-actor state could not be built inside a
    /// view's body without a concurrency error; taking the value as an
    /// argument keeps this a pure function of its inputs, which is also what
    /// makes it checkable without a running app.
    /// The two fixed names are literals here rather than table entries: they
    /// are the *names of languages*, and the table's job is copy that changes
    /// meaning under translation. `.system` has no such name of its own, so it
    /// is the one that lives in the table and follows the active language.
    nonisolated func label(in active: Language) -> String {
        switch self {
        case .system:
            return active == .simplifiedChinese
                ? S.languageFollowSystem.simplifiedChinese
                : S.languageFollowSystem.english
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

/// The language setting, and the observable every localized string reads.
///
/// `@Observable` rather than a plain singleton, and that is load-bearing
/// rather than stylistic: `L(_:)` reads `resolved` from this object inside a
/// view's body, so SwiftUI records the dependency and a change to `language`
/// repaints every view that draws a string. A plain `static var` would compile,
/// would look right, and would leave every label in the window in the old
/// language until something else happened to invalidate it.
@MainActor
@Observable
final class Localization {
    static let shared = Localization()

    /// What the user picked. Persisted under `ui2.language` — the same `ui2.`
    /// namespace as the rest of this window's state (`Session.uiKey`), so it
    /// travels with the other interface settings rather than starting a
    /// second, parallel convention.
    ///
    /// Assigning it does not touch any view: the views read `resolved` during
    /// their own body, and `@Observable` tells them to re-run.
    var language: LanguageSetting {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Keys.language)
        }
    }

    /// The language copy is actually drawn in.
    ///
    /// Computed, not stored: it is a function of the setting and the system,
    /// and a stored copy would be a second source of truth for a question that
    /// already has one. It reads `self.language`, which is what registers the
    /// `@Observable` dependency — a stored property would work too, but this
    /// keeps the derivation in one place.
    var resolved: Language {
        switch language {
        case .english: return .english
        case .simplifiedChinese: return .simplifiedChinese
        case .system: return Self.resolve(Self.systemPreferredLanguages)
        }
    }

    /// The user's preferred languages, read **once**.
    ///
    /// `Locale.preferredLanguages` is a preferences read, not a constant, and
    /// `resolved` is on the path of every text view in the editor — a drag
    /// re-evaluates a rail sixty times a second, and each pass would pay for
    /// the same answer. `static let` is initialized once, lazily. The cost is
    /// that a system language change mid-session is not followed; on macOS it
    /// is not followed by anything else either, and the setting is re-read on
    /// the next launch.
    ///
    /// `Bundle.preferredLocalizations` would be the other candidate and is not
    /// usable: the bundle declares no localizations at all (`knownRegions` is
    /// `en` and `Base` in the project generator), so it can answer nothing
    /// but English.
    private static let systemPreferredLanguages = Locale.preferredLanguages

    private let defaults: UserDefaults

    private enum Keys {
        static let language = Session.uiKey + "language"
    }

    /// `defaults` is injectable for the same reason `Diagnostics`' is: a test
    /// can write a setting and read back what the app would do with it without
    /// disturbing the real one.
    init(defaults: UserDefaults = .standard) {
        // `defaults` is assigned before `language` because the `didSet` above
        // may run during this call — `@Observable` rewrites the stored
        // property into a computed one, and the compiler's "observers do not
        // run during initialization" rule does not survive that rewriting.
        // (The same rewriting is why a `didSet` that assigns to *itself*
        // recurses; this one writes to `defaults` and to nothing else.)
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.language)
            .flatMap(LanguageSetting.init(rawValue:)) ?? .system
        language = stored
    }

    // MARK: - resolution

    /// Which language a preference list resolves to.
    ///
    /// The list is walked in order and the **first tag this app has copy for**
    /// wins — the system's own rule, and the reason the check is per-tag rather
    /// than a scan of the whole list.
    ///
    /// A traditional-Chinese tag is **not** a match for Simplified. The app
    /// ships no `zh-Hant` copy, and silently showing a Taiwanese reader
    /// Simplified because it is the nearest thing available is worse than
    /// showing them English: English is at least a language they chose to read,
    /// and the two scripts are not the same reading experience for someone who
    /// cannot read one of them. So `["zh-Hant"]` alone falls through to
    /// English, while `["zh-Hant", "zh-Hans"]` reaches Simplified on its second
    /// tag — that second tag is a real statement of preference, and honouring
    /// it is not the same thing as assuming it.
    ///
    /// Pure and `nonisolated` on purpose: every branch below is checkable by
    /// passing a list of tags, without a running app or a system to configure.
    nonisolated static func resolve(_ preferred: [String]) -> Language {
        for tag in preferred {
            if let match = match(tag) { return match }
        }
        return .english
    }

    /// One tag, or `nil` when it names a language this app has no copy for.
    private nonisolated static func match(_ tag: String) -> Language? {
        let parts = tag.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
        guard let primary = parts.first else { return nil }
        switch primary {
        case "en":
            return .english
        case "zh":
            // Script beats region when both are present: `zh-Hans-TW` is
            // Simplified and `zh-Hant-CN` is not ours.
            if parts.contains("hant") { return nil }
            if parts.contains("hans") { return .simplifiedChinese }
            // No script given, so the region decides — and only the regions
            // that are Simplified by default are claimed. `zh-TW`, `zh-HK` and
            // `zh-MO` are traditional and fall through unmatched, which is
            // what sends them to English.
            if parts.contains("tw") || parts.contains("hk") || parts.contains("mo") { return nil }
            // Bare `zh` and the remaining regions: Simplified. macOS writes a
            // bare `zh` when the script is unstated, and Simplified is the
            // majority reading of an unstated `zh`.
            return .simplifiedChinese
        default:
            return nil
        }
    }
}
