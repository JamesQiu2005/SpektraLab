//  Sources.swift — where the photos live, and what the app keeps of them.
//
//  design/flow, "Where the photos live" (proposed 2026-10-02). The originals
//  are never moved; what the app keeps can always be rebuilt from them.
//
//  |              | Photos            | Linked folder        | Copied in     |
//  |--------------|-------------------|----------------------|---------------|
//  | Original     | stays in Photos   | stays in the folder  | in SpektraLab |
//  | Preview copy | here              | here                 | here          |
//  | Working copy | here, while needed| here, while needed   | not needed    |
//  | Away         | iCloud: downloads | unplugged or missing | never         |
//  | Edits        | in SpektraLab     | in SpektraLab        | in SpektraLab |

import Foundation

/// A folder the user linked: a card's `DCIM`, a disk, iCloud Drive. Read in
/// place, never written to. The app keeps a bookmark and asks for access again
/// when the folder returns (`LibraryPersistence`: kept on disk with the
/// library since 2026-10-05, and resolved at the next launch).
struct LinkedFolder: Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case disk = "disk", iCloud = "iCloud", onDevice = "onDevice" }
    let id: UUID
    /// "SANDISK SSD", "iCloud Drive".
    var volume: String
    /// "DCIM", "Scans".
    var path: String
    var kind: Kind
    var frameCount: Int
    var isConnected: Bool
    /// Frames whose originals are in iCloud only.
    var stillInCloud = 0
    /// Copy the originals in, for whoever wants the disk free. Off by default.
    var keepsLocalCopy = false
    /// The way back to the folder in a later session: the operating system's security-scoped
    /// bookmark of it. Nil for the demo library's folders.
    var bookmark: Data? = nil
    /// Where the folder really is, as the Files app names it: its volume, then
    /// every folder down to it — ["SANDISK SSD", "DCIM", "100RICOH"],
    /// ["iCloud Drive", "Photos", "Scans"]. Read from the bookmark's URL at
    /// every check (`FolderReach.place`) and kept, so that a folder that is
    /// away still says where it was. Nil until a build of 2026-10-21 checked it.
    var location: [String]? = nil
    /// Why a folder that is not connected is not, where that is known; nil for
    /// a connected folder and for a disk that is simply away. Not kept: every
    /// check finds it again (`FrameCatalog.recheckFolders`).
    var lost: Lost? = nil

    enum Lost: Equatable, Sendable {
        /// Its bookmark leads nowhere: moved off its volume, or deleted.
        case notFound
        /// It is there, and the app may no longer read it.
        case accessLost
    }

    /// What the Sources rows say of a folder (2026-10-21).
    enum Status: Equatable, Sendable { case connected, notConnected, notFound, accessLost }

    var status: Status {
        if isConnected { return .connected }
        switch lost {
        case .notFound: return .notFound
        case .accessLost: return .accessLost
        case nil: return .notConnected
        }
    }

    /// "SANDISK SSD › DCIM".
    var title: String { "\(L(shown: volume)) › \(path)" }

    /// Where it is, in the app's language: "SANDISK SSD › DCIM › 100RICOH". A
    /// folder not checked yet says what it was linked as.
    var place: String {
        let parts = location ?? ([volume] + path.components(separatedBy: " › "))
        guard let first = parts.first else { return title }
        return ([L(shown: first)] + parts.dropFirst()).joined(separator: " › ")
    }

    /// Whether `frame` is one of this folder's: the same volume, and the folder's path or one under
    /// it ("DCIM › 100RICOH" under "DCIM"; `ImportService.link`).
    func holds(_ source: FrameOrigin) -> Bool {
        guard case .linkedFolder(let disk, let p) = source else { return false }
        return disk == volume && (p == path || p.hasPrefix(path + " › "))
    }
}

/// What the app keeps on the device (F5). The limits are placeholders
/// (design/flow: 5 GB of working copies, 10 GB of previews) until measured;
/// they are kept as they are set (`AppSettings`). The working copies' is held
/// (`WorkingCopies.trim`); the preview copies' clears nothing yet.
struct StorageReport: Equatable, Sendable {
    /// The only copy of shares and files copied in. Never cleared to make room.
    var copiedInOriginals: Int64
    /// How many frames those originals are, beyond the ones in the library's
    /// own list: the demo library's figure, 0 once a library is on disk.
    var copiedInFrames = 0
    /// Originals that stay in Photos, copied here while they are worked on;
    /// the oldest go first.
    var workingCopies: Int64
    var workingCopiesLimit: Int64 = 5 << 30
    /// One per frame, so editing never waits on a disk.
    var previewCopies: Int64
    var previewCopiesLimit: Int64 = 10 << 30
    /// Thumbnails and cache: rebuilt whenever needed.
    var cache: Int64

    var total: Int64 { copiedInOriginals + workingCopies + previewCopies + cache }
}
