//  LibraryFrame.swift — one photograph in the library, and where its original is.
//
//  Three sources, the same on reference device and window (design/flow, "Where the photos
//  live"): Photos, read where it is; a linked folder, read where it is; and
//  files copied in, which are the app's own. Whatever the source, the app
//  keeps the edit and a **preview copy**, so browsing and editing never wait
//  on a RAW decode or a disk, and keep working while the disk is gone.

import CoreGraphics
import Foundation

/// Where a frame came from. (`FrameSource` is the engine adapter's word for its host —
/// `SpkEngine.swift` — so this is the frame's *origin*.)
enum FrameOrigin: Codable, Equatable, Sendable {
    /// The keys as they are written: a case's name and its labels are keys, and must not move with a rename.
    enum CodingKeys: String, CodingKey { case photos = "photos", linkedFolder = "linkedFolder", copiedIn = "copiedIn" }
    enum LinkedFolderCodingKeys: String, CodingKey { case disk = "disk", path = "path" }
    /// In the Photos library, read in place.
    case photos
    /// In a folder the user linked: a card, a disk, iCloud Drive. `disk` is the
    /// volume's name ("SANDISK SSD") and `path` the folder under it.
    case linkedFolder(disk: String, path: String)
    /// Copied into the app: a share, an AirDrop, *Copy files in*, a shot, or a
    /// photo picked from Photos whose original the app keeps (`assetIdentifier`
    /// still set: Settings › Sources › *Keep Originals in Spek*).
    case copiedIn

    /// Info's *Original* row.
    var whereText: String {
        switch self {
        case .photos: L("In Photos")
        case .linkedFolder(let disk, let path): "\(L(shown: disk)) › \(path)"
        case .copiedIn: L("In SpektraLab")
        }
    }

    /// Info's *Kept here* row.
    var keptText: String {
        switch self {
        case .photos, .linkedFolder: L("The edit and a preview copy")
        case .copiedIn: L("The original, the edit, a preview copy")
        }
    }
}

/// Whether the original can be read right now. The preview copy and the edit
/// are kept either way.
enum OriginalState: Codable, Equatable, Sendable {
    /// The keys as they are written: a case's name and its labels are keys, and must not move with a rename.
    enum CodingKeys: String, CodingKey {
        case available = "available", offline = "offline", missing = "missing", inCloud = "inCloud"
    }
    enum OfflineCodingKeys: String, CodingKey { case disk = "disk" }
    case available
    /// Its disk is unplugged: previews still edit; 12 MP and full size wait.
    case offline(disk: String)
    /// Moved, renamed or deleted: find the file or its folder, or remove it.
    case missing
    /// In iCloud only: downloads when needed, with progress.
    case inCloud

    var isAvailable: Bool { self == .available }
}

/// What the page draws for a frame: a bundled demo picture, a picture on
/// disk, or a develop just made and still in memory.
enum PictureRef: Codable, Equatable, Hashable, Sendable {
    case sample(String)
    case file(URL)
    /// A develop the engine has just handed over, held by the page that asked
    /// for it (`RenderedPictures`): the develop page's canvas between edits.
    /// Never kept in a frame and never written — a frame's kept develop is a
    /// file (`DevelopedPicture`).
    case rendered(UUID)

    var fileURL: URL? { if case .file(let url) = self { url } else { nil } }
}

/// Where a frame is in the one develop queue (shots, imports and exports share
/// it). The library tile reads this.
enum DevelopState: Equatable, Sendable {
    /// Done: the tile has no ring.
    case developed
    /// In the queue: a dim tile with an empty ring.
    case queued
    /// Under way: the accent ring.
    case developing(progress: Double)
    /// It cannot run yet, and says why (RFC-036 §3.5).
    case waiting(WaitReason)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .developed, .failed: false
        case .queued, .developing, .waiting: true
        }
    }
}

