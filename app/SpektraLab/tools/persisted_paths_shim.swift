//  persisted_paths_shim.swift — what `persisted_check` needs of `Features/Import/ImportService.swift`.
//
//  `LightTableStore.beside` names the app's folder through `ImportService.root`, and ImportService.swift
//  imports UIKit, which a plain macOS `swiftc` does not have. This stands in for it in that compile and
//  nowhere else: the storage paths only, rooted in the system's temporary folder, so a check can never
//  read or write the person's own `Application Support/<bundle id>` (AGENTS.md trap 24). The check itself
//  reads only the scratch copy it is handed.

import Foundation

struct ImportService {
    nonisolated static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("persisted-check", isDirectory: true) }
    nonisolated static var originals: URL { root.appendingPathComponent("Originals", isDirectory: true) }
    nonisolated static var previews: URL { root.appendingPathComponent("Previews", isDirectory: true) }
}
