// slider_selftest.swift — the slider's arithmetic (Sources/DesignSystem/SliderMapping.swift), 2026-11-11.
//
// A user, forwarded by the owner: "滑块有时不太准" — the slider is sometimes not where the pointer is. The knob
// must be where the pointer puts it: a press on the knob takes it where it was pressed, a press on the track
// brings it to the pointer, and after either it follows the pointer point for point, held at the ends, on the
// step, and at rest where the control has a detent.
//
//   swiftc -O -parse-as-library Sources/Model/Format.swift Sources/Model/Localization.swift \
//     Sources/DesignSystem/SliderMapping.swift tools/slider_selftest.swift -o build/tools/slider_selftest

import CoreGraphics
import Foundation

@main struct SliderCheck {
    static func main() {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

        // Brightness's shape: −100…100 on a 200 pt track, continuous, a detent at 0.
        let m = SliderMapping(range: -100...100, width: 200, rest: 0, step: nil, detentAtRest: true)

        // The knob at 40 (x = 140). A press 3 pt right of its middle takes it there: nothing jumps.
        let onKnob = m.begin(at: 143, value: 40)
        check(near(m.value(onKnob, at: 143), 40), "a press on the knob leaves the value as it was")
        // …and it follows the pointer point for point, keeping the 3 pt where it was taken.
        check(near(Double(m.x(m.value(onKnob, at: 173))), 170, 1e-6), "a knob taken follows the pointer 1:1")
        check(near(Double(m.x(m.value(onKnob, at: 63))), 60, 1e-6), "…both ways")

        // A press on the track, 100 pt from the knob: the knob comes to the pointer.
        let onTrack = m.begin(at: 40, value: 40)
        check(near(m.value(onTrack, at: 40), -60), "a press on the track puts the knob under the pointer")
        // …and stays under it as the pointer moves (absolute, not relative to the press).
        for x in stride(from: 40.0, through: 190.0, by: 15.0) where abs(x - 100) > 2.5 {   // the detent's band aside
            let v = m.value(onTrack, at: CGFloat(x))
            check(near(Double(m.x(v)), x, 1e-6), "the knob is under the pointer at x = \(x)")
        }

        // The ends hold, and the knob is back under the pointer the moment the pointer is back on the track.
        check(near(m.value(onTrack, at: 260), 100), "past the right end: the top of the range")
        check(near(m.value(onTrack, at: -80), -100), "past the left end: the bottom of the range")
        check(near(Double(m.x(m.value(onTrack, at: 180))), 180, 1e-6), "back from past the end: under the pointer again")

        // A press just outside the knob is a press on the track; just inside, the knob.
        check(near(m.value(m.begin(at: 140 + SliderMapping.grabHalfWidth + 1, value: 40), at: 140 + SliderMapping.grabHalfWidth + 1),
                   m.raw(140 + SliderMapping.grabHalfWidth + 1)), "a press just past the knob's edge moves the knob there")
        check(near(m.value(m.begin(at: 140 + SliderMapping.grabHalfWidth - 1, value: 40), at: 140 + SliderMapping.grabHalfWidth - 1), 40),
              "a press just inside the knob's edge keeps the value")

        // The detent at rest: within 1.2 % of the span the value is held at 0.
        check(m.value(onTrack, at: 101.5) == 0, "within the detent: rest")
        check(m.value(onTrack, at: 105) > 0, "past the detent: not rest")

        // A stepped control (柔光镜 强度: −3…1, step 1, five detents across 200 pt).
        let s = SliderMapping(range: -3...1, width: 200, rest: -1, step: 1, detentAtRest: true)
        let sDrag = s.begin(at: 10, value: -1)                       // on the track, far left of the knob at x 100
        check(s.value(sDrag, at: 10) == -3, "a stepped press on the track: the step under the pointer")
        check(s.value(sDrag, at: 160) == 0, "a stepped drag lands on the step nearest the pointer")
        check(s.value(sDrag, at: 199) == 1, "…and on the last step at the end")

        // The knob's own x for a value, and the value for an x, agree.
        for v in stride(from: -100.0, through: 100.0, by: 12.5) {
            check(near(m.raw(m.x(v)), v, 1e-9), "x and raw agree at \(v)")
        }

        // The number box's drag.
        var sc = SliderScrub(at: 50, value: 10)                      // Brightness: 200 over 300 pt, so 2/3 a point
        check(near(sc.value(at: 80, factor: 1, m), 30), "a scrub of 30 pt moves 20 at the normal rate")
        check(near(sc.value(at: 80, factor: 5, m), 30), "a change of rate takes up where the value is: no jump")
        check(near(sc.value(at: 83, factor: 5, m), 40), "⇧: five times the rate")
        check(near(sc.value(at: 83, factor: 0.1, m), 40), "…and back to ⌥: no jump")
        check(near(sc.value(at: 98, factor: 0.1, m), 41), "⌥: a tenth of the rate")
        var top = SliderScrub(at: 0, value: 90)
        check(top.value(at: 400, factor: 1, m) == 100, "held at the top")
        check(near(top.value(at: 397, factor: 1, m), 98), "coming back from past the top moves the value at once")
        var st = SliderScrub(at: 0, value: -1)                       // the soft filter: −3…1, step 1
        check(st.value(at: 30, factor: 1, s) == -1, "a stepped scrub stays on the step until it reaches the next")
        check(st.value(at: 60, factor: 1, s) == 0, "…then lands on it")
        check(st.value(at: -999, factor: 1, s) == -3, "…and is held at the bottom")
        // ↑ / ↓.
        check(near(SliderScrub.keyStep(10, up: true, shift: false, option: false, m), 12), "↑: one step (a 100th of ±100: 2)")
        check(near(SliderScrub.keyStep(10, up: false, shift: true, option: false, m), -10), "⇧↓: ten")
        check(near(SliderScrub.keyStep(10, up: true, shift: false, option: true, m), 10.2), "⌥↑: a tenth")
        check(near(SliderScrub.keyStep(99.5, up: true, shift: true, option: false, m), 100), "held at the top")
        let b = SliderMapping(range: -50...50, width: 200)
        check(near(SliderScrub.keyStep(25, up: true, shift: false, option: false, b), 26), "Brightness's ±50: ↑ is 1")
        let ev = SliderMapping(range: -3...3, width: 200)
        check(near(SliderScrub.keyStep(0, up: true, shift: false, option: false, ev), 0.05), "±3 EV: ↑ is 0.05")
        check(SliderScrub.nice(0.06) == 0.05 && SliderScrub.nice(2) == 2 && SliderScrub.nice(0.8) == 1, "1, 2 or 5 of a power of ten")
        check(SliderScrub.keyStep(-1, up: true, shift: false, option: true, s) == 0, "⌥ on a stepped control is still one step")
        check(SliderScrub.keyStep(-1, up: true, shift: true, option: false, s) == 1, "⇧ on a stepped control is held at the end")

        print("Slider: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
