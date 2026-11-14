//  HighDynamicRangeGroup.swift — 解码 › 高动态范围 (High Dynamic Range): the print's EDR, the picture's HDR and its peak.
//
//  The owner, 2026-11-09 (PRD-B items 2, 3 and 6): one collapsible row under 解码 holding, in order,
//
//  1. **Extended Dynamic Range (EDR)**, the 1.x print switch restored (`FilmParams.extendedDynamicRange`, on the
//     wire as `effectiveExtendedDynamicRange`; 1.x 57bf22c6's checked item in the Paper pill). It changes the
//     **print**: the paper's range past its white is kept while a print profile renders. It stands down, with
//     its reason under it, where nothing is printed: a scanned film (No Print Profile) and a Digital
//     Intermediate, as in 1.x. **Not the screen's EDR** (the canvas past SDR white): that is item 2's, and the
//     two are kept apart here, in the model and in the strings.
//  2. **Enable HDR**, the per-picture switch of the 2026-11-06 port (`FrameEdit.hdr`, D5). **Greyed, never
//     hidden**, while no screen of this Mac can show EDR (`HDRDisplays.showsHDR`, any attached screen's
//     *potential* headroom), and it comes back live when one is attached or the window moves onto one. Greyed
//     too while EDR is on (the engine measures the curve on the print without EDR and refuses it with EDR on,
//     API-SPEC §19.2), or where the engine gave the session no curve.
//  3. **HDR Peak Brightness** (`FrameEdit.hdrPeak`, stops over SDR white): the curve's H. 2 stops (H 4,
//     `A_H4`) is today's picture. Disabled while HDR is off.
//
//  The first two are print and picture; the third is the picture's HDR only. Undo is the page's
//  (`OpenFrameSession.change`); Copy Settings carries all three as its HDR group (`ClipboardGroup.hdr`).
//
//  Placement (PRD-B's conflict): item 2 said "under 应用胶片模拟", item 6 "in 解码 › 高动态范围". On the Mac's column
//  应用胶片模拟 is not inside 解码 — it is the switch under it — so item 6's layout wins: the group is 解码's last
//  part, and so the row directly above 应用胶片模拟.

import SwiftUI

struct HighDynamicRangeGroup: View {
    let session: OpenFrameSession
    private var prefs: DevelopPanelPrefs { .shared }
    private var displays: HDRDisplays { .shared }

    /// The group's height folded: its header (`ColumnSectionHeader`, no hairline).
    static var titleHeight: CGFloat { FoldHeader<EmptyView, EmptyView>.height }
    /// Decode's sub-sections' indent: their chevron under Decode's name.
    static let indent: CGFloat = 18

    private var edit: FrameEdit { session.edit }
    private var params: FilmParams { edit.params }

    /// Why EDR stands down, or nil where it applies (a print profile renders).
    private var edrReason: String? {
        if !edit.appliesFilm { return L("Off with film emulation off") }
        if params.digitalIntermediate { return L("A Digital Intermediate is not printed") }
        if params.scanFilm { return L("A scanned film is not printed") }
        return nil
    }

    /// Why Enable HDR is greyed, or nil where it can be turned. No sentence for the engine's own refusal (it is in
    /// the log): the row is greyed for it as the 2026-11-06 port greyed it.
    private var hdrReason: String? {
        if !displays.showsHDR { return L("No screen of this Mac can show HDR") }
        if params.effectiveExtendedDynamicRange { return L("Off while EDR is on") }
        return nil
    }
    private var hdrEnabled: Bool { hdrReason == nil && edit.hdrAvailable(session.hdr) }

    var body: some View {
        VStack(spacing: 0) {
            title
            if !prefs.hdrCollapsed {
                toggleRow(L("Extended Dynamic Range (EDR)"), note: edrReason ?? L("The print keeps its range past paper white"),
                          isOn: Binding(get: { params.extendedDynamicRange },
                                        set: { on in session.change { $0.params.extendedDynamicRange = on } }),
                          id: "v5.develop.edr")
                    .rowEnabled(edrReason == nil)
                toggleRow(L("Enable HDR"), note: hdrReason,
                          isOn: Binding(get: { edit.hdr }, set: { on in session.switchHDR(on) }),
                          id: "v5.develop.hdr")
                    .rowEnabled(hdrEnabled)
                ValueSlider(title: L("HDR Peak Brightness"), value: session.binding(\.hdrPeak),
                            range: FrameEdit.peakStopsRange, rest: FrameEdit.defaultPeakStops,
                            text: { String(format: "%.1f EV", $0) }, detentAtRest: true,
                            labelWidth: Self.labelWidth(L("HDR Peak Brightness")),
                            onEditingChanged: session.editing(.print))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("v5.develop.hdr-peak")
                    .rowEnabled(hdrEnabled && edit.hdr)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("v5.develop.hdr-group")
    }

    /// The slider's name column: the slider's 92 pt at least, else the name's own width in the slider's type —
    /// "HDR Peak Brightness" is wider than 92 pt, and a name is never cut to "…" (memory `ui-text-fit-and-density`).
    static func labelWidth(_ title: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 13.5, weight: .semibold)
        return max(92, ((title as NSString).size(withAttributes: [.font: font]).width + 2).rounded(.up))
    }

    /// The group's own fold: Decode's folding header, a step in, as 放大机's.
    private var title: some View {
        ColumnSectionHeader(title: L("High Dynamic Range"), folded: prefs.hdrCollapsed, id: "hdr",
                            rule: false, indent: Self.indent, toggleFold: { prefs.hdrCollapsed.toggle() })
    }

    /// A switch row as Apply Film Emulation's, with a line under its name that wraps (never "…").
    private func toggleRow(_ name: String, note: String?, isOn: Binding<Bool>, id: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(Theme.Font.ui(10.5)).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            SpkToggle(isOn: isOn, size: .compact)
                .accessibilityLabel(name)
                .accessibilityIdentifier(id)
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .frame(minHeight: 32)
    }
}
