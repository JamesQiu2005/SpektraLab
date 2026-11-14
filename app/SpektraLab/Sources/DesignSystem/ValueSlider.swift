//  ValueSlider.swift — the one slider: a fixed track, a knob at the value, and
//  a number you can type.
//
//  The owner's reference (2026-10-26, Capture One's 曝光 group) is a row: the
//  name at the left, a track that never moves, the knob where the value is, and
//  the number in a box at the right that takes typing. The complaint that
//  brought it here, from a friend using the app: "它是拖动底下的条，那个值永远在
//  正中间 … 想判断一下大概改了什么，还要看旁边的数字". `TickRuler` slid its scale
//  under a fixed mark, so a panel could not be read at a glance.
//
//  The track maps the whole range across its width. `rest` is the value the
//  knob is held at when a drag lands within 1.2 % of it (zero, one stop,
//  1.00×), and is marked with a hairline.
//
//  **The knob is where the pointer is** (2026-11-11, a user: "滑块有时不太准 然后卡卡的"; `SliderMapping`):
//  a press on the knob takes it where it was pressed, a press anywhere else on the track brings it to the
//  pointer, and from there it follows the pointer point for point. On the Mac a pointer's press is the
//  slider's at once; a finger still waits for 8 pt of sideways travel, so that it can scroll the panel instead.
//  Until then the drag was relative — the value moved by the pointer's travel — and on the Mac the first 8 pt
//  were swallowed by that finger's rule, so a press on the track moved a knob that stayed apart from the pointer
//  (15–70 pt in the measured drags). And the travel was read in the window's points while the track is laid out
//  in the page's, which the develop page draws 1.25 times larger at 100 % (`InterfaceScale`): the knob ran 25 %
//  ahead of the pointer (measured: two presses 87.3 window points apart were 69.9 apart on the track). The
//  drag's points are now the track's own (`CoexistingDrag`'s converter).
//
//  **The knob and the number are the slider's own while it moves**, drawn at the display's rate; the value is
//  written at most once a display frame, and no sooner than the frame the last write cost has passed
//  (`SliderWrites`). Measured 2026-11-11 (120 Hz CGEvent drags of 1.4 s, `SliderProbe`, before and after
//  interleaved): Brightness's knob drawn in 11–18 frames, 119–129 after; Grain's 17–22, 91–104 after; Film
//  Exposure's 9–17, 90–96 after. Edit's controls give the value to the GPU's pass alone while they move
//  (`OpenFrameSession.moveEdit`).
//
//  The number is a text field in both states: it shows the formatted value, and
//  a person can select it and type another (a unit after the number is ignored,
//  as `SliderField.number` explains). Over it the pointer is the resize cursor: a drag sideways moves the value
//  (⇧ coarse, ⌥ fine), a click opens it for typing with the number selected, and ↑ ↓ step it.

