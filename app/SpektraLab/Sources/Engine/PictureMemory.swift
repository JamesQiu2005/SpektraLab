//  PictureMemory.swift — which pictures are made over memory their maker holds, and may be written into.
//
//  A `CGImage` says nothing of its bytes: its provider may hand over the memory it was made on, or a cached copy that is
//  not to be written (measured on a Mac, 2026-11-13: a cut picture's bytes are such a copy, and writing them is a
//  fault). So the makers that own a picture's memory say so here — the output transform's buffer, Layer 2's passes and
//  its export, the host's turn — and a pass that draws into a picture in place (水印's 成片 marks, `WatermarkComposite`)
//  asks. A picture nobody spoke for is never written into: it is copied once.
//
//  Held weakly; the last few. Any thread. No dependencies, so any check that compiles a maker compiles this.

import CoreGraphics
import Foundation

enum PictureMemory {
    private final class Own {
        weak var image: CGImage?
        let bytes: UnsafeMutableRawPointer
        init(_ image: CGImage, _ bytes: UnsafeMutableRawPointer) { self.image = image; self.bytes = bytes }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var owned: [Own] = []

    /// `image` is made over `bytes`, which its maker holds for as long as it lives and which may be written.
    static func owns(_ image: CGImage, bytes: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        owned.removeAll { $0.image == nil }
        owned.append(Own(image, bytes))
        if owned.count > 16 { owned.removeFirst(owned.count - 16) }
    }

    /// The picture's own bytes, where its maker said them; nil for any other picture.
    static func bytes(of image: CGImage) -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        return owned.first { $0.image === image }?.bytes
    }
}
