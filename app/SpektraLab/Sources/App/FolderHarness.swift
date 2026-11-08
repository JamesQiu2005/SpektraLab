//  FolderHarness.swift — a debug build's way to link and reconnect folders from a Mac (2026-10-21).
//
//  A folder is linked by its path, without driving the system's folder picker:
//
//  - `--link-folder <path> …`: each folder linked at launch as *Link a Folder* links it, unless a
//    folder of that name is linked already (a second launch adds nothing);
//  - `--reconnect-folder <path>`: the first linked folder reconnected to `<path>`, as *Reconnect…*
//    does with the folder picked.
//
//  Both need `--library real`. What came of them is in the library's own
//  file (`Application Support/SpektraLab/library.json`: each folder's `location`, each frame's state).

#if DEBUG
import Foundation

@MainActor
enum FolderHarness {
    static func run(_ model: AppServices, arguments: [String]) {
        let link = paths(after: "--link-folder", in: arguments)
        let reconnect = paths(after: "--reconnect-folder", in: arguments).first
        guard !link.isEmpty || reconnect != nil else { return }
        Task {
            for path in link {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                guard !model.library.linkedFolders.contains(where: { $0.path == url.lastPathComponent }) else { continue }
                let n = await ImportService(model: model).link(folder: url)
                NSLog("[folders] linked %@: %d frames", url.lastPathComponent, n)
            }
            if let reconnect, let folder = model.library.linkedFolders.first {
                let result = await ImportService(model: model).reconnect(folder.id, to: URL(fileURLWithPath: reconnect, isDirectory: true))
                NSLog("[folders] reconnect %@ -> %@: %@", folder.title, reconnect, String(describing: result))
            }
        }
    }

    private static func paths(after flag: String, in arguments: [String]) -> [String] {
        guard let i = arguments.firstIndex(of: flag) else { return [] }
        return Array(arguments[(i + 1)...].prefix { !$0.hasPrefix("--") })
    }
}
#endif
