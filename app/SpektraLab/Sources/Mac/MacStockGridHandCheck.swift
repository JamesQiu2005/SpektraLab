//  MacStockGridHandCheck.swift — `--stock-grid-check`'s hand (2.4.1 round 4, the owner's third hand test, 2026-11-16):
//  the strips under a mouse and a trackpad, each event posted into the app's own queue (`MacHIDPost`) so AppKit and UIKit
//  route it as they route a hand's — the monitors, the window, the hit-test, the recognisers, the scroll views — with
//  nothing brought to the front and the real cursor never moved. Round 3's check handed its drag and scroll to the
//  process from outside, which reached no view on this Mac ("UNREACHED"), and the owner found the grip "not really
//  draggable", the maker's name over the cards, and the scroll going to the wrong one or to nothing.
//
//  - **The grip** (`StripSplitGrip`): its hover under the pointer; a drag down and up at 100 %, up at 120 %, down at 80 % moves the
//    strip's foot by the pointer's travel in the page's points (within a point and a half), the column not scrolled; a
//    press a few points inside the strip's foot, on the grip's reach, drags too; the lift writes the height.
//  - **The maker's name** held at the strip's top: a click on it over a card under it does not choose that card; a click
//    just under it, on the card's visible part, does. A scroll leaves the strip at a row's rest (no row under the name).
//  - **Where a scroll goes** (`MacNestedScrolls`): over the strip, its name, a gap between cards and its margin, while it
//    can follow, the strip's — a trackpad's, a glide's and a wheel's; at its foot or top the column's — a trackpad's, a
//    wheel's and a smooth-scrolling mouse's momentum alone; a glide that reaches the strip's foot stops there; over the
//    grip the column's; and a column's scroll that brings a strip under the pointer stays the column's.
//  - **The strip's scroll indicator is at the panel's left edge**, and no native one is drawn inside a strip — read from
//    the view tree and its layers (`nativeIndicators`), at rest at every hold and right after a strip scroll at 80, 100
//    and 150 % (2026-11-16: the Mac's scroller Catalyst draws survived `showsVerticalScrollIndicator = false`).
//
//  Where an act cannot be posted (no window, or an act brought the app to the front and the rest were stopped), each
//  step says `UNREACHED` and is not a failure.

#if targetEnvironment(macCatalyst) && DEBUG
import SwiftUI
import UIKit