import QuartzCore
import SwiftUI
import UIKit

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// The value a drag is held at nearby, and the hairline's value.
    var rest: Double = 0
    /// The step a drag lands on; nil is continuous (typed values are never snapped).
    var step: Double? = nil
    var text: (Double) -> String = { Fmt.signed($0, decimals: 0) }
    /// A quiet word under the label ("stops", "As Shot", the film's name).
    var sub: String? = nil
    /// The track drawn in a colour per position (temperature, tint): 0 at its
    /// leading end, 1 at its trailing one.
    var tint: ((Double) -> Color)? = nil
    /// Or in a gradient of these, left to right (saturation, the HSL bands).
    var track: [Color]? = nil
    var detentAtRest = false
    /// False where `rest` means nothing on this scale (a pre-flash, which starts at 0).
    var showsRest = true
    var labelWidth: CGFloat = 92
    var fieldWidth: CGFloat = 78
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The value while the knob or the number is moving: drawn by both, written to `value` by `writes`.
    @State private var live: Double?
    @State private var writes = SliderWrites()

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(title)
                    .font(Theme.Font.ui(13.5, .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let sub {
                    Text(sub)
                        .font(Theme.Font.ui(10.5))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: labelWidth, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { commit(rest) }
            .accessibilityHidden(true)

            SliderTrack(value: $value, range: range, rest: rest, step: step,
                        tint: tint, colours: track, detentAtRest: detentAtRest,
                        showsRest: showsRest, onEditingChanged: onEditingChanged, probeName: title,
                        sharedLive: $live, sharedWrites: writes)
                .frame(height: 28)

            SliderField(shown: text(live ?? value), width: fieldWidth,
                        parse: SliderField.number(from:), commit: commit,
                        scrub: .init(value: live ?? value, mapping: mapping,
                                     began: { onEditingChanged(true) },
                                     moved: { v in live = v; writes.write { value = v } },
                                     ended: {
                                         writes.flush()
                                         if let l = live { if l != value { value = l }; live = nil }
                                         onEditingChanged(false)
                                     }))
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var mapping: SliderMapping {
        SliderMapping(range: range, width: 1, rest: rest, step: step, detentAtRest: detentAtRest)
    }

    private func commit(_ v: Double) {
        let landed = v.clamped(to: range)
        onEditingChanged(true)
        value = landed
        onEditingChanged(false)
    }
}

/// The track alone: a click or a drag, no label and no number. For a panel that
/// draws its own row around it (`FilmPanel`'s exposure).
struct SliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var rest: Double = 0
    var step: Double? = nil
    var tint: ((Double) -> Color)? = nil
    var colours: [Color]? = nil
    var detentAtRest = false
    var showsRest = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// The slider's name in a debug build's measurement (`SliderProbe`); nothing otherwise.
    var probeName: String = ""
    /// A row's own (`ValueSlider`): the value while moving and its writes, which its number box shares. A track
    /// alone keeps its own.
    var sharedLive: Binding<Double?>? = nil
    var sharedWrites: SliderWrites? = nil

    @State private var drag: SliderMapping.Drag?
    @State private var ownLive: Double?
    @State private var ownWrites = SliderWrites()
    @State private var ownership = DragOwnership()
    @State private var width: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var calm

    private var live: Double? {
        get { sharedLive?.wrappedValue ?? ownLive }
        nonmutating set { if let sharedLive { sharedLive.wrappedValue = newValue } else { ownLive = newValue } }
    }
    private var writes: SliderWrites { sharedWrites ?? ownWrites }

    private func mapping(_ w: CGFloat) -> SliderMapping {
        SliderMapping(range: range, width: w, rest: rest, step: step, detentAtRest: detentAtRest)
    }

    private var fill: AnyShapeStyle {
        if let colours {
            return AnyShapeStyle(LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing))
        }
        if let tint {
            let stops = stride(from: 0.0, through: 1.0, by: 0.1).map {
                Gradient.Stop(color: tint($0), location: $0)
            }
            return AnyShapeStyle(LinearGradient(gradient: Gradient(stops: stops),
                                                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Theme.rule)
    }

    var body: some View {
        GeometryReader { geo in
            let m = mapping(max(geo.size.width, 1))
            let knobX = m.x(live ?? value)
            #if DEBUG || SPK_SLIDER_PROBE
            let _ = SliderProbe.laidOut()
            #endif
            ZStack(alignment: .leading) {
                // The bar: the same grey as Capture One's, or the control's own colours.
                Rectangle().fill(fill).frame(height: 3)
                if showsRest, range.contains(rest) {
                    Rectangle().fill(Theme.secondaryText.opacity(0.55))
                        .frame(width: 1, height: 11)
                        .offset(x: m.x(rest))
                        .allowsHitTesting(false)
                }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Theme.selection)
                    .frame(width: 9, height: 19)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 0.5)
                    .scaleEffect(drag != nil && !calm ? 1.12 : 1)
                    .offset(x: knobX - SliderMapping.knobHalfWidth)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max($0, 1) }
            #if DEBUG || SPK_SLIDER_PROBE
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SliderProbe.where_(probeName, $0) }
            #endif
        }
        .frame(height: 28)
        .dragBesideScroll(onChanged: { g in
            #if DEBUG || SPK_SLIDER_PROBE
            let handling = CACurrentMediaTime()
            let arrived = g.eventTime ?? handling
            #endif
            // A pointer's press is the slider's at once (on the Mac a drag is never a scroll); a finger's once it
            // has gone sideways (`DragOwnership`), so that it may scroll the panel instead.
            guard g.pointer || ownership.update(x: g.translation.width, y: g.translation.height) else { return }
            let m = mapping(width)
            if drag == nil {
                // The press: on the knob it is taken where it was pressed; elsewhere the knob comes to it.
                drag = m.begin(at: g.start.x, value: live ?? value)
                #if DEBUG || SPK_SLIDER_PROBE
                SliderProbe.began(probeName, pointer: g.pointer)
                #endif
                onEditingChanged(true)
            }
            guard let drag else { return }
            let next = m.value(drag, at: g.location.x)
            if next != (live ?? value) {
                live = next
                writes.write { value = next }
            }
            #if DEBUG || SPK_SLIDER_PROBE
            SliderProbe.event(arrived: arrived, handling: handling, pointerX: g.location.x, knobX: m.x(live ?? value))
            #endif
        }, onEnd: { end in
            if drag == nil, !end.pointer, abs(end.translation.width) < 8, abs(end.translation.height) < 8 {
                // A finger's tap (it never took the drag): the knob goes where it was tapped, one edit.
                commit(mapping(width).value(mapping(width).begin(at: end.start.x, value: value), at: end.start.x))
            } else if drag != nil {
                land()
            }
            ownership = DragOwnership()
        })
        .onDisappear {
            if drag != nil { land() }
            ownership = DragOwnership()
        }
        .accessibilityValue(String(format: "%.2f", live ?? value))
        .accessibilityAdjustableAction { direction in
            let s = step ?? (range.upperBound - range.lowerBound) / 100
            let next = value + (direction == .increment ? s : -s)
            commit(next)
        }
    }

    /// The drag ends: the last value written now, then the release.
    private func land() {
        #if DEBUG || SPK_SLIDER_PROBE
        SliderProbe.ended()
        #endif
        writes.flush()
        if let l = live { if l != value { value = l }; live = nil }
        drag = nil
        onEditingChanged(false)
    }

    private func commit(_ v: Double) {
        onEditingChanged(true)
        value = v.clamped(to: range)
        onEditingChanged(false)
    }
}

