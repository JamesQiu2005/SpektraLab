//  RawProxyName.swift — what a RAW's proxy is named by (`RawProxy`): a file and its decode, never a frame.
//
//  PRD-G §5 (2026-11-13): two frames of one RAW with one white balance — the coming variants — read one proxy,
//  so that the second is not another 2.6–2.9 GB first decode (DIAG-2026-11-13). Until then the name began with
//  the frame's id (`<frame>-<16 hex>.spkraw`), so every frame decoded its own; and the rest of the hash took only
//  the file's *name*, which the frame's id made safe and nothing else did: two `DSC00001.ARW` in two folders,
//  each a frame of its own, would — with the id gone — have read each other's pixels.
//
//  **The file's identity is its whole standardized path** (`URL.standardizedFileURL.path`), as the decoder
//  reports it (`RawExposureFacts.sourcePath`). A file moved is another proxy, made once more; a file replaced
//  in place under the same path is not seen — as it was not before. A RAW read from Photos is developed from
//  its working copy (`WorkingCopies/<frame>/<name>`), so two frames of one Photos asset keep a proxy each.
//
//  The rest is what changes the pixels: the proxy's layout (`version`), the RAW decoder this build drives
//  (`DevelopStamp.decoder`), the system's version (an update may decode a RAW differently), the decode's own
//  settings (`DecodeSettings.pixelsKey`: white balance, lens correction, the exposure treatment) and the long
//  edge it is made at. SHA-256, 128 bits of it: the name is the only key, and a collision would hand one
//  photograph another's pixels.
//
//  Foundation and CryptoKit only: the storage self-test compiles it (`tools/storage_selftest.swift`).

import CryptoKit
import Foundation

enum RawProxyName {
    /// Moved whenever the file's layout, what it holds or how it is named changes. `proxy.1` named a proxy by
    /// its frame (2.3.x and before).
    static let version = "proxy.2"

    /// `raw-<32 hex>.spkraw`.
    static func of(sourcePath: String, pixelsKey: String, longEdge: Int, decoder: String, system: String) -> String {
        let words = [version, decoder, system, sourcePath, pixelsKey, "\(longEdge)"]
        let digest = SHA256.hash(data: Data(words.joined(separator: "\u{1F}").utf8))
        return "raw-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".spkraw"
    }
}