extension MacStockGridCheck {
    static func hand(_ model: AppServices, _ s: OpenFrameSession, out: URL, check: (Bool, String) -> Void,
                     film filmCards: [StockPreviewCard], paper: () -> [StockPreviewCard],
                     hold: (String) async -> Laid) async -> [String: Any] {
        let tag = "stock-grid-check"
        var facts: [String: Any] = [:]
        let heights = StockGridHeights.shared
        let defaults = UserDefaults.standard
        func kept() -> Double? { defaults.object(forKey: StockGridHeights.filmKey) as? Double }
        func now() -> Laid { laid(film: filmCards, paper: paper()) }
        var unreached = 0
        func column0Reset() { now().column?.view.setContentOffset(.zero, animated: false) }
        func reached(_ posted: Bool, _ what: String) -> Bool {
            if !posted { unreached += 1; print("\(tag): UNREACHED \(what)") }
            return posted
        }

        heights.drag(film: 220, paper: 180)
        heights.save()
        _ = await hold("hand-start")
        facts["scroller_style"] = scrollerStyle()
        print("\(tag): the system's scroller style here: \(scrollerStyle() == 0 ? "legacy (always shown)" : scrollerStyle() == 1 ? "overlay" : "unknown")")

        // The pointer over the grip: its hover is the grip's (which sets the up-and-down resize cursor). The cursor
        // itself is AppKit's and shown only for the frontmost app: with the check in the background it is the hand check's.
        if let film = now().film {
            let factor = film.frame.height / max(film.view.bounds.height, 1)
            let p = CGPoint(x: film.frame.minX + film.frame.width * 0.3, y: film.frame.maxY + StripSplitGrip.height * factor / 2)
            GripPointerView.lastHover = nil
            if reached(await MacHIDPost.hover(p), "hover the grip") {
                await MacMasksCheck.pause(0.4)
                facts["grip_hovered"] = GripPointerView.lastHover.map { "\($0)" } ?? "none"
                facts["grip_cursor_resize"] = currentCursorIs("resizeUpDownCursor")
                // A background app is sent no hover by AppKit for a posted move (seen: none, while a press and a drag at
                // the same point reach the grip): the hover and its cursor are the hand check's.
                print("\(tag): HAND the grip's hover and resize cursor (\(GripPointerView.lastHover.map { "hovered \($0)" } ?? "no hover reached a background app"))")
            }
        }

        // The grip dragged: the strip's foot follows the pointer 1:1 in the window, at three interface scales.
        func drag(_ name: String, by travel: CGFloat, inside: Bool = false) async {
            heights.drag(film: 220)
            heights.save()
            await MacMasksCheck.pause(0.6)
            var l = now()
            guard var film = l.film, let column = l.column, let window = film.view.window else { check(false, "\(name): the film's strip is on the page"); return }
            var factor = film.frame.height / max(film.view.bounds.height, 1)
            // The grip and the drag's travel in the window: the column scrolled to show them (a large interface scale
            // leaves the column a short window).
            let below = film.frame.maxY + (StripSplitGrip.height + 8) * factor + max(travel, 0) - window.bounds.height
            if below > 0 {
                column.view.setContentOffset(CGPoint(x: 0, y: column.view.contentOffset.y + below / factor), animated: false)
                await MacMasksCheck.pause(0.5)
                l = now()
                guard let again = l.film else { return }
                film = again
                factor = film.frame.height / max(film.view.bounds.height, 1)
            }
            // Along the line, off the pill (the whole line is the grip); `inside`: 3 page points up into the strip's foot.
            let x = film.frame.minX + film.frame.width * 0.3
            let y = inside ? film.frame.maxY - 3 * factor : film.frame.maxY + StripSplitGrip.height * factor / 2
            let before = l.height(film), columnAt = column.view.contentOffset.y, chosen = s.edit.params.filmStock
            guard reached(await MacHIDPost.drag(CGPoint(x: x, y: y), CGPoint(x: x, y: y + travel)), name) else { return }
            await MacMasksCheck.pause(0.6)
            let after = now()
            let grew = after.height(after.film) - before, want = Double(travel / factor)
            facts[name] = ["factor": Double(factor), "before": before, "after": after.height(after.film), "want": want,
                           "kept": kept() ?? -1, "column_moved": Double(column.view.contentOffset.y - columnAt)]
            check(abs(grew - want) <= 1.5 && abs((kept() ?? -1) - after.height(after.film)) <= 0.5,
                  "\(name): the grip dragged \(Int(travel)) window points, the strip's foot moved \(grew) pt for \(want) (the page's points at ×\(factor)), written at the lift (\(kept() ?? -1))")
            check(abs(column.view.contentOffset.y - columnAt) < 0.5, "\(name): the column did not scroll under the grip's drag")
            check(s.edit.params.filmStock == chosen, "\(name): no card chosen by the press")
            await MacMasksCheck.capture(name)
        }
        await drag("grip-100-down", by: 60)
        await drag("grip-100-up", by: -36)
        await drag("grip-100-inside-foot", by: 40, inside: true)
        // 120 %: up (this window's column at 120 % holds the film's strip at its most); 80 %: down. (At 150 % this
        // window's column leaves the strip no room either way: its least is its most, 127 pt.)
        for (scale, travel) in [(InterfaceScale.p120, -36.0), (.p80, 60.0)] {
            defaults.set(scale.rawValue, forKey: InterfaceScale.key)
            await MacMasksCheck.pause(1.0)
            await drag("grip-\(scale.rawValue)-\(travel < 0 ? "up" : "down")", by: CGFloat(travel))
            column0Reset()
        }
        defaults.removeObject(forKey: InterfaceScale.key)
        heights.drag(film: 220)
        heights.save()
        _ = await hold("hand-after-grip")

        // Where a scroll goes. Each case sets the strip and the column, posts at a point, and reads both after the
        // gesture and any settle.
        guard let l0 = now().film, let column0 = now().column else { check(false, "the strips for the scroll cases"); return facts }
        let film = l0.view, column = column0.view
        let factor = l0.frame.height / max(film.bounds.height, 1)
        let lay = layout(filmCards, width: Double(film.bounds.width))
        let window = Double(film.bounds.height)
        let foot = CGFloat(lay.foot(window: window))
        let rests = (lay.rows.indices.map { min(lay.rest($0), lay.foot(window: window)) } + [lay.foot(window: window)])
        func atRest(_ y: CGFloat) -> Bool { rests.contains { abs($0 - Double(y)) <= 0.5 } }
        let cell = CGFloat(StockGridRule.cell(width: Double(film.bounds.width))), margin = CGFloat(StockGridRule.margin)
        var cases: [[String: Any]] = []
        func frame() -> CGRect { film.convert(film.bounds, to: film.window) }
        enum Goes { case strip, column, neither }
        func scroll(_ name: String, at: (CGRect) -> CGPoint, dy: Int, count: Int, _ kind: MacHIDPost.Scroll,
                    strip from: CGFloat, column columnFrom: CGFloat, goes: Goes, rests: Bool = false, shot: String? = nil) async {
            column.setContentOffset(CGPoint(x: 0, y: columnFrom), animated: false)
            film.setContentOffset(CGPoint(x: 0, y: from), animated: false)
            await MacMasksCheck.pause(0.6)
            let p = at(frame())
            let s0 = film.contentOffset.y, c0 = column.contentOffset.y
            guard reached(await MacHIDPost.scroll(p, dy: dy, count: count, kind), "scroll \(name)") else { return }
            // As the gesture ends: the strip's own indicator shown at the panel's left while it moves.
            if let shot {
                MacHistoryPageCheck.layoutWindows(); MacWindowCapture.capture(named: shot)
                // Right after a strip scroll, from the view tree: no native bar inside a strip, its own at the left.
                strips(now(), shot, scrolled: film, check: check)
            }
            await MacMasksCheck.pause(1.2)
            let s1 = film.contentOffset.y, c1 = column.contentOffset.y
            cases.append(["case": name, "kind": kind.rawValue, "strip": [Double(s0), Double(s1)], "column": [Double(c0), Double(c1)]])
            let ds = abs(s1 - s0), dc = abs(c1 - c0)
            switch goes {
            case .strip: check(ds > 8 && dc < 0.5 && (s1 > s0) == (dy < 0), "scroll \(name) (\(kind)): the strip's (strip \(s0)→\(s1), column \(c0)→\(c1))")
            case .column: check(dc > 8 && ds < 0.5, "scroll \(name) (\(kind)): the column's (strip \(s0)→\(s1), column \(c0)→\(c1))")
            case .neither: check(dc < 0.5, "scroll \(name) (\(kind)): the column not moved (strip \(s0)→\(s1), column \(c0)→\(c1))")
            }
            if rests { check(atRest(s1), "scroll \(name) (\(kind)): the strip comes to rest with a row straight under its maker's name (at \(s1))") }
        }
        let mid: (CGRect) -> CGPoint = { CGPoint(x: $0.midX, y: $0.midY) }
        let header: (CGRect) -> CGPoint = { CGPoint(x: $0.minX + 90 * factor, y: $0.minY + 11 * factor) }
        let gap: (CGRect) -> CGPoint = { CGPoint(x: $0.minX + (margin + cell + CGFloat(StockGridRule.gap) / 2) * factor, y: $0.midY) }
        let edge: (CGRect) -> CGPoint = { CGPoint(x: $0.minX + 6 * factor, y: $0.midY) }
        let grip: (CGRect) -> CGPoint = { CGPoint(x: $0.minX + $0.width * 0.3, y: $0.maxY + StripSplitGrip.height * factor / 2) }
        let under: (CGRect) -> CGPoint = { CGPoint(x: $0.minX + $0.width * 0.3, y: $0.maxY + (StripSplitGrip.height + 14) * factor) }
        await scroll("over the strip", at: mid, dy: -8, count: 10, .phased, strip: 0, column: 0, goes: .strip, rests: true, shot: "scroll-strip-indicator")
        await scroll("over the strip", at: mid, dy: -1, count: 3, .wheel, strip: 0, column: 0, goes: .strip, rests: true)
        await scroll("over the strip", at: mid, dy: -10, count: 10, .glide, strip: 0, column: 0, goes: .strip, rests: true)
        await scroll("over the maker's name", at: header, dy: -8, count: 10, .phased, strip: 0, column: 0, goes: .strip, rests: true)
        await scroll("over a gap between cards", at: gap, dy: -8, count: 10, .phased, strip: 0, column: 0, goes: .strip, rests: true)
        await scroll("over the strip's margin", at: edge, dy: -8, count: 10, .phased, strip: 0, column: 0, goes: .strip, rests: true)
        await scroll("at the strip's foot", at: mid, dy: -8, count: 10, .phased, strip: foot, column: 0, goes: .column)
        await scroll("at the strip's foot", at: mid, dy: -1, count: 3, .wheel, strip: foot, column: 0, goes: .column)
        await scroll("at the strip's foot", at: mid, dy: -12, count: 10, .momentum, strip: foot, column: 0, goes: .column)
        await scroll("up at the strip's top", at: mid, dy: 8, count: 10, .phased, strip: 0, column: 120, goes: .column)
        await scroll("up at the strip's top", at: mid, dy: 1, count: 3, .wheel, strip: 0, column: 120, goes: .column)
        await scroll("a glide that reaches the foot", at: mid, dy: -10, count: 12, .glide, strip: max(foot - 40, 0), column: 0, goes: .neither)
        check(abs(film.contentOffset.y - foot) < 0.5, "a glide that reaches the strip's foot stops there (\(film.contentOffset.y) for \(foot))")
        await scroll("over the grip", at: grip, dy: -8, count: 10, .phased, strip: 0, column: 0, goes: .column)
        // The column scrolled from under the strip (on the paper's header) upward: the film's strip comes down under the
        // pointer as the gesture goes on, and the gesture stays the column's.
        await scroll("the column's, a strip coming under it", at: under, dy: 10, count: 16, .glide, strip: foot, column: 160, goes: .column)
        facts["scroll_cases"] = cases
        column.setContentOffset(.zero, animated: false)
        film.setContentOffset(.zero, animated: false)
        await MacMasksCheck.pause(0.5)

        // The strip's own scroll indicator, at the panel's left edge (the owner: "their bar moved to the left side").
        let bar = film.subviews.first { $0.accessibilityIdentifier == "v5.develop.grid.indicator" }
        let barFrame = bar.map { $0.convert($0.bounds, to: film.window) }
        facts["indicator"] = barFrame.map { "\($0)" } ?? "none"
        // Not `showsVerticalScrollIndicator`: it was false while the Mac's scroller was drawn on the right (2026-11-16).
        let native = nativeIndicators(in: film)
        check(native.isEmpty && (barFrame.map { $0.minX < frame().minX + 8 * factor } ?? false),
              "the strip's scroll indicator is at the panel's left edge, no native one drawn inside the strip (\(barFrame.map { "\($0)" } ?? "none"); native: \(native.isEmpty ? "none" : native.joined(separator: "; ")))")

        // The maker's name held over a row of the same maker's cards: a click on the name does not choose the card under
        // it; a click just under the name, on the card's visible part, does.
        // A row that is not its maker's first (no name between it and the row above) and not the last: the held name is its own.
        let pitch = lay.rowHeight + StockGridRule.gap
        if let r = lay.rows.indices.dropFirst().first(where: { $0 + 1 < lay.rows.count && abs(lay.rows[$0].top - lay.rows[$0 - 1].top - pitch) < 0.5
                                                                 && abs(lay.rows[$0 + 1].top - lay.rows[$0].top - pitch) < 0.5 }) {
            let card = lay.rows[r].cards.lowerBound
            let to = CGFloat(lay.rows[r].top) - 10        // the row's pictures 10 pt under the strip's top: 12 of them under the name
            column.setContentOffset(.zero, animated: false)
            film.setContentOffset(CGPoint(x: 0, y: to), animated: false)
            if filmCards[card].stock == s.edit.params.filmStock { s.change { $0.params.load(film: "kodak_portra_400") } }
            await MacMasksCheck.pause(0.8)
            await MacMasksCheck.capture("header-over-a-row")
            let x = margin + cell / 2
            let onName = film.convert(CGPoint(x: x, y: to + 15), to: film.window), below = film.convert(CGPoint(x: x, y: to + 30), to: film.window)
            let before = s.edit.params.filmStock
            if reached(await MacHIDPost.drag(onName, onName, steps: 1), "click on the maker's name") {
                await MacMasksCheck.pause(0.8)
                check(s.edit.params.filmStock == before, "a click on the maker's name does not choose the card under it (\(s.edit.params.filmStock))")
                film.setContentOffset(CGPoint(x: 0, y: to), animated: false)
                await MacMasksCheck.pause(0.5)
                if reached(await MacHIDPost.drag(below, below, steps: 1), "click under the maker's name") {
                    _ = await MacMasksCheck.until(3, every: 50) { s.edit.params.filmStock == filmCards[card].stock }
                    check(s.edit.params.filmStock == filmCards[card].stock,
                          "a click just under the maker's name chooses the card seen there (\(s.edit.params.filmStock) for \(filmCards[card].stock))")
                    await MacMasksCheck.pause(0.6)
                    check(atRest(film.contentOffset.y), "the card clicked under the name is brought to its rest (\(film.contentOffset.y))")
                    await MacMasksCheck.capture("header-card-chosen")
                }
            }
            s.change { $0.params.load(film: "kodak_vision3_500t") }
            _ = await MacMasksCheck.developed(s, model, from: nil)
        }
        facts["unreached"] = unreached
        if unreached > 0 { print("\(tag): UNREACHED \(unreached) posted acts did not reach the window — those cases are on the hand-check list") }
        return facts
    }