/// A moving slider's writes: the latest value, written at the next display frame — and, where the last write
/// cost the frame more than a frame (it redrew what reads the value), not before that much time again has
/// passed, so that the knob and the number, drawn by the slider itself, get the frames between. `flush` writes
/// what is pending now (the drag's end).
///
/// Measured on 2026-11-11 with 120 Hz CGEvent drags on this Mac (frames a 1.4 s drag gets): Grain (a develop
/// slider), a write per event 19, a write a frame 38, the knob alone 160. A write that costs nothing costs no frames.
@MainActor
final class SliderWrites {
    private var pending: (() -> Void)?
    private var link: CADisplayLink?
    private var target: Target?
    /// The display frame a write ran in, to measure what it cost at the next.
    private var wroteAt: CFTimeInterval?
    private var holdUntil: CFTimeInterval = 0
    /// How much of a write's overrun is waited out before the next: 1 gives the knob as much time as the writes.
    static let pace: Double = {
        #if DEBUG || SPK_SLIDER_PROBE
        if let s = ProcessInfo.processInfo.environment["SPK_SLIDER_PACE"], let v = Double(s) { return v }
        #endif
        return 1
    }()

    private final class Target: NSObject {
        weak var owner: SliderWrites?
        @objc func tick(_ l: CADisplayLink) { MainActor.assumeIsolated { owner?.tick(l) } }
    }

    func write(_ f: @escaping () -> Void) {
        pending = f
        if link == nil {
            let t = Target(); t.owner = self; target = t
            let l = CADisplayLink(target: t, selector: #selector(Target.tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.isPaused = false
    }

    func flush() {
        let f = pending
        pending = nil
        wroteAt = nil
        holdUntil = 0
        link?.isPaused = true
        f?()
    }

    private func tick(_ l: CADisplayLink) {
        let frame = max(l.duration, 1.0 / 240)
        if let w = wroteAt {
            // The frame after a write: what it ran over a frame is what the next write waits.
            holdUntil = l.timestamp + max(0, l.timestamp - w - frame) * Self.pace
            wroteAt = nil
        }
        guard let f = pending else { l.isPaused = true; return }
        guard l.timestamp + frame / 2 >= holdUntil else { return }
        pending = nil
        wroteAt = l.timestamp
        f()
    }

    deinit { link?.invalidate() }
}

/// The value's box: the number as it is written, and a place to type another.
/// A unit after the number (" K", " EV", "×", "%", "°") is kept for reading and
/// ignored when parsing, and a true minus (−) is accepted as a sign.
///
/// With `scrub` (a slider's own box): the pointer over it is the resize cursor, a drag sideways moves the value
/// (⇧ coarse, ⌥ fine, on the control's step, one Undo step a drag), a click opens it for typing with the number
/// selected, and while it is open ↑ ↓ step it (⇧ ten, ⌥ a tenth). Return and Tab take what is typed; Esc puts the
/// number back.
struct SliderField: View {
    let shown: String
    var width: CGFloat = 78
    let parse: (String) -> Double?
    let commit: (Double) -> Void
    var scrub: Scrub? = nil

    struct Scrub {
        var value: Double
        var mapping: SliderMapping
        var began: () -> Void
        var moved: (Double) -> Void
        var ended: () -> Void
    }

    @State private var draft: String = ""
    /// The text the value last showed, so Return followed by the focus leaving
    /// commits once and not the stale string twice.
    @State private var settled: String = ""
    @FocusState private var focused: Bool
    @State private var commitOwner = UUID()
    @State private var scrubbing: SliderScrub?
    /// An arrow's step landed: the field shows the value it made, selected (it otherwise keeps what is typed).
    @State private var stepped = false
    /// Esc: the focus goes and what was typed with it.
    @State private var cancelled = false

    var body: some View {
        // Open, the field is what is typed; closed, it is the value as it is now (never a draft left over from a
        // commit the value did not move for — "−5025" clamped to −50 showed "−5025" until the next change).
        TextField("", text: Binding(get: { focused ? draft : shown }, set: { draft = $0 }))
            .textFieldStyle(.plain)
            .font(Theme.Font.ui(12.5, .semibold))
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7)
            .frame(width: width, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.card))
            .focused($focused)
            .overlay {
                // Not open for typing: the box is the scrub's. Open, the field has every click (the caret, a word).
                if let scrub, !focused { scrubSurface(scrub) }
            }
            .onChange(of: shown) { _, s in
                guard focused, stepped else { return }
                draft = s
                settled = s
                stepped = false
                selectAll()
            }
            .onChange(of: focused) { _, f in
                // Catalyst closes a field on Esc itself, before any key handler of ours sees the key.
                if !f, MacKeys.handlingEscape { cancelled = true }
                if f {
                    draft = shown; settled = shown; cancelled = false
                    if scrub != nil { selectAll() }
                } else {
                    stepped = false
                    if cancelled { cancelled = false } else { apply() }
                }
                if f {
                    MacKeyFocus.commitEditing = .init(owner: commitOwner, finish: { apply(); focused = false },
                                                      cancel: { cancelled = true; focused = false })
                } else if MacKeyFocus.commitEditing?.owner == commitOwner { MacKeyFocus.commitEditing = nil }
            }
            .onDisappear {
                if MacKeyFocus.commitEditing?.owner == commitOwner { MacKeyFocus.commitEditing = nil }
            }
            .onSubmit { apply(); focused = false }
            // Esc never reaches the field (a `UITextField` passes it up): the window's Esc asks the field to put its
            // text back (`MacKeyFocus.cancelEditing`, through `commitEditing.cancel`).
            // Tab takes what is typed, as Return does (a lone field has nowhere for Tab to go, and kept it open).
            .onKeyPress(.tab) {
                guard focused else { return .ignored }
                apply(); focused = false
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard focused, let scrub else { return .ignored }
                // From what is typed where something is; else from the value (the box shows it rounded).
                let typed = draft != settled ? parse(draft) : nil
                let from = typed.map { $0.clamped(to: scrub.mapping.range) } ?? scrub.value
                let next = SliderScrub.keyStep(from, up: press.key == .upArrow,
                                               shift: press.modifiers.contains(.shift),
                                               option: press.modifiers.contains(.option), scrub.mapping)
                stepped = true
                commit(next)
                return .handled
            }
            .accessibilityLabel(shown)
    }

