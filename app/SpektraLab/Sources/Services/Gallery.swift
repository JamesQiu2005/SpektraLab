//  Gallery.swift — retained library-view choices for settings compatibility.
//  The Mac browser owns its grouping and viewer; a retired saved choice falls back to All.

import Foundation

/// Which of the views the gallery shows.
enum GalleryView: String, CaseIterable, Codable, Sendable, Identifiable {
    case all = "all", imported = "imported"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("All", as: "the gallery")
        case .imported: L("Imported")
        }
    }
}
