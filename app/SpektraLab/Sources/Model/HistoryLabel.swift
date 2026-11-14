//  HistoryLabel.swift — what a step of a frame's edit history is called, and where it was made (PRD-F §3.3, §3.4).
//
//  A label is kept as a key of the app's strings and the values put into it, never as text: switching the
//  language relabels the history. The key is spelt as `L` spells one (`Localization.swift`: an interpolation is
//  `%@`), so the page shows a label with `LText.filled(<the key's translation>, args)`.
//
//  The labels that are certain where a step is made are here: a paste names its source, a preset its name, Crop's
//  and the Film Edge flow's Done their flow, a composite the piece. A step of the develop page is named from the
//  difference it made, by the table of named fields in `HistoryFields.swift` (`HistoryLabels.develop`, PRD-F
//  part 2, 2026-11-13).

import Foundation

/// Where a step was made (PRD-F §3.3). Kept by its raw value; a value this build does not know (a newer build's)
/// reads as `elsewhere`, and its raw text is kept beside it (`HistoryStepInfo.originText`).
enum HistoryOrigin: String, Codable, Sendable, CaseIterable {
    /// A control of the develop page (冲洗 or 编辑), a reset (↺), a card: one per gesture or held transaction.
    case develop
    /// Crop's Done, the Film Edge flow's Done.
    case flow
    /// Paste Settings, one step per frame reached.
    case paste
    /// A preset applied, one step per frame reached.
    case preset
    /// A half-frame pair's or a double exposure's step that changed this photograph's decode.
    case composite
    /// The edit changed where no step was recorded: an older build, a restored backup, a sweep of Settings, an
    /// agent; or the base of the history.
    case elsewhere

    init(stored: String) { self = HistoryOrigin(rawValue: stored) ?? .elsewhere }
}

/// A step's name as kept: a string key and the values put into it, never text (PRD-F §3.4): the page looks the key
/// up where it shows the label (`text`), so switching the language relabels the history. Unknown fields of a newer
/// build's label are ignored, a missing one reads as none (PRD-F §3.5).
///
/// - `key` is the control's name as the UI spells its key (`L("Film Exposure")`, `L("Tint", as: "the colour shift")`
///   is `Tint {the colour shift}`), or a sentence with `%@` for `args` (*Paste Settings from %@*).
/// - `value` is the new value where there is one and it is never translated: a number as the control shows it
///   (`+0.3`, `5200 K`), a stock's name. `valueKey` is one that is: *On*, *Off*. Shown after the name: a number with
///   a space (*Film Exposure +0.3*), a word after a colon (*Film: Portra 400*).
/// - `more`: a step that moved several groups names the first and *+2 more* (另 2 项).
struct HistoryLabel: Codable, Equatable, Hashable, Sendable {
    var key: String
    var args: [String]
    var value: String?
    var valueKey: String?
    var more: Int?

    /// As kept: a key and what goes into it.
    init(key: String, args: [String] = [], value: String? = nil, valueKey: String? = nil, more: Int? = nil) {
        self.key = key
        self.args = args
        self.value = value
        self.valueKey = valueKey
        self.more = more
    }

    /// A sentence as the sources write `L`'s, kept as its key and arguments: `HistoryLabel("Paste Settings from
    /// \(name)")` is the key `Paste Settings from %@` with one argument, `HistoryLabel("Tint", as: "the colour shift")`
    /// the key `Tint {the colour shift}`. `tools/localization_check.py` reads `HistoryLabel("…")` as it reads `L("…")`:
    /// a key written here that the catalog lacks fails it.
    init(_ text: LText, as sense: String? = nil, value: String? = nil, valueKey: String? = nil) {
        self.init(key: text.key + (sense.map { " {" + $0 + "}" } ?? ""), args: text.isFormat ? text.arguments : [],
                  value: value, valueKey: valueKey)
    }

    private enum CodingKeys: String, CodingKey { case key, args, value, valueKey, more }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? HistoryLabel.adjustment.key
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        value = try c.decodeIfPresent(String.self, forKey: .value)
        valueKey = try c.decodeIfPresent(String.self, forKey: .valueKey)
        more = try c.decodeIfPresent(Int.self, forKey: .more)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(args, forKey: .args)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(valueKey, forKey: .valueKey)
        try c.encodeIfPresent(more, forKey: .more)
    }

    /// The same name with the count of the other groups a step moved.
    func and(more n: Int) -> HistoryLabel {
        var copy = self
        copy.more = n > 0 ? n : nil
        return copy
    }

    /// A step whose control has no name (no control sets the field, or a newer build's field): 调整.
    static let adjustment = HistoryLabel("Adjustment")
    /// The reconciliation guard's step (PRD-F §3.2): 在别处更改.
    static let changedElsewhere = HistoryLabel("Changed elsewhere")
    /// Paste Settings from another frame, by its file's name.
    static func paste(from source: String) -> HistoryLabel {
        source.isEmpty ? HistoryLabel("Paste Settings") : HistoryLabel("Paste Settings from \(source)")
    }
    /// A preset applied, by its name.
    static func preset(_ name: String) -> HistoryLabel { HistoryLabel("Preset: \(name)") }
    /// Crop's Done: Develop's crop of the photograph, and Edit's of the finished picture. One word for both, the
    /// crop page's own (`EditTool.crop`, `CoverRoute.crop`): the origin and the group tell them apart on the page.
    static let crop = HistoryLabel("Crop")
    static let printCrop = HistoryLabel("Crop")
    /// The Film Edge flow's Done.
    static let filmEdge = HistoryLabel("Film Edge")
    /// A step of a pair or a double that changed this photograph's decode, by the piece's name.
    static func composite(_ name: String) -> HistoryLabel { HistoryLabel("Changed in \(name)") }
    /// Settings' *Lens Correction*, held over the library.
    static let lensCorrection = HistoryLabel("Lens Correction")
    /// A change an agent asked for (`AgentExecutor`).
    static let agent = HistoryLabel("Changed by an agent")
}

// MARK: - shown

extension HistoryLabel {
    /// The label in the app's language, as the history page shows it: the key looked up (English is the key, a
    /// sense left out), its arguments filled, the value after it, and *+N more*.
    var text: String {
        var name = Self.shown(key)
        if !args.isEmpty || key.contains("%") { name = LText.filled(name, args) }
        if let v = value ?? valueKey.map(Self.shown), !v.isEmpty {
            name = Self.joinsWithSpace(v) ? name + " " + v : L("\(name): \(v)")
        }
        if let more, more > 0 { name = L("\(name) +\(more) more") }
        return name
    }

    /// A key in the app's language; a key with a sense (`Tint {the colour shift}`) is its word in English.
    static func shown(_ key: String) -> String {
        let t = L(shown: key)
        guard t == key, key.hasSuffix("}"), let open = key.range(of: " {", options: .backwards) else { return t }
        return String(key[..<open.lowerBound])
    }

    /// A number follows its name with a space (*Film Exposure +0.3*, *Grain 1.20×*); a word, after a colon.
    private static func joinsWithSpace(_ value: String) -> Bool {
        guard let c = value.unicodeScalars.first else { return true }
        return CharacterSet.decimalDigits.contains(c) || "+-\u{2212}±".unicodeScalars.contains(c)
    }
}
