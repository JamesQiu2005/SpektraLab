import Foundation

/// A viewing visit holds its browsing context while edits change collection
/// membership. Deleting a frame moves to its neighbour, never a random frame.
struct LibraryBrowser: Equatable {
    private(set) var ids: [UUID] = []
    private(set) var selectedID: UUID?
    private(set) var started = false

    init(selectedID: UUID? = nil) { self.selectedID = selectedID }

    mutating func start(_ ids: [UUID]) {
        guard !started else { return }
        started = true
        self.ids = ids
        if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
    }

    mutating func select(_ id: UUID) {
        guard ids.contains(id) else { return }
        selectedID = id
    }

    /// The frames the visit walks are `ids` — not the ones it started with. The Mac's develop page has
    /// this: its strip is the window's browser (`MainWindowLayout`), whose rows the page was not opened
    /// with — a mode pressed with one row chosen carries that one picture (`MacDevelopCarry`), and the
    /// browser beside the canvas shows the whole collection. `id` is the frame opened, which the visit
    /// must be able to reach even when the list a caller built from the library has not caught up with
    /// it (a frame made a moment ago).
    mutating func restart(_ ids: [UUID], selecting id: UUID? = nil) {
        started = true
        self.ids = ids.contains(where: { $0 == id }) ? ids : ids + (id.map { [$0] } ?? [])
        if let id, self.ids.contains(id) { selectedID = id }
        else if !self.ids.contains(where: { $0 == selectedID }) { selectedID = self.ids.first }
    }

    mutating func reconcile(_ remaining: Set<UUID>) {
        let previous = ids
        let index = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        ids.removeAll { !remaining.contains($0) }
        if !ids.contains(where: { $0 == selectedID }) {
            selectedID = previous.dropFirst(index + 1).first(where: remaining.contains)
                ?? previous.prefix(index).reversed().first(where: remaining.contains)
        }
    }
}
