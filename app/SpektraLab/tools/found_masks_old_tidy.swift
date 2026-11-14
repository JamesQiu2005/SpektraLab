//  found_masks_old_tidy.swift — 2.3.2's own launch tidy and *Clear Working Copies* (its `WorkingCopies.swift` and
//  `StorageTidy.swift` at release commit 88685135, `git show`n and compiled apart by found_mask_selftest.sh) run over a
//  library root that holds `Masks/<frame>/<asset>.spkmask` and `layers.json`: both are left as they were. With
//  `git grep` of 88685135 (no other `removeItem` or directory walk of the root, FoundMaskFiles' note), this is the
//  proof that a 2.3.x build opening a 2.4 library does not take its found masks.

import Foundation

@main struct OldTidy {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("found-masks-old-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = UUID()
        let masks = root.appendingPathComponent("Masks/\(frame.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        let file = masks.appendingPathComponent(String(repeating: "c", count: 32) + ".spkmask")
        try? Data("a found mask".utf8).write(to: file)
        try? Data("{}".utf8).write(to: root.appendingPathComponent("layers.json"))
        let previews = root.appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: StorageTidy.cardsFolder(in: previews), withIntermediateDirectories: true)
        // The launch's tidy as 2.3.2 runs it (`AppServices.tidyStorage`), with a library that has no frame at all —
        // the widest it can sweep — then Clear Working Copies.
        let copies = WorkingCopies(folder: root.appendingPathComponent("WorkingCopies", isDirectory: true), limit: 1)
        copies.sweep(known: [])
        StorageTidy.sweep(previews, keeping: [], now: Date().addingTimeInterval(1e7), age: 0)
        StorageTidy.sweepCards(StorageTidy.cardsFolder(in: previews), keepingFrames: [])
        copies.clear()
        let ok = (try? Data(contentsOf: file)) == Data("a found mask".utf8) && FileManager.default.fileExists(atPath: root.appendingPathComponent("layers.json").path)
        print(ok ? "ok    2.3.2's launch tidy and Clear Working Copies leave Masks/ and layers.json as they were"
                 : "FAIL  2.3.2's tidy took a found mask")
        exit(ok ? 0 : 1)
    }
}
