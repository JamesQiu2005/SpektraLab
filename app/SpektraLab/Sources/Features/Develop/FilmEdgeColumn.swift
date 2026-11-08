//  FilmEdgeColumn.swift — Develop › Format's 片边 Film Edge and 日期后背 Date Back, in a wide
//  window's column, and the fold header the column's sections share.
//
//  "片边 and 日期后背 don't get
//  their own page. Their controls rest completely in the left panel, below the film selection (also
//  collapsible). No 日期后背 should be in 片边, and the final round of 片边 is completely removed. 片边
//  gets its own collapsible column in the left as well." And: "drop the frame alignment step."
//
//  So in a wide window Format's two rows and the full-screen flow they opened (`FilmEdgeFlow`, Film →
//  Frame → Edge → Date) are not reached; the flow stays, the host's. "Below the film selection" is below
//  Format's film-size cards (the owner, through the coordinator, 2026-10-25: not on Film & Paper), in the
//  rows' place, then Remove anti-halation layer and the effects:
//
//  - **片边 Film Edge**: its switch, then the flow's Film step (`FilmStepPanel`: the format cards, the
//    view) and its Edge step's five tools laid flat, one after another (`EdgeStepPanel(flat:)`) — no
//    chooser of tools, no Date in it.
//  - **日期后背 Date Back**: its switch, then the Date step's faces, the corner, the size and the
//    brightness, flat (`DateStepPanel(flat:)`).
//
//  **No Frame step.** The picture is not placed in the gate by hand here: the film edge goes on with
//  the framing the flow starts every frame with — `filmEdge.framing` nil, which is the gate's largest
//  cut of the picture about its middle, with the picture's own quarter turns and flips and none of its
//  crop (`FilmFraming.resolved` / `.largest`), and the film lying the way the picture does
//  (`FilmEdgeFormat.defaultTurn`). A frame placed by hand on a reference device keeps its placement until its
//  format changes, as in the flow. The flow's ↻ half turn has no control here.
//  On the Mac the placement came back on 2026-10-25, in Develop's crop: with the film edge on, the crop
//  box is the gate and the picture is moved and enlarged under it (`CropScreen`'s `filmStage`); the
//  section's *Adjust Framing* opens it.
//
//  **Writes.** There is no draft and no Cancel: every control is a film-side edit of the frame's
//  `OpenFrameSession` — the panels' `draft` is bound to `session.edit` — developed when a ruler's finger
//  rests or lifts (`began`/`ended`), as the flow's Edge and Date steps already were. Undo walks them.
//
//  A half-frame pair keeps Format's own Film Edge and Date Back lines (`PairFramePanel`): these
//  sections are a single frame's. The Half card's *Enter Half-Frame Pair* link is the flow's only.

import SwiftUI

/// A section's title line in the column: its name, what the section switches (a toggle), and at the right the bare chevron that folds it — the strips' fold
/// (`StockPreviewPanel(foldable:)`): down while it shows, right when folded.
struct ColumnSectionHeader<Accessory: View>: View {
    let title: String
    let folded: Bool
    /// The fold's accessibility identifier's tail (`v5.develop.fold.<id>`).
    let id: String
    let toggleFold: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.Font.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory()
            Button {
                withAnimation(.easeOut(duration: 0.2)) { toggleFold() }
            } label: {
                Icon(.chevronDown, size: 13, color: Theme.secondaryText)
                    .rotationEffect(.degrees(folded ? -90 : 0))
                    .frame(width: 32, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(folded ? L("Show the controls") : L("Fold the controls away"))
            .accessibilityValue(title)
            .accessibilityIdentifier("v5.develop.fold." + id)
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 44)
    }
}

extension ColumnSectionHeader where Accessory == EmptyView {
    init(title: String, folded: Bool, id: String, toggleFold: @escaping () -> Void) {
        self.init(title: title, folded: folded, id: id, toggleFold: toggleFold) { EmptyView() }
    }
}

