//  MemoryRelease.swift — one word for "the host is short of memory", heard by everything that holds what it can
//  draw again (DIAG-2026-11-13 Part 2 item 4).
//
//  The scheduler hears the operating system — its memory-pressure source (`SchedulerSignals`, a
//  `DispatchSource`) and UIKit's memory warning — and its own watch, and asks the frontend to give back
//  its caches (`RenderQueue.onTrimCaches`, which `AppServices` answers). Until 2026-11-13 that reached only
//  the thumbnails, Develop's cards and the full-size details; everything below listened to **UIKit's
//  warning alone, or to nothing**:
//
//  | holder | held | before | now |
//  |---|---|---|---|
//  | `RenderedPictures` | the pages' develops between edits (35 MB at 2,400 px each) | documented as emptied, never emptied | emptied |
//  | `Layer2Live` | Edit's copies of the picture and their buffers | UIKit's warning only | this word too |
//  | `GamutProof` | 12 sources and their proofs | never | emptied |
//  | `MacRailPictures` | the Light Table rail's 120 pictures | when the page closes | emptied |
//  | `FilmPainter` (`FilmCanvasView`) | 8 corrected pictures, and a Core Image context caching intermediates | never | emptied, context cleared (and no longer caching) |
//
//  **Whether Mac Catalyst posts UIKit's memory warning on macOS was not established** (DIAG: inferred that it
//  does not, since `MacRenderCheck` posts one by hand). Nothing here depends on the answer: the dispatch source
//  is libdispatch's own on any Mac, and it reaches this word through the scheduler. `MacMemoryCheck` delivers a
//  warning down that very path (`SchedulerSignals.deliver`) and reads `counts` before and after, so each release
//  is seen, not assumed.

import Foundation

extension Notification.Name {
    /// The host is short of memory (`MemoryRelease.post`): whatever can be drawn again lets it go. Posted on the
    /// main actor.
    static let spkMemoryWarning = Notification.Name("spk.memoryWarning")
}

@MainActor
enum MemoryRelease {
    /// How often each holder has let go, for the check.
    private(set) static var released: [String: Int] = [:]

    /// The word, from `RenderQueue.onTrimCaches`.
    static func post() {
        RenderedPictures.shared.removeAll()
        tally("rendered_pictures")
        FilmPainter.releaseCorrected()
        NotificationCenter.default.post(name: .spkMemoryWarning, object: nil)
    }

    /// A holder has let go (called by each, as it does).
    static func tally(_ holder: String) { released[holder, default: 0] += 1 }

    /// What each holder holds now, and how often each has let go: for `MacMemoryCheck`.
    static func counts() -> [String: Int] {
        var out: [String: Int] = ["rendered_pictures_held": RenderedPictures.shared.count,
                                  "gamut_proofs_held": GamutProof.shared.keptCount,
                                  "corrected_pictures_held": FilmPainter.correctedCount]
        #if targetEnvironment(macCatalyst)
        out["rail_pictures_held"] = MacRailPictures.shared.count
        #endif
        for (holder, n) in released { out["released_" + holder] = n }
        return out
    }
}
