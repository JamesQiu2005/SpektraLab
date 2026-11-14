//  SliderProbe.swift — a debug build's measurement of a slider drag (the feel round, 2026-11-11).
//
//      SPK_SLIDER_PROBE=1 SpektraLab …
//
//  A user (forwarded by the owner, 2026-11-11): "滑块有时不太准 然后卡卡的" — the slider is sometimes imprecise and
//  stutters. This writes, for every drag of a `SliderTrack`, one line to the log: how many pointer events reached the
//  handler, how long the handler took (the binding's write, which is the frame's edit), how long from an event to the
//  knob's next layout, and the frames the main thread missed meanwhile (a display link's intervals). And, once a
//  track is laid out, where it is in the window (`slider-frame`), for a driver that drags it with real mouse events.
//  Nothing is measured, and nothing is drawn differently, without the variable. Not in a release build.

#if DEBUG || SPK_SLIDER_PROBE
import QuartzCore
import SwiftUI
import UIKit

@MainActor
enum SliderProbe {
    static let on = ProcessInfo.processInfo.environment["SPK_SLIDER_PROBE"] == "1"

    private static var name = ""
    private static var handler: [Double] = []
    private static var work: [Double] = []
    private static var pointer = false
    /// The pointer's distance from the knob's middle along the track, in points, at each event.
    private static var apart: [Double] = []
    private static var firstPointer: Double?
    private static var toLayout: [Double] = []
    private static var pending: Double?
    private static var events = 0
    private static var link: CADisplayLink?
    private static var target: LinkTarget?
    private static var lastFrame: CFTimeInterval = 0
    private static var gaps: [Double] = []
    private static var started: CFTimeInterval = 0

    private final class LinkTarget: NSObject {
        @objc func tick(_ l: CADisplayLink) { MainActor.assumeIsolated { SliderProbe.tick(l) } }
    }

    static func where_(_ title: String, _ frame: CGRect) {
        guard on, !title.isEmpty else { return }
        NSLog("slider-frame %@ %.1f %.1f %.1f %.1f", title, frame.minX, frame.minY, frame.width, frame.height)
    }

    static func began(_ title: String, pointer isPointer: Bool = false) {
        guard on else { return }
        name = title; pointer = isPointer; handler = []; work = []; apart = []; firstPointer = nil; toLayout = []; pending = nil; events = 0; gaps = []
        started = CACurrentMediaTime(); lastFrame = 0
        let t = LinkTarget()
        target = t
        let l = CADisplayLink(target: t, selector: #selector(LinkTarget.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// One pointer event handled: when it arrived, and when the handler began on it (its write took the rest).
    static func event(arrived: CFTimeInterval, handling: CFTimeInterval, pointerX: Double, knobX: Double) {
        guard on, link != nil else { return }
        events += 1
        apart.append(pointerX - knobX)
        if firstPointer == nil { firstPointer = pointerX }
        let now = CACurrentMediaTime()
        handler.append((now - arrived) * 1000)
        work.append((now - handling) * 1000)
        if pending == nil { pending = arrived }
    }

    /// The knob was laid out at a new place.
    static func laidOut() {
        guard on, let p = pending else { return }
        toLayout.append((CACurrentMediaTime() - p) * 1000)
        pending = nil
    }

    private static func tick(_ l: CADisplayLink) {
        if lastFrame > 0 { gaps.append((l.timestamp - lastFrame) * 1000) }
        lastFrame = l.timestamp
    }

    static func ended() {
        guard on, let l = link else { return }
        l.invalidate(); link = nil; target = nil
        func q(_ a: [Double], _ p: Double) -> Double {
            guard !a.isEmpty else { return 0 }
            let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        let frame = q(gaps, 0.5)
        let missed = gaps.reduce(0) { $0 + max(0, Int(($1 / max(frame, 1)).rounded()) - 1) }
        NSLog("slider-drag %@ (%@) events %d in %.0f ms; write ms p50 %.2f p95 %.2f max %.2f; event->written ms p50 %.2f p95 %.2f max %.2f; event->layout ms p50 %.2f p95 %.2f max %.2f; frames %d (%.1f ms) missed %d, worst gap %.1f ms; pointer-knob pt first %.1f last %.1f worst %.1f (pointer x first %.1f)",
              name, pointer ? "pointer" : "touch", events, (CACurrentMediaTime() - started) * 1000,
              q(work, 0.5), q(work, 0.95), q(work, 1), q(handler, 0.5), q(handler, 0.95), q(handler, 1),
              q(toLayout, 0.5), q(toLayout, 0.95), q(toLayout, 1), gaps.count, frame, missed, gaps.max() ?? 0,
              apart.first ?? 0, apart.last ?? 0, apart.max(by: { abs($0) < abs($1) }) ?? 0, firstPointer ?? -1)
    }
}
#endif
