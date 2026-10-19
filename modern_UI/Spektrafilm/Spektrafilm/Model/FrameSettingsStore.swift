//  FrameSettingsStore.swift — where the open frames' settings are kept.
//
//  `Session` read and wrote a frame's settings through `Sidecar.load(for:)`
//  and `sidecar.save(for:)` directly, a dozen times over. 2.0 adds a second
//  home for them — a library's edits, one per variant, kept by the library
//  helper with a revision — and this is the one seam between the two:
//
//  * **A folder** (Open…, a drop, Finder's Open With) uses `SidecarFileStore`,
//    which *is* the 1.x calls, unchanged: the same files in Application
//    Support, the same migration, the same timing. `Session.open(urls:)` puts
//    it back every time, so nothing a folder does can reach a library.
//  * **Frames handed over by the Library** use `LibrarySettingsStore`
//    (`Library/`), which answers from the library for the files it maps and
//    falls back to the sidecar files for anything else — a half-frame pair,
//    or a file dropped on the strip.
//
//  The contract both keep, and the reason `isReady` exists: `load(for:)`
//  returns **the truth or nothing**. `Session.select` saves the frame it is
//  leaving (`flushSave`) with whatever it loaded, so a store that answered
//  "no settings" for a frame whose edit simply had not arrived yet would have
//  that frame's real edit overwritten with defaults on the next frame switch.
//  A library's edit arrives over a pipe; until it has, `isReady` is false and
//  `Session` waits for `fetch` rather than guessing.

import Foundation

@MainActor
protocol FrameSettingsStore: AnyObject {
    /// Whether `load(for:)` can answer for `url` now, without waiting.
    func isReady(_ url: URL) -> Bool
    /// Make `load(for:)` ready for these frames. Returns when it is, or when
    /// it has failed; `isReady` says which.
    func fetch(_ urls: [URL]) async
    /// The frame's settings, or nil for a frame that has none.
    func load(for url: URL) -> Sidecar?
    func save(_ sidecar: Sidecar, for url: URL) throws
    /// The frame's settings removed — a reset. Once this returns, `load`
    /// answers with none for a frame the store holds: the Film menu's reset
    /// reopens the frame at once, and must not reopen it on the old edit.
    func remove(for url: URL)
    /// The frame on the canvas: kept ready while it is open.
    func pin(_ url: URL?)
    /// Every write handed to the store has reached its home.
    func flush() async
    /// Which developed pictures are this frame's (`DevelopedThumbnails`):
    /// nil for the 1.x sidecar files, and a library variant for a library
    /// frame — so a file developed as a folder frame and in a library, or in
    /// two variants, keeps a picture of each and shows the right one.
    func pictureScope(for url: URL) -> String?
}

/// The 1.x store: one sidecar file per frame in Application Support
/// (AGENTS.md trap 35). Every method is the call `Session` used to make
/// itself, so a folder behaves exactly as it did before libraries existed.
@MainActor
final class SidecarFileStore: FrameSettingsStore {
    static let shared = SidecarFileStore()

    func isReady(_ url: URL) -> Bool { true }
    func fetch(_ urls: [URL]) async {}
    func load(for url: URL) -> Sidecar? { Sidecar.load(for: url) }
    func save(_ sidecar: Sidecar, for url: URL) throws { try sidecar.save(for: url) }
    func remove(for url: URL) { Sidecar.remove(for: url) }
    func pin(_ url: URL?) {}
    func flush() async {}
    func pictureScope(for url: URL) -> String? { nil }
}

/// What the editor was handed its frames by.
enum FrameSource: Equatable, Sendable {
    /// A folder or files: 1.x's "the folder is the session".
    case folder
    /// A library's current result, from the Library.
    case library(LibrarySourceSummary)

    var isLibrary: Bool { if case .library = self { true } else { false } }
}

/// The few facts about a library the editor shows or obeys.
struct LibrarySourceSummary: Equatable, Sendable {
    /// "Capture One Catalog", "Portfolio", "Shoot 2026-10-18".
    var name: String
    /// The collection the frames came from: "All Images", an album.
    var collection: String
    /// A linked Capture One catalog: nothing is written beside its originals.
    var readOnly: Bool
}
