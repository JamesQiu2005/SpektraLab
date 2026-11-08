//  Supporters.swift — the people Settings › General › About › Supporters thanks, and that page's words.
//
//  The owner, 2026-11-08: opening the desktop costs it the paid route, so the people who paid toward the
//  Mac app's development, left a note and want to see it go on are thanked inside the app.
//
//  - **The list is `Resources/Supporters.json`**: an array of `{"name": String, "note": String?}`, in the
//    order they supported, earliest first. Adding one is a line of that file in a normal commit.
//  - **Only those who said yes**, with the name they chose (a name, a handle, "Anonymous") and their note
//    only if they agreed to it being shown. Never filled from payment records, emails or any database:
//    the repository is public and keeps every name it was ever given.
//  - **Their words as they wrote them**: a name and a note are shown verbatim, in the language they were
//    written in, never translated (never through `L`). Nothing else of a supporter is held: no amount, no
//    date, no email, no country.
//  - Decoded once (`SupportersPage.shipped`). A file that does not decode lists nobody, and
//    `tools/supporters_selftest.swift` decodes the shipped file so that cannot ship unnoticed.

import Foundation

/// One entry of `Resources/Supporters.json`.
struct Supporter: Decodable, Equatable, Sendable {
    /// The name they chose to be thanked by.
    let name: String
    /// What they wrote, verbatim; nil when they left none or did not want it shown.
    let note: String?

    private enum CodingKeys: String, CodingKey {
        case name = "name"
        case note = "note"
    }

    /// The shipped list, earliest supporter first: the file's own order.
    static func decode(_ data: Data) throws -> [Supporter] {
        try JSONDecoder().decode([Supporter].self, from: data)
    }
}

/// What the Supporters page shows: the thanks, then each supporter with their note.
struct SupportersPage: Equatable, Sendable {
    struct Entry: Equatable, Identifiable, Sendable {
        /// The place in the list: two supporters may well choose the same name ("Anonymous").
        let id: Int
        let name: String
        /// Nil for no note: a note of nothing but spaces and line ends is no note, and draws no empty line.
        let note: String?
    }

    let entries: [Entry]

    init(_ supporters: [Supporter]) {
        entries = supporters.enumerated().map { i, s in
            let note = s.note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return Entry(id: i, name: s.name, note: note)
        }
    }

    /// The thanks, in the app's language (wording for the owner to approve, handoff §6).
    var thanks: String {
        L("SpektraLab for the Mac is free and open source. Thank you to everyone who supports its development.")
    }

    /// The bundle's list, read once; nobody when the file is missing or does not decode.
    static let shipped = SupportersPage(
        Bundle.main.url(forResource: "Supporters", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? Supporter.decode($0) } ?? [])
}
