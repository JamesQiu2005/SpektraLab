// Recognize library documents before an import scan can mistake them for folders of pictures.
// Extension checks do not depend on Launch Services having registered a package type on this Mac.
import Foundation

enum MacLibraryDocuments {
    enum Kind { case catalog, session, captureOneCatalog, captureOneSession }

    static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "spkcatalog": return .catalog
        case "spksession": return .session
        case "cocatalog": return .captureOneCatalog
        case "cosessiondb": return .captureOneSession
        default: break
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).map { $0.lowercased() }
        if names.contains("library.spkdb") { return .catalog }
        if names.contains(where: { $0.hasSuffix(".spksession") }) { return .session }
        if names.contains(where: { $0.hasSuffix(".cocatalogdb") }) { return .captureOneCatalog }
        if names.contains(where: { $0.hasSuffix(".cosessiondb") }) { return .captureOneSession }
        return nil
    }

    /// A session database and its containing folder are one source, including duplicate-open checks.
    static func sourceURL(_ url: URL) -> URL {
        ["spksession", "cosessiondb"].contains(url.pathExtension.lowercased())
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            ? url.deletingLastPathComponent().standardizedFileURL : url.standardizedFileURL
    }
}