struct LibraryFrame: Identifiable, Equatable, Sendable {
    typealias ID = UUID
    let id: ID
    /// The original's own name: "_DSC0061.NEF".
    var fileName: String
    var captureDate: Date
    /// "NIKON Z 7_2", as the file's metadata has it.
    var camera: String?
    /// "1/250 s · f/5.6 · ISO 100".
    var exposure: String?
    /// The original's size. Full size is made by Export, and by the develop page zoomed past its preview (`FullRender`).
    var originalSize: PixelSize
    /// The preview copy's: what every page shows and edits.
    var previewSize: PixelSize
    /// RAW or DNG. A JPEG or HEIC comes in already developed by its camera, so
    /// the film starts from that picture, not from RAW — and says so.
    var isRAW: Bool
    var source: FrameOrigin
    var original: OriginalState = .available
    /// For a frame read in place from Photos: the asset's own identifier, the
    /// way back to its original, which is fetched into the working copies
    /// whenever something is about to read it (`Originals`). The preview copy
    /// is all the app keeps of the picture itself. For a photo whose original
    /// the app keeps (`cameFromPhotos`), where it came from: nothing is asked
    /// of Photos through it. Nil for every other source.
    var assetIdentifier: String? = nil
    var picture: PictureRef
    /// The frame as decoded, before any film: what *Original* shows on the
    /// develop page. Nil when there is none to show (this build has one only
    /// for the demo frame whose undeveloped scene is in `design/src`).
    var originalPicture: PictureRef? = nil
    /// The frame's develop, kept on disk: what every page shows once the
    /// engine has developed it. Nil until then, and where there is no engine.
    var developed: DevelopedPicture? = nil
    var develop: DevelopState = .developed
    var isFavourite = false
    var edit = FrameEdit.default
    var importedAt: Date
    /// **A half-frame pair** (`HalfFramePair`): this item is a piece of film
    /// with two of the library's frames on it, not a photograph. Its `edit` is
    /// the pair's own look — one film, one paper, one enlarger; `originalSize`
    /// is the piece at the size neither picture is enlarged in; `picture` is a
    /// guide made of the two frames' own previews, shown until the engine has
    /// developed the piece. Everything after the decode — the develop page,
    /// the queue, the kept develop, an export — handles it as it handles a
    /// frame, which is the desktop's way (`Import/PairComposer`); the decode
    /// itself is the host's composing (`EngineRouter`, `PairDevelop.swift`).
    /// Nil for a photograph.
    var pair: HalfFramePair? = nil
    /// Shot by the host app's camera; kept as the library file has it (this app sets it on
    /// nothing). Nil for anything brought in.
    var shotHere: Bool? = nil
    /// The crop a camera wrote into its DNG (`CameraCrop`) has been read for this frame — taken as its
    /// first crop, found to be none, or passed over because the frame's crops were already edited — and
    /// is never taken again: a Reset to the whole picture stays the whole picture. Set as a frame is made
    /// (`ImportService.frame`). Nil for a frame made before 2026-11-05 until the launch's catch-up has
    /// read its file (`AppServices.holdCameraCrops`), and for a frame that file has not been readable for.
    var cameraCropRead: Bool? = nil

    /// "_DSC0061": the name without its extension, for Export's title and the
    /// exported file.
    var stem: String { (fileName as NSString).deletingPathExtension }

    var isPair: Bool { pair != nil }

    /// Picked from the Photos library: read where it is there, or its original
    /// kept in the app (2026-10-21) — which Photos may then delete without the
    /// frame missing anything.
    var cameFromPhotos: Bool { source == .photos || (source == .copiedIn && assetIdentifier != nil) }

    /// One of the drawings' own frames: a picture SpektraLab really developed,
    /// bundled with the app, and never sent to the engine (it would be a print
    /// of a print). Any other frame shows its own develop once it has one, and
    /// its camera's preview until then — and says which.
    var isDemo: Bool { if case .sample = picture { true } else { false } }

    /// The file the engine develops from, when the frame has one to read: the
    /// original — for a frame read in place from Photos, whose original stays
    /// there, its working copy (`Originals`). That is one path whether the
    /// copy is here at the moment or not: whoever hands it to the engine
    /// brings the original first (`EngineRouter.bring`).
    var developSource: URL? {
        guard !isDemo, original.isAvailable else { return nil }
        return readsFromPhotos ? workingCopy : picture.fileURL
    }

    /// The cut of the picture that is shown and developed: Film Edge's own
    /// framing while a film edge is on (the photo's crop is kept beside it and
    /// returns when the film goes), the photo's crop otherwise.
    var pictureGeometry: Geometry {
        guard edit.filmEdge.effective else { return edit.geometry }
        return FilmFraming.resolved(edit.filmEdge, source: CGSize(width: originalSize.width, height: originalSize.height),
                                    photo: edit.geometry)
    }

    /// The picture's shape as it is shown and exported: the cut, then the
    /// quarter turns. (In its film, a frame's file is the film's canvas, which
    /// only the layout can size: `AppServices.filmEdge(for:)`.)
    var displaySize: PixelSize {
        let out = pictureGeometry.outputSize(for: CGSize(width: originalSize.width, height: originalSize.height))
        return PixelSize(width: Int(out.width), height: Int(out.height))
    }
    var displayAspect: Double { displaySize.aspect }
}