    /// The native vertical scroll indicators drawn inside `strip`, read from the view tree and its layers (not a flag):
    /// UIKit's own (`_UIScrollViewScrollIndicator`) and AppKit's scroller Catalyst draws (`_UIScrollerImpContainerView`,
    /// `StripIndicator.hideNative`), each seen — no hidden view up to the window, an alpha and a layer opacity above
    /// nothing — and with something of it drawn (a scroller's track or knob layer shown). Empty: none is drawn.
    static func nativeIndicators(in strip: UIScrollView) -> [String] {
        guard let window = strip.window else { return ["the strip is in no window"] }
        func opacity(_ l: CALayer) -> Float { l.presentation()?.opacity ?? l.opacity }
        func seen(_ v: UIView) -> Bool {
            var a: CGFloat = 1, u: UIView? = v
            while let x = u { if x.isHidden || x.layer.isHidden { return false }; a *= x.alpha * CGFloat(opacity(x.layer)); u = x.superview }
            return a > 0.01
        }
        var found: [String] = []
        func walk(_ v: UIView) {
            let name = NSStringFromClass(type(of: v))
            if v !== strip, name.contains("ScrollerImp") || name.contains("ScrollIndicator"), v.bounds.height >= v.bounds.width,
               v.bounds.height > 0, seen(v) {
                let all = v.layer.sublayers ?? []
                let drawn = all.filter { !$0.isHidden && opacity($0) > 0.01 && $0.bounds.height > 0 }
                if all.isEmpty || !drawn.isEmpty {
                    let f = v.convert(v.bounds, to: window)
                    found.append("\(name) at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)), drawn \(drawn.map { "\(Int($0.frame.minY))+\(Int($0.frame.height)) op \(opacity($0))" })")
                }
            }
            v.subviews.forEach(walk)
        }
        walk(strip)
        return found
    }

