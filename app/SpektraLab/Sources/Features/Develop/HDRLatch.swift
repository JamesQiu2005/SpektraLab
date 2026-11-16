//  HDRLatch.swift — which HDR rendition a page picture shows, and when the next one is made (issue #123, 2026-11-14).
//
//  `HDRShowing` (HDRImage.swift) is this, with the app's prepare and display pass. Its rules live here, free of
//  UIKit and Metal, so `tools/hdr_latch_selftest.swift` holds them with stand-in passes.
//
//  - **The last rendition stays while the next is made** (HDRImage.swift's "never a flash of SDR"), and **the last
//    picture asked is the one left on screen** once the passes settle. Before 2026-11-14 neither half held for every
//    order of events, and the canvas stayed on an older picture until something rebuilt the view. Compare did that:
//    it swaps the branch `DevelopCanvas.printCropped` draws, and the new `HDRImage` gets a new latch. That is what the
//    report on 2.4.0 saw ("edit 很多选项都无法立即生效，必须要点一下 compare 之类的才能够刷新": many Edit options do not
//    take effect until Compare is clicked).
//  - **A picture is matched by the picture itself (`===`), held, and never by its address.** The latch used to keep
//    `ObjectIdentifier(sdr)` and let the picture go (`HDRRendition.Prepared` copies its pixels). Layer 2 makes a new
//    `CGImage` of the same size each pass, and malloc hands a just-freed slot straight back: in a probe on this Mac a new
//    picture had the dead prepared one's address 1,994 times in 2,000. So the next edit's picture was taken for the one
//    already prepared. Its old rendition was shown and nothing was queued: the edit as it stood, often a slider's
//    release, never reached the screen. Holding the picture costs one picture, which the canvas holds anyway.
//  - **A picture already prepared is taken at once only while nothing is being made.** While another prepare is out,
//    it is queued like any other, because the one out lands after it and would cover it. That costs one prepare, only
//    when an edit goes back to a picture that is still kept.
//  - **A failed prepare or display pass shows the SDR picture**, as `HDRLook` promises ("replaced … by the SDR picture
//    where it fails"). It no longer leaves the last rendition, of an older picture, on screen.

