//  Layer2Copies.swift — the edited picture, kept for every page that is not the develop page.
//
//  The library's tile, its top frame and Exporting's thumbnail draw a frame's kept develop (`FrameView`). Once a
//  frame carries an edit (Layer 2) they draw it edited: a copy of the kept
//  develop at its own size with the layer applied — the page's pass, the same
//  maths — written beside it under `Previews` and served where the develop is
//  served (`served`). A frame whose layer is neutral serves its develop
//  exactly as before; so does one whose copy is not made yet.
//
//  - **Made after the finger lifts.** The library changes at every step of a
//    slider; a copy is asked for half a second after the last change, never
//    for a frame whose Edit control is under a finger (`hold`), and one at a
//    time, off the main thread.
//  - **Only when nothing else runs**: no job in the scheduler and no camera
//    (`canRun`). A copy is a picture's worth of memory three times over for a
//    tenth of a second (the develop decoded, the pass's two buffers: 117 MB at
//    2,560 × 1,920), and it waits for a moment when the app holds nothing else.
//  - **Named by what it is of**: `edit-<frame>-<hash of the develop's stamp and
//    the layer's key>.heic`. A launch finds the copies still right by name and
//    takes them; any other `edit-` file is the app's own leftover and goes.
//    (`StorageTidy` does not know the name, and leaves these alone.)
//
//  Not seen on a host: its time and its memory are this Mac's in a simulator.

import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import os

@MainActor
@Observable
final class Layer2Copies {
    static let shared = Layer2Copies()

    struct Copy: Equatable, Sendable {
        var picture: PictureRef
        /// The develop's stamp the copy was made from.
        var of: String
        /// The layer it carries (`Adjustments.key`).
        var key: String
        var name: String
    }

    private(set) var copies: [UUID: Copy] = [:]
    /// Whether a copy may be made now: nothing in the scheduler, no camera. Set by the app's model.
    @ObservationIgnored var canRun: () -> Bool = { true }
    @ObservationIgnored private weak var library: FrameCatalog?
    @ObservationIgnored private var held: Set<UUID> = []
    @ObservationIgnored private var soon: Task<Void, Never>?
    @ObservationIgnored private var making: UUID?
    @ObservationIgnored private let worker = DispatchQueue(label: "com.spektralab.layer2.copies", qos: .utility)
    @ObservationIgnored private let log = Logger(subsystem: "com.spektralab.mac", category: "layer2")
    /// The last copies' times, for a check to read.
    @ObservationIgnored private(set) var lastMilliseconds: Double?

    /// The prefix every copy's file name starts with.
    nonisolated static let prefix = "edit-"

    /// What a tile draws in place of the frame's develop: its edited copy,
    /// where the frame carries an edit and the copy is of the develop it has.
    /// A copy of an older edit of the same develop stands in until the new one
    /// is made, so a tile does not go back to the unedited picture for the
    /// length of a copy. Nil everywhere else: the develop, as before.
    func served(_ frame: LibraryFrame) -> PictureRef? {
        guard frame.edit.adjustments.isActive, let copy = copies[frame.id], let developed = frame.developed,
              copy.of == developed.stamp else { return nil }
        return copy.picture
    }

    /// The library to keep copies for: watched from now on, its copies found
    /// on disk, and what is left of others swept.
    func watch(_ library: FrameCatalog) {
        self.library = library
        let names = Set(library.frames.compactMap { f -> String? in
            guard let w = wanted(f) else { return nil }
            return w.name
        })
        let folder = ImportService.previews
        worker.async {
            let swept = Self.sweep(folder, keeping: names)
            if swept > 0 { Logger(subsystem: "com.spektralab.mac", category: "layer2").info("layer 2: \(swept) edited copies no frame names went") }
        }
        track()
        reconcile()
    }

    /// A finger is on one of this frame's Edit controls: no copy until it lifts.
    func hold(_ id: UUID) { held.insert(id) }

    /// It lifted: the copy is asked for, a moment later.
    func release(_ id: UUID) {
        held.remove(id)
        reconcileSoon()
    }