    /// No native bar inside either strip (`nativeIndicators`), and with `scrolled`, the strip's own at the panel's left shown.
    static func strips(_ l: Laid, _ name: String, scrolled: UIScrollView? = nil, check: (Bool, String) -> Void) {
        for (what, s) in [("film", l.film), ("paper", l.paper)] {
            guard let s else { continue }
            let seen = nativeIndicators(in: s.view)
            check(seen.isEmpty, "\(name): no native scroll bar is drawn inside the \(what)'s strip (\(seen.isEmpty ? "none" : seen.joined(separator: "; ")))")
        }
        guard let scrolled, let window = scrolled.window else { return }
        let bar = scrolled.subviews.first { $0.accessibilityIdentifier == "v5.develop.grid.indicator" }
        let f = bar.map { $0.convert($0.bounds, to: window) }, strip = scrolled.convert(scrolled.bounds, to: window)
        check((bar?.alpha ?? 0) > 0.5 && !(bar?.isHidden ?? true) && (f.map { $0.minX < strip.minX + 8 * strip.width / max(scrolled.bounds.width, 1) && $0.height > 0 } ?? false),
              "\(name): the strip's own bar is shown at the panel's left while it scrolls (\(f.map { "\($0)" } ?? "none"), alpha \(bar?.alpha ?? 0))")
    }

