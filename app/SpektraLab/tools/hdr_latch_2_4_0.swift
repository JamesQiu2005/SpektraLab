//  hdr_latch_2_4_0.swift — the 2.4.0 side of `tools/hdr_latch_selftest.sh --self-test`: `HDRShowing`'s rules as
//  2.4.0 shipped them (HDRImage.swift at spektralab-v2.4.0, lines 211-288), with the app's passes made hooks, exactly as
//  `Sources/Features/Develop/HDRLatch.swift` has them. Compiled **in place of** HDRLatch.swift, never beside it: the
//  self-test passes only when every case it holds is red here (issue #123).
//
//  Line for line, the only changes are the type names and the passes: `ObjectIdentifier(sdr)` kept and the picture let
//  go; the fast path taken while another prepare is out; a failed prepare or display pass leaving `image` as it was.

import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class HDRLatch<Source: AnyObject, Look, Made: AnyObject, Shown> {
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

    private(set) var image: Shown?
    private(set) var look: Look?
    private(set) var place: CGRect?
    @ObservationIgnored private let passes: Passes
    @ObservationIgnored private var prepared: Made?
    @ObservationIgnored private var preparedFor: (ObjectIdentifier, Look)?
    @ObservationIgnored private var preparedPlace: CGRect?
    @ObservationIgnored private var showing = false
    @ObservationIgnored private var wanted: Double?
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var next: (sdr: Source, look: Look, place: CGRect?)?
    @ObservationIgnored private var epoch = 0

    init(passes: Passes) { self.passes = passes }

    func request(_ sdr: Source, look: Look, place: CGRect? = nil) async {
        if let p = preparedFor, p.0 == ObjectIdentifier(sdr), passes.sameLook(p.1, look), prepared != nil {
            if place != preparedPlace { preparedPlace = place }
            await show(weight: passes.weight(look))
            return
        }
        next = (sdr, look, place)
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        while let job = next {
            next = nil
            let mine = epoch
            let made: Made
            do {
                made = try await passes.prepare(job.sdr, job.look)
            } catch {
                passes.note(.prepareFailed(job.look, error))
                continue
            }
            guard mine == epoch else { continue }
            prepared = made; preparedFor = (ObjectIdentifier(job.sdr), job.look); preparedPlace = job.place; self.look = job.look
            passes.note(.prepared(job.sdr, job.look, milliseconds: 0, waiting: next != nil))
            await show(weight: passes.weight(job.look))
        }
    }

    func show(weight: Double) async {
        wanted = weight
        guard !showing else { return }
        showing = true; defer { showing = false }
        while let w = wanted, let p = prepared {
            wanted = nil
            let at = preparedPlace
            let made = try? await passes.display(p, w)
            guard let made, prepared === p else { continue }
            image = made
            place = at
            passes.note(.displayed(p, weight: w, milliseconds: 0))
        }
    }

    func clear() {
        epoch &+= 1
        image = nil; look = nil; place = nil; prepared = nil; preparedFor = nil; preparedPlace = nil; wanted = nil; next = nil
    }
}