    private func track() {
        guard let library else { return }
        withObservationTracking { _ = library.frames } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcileSoon()
                self?.track()
            }
        }
    }

    func reconcileSoon(after seconds: Double = 0.5) {
        soon?.cancel()
        soon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    /// What a frame's copy would be, if it is to have one.
    private func wanted(_ frame: LibraryFrame) -> (source: URL, of: String, key: String, name: String)? {
        let a = frame.edit.adjustments
        guard !frame.isDemo, a.isActive, let developed = frame.shownDevelop, let url = developed.picture.fileURL else { return nil }
        let key = key(frame.id, a)
        return (url, developed.stamp, key, Self.name(frame.id, of: developed.stamp, key: key))
    }

    /// A layer's key, kept per frame: the library changes at every step of a
    /// develop's progress, and a key is an encoding and a hash.
    @ObservationIgnored private var keys: [UUID: (layer: Adjustments, key: String)] = [:]
    private func key(_ id: UUID, _ a: Adjustments) -> String {
        if let k = keys[id], k.layer == a { return k.key }
        let k = a.key
        keys[id] = (a, k)
        return k
    }

    nonisolated static func name(_ id: UUID, of stamp: String, key: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325           // FNV-1a over the two words: a name, not a secret
        for b in (stamp + "|" + key).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return prefix + id.uuidString + "-" + String(format: "%016llx", h) + ".heic"
    }

    /// Every frame held to what it should have: a copy taken where its file is
    /// there already, one asked for where it is not, one let go where the frame
    /// no longer carries an edit.
    func reconcile() {
        guard let library else { return }
        var next: (id: UUID, source: URL, of: String, key: String, name: String, adjustments: Adjustments)?
        for frame in library.frames {
            guard let w = wanted(frame) else {
                if copies[frame.id] != nil { drop(frame.id) }
                continue
            }
            if copies[frame.id]?.name == w.name { continue }
            let url = ImportService.previews.appendingPathComponent(w.name)
            if FileManager.default.fileExists(atPath: url.path) {
                take(frame.id, Copy(picture: .file(url), of: w.of, key: w.key, name: w.name))
                continue
            }
            if next == nil, !held.contains(frame.id) {
                next = (frame.id, w.source, w.of, w.key, w.name, frame.edit.adjustments)
            }
        }
        // A frame gone from the library takes its copy with it.
        let here = Set(library.frames.map(\.id))
        for id in copies.keys where !here.contains(id) { drop(id) }
        keys = keys.filter { here.contains($0.key) }
        guard let next, making == nil else { return }
        guard canRun() else { reconcileSoon(after: 1); return }
        make(next.id, source: next.source, of: next.of, key: next.key, name: next.name, adjustments: next.adjustments)
    }

    private func make(_ id: UUID, source: URL, of stamp: String, key: String, name: String, adjustments: Adjustments) {
        making = id
        let target = ImportService.previews.appendingPathComponent(name)
        worker.async { [weak self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let outcome = Result { try autoreleasepool { try Self.write(source, adjustments, to: target) } }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            Task { @MainActor in
                guard let self else { return }
                self.making = nil
                self.lastMilliseconds = ms
                switch outcome {
                case .success:
                    // Still what the frame wants (it may have moved on meanwhile): taken. Else it goes.
                    if let frame = self.library?.frame(id), let w = self.wanted(frame), w.name == name {
                        self.take(id, Copy(picture: .file(target), of: stamp, key: key, name: name))
                        self.log.info("layer 2: an edited copy of \(Log.frame(id), privacy: .public) in \(ms, format: .fixed(precision: 0)) ms")
                    } else {
                        try? FileManager.default.removeItem(at: target)
                    }
                case .failure(let error):
                    self.log.error("layer 2: no edited copy of \(Log.frame(id), privacy: .public): \(String(describing: error), privacy: .public)")
                }
                self.reconcileSoon(after: 0.1)
            }
        }
    }

    private func take(_ id: UUID, _ copy: Copy) {
        let old = copies[id]
        copies[id] = copy
        if let old, old.name != copy.name, let url = old.picture.fileURL {
            worker.async { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func drop(_ id: UUID) {
        guard let old = copies.removeValue(forKey: id), let url = old.picture.fileURL else { return }
        worker.async { try? FileManager.default.removeItem(at: url) }
    }

    /// The develop at `source`, with the layer, written to `target`: HEIF where
    /// this system writes it, Display P3, its profile in the file — as a kept
    /// develop is written (`EngineHost.write`). Any thread.
    nonisolated static func write(_ source: URL, _ adjustments: Adjustments, to target: URL) throws {
        guard let renderer = Layer2Renderer.shared else { throw Layer2Kernel.Failure.noDevice }
        guard let file = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(file, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Layer2Renderer.Failure.picture("the develop could not be read")
        }
        let picture = try renderer.source(image)
        let (made, _) = try renderer.image(picture, adjustments)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent)
        for type in [UTType.heic, UTType.jpeg] {
            guard let dest = CGImageDestinationCreateWithURL(partial as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, made, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            if CGImageDestinationFinalize(dest) {
                _ = try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
                return
            }
            try? FileManager.default.removeItem(at: partial)
        }
        throw Layer2Renderer.Failure.picture("the edited copy could not be written")
    }

    /// The `edit-` files in `folder` no frame names go. Returns how many.
    nonisolated static func sweep(_ folder: URL, keeping: Set<String>) -> Int {
        guard let all = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var gone = 0
        for name in all where (name.hasPrefix(prefix) || name.hasPrefix("." + prefix)) && !keeping.contains(name) {
            if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))) != nil { gone += 1 }
        }
        return gone
    }
}