/// 片边 and 日期后背, one after the other, for a single frame (not a pair).
struct FilmEdgeColumn: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    private var prefs: DevelopPanelPrefs { .shared }

    private var edge: FilmEdgeSettings { session.edit.filmEdge }
    private var back: DateBackSettings { session.edit.dateBack }
    private var appliesFilm: Bool { session.edit.appliesFilm }

    var body: some View {
        VStack(spacing: 0) {
            if FeatureFlags.filmEdge { filmEdgeSection }
            if FeatureFlags.dateBack { dateBackSection }
        }
        .frame(maxWidth: .infinity)
        // The panels are drawn to a width (their cards wrap at it): the column's.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @State private var width: CGFloat = 393

    // MARK: the session as the panels' draft

    /// The flow's panels edit a `draft`; here it is the frame itself: what they set is one film-side
    /// edit through the session, the film edge, the date and the advance's seed — nothing else.
    private var draft: Binding<FrameEdit> {
        Binding(get: { session.edit }, set: { new in
            let (e, d, seed) = (new.filmEdge, new.dateBack, new.frameSeed)
            guard e != session.edit.filmEdge || d != session.edit.dateBack || seed != session.edit.frameSeed else { return }
            session.change { $0.filmEdge = e; $0.dateBack = d; $0.frameSeed = seed }
        })
    }

    private func editing(_ down: Bool) { if down { session.began(.shoot) } else { session.ended() } }

    /// The picture's shape as the user has it: turned, not cropped (the flow's `pictureAspect`).
    private var pictureAspect: Double {
        let a = frame.originalSize.aspect
        return session.edit.geometry.quarterTurns % 2 == 0 ? a : 1 / max(a, 0.0001)
    }

    // MARK: 片边 Film Edge

    /// The section's controls are live with the film edge on and the film applied.
    private var edgeLive: Bool { edge.active && appliesFilm }

    private var filmEdgeSection: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
            ColumnSectionHeader(title: L("Film Edge"), folded: prefs.filmEdgeCollapsed,
                                id: "film-edge", toggleFold: { prefs.filmEdgeCollapsed.toggle() }) {
                SpkToggle(isOn: Binding(get: { edge.active }, set: { setFilmEdge($0) }))
                    .rowEnabled(appliesFilm)
                    .accessibilityLabel(L("Film Edge"))
                    .accessibilityIdentifier("v5.develop.film-edge")
            }
            if !prefs.filmEdgeCollapsed {
                VStack(spacing: 0) {
                    // Mac (2026-10-25): the picture is placed under the gate in Develop's crop, whose crop box
                    // the gate replaces while the film edge is on (`CropScreen`'s `filmStage`).
                    HStack {
                        TextButton(title: L("Adjust Framing"), color: Theme.accent, font: Theme.Font.ui(12.5, .semibold)) { router.show(.crop(frame.id)) }
                            .accessibilityIdentifier("v5.develop.film-edge.framing")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    FilmStepPanel(frame: frame, draft: draft, width: width, pick: pick)
                    EdgeStepPanel(film: model.filmEdge(for: frame, edit: session.edit, forcing: true), draft: draft,
                                  tool: .constant(.gate), width: width, editing: editing, changed: {}, flat: true)
                }
                .rowEnabled(edgeLive)
            }
        }
    }

    /// The switch. The first time on, the film
    /// lies the way the picture does, shot through this device's body; the framing stays the default
    /// (nil: the gate's largest cut about the middle) — there is no Frame step to place it.
    private func setFilmEdge(_ on: Bool) {
        guard on != edge.active else { return }
        let aspect = pictureAspect, body = settings.bodySeed
        session.change { e in
            if on, e.filmEdge.cameraSeed == 0 {
                e.filmEdge.turn = e.filmEdge.format.defaultTurn(pictureAspect: aspect)
                e.filmEdge.cameraSeed = body
            }
            e.filmEdge.active = on
        }
    }

    /// A format card: the flow's `pick`, through the session — the gate lies the way the picture does
    /// (a half turn already chosen is kept), the cut starts again, and a date face the format cannot
    /// print gives way to one it can.
    private func pick(_ format: FilmEdgeFormat) {
        guard format != edge.format else { return }
        let aspect = pictureAspect
        withAnimation(.easeOut(duration: 0.18)) {
            session.change { e in
                let wasHalfTurned = e.filmEdge.turn >= 2
                e.filmEdge.format = format
                e.filmEdge.turn = format.defaultTurn(pictureAspect: aspect) + (wasHalfTurned ? 2 : 0)
                e.filmEdge.framing = nil
                if !format.draws(e.dateBack.style), let face = DateBackFace.allCases.first(where: format.draws) {
                    e.dateBack.style = face
                }
            }
        }
    }

    // MARK: 日期后背 Date Back

    private var printsNothing: Bool { FilmEdgeOptions.printsNothing(back, edge) }
    /// The faces and rulers are live with the film applied. The date is not the film's own (a bare
    /// frame carries it too), but a frame with the film off is Apple's decode: no film, no back.
    private var dateLive: Bool { appliesFilm }

    private var dateBackSection: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.rule).frame(height: Theme.Metric.rule).padding(.horizontal, Theme.Metric.margin)
            ColumnSectionHeader(title: L("Date Back"), folded: prefs.dateBackCollapsed,
                                id: "date-back", toggleFold: { prefs.dateBackCollapsed.toggle() }) {
                SpkToggle(isOn: Binding(get: { back.active && !printsNothing }, set: { setDate($0) }))
                    .rowEnabled(appliesFilm && !printsNothing)
                    .accessibilityLabel(L("Date Back"))
                    .accessibilityIdentifier("v5.develop.date-back")
            }
            if !prefs.dateBackCollapsed {
                DateStepPanel(frame: frame, draft: draft, control: .constant(.corner), width: width,
                              editing: editing, changed: {}, pick: pickFace, flat: true)
                    .rowEnabled(dateLive)
            }
        }
    }

    /// The date's switch. Switched on with a face this camera
    /// cannot print, it takes one it can (the Date step's own switch). One step of Undo.
    private func setDate(_ on: Bool) {
        guard on != back.active else { return }
        session.change { e in
            e.dateBack.active = on
            if on, !e.dateBack.prints(e.dateBack.style, filmEdge: e.filmEdge),
               let face = DateBackFace.allCases.first(where: { e.dateBack.prints($0, filmEdge: e.filmEdge) }) {
                e.dateBack.style = face
            }
        }
    }

    /// A face: LCD and Dots are the date, one at a time; Data is its own switch (`DateBackSettings.tap`).
    private func pickFace(_ face: DateBackFace) {
        var b = back
        b.tap(face)
        guard b != back else { return }
        session.change { $0.dateBack = b }
    }
}
