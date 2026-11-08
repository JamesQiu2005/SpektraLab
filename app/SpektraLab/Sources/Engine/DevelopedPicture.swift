//  DevelopedPicture.swift — a frame's develop, kept.
//
//  The owner's flow, step 4 (2026-10-03): "what has been developed is kept and
//  read back." A frame's own develop — a shot's, an import's, the one the
//  develop page leaves behind — is written beside the preview copies as a
//  picture in Display P3, and the library and Exporting's thumbnail read
//  that file. Nothing is developed again to draw a
//  tile.
//
//  **The stamp is what the picture was made from**: the whole wire, the decode
//  settings, the decoder, and the engine's own identity — its effect versions,
//  because two engines that differ there render different pictures from the
//  same settings (API-SPEC §14), and the commit its sources were built at. A
//  frame whose stamp is not the one its edit would make today is stale: it is
//  shown as it is, and developed again in the queue.
//
//  The stamp is in the file's name too, because the page's picture cache keys
//  by path: a new develop under an old name would be served stale.

import CryptoKit
import Foundation

struct DevelopedPicture: Codable, Equatable, Sendable {
    /// The file under `Previews`. Already cut: drawn as it is.
    var picture: PictureRef
    var size: PixelSize
    var stamp: String
}

/// **A develop whose file is missing** (the review of catalog-kept previews, 2026-11-05). A frame's
/// develop is more than its file on the Mac: that SpektraLab developed it is the Light Table's rule for
/// laying it down (`MacLightTableCarry.takes`), and its size is the shape a film edge's canvas is drawn in
/// (`MacShownFrame.aspect`). So when the file goes (Settings' *Delete Previews*, a catalog's `Cache`
/// deleted, the same on another Mac) the develop is kept with its size, and only its stamp is marked:
/// no stamp a frame's edit makes ever equals a marked one, so every place that asks "is the kept develop
/// the one this edit makes?" (`OpenFrameSession.close`, Export's `want`, the table's `tableWants`) develops it
/// again, and every place that draws it (`FrameView`, the Light Table's `source`) draws the camera's
/// preview, as for a frame with no develop, until the new one lands.
extension DevelopedPicture {
    static let missingMark = "missing:"

    var isMissing: Bool { stamp.hasPrefix(Self.missingMark) }

    /// The same develop, its file known to be gone. The stamp it had is kept after the mark, for the log.
    var markedMissing: DevelopedPicture {
        isMissing ? self : DevelopedPicture(picture: picture, size: size, stamp: Self.missingMark + stamp)
    }
}

extension LibraryFrame {
    /// The kept develop there is a picture of to draw: nil for none, and for one whose file is missing.
    var shownDevelop: DevelopedPicture? { developed.flatMap { $0.isMissing ? nil : $0 } }
}

enum DevelopStamp {
    /// The app's own decode, as a word: moved whenever the way a file is
    /// turned into the engine's frame changes (the look, the working space,
    /// the scaling), so pictures made the old way are developed again.
    static let decoder = "decode.1"

    /// `engine` is `EngineIdentity.stamp`: the effect versions and the commit.
    /// `cut` and `turns` are the host's own work on either side of the engine
    /// — a film edge's framing, cut from the decode before the engine sees it
    /// (`FrameEdit.hostCut`), and the film's half turn given to the canvas
    /// afterwards (`FrameEdit.hostTurns`): not on the wire, and part of the
    /// picture. A frame with no film edge has neither, and its stamp is what
    /// it always was. `piece` is a half-frame pair's frame as the host lays
    /// it out (`PieceAsk.key`): which pictures, each one's own decode and cut,
    /// where each sits under its hole and how it is exposed. `origin` is a
    /// word for where the file read came from, where that is part of what the
    /// picture is (`LibraryFrame.stampOrigin`); nil for every frame whose
    /// stamp is what it always was. `prints` are a pair's frames that print
    /// as their own (`PrintLayer.key`): not on the wire, which is the film's
    /// print, and part of the picture — a frame's print changed is another
    /// picture. A piece that is one print has none, and its stamp is what it
    /// was.
    static func of(wire: [String: ParamValue], cut: Geometry? = nil, turns: Int = 0, decode: DecodeSettings, isRAW: Bool,
                   longEdge: Int, engine: String, piece: String? = nil, origin: String? = nil,
                   prints: [String] = []) -> String {
        var hash = SHA256()
        func add(_ s: String) { hash.update(data: Data(s.utf8)); hash.update(data: Data([0])) }
        add(engine)
        add(decoder)
        add("\(longEdge)")
        if let cut { add("cut " + cut.cutKey) }
        if turns != 0 { add("turned \(turns)") }
        if let piece { add(piece) }
        if let origin { add("from " + origin) }
        for own in prints { add(own) }
        // The decode's settings change a RAW's pixels and nothing else's.
        if isRAW {
            add(decode.whiteBalance.rawValue)
            if decode.whiteBalance != .asShot { add("\(decode.temperature)|\(decode.tint)") }
            add(decode.lensCorrection ? "lens" : "")
            if !decode.exposureKey.isEmpty { add(decode.exposureKey) }
        }
        // A frame with no Decode curve is stamped as it was before the field existed.
        for key in wire.keys.sorted() where !(key == "scene_curve" && wire[key] == .string("")) {
            add(key + "=" + (wire[key]?.description ?? ""))
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension ImportService {
    /// Where a frame's develop is kept: `<folder>/dev-<frame>-<stamp>.<ext>`, the folder its library's
    /// previews (`LibraryPreviews.folders`, the Mac's catalogs and sessions, 2026-11-05) or the app's `Previews`.
    nonisolated static func developedURL(frameID: UUID, stamp: String, fileExtension: String, in folder: URL = previews) -> URL {
        folder.appendingPathComponent("dev-\(frameID.uuidString)-\(stamp).\(fileExtension)")
    }

    /// A develop that has been replaced, or whose frame is gone. Only a file
    /// under the app's own `Previews`, or a kept develop in a library's
    /// previews folder (`LibraryPreviews.isDiscardable`): never anything else
    /// of a catalog or a session.
    nonisolated static func discard(_ developed: DevelopedPicture?) {
        guard let url = developed?.picture.fileURL, LibraryPreviews.isDiscardable(url, appPreviews: previews) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