import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class HDRLatch<Source: AnyObject, Look, Made: AnyObject, Shown> {
    /// What the latch asks of the app: the heavy pass (once a picture and a look), the light one (a screen's share),
    /// whether two looks are the same, the share a look takes on this screen now, and what it says.
    struct Passes {
        var prepare: @MainActor (Source, Look) async throws -> Made
        var display: @MainActor (Made, Double) async throws -> Shown
        var sameLook: @MainActor (Look, Look) -> Bool
        var weight: @MainActor (Look) -> Double
        var note: @MainActor (Event) -> Void = { _ in }
    }

    enum Event {
        case prepared(Source, Look, milliseconds: Int, waiting: Bool)
        case prepareFailed(Look, Error)
        case displayed(Made, weight: Double, milliseconds: Int)
        case displayFailed(Made, weight: Double, Error)
    }

    /// The rendition on screen; nil draws the SDR picture.
    private(set) var image: Shown?
    /// The look `image` was made under.
    private(set) var look: Look?
    /// Where the shown rendition sits (a full-size part's rect); nil for a whole picture.
    private(set) var place: CGRect?
    /// The picture `image` was made of (what `--edit-refresh-check` holds the canvas to).
    @ObservationIgnored private(set) var shownSource: Source?

    @ObservationIgnored private let passes: Passes
    @ObservationIgnored private var prepared: Made?
    /// The picture `prepared` was made of: held, so no other picture can have its address while it is compared.
    @ObservationIgnored private var preparedSource: Source?
    #if DEBUG
    /// `--edit-refresh-check-break address`'s: the address 2.4.0 matched by, with the picture let go.
    @ObservationIgnored private var preparedAddress: ObjectIdentifier?
    #endif
    @ObservationIgnored private var preparedLook: Look?
    @ObservationIgnored private var preparedPlace: CGRect?
    @ObservationIgnored private var showing = false
    @ObservationIgnored private var wanted: Double?
    /// One prepare at a time; while one is out only the newest picture waits, and the one out is never thrown away
    /// (2026-11-10): each one that finishes is shown, at its own place, so the canvas follows a gesture at the rate
    /// renditions are made, and the last one made is of the last picture asked.
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var next: (sdr: Source, look: Look, place: CGRect?)?
    @ObservationIgnored private var epoch = 0

    init(passes: Passes) { self.passes = passes }

    /// Ask for the rendition of `sdr` under `look` (at `place`), shown when made. Returns at once when another is
    /// being made: that one's loop takes this one next.
    func request(_ sdr: Source, look: Look, place: CGRect? = nil) async {
        if isPrepared(sdr, look) {
            if place != preparedPlace { preparedPlace = place }
            await show(weight: passes.weight(look))
            return
        }
        next = (sdr, look, place)
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        while let job = next {
            next = nil
            let mine = epoch, started = Date()
            let made: Made
            do {
                made = try await passes.prepare(job.sdr, job.look)
            } catch {
                passes.note(.prepareFailed(job.look, error))
                // What is on screen is an older picture's rendition: the SDR picture is drawn instead.
                if mine == epoch { letGo() }
                continue
            }
            guard mine == epoch else { continue }
            prepared = made; preparedSource = job.sdr; preparedLook = job.look; preparedPlace = job.place
            #if DEBUG
            if HDRLatchRules.broken == "address" { preparedAddress = ObjectIdentifier(job.sdr); preparedSource = nil }
            #endif
            self.look = job.look
            passes.note(.prepared(job.sdr, job.look, milliseconds: Self.ms(since: started), waiting: next != nil))
            await show(weight: passes.weight(job.look))
        }
    }

    /// The display pass at `weight`; the latest asked wins, one at a time.
    func show(weight: Double) async {
        wanted = weight
        guard !showing else { return }
        showing = true; defer { showing = false }
        while let w = wanted, let p = prepared {
            wanted = nil
            let at = preparedPlace, of = preparedSource
            let started = Date()
            do {
                let made = try await passes.display(p, w)
                guard prepared === p else { continue }
                image = made
                place = at
                shownSource = of
                passes.note(.displayed(p, weight: w, milliseconds: Self.ms(since: started)))
            } catch {
                passes.note(.displayFailed(p, weight: w, error))
                // Not a stale rendition in its place: the SDR picture, until a pass succeeds.
                if prepared === p { image = nil; place = nil; shownSource = nil }
            }
        }
    }

    /// Let go of everything: the picture is SDR again.
    func clear() {
        epoch &+= 1
        letGo()
        wanted = nil; next = nil
    }

    /// `sdr` under `look` is the one prepared, and may be shown at once: only while nothing else is being made, whose
    /// landing would cover it.
    private func isPrepared(_ sdr: Source, _ look: Look) -> Bool {
        guard prepared != nil, let had = preparedLook, passes.sameLook(had, look) else { return false }
        #if DEBUG
        if HDRLatchRules.broken == "address" { return preparedAddress == ObjectIdentifier(sdr) }   // 2.4.0's, while out too
        #endif
        guard !preparing, let source = preparedSource else { return false }
        return source === sdr
    }

    private func letGo() {
        image = nil; look = nil; place = nil; shownSource = nil
        prepared = nil; preparedSource = nil; preparedLook = nil; preparedPlace = nil
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }
}

#if DEBUG
/// `--edit-refresh-check-break <rule>` (`MacEditRefreshCheck`): one of 2.4.0's rules back, for the check to be red on.
/// "address": a picture matched by its address, let go once prepared, and taken at once while another is made. Nothing
/// outside a check sets it.
enum HDRLatchRules {
    nonisolated(unsafe) static var broken: String?
}
#endif
