// Shared chronology for Library, Select and pair pickers.
import Foundation

struct LibraryDay: Identifiable {
    let day: Date
    let frames: [LibraryFrame]
    var id: Date { day }
}

extension FrameCatalog {
    /// Capture chronology governs both the day sections and their photos.
    /// Import time and ID only break ties, including a pair beside its source.
    private func grouped(_ frames: [LibraryFrame], oldestFirst: Bool) -> [LibraryDay] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: frames) { calendar.startOfDay(for: $0.captureDate) }
        return groups.keys.sorted { oldestFirst ? $0 < $1 : $0 > $1 }.map { day in
            let frames = groups[day, default: []].sorted { a, b in
                if a.captureDate != b.captureDate {
                    return oldestFirst ? a.captureDate < b.captureDate : a.captureDate > b.captureDate
                }
                if a.importedAt != b.importedAt {
                    return oldestFirst ? a.importedAt < b.importedAt : a.importedAt > b.importedAt
                }
                return oldestFirst ? a.id.uuidString < b.id.uuidString : a.id.uuidString > b.id.uuidString
            }
            return LibraryDay(day: day, frames: frames)
        }
    }

    var days: [(day: Date, frames: [LibraryFrame])] {
        grid().map { ($0.day, $0.frames) }
    }

    func grid(oldestFirst: Bool = false) -> [LibraryDay] {
        grouped(visible, oldestFirst: oldestFirst)
    }

    /// Every frame, pairs too, by day in the grid's sort, independently of the grid filter:
    /// the light table's Add sheet (RFC-045, design/lighttable L2).
    func everyDay(oldestFirst: Bool = false) -> [LibraryDay] {
        grouped(frames, oldestFirst: oldestFirst)
    }

    /// Pair pickers offer every photograph, independently of the grid filter.
    func photographs(oldestFirst: Bool = false) -> [LibraryFrame] {
        grouped(frames.filter { !$0.isPair }, oldestFirst: oldestFirst).flatMap(\.frames)
    }
}
