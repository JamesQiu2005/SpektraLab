//  Format.swift — how the pages write numbers and dates.
//
//  One place, so "+0.3 EV" on the dial, in the status line and in Copy Settings
//  is the same string. The drawings' conventions: a true minus (−), a thin
//  multiplication sign in sizes (6,000 × 4,000), a middle dot between parts.

import Foundation

enum Fmt {
    /// The separator in a status line: "Developing  ·  Film Exp. +0.3". Wider than the
    /// single-spaced dot inside a value ("Porta 400 · Supera Enduro").
    static let dot = "  ·  "

    /// "+0.3", "−1.25", "0.00" at 0 when `plusAtZero` is false.
    static func signed(_ v: Double, decimals: Int = 1, plusAtZero: Bool = false) -> String {
        let body = String(format: "%.\(decimals)f", abs(v))
        let zero = Double(body) == 0
        if zero { return plusAtZero ? "±" + body : body }
        return (v < 0 ? "−" : "+") + body
    }

    /// "6,000".
    static func thousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "12.0 MP".
    static func megapixels(_ mp: Double) -> String { String(format: "%.1f MP", mp) }

    /// "6.9 GB", "0.2 GB".
    static func gigabytes(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }

    /// "1.00×".
    static func times(_ v: Double) -> String { String(format: "%.2f×", v) }

    /// English writes its dates as the drawings do ("28 Sep 2026"). Chinese writes them its own
    /// way round ("2026年9月28日"), which is `chinese`, in the script the app is in (`Language`);
    /// Japanese writes them the same way round, its weekday its own ("日曜日").
    private static func formatter(_ format: String, chinese: String) -> DateFormatter {
        let f = DateFormatter()
        let language = Language.shared.current
        f.locale = Locale(identifier: language.writesDatesWithYearFirst ? language.rawValue : "en_GB")
        f.dateFormat = language.writesDatesWithYearFirst ? chinese : format
        return f
    }
    private static func clock(_ d: Date) -> String { formatter("HH:mm", chinese: "HH:mm").string(from: d) }

    /// "28 Sep 2026 · 18:42": the library's line under the top frame.
    static func stamp(_ d: Date) -> String { formatter("d MMM yyyy", chinese: "y年M月d日").string(from: d) + " · " + clock(d) }

    /// "Sunday 28 Sep 2026 · 18:42": Info's first line.
    static func longStamp(_ d: Date) -> String { formatter("EEEE d MMM yyyy", chinese: "y年M月d日 EEEE").string(from: d) + " · " + clock(d) }

    /// "30 Sep": the date beside a day's name in the grid.
    static func dayMonth(_ d: Date) -> String { formatter("d MMM", chinese: "M月d日").string(from: d) }

    /// "Today", "Yesterday", else the weekday: the grid's group name.
    static func dayName(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return L("Today") }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return L("Yesterday") }
        return formatter("EEEE", chinese: "EEEE").string(from: d)
    }
}

/// A picture's size in pixels.
struct PixelSize: Codable, Equatable, Hashable, Sendable {
    /// The keys as they are written: renaming a property must not move its key.
    enum CodingKeys: String, CodingKey { case width = "width", height = "height" }
    var width: Int
    var height: Int

    var megapixels: Double { Double(width) * Double(height) / 1_000_000 }
    var aspect: Double { height > 0 ? Double(width) / Double(height) : 1 }
    var longEdge: Int { max(width, height) }
    var shortEdge: Int { min(width, height) }
    /// "6,000 × 4,000".
    var text: String { "\(Fmt.thousands(width)) × \(Fmt.thousands(height))" }

    /// The same shape with `megapixels` pixels (never larger than this).
    func scaled(toMegapixels mp: Double) -> PixelSize {
        guard megapixels > mp, mp > 0 else { return self }
        let s = (mp / megapixels).squareRoot()
        return PixelSize(width: Int((Double(width) * s).rounded()), height: Int((Double(height) * s).rounded()))
    }

    /// The same shape with this short edge (never larger than this).
    func scaled(toShortEdge edge: Int) -> PixelSize {
        guard shortEdge > edge, edge > 0 else { return self }
        let s = Double(edge) / Double(shortEdge)
        return PixelSize(width: Int((Double(width) * s).rounded()), height: Int((Double(height) * s).rounded()))
    }

    /// The same shape with this long edge (never larger than this).
    func scaled(toLongEdge edge: Int) -> PixelSize {
        guard longEdge > edge, edge > 0 else { return self }
        let s = Double(edge) / Double(longEdge)
        return PixelSize(width: Int((Double(width) * s).rounded()), height: Int((Double(height) * s).rounded()))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
