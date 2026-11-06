// Import decisions use the visible order, never the editor's picked set.
import Foundation

enum ImportSelection {
    static let preferenceKey = "ui2.showFolderImport"

    static func range(in urls: [URL], anchor: URL?, end: URL) -> Set<URL> {
        guard let b = urls.firstIndex(of: end) else { return [] }
        let a = anchor.flatMap { urls.firstIndex(of: $0) } ?? b
        return Set(urls[min(a, b)...max(a, b)])
    }

    /// Only suppress paired JPEGs. A JPEG-only shoot must still be importable.
    static func removingPairedJPEGs(_ urls: [URL], rawExtensions: Set<String>) -> [URL] {
        func key(_ url: URL) -> String { url.deletingPathExtension().standardizedFileURL.path.lowercased() }
        let raw = Set(urls.filter { rawExtensions.contains($0.pathExtension.lowercased()) }.map(key))
        return urls.filter {
            !(["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && raw.contains(key($0)))
        }
    }

    static func filtered(_ urls: [URL], minimumRating: Int = 0,
                         checkedOnly: Bool = false, checked: Set<URL>, ratings: [URL: Int]) -> [URL] {
        urls.filter { (ratings[$0] ?? 0) >= minimumRating && (!checkedOnly || checked.contains($0)) }
    }

    static func importURLs(_ checked: Set<URL>) -> [URL] {
        checked.sorted {
            let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