    /// The film's strip scrolled by a posted trackpad gesture at this scale: no native bar inside a strip, the strip's own at
    /// the left; captured at once (the app's drawing) and, with `--masks-check-hold`, by the shell by window id with the
    /// strip's bar kept shown.
    static func scrolledStrip(_ name: String, film filmCards: [StockPreviewCard], paper: [StockPreviewCard], check: (Bool, String) -> Void) async {
        let l = laid(film: filmCards, paper: paper)
        guard let film = l.film, let column = l.column else { check(false, "\(name): the strips are on the page"); return }
        let columnAt = column.view.contentOffset, filmAt = film.view.contentOffset
        column.view.setContentOffset(.zero, animated: false)
        film.view.setContentOffset(.zero, animated: false)
        await MacMasksCheck.pause(0.6)
        let f = film.view.convert(film.view.bounds, to: film.view.window)
        guard await MacHIDPost.scroll(CGPoint(x: f.midX, y: f.midY), dy: -8, count: 10, .phased) else {
            print("stock-grid-check: UNREACHED scroll \(name)")
            column.view.setContentOffset(columnAt, animated: false); film.view.setContentOffset(filmAt, animated: false)
            return
        }
        MacHistoryPageCheck.layoutWindows()
        strips(l, name, scrolled: film.view, check: check)
        MacWindowCapture.capture(named: name)
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--masks-check-hold"), i + 1 < a.count, let s = Double(a[i + 1]) {
            print("masks-check: CAPTURE \(name)")
            fflush(stdout)
            let probe = MacNestedScrolls.shared.probes.compactMap(\.probe).first { $0.scrollView === film.view }
            let end = Date().addingTimeInterval(s)
            while Date() < end { probe?.indicator?.flash(); await MacMasksCheck.pause(0.3) }
            strips(laid(film: filmCards, paper: paper), name + " (held)", check: check)
        }
        // Back where the hold found both, once the gesture has settled, and the strip's cards asked for again from there.
        await MacMasksCheck.pause(1.0)
        column.view.setContentOffset(columnAt, animated: false)
        film.view.setContentOffset(filmAt, animated: false)
        await MacMasksCheck.pause(0.8)
    }

    /// AppKit's scroller style as this app sees it ("Show scroll bars"): 0 legacy (always shown, a track), 1 overlay.
    static func scrollerStyle() -> Int {
        (NSClassFromString("NSScroller") as AnyObject?)?.value(forKey: "preferredScrollerStyle").flatMap { ($0 as? NSNumber)?.intValue } ?? -1
    }

    /// Whether AppKit's current cursor is `NSCursor.<name>` (`resizeUpDownCursor`, `arrowCursor`).
    static func currentCursorIs(_ name: String) -> Bool {
        guard let cls = NSClassFromString("NSCursor") as AnyObject?,
              let current = cls.perform(NSSelectorFromString("currentCursor"))?.takeUnretainedValue(),
              let want = cls.perform(NSSelectorFromString(name))?.takeUnretainedValue() else { return false }
        return current === want
    }
}
#endif