    private func scrubSurface(_ scrub: Scrub) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: MacCursor.resize(sideways: true)
                case .ended: if scrubbing == nil { MacCursor.arrow() }
                }
            }
            .dragBesideScroll(onChanged: { g in
                if scrubbing == nil {
                    MacKeyFocus.fieldOpening = true
                    // A press that has not moved yet is still a click.
                    guard abs(g.translation.width) >= SliderScrub.threshold || abs(g.translation.height) >= SliderScrub.threshold else { return }
                    guard abs(g.translation.width) >= abs(g.translation.height) || g.pointer else { return }
                    scrubbing = SliderScrub(at: g.start.x, value: scrub.value,
                                            factor: SliderScrub.factor(shift: g.modifiers.contains(.shift),
                                                                       option: g.modifiers.contains(.alternate)))
                    scrub.began()
                }
                MacCursor.resize(sideways: true)
                let f = SliderScrub.factor(shift: g.modifiers.contains(.shift), option: g.modifiers.contains(.alternate))
                if let next = scrubbing?.value(at: g.location.x, factor: f, scrub.mapping) { scrub.moved(next) }
            }, onEnd: { end in
                if scrubbing != nil {
                    scrubbing = nil
                    scrub.ended()
                } else if abs(end.translation.width) < SliderScrub.threshold, abs(end.translation.height) < SliderScrub.threshold {
                    // A click (not a scroll that began here): the number, selected, for typing.
                    focused = true
                }
                DispatchQueue.main.async { MacKeyFocus.fieldOpening = false }
            })
    }

    /// The number selected, so typing replaces it: once the field has the keys (a turn after the focus moves).
    private func selectAll() {
        DispatchQueue.main.async {
            // Only a field: the window's anchor answers Select All with the library's (⌘A, every photograph).
            guard MacKeyFocus.editingField != nil else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }

    private func apply() {
        guard draft != settled else { return }
        if let v = parse(draft) {
            commit(v)
            settled = draft
        } else {
            draft = shown
            settled = shown
        }
    }

    /// "−1.25", "+2 EV", "5444 K", "1.00×", "100%": the first number in it.
    static func number(from s: String) -> Double? {
        let t = s.replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: "")
        let keep = t.filter { "0123456789+-.".contains($0) }
        guard keep.contains(where: \.isNumber) else { return nil }
        return Double(keep)
    }
}
