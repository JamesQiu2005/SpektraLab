import Foundation

enum FilmstripFilter: Int, CaseIterable, Identifiable {
    case all, one, two, three, four, five, edited, unedited
    var id: Int { rawValue }
    @MainActor var title: String {
        switch self {
        case .all: L("All", zh: "全部")
        case .one, .two, .three, .four: "≥\(rawValue)★"
        case .five: "5★"
        case .edited: L("Edited", zh: "已修")
        case .unedited: L("Unedited", zh: "未修")
        }
    }
    func includes(rating: Int, edited: Bool) -> Bool {
        switch self {
        case .all: true
        case .edited: edited
        case .unedited: !edited
        default: rating >= rawValue
        }
    }
}
