//  CropSection.swift — aspect, straighten, quarter turns, flips.
//
//  Placed after Camera, and in the *left* panel, because the frame's geometry
//  is a camera-side decision: format, then what part of the frame the picture
//  actually is. It is not Layer 1 (it reaches no engine parameter today) and
//  it is not Layer 2 (it is not an adjustment to a scan) — it is upstream of
//  both, which is also why it is the first thing `Exporter` applies after the
//  print comes back.
//
//  Every control here goes through a `Geometry` method that returns something
//  already fitted to the frame, so nothing in this file can produce a crop
//  with a corner hanging outside the image. That is the "fallback": drag the
//  angle to 45° on a full-frame crop and it shrinks to what still fits,
//  visibly, rather than exporting a picture with transparent triangles in it.

import SwiftUI

struct CropSection: View {
    @Bindable var session: Session

    private var size: CGSize { session.sourceImageSize }
    private var g: Geometry { session.geometry }

    // The 2026-09-17 drawing leaves this section collapsed and says so: "I
    // didn't draw the crop, since it just need to change it's layout to the
    // new system, everything else works fine there." So the rows are the
    // rows, moved onto the rail — no well, no section icon, the new insets.
    var body: some View {
        PanelSection(L(.sectionCrop), key: "crop", initiallyExpanded: false, menu: { AnyView(menu) }) {
            RailRows {
                aspectRow
                // Scrubbed through `scrubStraighten`, not written straight
                // to `geometry`: a scrub is a stream of writes and the
                // canvas must not rescale under it. The refit happens once,
                // on `onCommit` — the release, or the typed value.
                ScrubSlider(label: L(.cropStraighten), sublabel: L(.cropStraightenUnit),
                            value: Binding(get: { g.angle },
                                           set: { session.scrubStraighten(to: $0) }),
                            range: -Geometry.maxAngle...Geometry.maxAngle, snap: 1,
                            format: { String(format: "%+.1f°", $0) },
                            onCommit: { session.straightenScrubEnded() })
                turnsRow
                Text(dimensions)
                    .font(Theme.Font.caption).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The ratio, and which way up it is.
    ///
    /// Two controls, not one long list: the picker carries the *ratio* and
    /// the button carries the *orientation*, so 3:2 and 2:3 are one entry
    /// plus a state rather than two entries a user has to know to look for.
    /// Capture One does it this way (`PRD/capture_one_crop_reference.png`)
    /// and the complaint that prompted this was precisely that a landscape
    /// source could only be cropped landscape.
    ///
    /// The picker binds to `canonical`, so an upright crop still shows "3:2"
    /// selected rather than falling off the end of a list it is not in.
    private var aspectRow: some View {
        HStack(spacing: 6) {
            PillMenu(label: L(.cropAspect), options: CropAspect.pickerCases,
                     title: { $0.key.map { L($0) } ?? $0.label },
                     selection: Binding(get: { g.aspect.canonical },
                                        set: { a in
                                            // Changing the ratio keeps the
                                            // orientation the user already
                                            // chose; it is a property of the
                                            // crop, not of the ratio.
                                            setAspect(g.aspect.isPortrait ? a.transposed : a)
                                        }))
            orientationButton
        }
    }

    /// Swap the crop between upright and across. Disabled where there is
    /// nothing to swap — a free crop has no ratio and a square reads the same
    /// either way — rather than left live and inert.
    private var orientationButton: some View {
        let on = g.aspect.hasOrientation
        return Button { setAspect(g.aspect.transposed) } label: {
            Image(systemName: g.aspect.isPortrait ? "rectangle.portrait" : "rectangle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(on ? Theme.text : Theme.text.opacity(0.4))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .help(on ? (g.aspect.isPortrait ? "Upright — click for across" : "Across — click for upright")
                 : "This ratio has no orientation")
    }

    /// Every aspect change lands the same way: through `constrained`, which
    /// reshapes the crop about its centre, preserves its area and refits it.
    /// Going through one function is what keeps the orientation button and
    /// the picker from drifting into two different behaviours.
    private func setAspect(_ a: CropAspect) {
        var next = g
        next.aspect = a
        session.geometry = next.constrained(in: size)
    }

    /// Quarter turns and flips. These are exact — a 90° turn resamples
    /// nothing — which is why they are buttons rather than part of the
    /// straighten slider's range.
    private var turnsRow: some View {
        HStack(spacing: 0) {
            Text(L(.cropRotate)).font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            HStack(spacing: 6) {
                glyph("rotate.left", "Rotate left (⌥⌘[)") { session.geometry = g.turned(by: -1) }
                glyph("rotate.right", "Rotate right (⌥⌘])") { session.geometry = g.turned(by: 1) }
                glyph("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontally",
                      active: g.flipH) { var n = g; n.flipH.toggle(); session.geometry = n }
                glyph("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertically",
                      active: g.flipV) { var n = g; n.flipV.toggle(); session.geometry = n }
                Spacer()
            }
        }
        .frame(height: Theme.Metric.rowHeight)
    }

    private func glyph(_ name: String, _ help: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(active ? Theme.accent : Theme.text)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// What the crop actually costs, in the units a photographer cares about.
    /// A 12° straighten on a full frame is not free and this is where that
    /// shows: the number goes down as the angle goes up.
    private var dimensions: String {
        guard session.sourceLongEdge > 0, size.width > 1 else { return "—" }
        let scale = session.sourceLongEdge / max(size.width, size.height)
        let out = g.outputSize(for: size)
        let w = Int((out.width * scale).rounded()), h = Int((out.height * scale).rounded())
        let mp = Double(w * h) / 1_000_000
        return g.isIdentity ? "\(w) × \(h)  ·  full frame"
                            : String(format: "%d × %d  ·  %.1f MP", w, h, mp)
    }

    private var menu: some View {
        Group {
            Button(L(.helpResetCrop)) { session.geometry = .default }
            Button(L(.helpStraightenZero)) { session.geometry = g.straightened(to: 0, in: size) }
            Divider()
            Button(L(.helpCropWholeFrame)) {
                var n = g
                n.crop = .full
                n.angle = 0
                // The whole frame is not a size anyone chose — it is the
                // absence of one, so the next straighten treats it as
                // maximal-fit again instead of pinning it to 1×1.
                n.intendedSize = nil
                session.geometry = n
            }
        }
    }
}
