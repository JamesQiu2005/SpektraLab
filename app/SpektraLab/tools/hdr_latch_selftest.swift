// hdr_latch_selftest.swift -- the canvas left on an older picture (issue #123, 2026-11-14): `HDRLatch`, the rules of
// the HDR rendition a page picture shows (Sources/Features/Develop/HDRLatch.swift), and `Layer2DisplaySizes`, the sizes
// Edit's live picture is drawn at (Sources/Engine/Layer2DisplaySizes.swift). Stand-in passes, no GPU and no UIKit.
//
//   tools/hdr_latch_selftest.sh               this tree's rules: every case passes
//   tools/hdr_latch_selftest.sh --self-test   also built on 2.4.0's rules (tools/hdr_latch_2_4_0.swift,
//                                             tools/layer2_display_2_4_0.swift): every case marked HELD must fail there,
//                                             and every CONTROL must pass on both
//
// Each line is `ok    <id>` or `FAIL  <id>: …`; the script reads the ids.

import CoreGraphics
import Foundation

/// A page picture: a small object, made anew for each pass as Layer 2 makes a `CGImage`, so malloc can hand a freed
/// one's slot straight back.
final class Pic { let n: Int; init(_ n: Int) { self.n = n } }
/// A rendition made ready: of a picture's number, never holding the picture (`HDRRendition.Prepared` copies pixels).
final class Made { let n: Int; init(_ n: Int) { self.n = n } }
struct Look: Equatable { var curve = "c" }
struct Fail: Error {}

/// Holds a pass until released, to put an edit in while one is out.
@MainActor final class Gate {
    var open = true
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func pass() async {
        if open { await Task.yield(); return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        let w = waiting; waiting = []
        w.forEach { $0.resume() }
    }
}

@MainActor final class Bench {
    let gate = Gate()
    var prepares = 0
    var failPrepare = false
    var failDisplay = false
    lazy var latch = HDRLatch<Pic, Look, Made, String>(passes: .init(
        prepare: { [unowned self] pic, _ in
            let n = pic.n
            self.prepares += 1
            await self.gate.pass()
            if self.failPrepare { throw Fail() }
            return Made(n)
        },
        display: { [unowned self] made, w in
            await Task.yield()
            if self.failDisplay { throw Fail() }
            return "r\(made.n)@\(w)"
        },
        sameLook: { $0 == $1 },
        weight: { _ in 1 }))

