import Foundation

// Stand-ins contain only the data the actual LibraryOrdering extension uses.
struct LibraryFrame: Identifiable {
    let id: UUID
    let captureDate: Date
    let importedAt: Date
    var isPair = false
}
@MainActor final class FrameCatalog {
    var frames: [LibraryFrame] = []
    var visible: [LibraryFrame] = []
}

@main enum QuickFixesSelftest {
    @MainActor static func main() {
        var passed = 0, failed = 0
        func hold(_ ok: Bool, _ message: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(message)") }
        }
        hold(abs(CanvasZoom.scale(base: 1.5, magnification: 1.2, limit: 3) - 1.8) < 1e-9,
             "ordinary pinches retain their scale")
        for m: CGFloat in [100, 1e100, .greatestFiniteMagnitude, .infinity, .nan, -10, 0] {
            let z = CanvasZoom.scale(base: 2, magnification: m, limit: 3)
            hold(z.isFinite && z >= 0.6 && z <= 3.45, "malformed/extreme pinch \(m) is bounded and finite")
        }
        // A mouse wheel spun on past the largest zoom, then turned back (2026-11-05: the reverse did
        // nothing for 189 clicks). A session as `DevelopCanvas.scrollZoom` runs it: travel adds up from
        // the session's base; `held` drops what is spent past the band's stops (the control does not,
        // as before the fix, and must show the dead zone, so this check can fire).
        func session(held: Bool, _ steps: [CGFloat], base: CGFloat = 1, limit: CGFloat = 3) -> [CGFloat] {
            var travel: CGFloat = 0, origin: CGFloat = 0, out: [CGFloat] = []
            for step in steps {
                travel += step
                var t = travel
                if held { let h = CanvasZoom.heldTravel(travel, origin: origin, base: base, limit: limit); origin = h.origin; t = h.travel }
                out.append(CanvasZoom.scale(base: base, magnification: exp(t * 0.006), limit: limit))
            }
            return out
        }
        let spin = Array(repeating: CGFloat(120), count: 40) + Array(repeating: CGFloat(-24), count: 5)
        let fixed = session(held: true, spin), before = session(held: false, spin)
        hold(fixed[40] < fixed[39] - 1e-6, "a wheel turned back after spinning past the top zooms out at the first click (\(fixed[39]) → \(fixed[40]))")
        hold(before[40] >= before[39] - 1e-9, "control: without the held travel the first click back does nothing (the check can fire)")
        let down = Array(repeating: CGFloat(-120), count: 40) + Array(repeating: CGFloat(24), count: 5)
        let low = session(held: true, down)
        hold(low[40] > low[39] + 1e-6, "a wheel turned back after spinning past fit zooms in at the first click (\(low[39]) → \(low[40]))")
        let gentle: [CGFloat] = [24, 24, -24, 48, -24]
        hold(zip(session(held: true, gentle), session(held: false, gentle)).allSatisfy { abs($0 - $1) < 1e-9 },
             "within the band the held travel changes nothing")
        hold(session(held: true, spin).allSatisfy { $0.isFinite && $0 >= 0.6 && $0 <= 3 * 1.15 + 1e-9 }, "and it stays inside the band")
        func frame(_ id: Int, _ day: Int, _ hour: Int, _ arrival: Int, pair: Bool = false) -> LibraryFrame {
            let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!
            let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0,
                of: Date(timeIntervalSince1970: Double(day * 86400)))!
            return LibraryFrame(id: uuid, captureDate: date,
                                importedAt: Date(timeIntervalSince1970: Double(arrival)), isPair: pair)
        }
        let early = frame(1, 20000, 10, 50), late = frame(2, 20000, 16, 100)
        let yesterday = frame(3, 19999, 12, 100), pair = frame(4, 20000, 12, 20, pair: true)
        let store = FrameCatalog()
        store.frames = [early, yesterday, late, pair]; store.visible = store.frames
        hold(store.grid().flatMap(\.frames).map(\.id) == [late, pair, early, yesterday].map(\.id),
             "Newest First sorts capture times within days as well as days")
        hold(store.grid(oldestFirst: true).flatMap(\.frames).map(\.id) == [yesterday, early, pair, late].map(\.id),
             "Oldest First reverses the whole capture chronology")
        hold(store.photographs().map(\.id) == [late, early, yesterday].map(\.id), "picker follows newest capture chronology and excludes pairs")
        hold(store.photographs(oldestFirst: true).map(\.id) == [yesterday, early, late].map(\.id), "picker follows oldest capture chronology")
        store.visible = [early]
        hold(store.grid().flatMap(\.frames).map(\.id) == [early.id], "grid retains its filter")
        hold(store.photographs().count == 3, "picker retains photographs outside the grid filter")
        let a = frame(5, 20000, 12, 1), b = frame(6, 20000, 12, 2)
        store.visible = [a, b]
        hold(store.grid().first?.frames.map(\.id) == [b.id, a.id], "equal capture times use import time consistently")
        print("quick fixes: \(passed) passed, \(failed) failed, 0 skipped")
        if failed > 0 { exit(1) }
    }
}