    /// The rendition on screen, as the picture number it is of (nil: the SDR picture is drawn).
    var shownNumber: Int? {
        guard let s = latch.image else { return nil }
        return Int(s.dropFirst().prefix { $0 != "@" })
    }
}

@MainActor func until(_ what: () -> Bool) async -> Bool {
    for _ in 0..<10_000 { if what() { return true }; await Task.yield() }
    return what()
}

@main struct HDRLatchSelftest {
    @MainActor static func main() async {
        var failed = 0
        func check(_ id: String, _ ok: Bool, _ why: @autoclosure () -> String) {
            if ok { print("ok    \(id)") } else { failed += 1; print("FAIL  \(id): \(why())") }
        }

        // HELD 1. A new picture is never taken for a dead one at its address. Each edit's picture is made after the
        // last is let go, as Layer 2's are; 2.4.0 kept only the address, and showed the old rendition for most of them.
        do {
            let b = Bench()
            var behind = 0, first: Int?
            for k in 0..<500 {
                let p = Pic(k)
                await b.latch.request(p, look: Look())
                if b.shownNumber != k { behind += 1; if first == nil { first = k } }
            }
            check("held-address", behind == 0 && b.prepares == 500,
                  "\(behind) of 500 edits left an older picture on screen (first at edit \(first ?? -1)), \(b.prepares) prepares")
        }

        // HELD 2. An edit back to a picture still kept, made while another is being made, is not covered when that one
        // lands: the last picture asked is the one left on screen.
        do {
            let b = Bench()
            let a = Pic(1), c = Pic(2)
            await b.latch.request(a, look: Look())
            b.gate.open = false
            let t1 = Task { await b.latch.request(c, look: Look()) }
            _ = await until { b.gate.count == 1 }
            let t2 = Task { await b.latch.request(a, look: Look()) }
            for _ in 0..<50 { await Task.yield() }
            b.gate.release()
            await t1.value; await t2.value
            _ = await until { b.gate.count == 0 && b.shownNumber == 1 }
            check("held-back-while-out", b.shownNumber == 1,
                  "asked 1, 2, then 1 while 2 was out: picture \(b.shownNumber.map(String.init) ?? "SDR") is on screen")
        }

        // HELD 3. A failed prepare shows the SDR picture, never the last rendition, of an older picture.
        do {
            let b = Bench()
            await b.latch.request(Pic(1), look: Look())
            b.failPrepare = true
            let c = Pic(2)
            await b.latch.request(c, look: Look())
            check("held-prepare-fails", b.latch.image == nil,
                  "picture 2's prepare failed and picture \(b.shownNumber ?? -1)'s rendition is still on screen")
        }

        // HELD 4. A failed display pass of a new picture shows the SDR picture too.
        do {
            let b = Bench()
            await b.latch.request(Pic(1), look: Look())
            b.failDisplay = true
            let c = Pic(2)
            await b.latch.request(c, look: Look())
            check("held-display-fails", b.latch.image == nil,
                  "picture 2's display pass failed and picture \(b.shownNumber ?? -1)'s rendition is still on screen")
        }

        // CONTROL 5. A burst while one is made still ends on the last, in two prepares: the fix keeps the coalescing.
        do {
            let b = Bench()
            b.gate.open = false
            let pics = (0...50).map(Pic.init)
            let t0 = Task { await b.latch.request(pics[0], look: Look()) }
            _ = await until { b.gate.count == 1 }
            var tasks: [Task<Void, Never>] = []
            for k in 1...50 { tasks.append(Task { await b.latch.request(pics[k], look: Look()) }) }
            for t in tasks { await t.value }
            b.gate.release()
            await t0.value
            _ = await until { b.shownNumber == 50 }
            check("control-burst", b.shownNumber == 50 && b.prepares == 2,
                  "after 51 pictures: \(b.shownNumber.map(String.init) ?? "SDR") on screen, \(b.prepares) prepares (want 50, 2)")
        }

        // CONTROL 6. Cleared while one is made: nothing is shown when it lands.
        do {
            let b = Bench()
            b.gate.open = false
            let p = Pic(1)
            let t = Task { await b.latch.request(p, look: Look()) }
            _ = await until { b.gate.count == 1 }
            b.latch.clear()
            b.gate.release()
            await t.value
            check("control-clear", b.latch.image == nil, "a rendition was shown after clear()")
        }

        // CONTROL 7. The same picture asked again while nothing is made is shown at once, with no new prepare.
        do {
            let b = Bench()
            let p = Pic(1)
            await b.latch.request(p, look: Look())
            await b.latch.request(p, look: Look())
            check("control-same-again", b.prepares == 1 && b.shownNumber == 1, "\(b.prepares) prepares for one picture asked twice")
        }

        // HELD 8. The crop screen's picture closing does not take the size from the canvas still on screen.
        do {
            var s = Layer2DisplaySizes()
            s.set("canvas", maxPixel: 1600)
            s.set("crop", maxPixel: 1216)
            s.set("crop", maxPixel: nil)
            check("held-crop-closes", s.maxPixel == 1600, "the canvas draws at 1600 and the pass is made at \(s.maxPixel.map(String.init) ?? "none")")
        }

        // HELD 9. A view swapped for a new one (Compare): the new one appearing before the old one disappears.
        do {
            var s = Layer2DisplaySizes()
            s.set("old", maxPixel: 1600)
            s.set("new", maxPixel: 1600)
            s.set("old", maxPixel: nil)
            check("held-swap-order", s.maxPixel == 1600, "after the swap the pass is made at \(s.maxPixel.map(String.init) ?? "none")")
        }

        // CONTROL 11. A check's pinned size wins over a larger picture's, as a check's word won in 2.4.0: the in-app
        // checks wait for a pass at exactly their width (masks_check's identity cases went red without it).
        do {
            var s = Layer2DisplaySizes()
            s.set("canvas", maxPixel: 2432)
            s.pin(1600)
            check("control-check-pins", s.maxPixel == 1600, "pinned 1600 over the canvas's 2432: \(s.maxPixel.map(String.init) ?? "none")")
        }

        // CONTROL 10. Every picture gone: no picture is made; and the largest drawn wins while two draw.
        do {
            var s = Layer2DisplaySizes()
            s.set("a", maxPixel: 1600); s.set("b", maxPixel: 2432)
            let both = s.maxPixel
            s.set("b", maxPixel: nil); s.set("a", maxPixel: nil)
            check("control-sizes", both == 2432 && s.maxPixel == nil, "two drawn: \(both ?? -1); none drawn: \(s.maxPixel ?? -1)")
        }

        print(failed == 0 ? "hdr latch: 11 passed, 0 failed" : "hdr latch: \(11 - failed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
