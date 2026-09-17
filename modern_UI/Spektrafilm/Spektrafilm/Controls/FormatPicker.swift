//  FormatPicker.swift — the menu pill, and the two rows built on it.
//
//  Three shapes come out of the 2026-09-17 drawing and they are not
//  interchangeable:
//
//    * `PillMenu` **filling** the row after its label — AE Method, whose pill
//      runs from the label column to the row's trailing edge (the drawing:
//      86.35 → 235.6 on a 254 pt rail).
//    * `PillMenu` at a **fixed** width, right-aligned — Film Type and Side,
//      drawn 107 wide with the rest of the row left empty.
//    * `UnitField`, a number field and a unit pill side by side — Side
//      Length, whose field is `rx 8.5` (not a capsule) and whose unit pill is.
//
//  Both rules are in the drawing and both are kept, so `fill` is a parameter
//  and not a judgement made per caller.

import SwiftUI

struct PillMenu<T: Hashable>: View {
    let label: String
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T
    /// The label column. The editor's rails take the drawing's 74; the export
    /// page's is 68.5 — its own drawing — and every row on a page has to pass
    /// the same one or the pills stop lining up.
    var labelWidth: CGFloat = Theme.Metric.sliderLabelWidth
    /// The face both the label and the value are drawn in.
    var font: Font = Theme.Font.label
    /// Whether the pill takes the whole row after the label, or a fixed
    /// `pickerWidth` at the trailing edge. See the note at the top.
    var fill: Bool = true
    /// A pill on a **rail** is ground-coloured; a pill inside a **well** —
    /// the export page, Settings — has to be darker than the well it sits on.
    var plate: Color = Theme.pill
    var enabled: Bool = true
    var reason: String = ""
    /// An extra mark after the value: the `CINE` pill, on a cine film type.
    var trailingBadge: (T) -> Bool = { _ in false }

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(font).foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            if !fill { Spacer(minLength: 0) }
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { selection = o } label: {
                        if o == selection { Label(title(o), systemImage: "checkmark") } else { Text(title(o)) }
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    Text(title(selection)).font(font).foregroundStyle(Theme.text).lineLimit(1)
                        .padding(.leading, 10)
                    if trailingBadge(selection) { CinePill().padding(.leading, 5) }
                    Spacer(minLength: 4)
                    // The drawing's chevron is the **same hollow triangle**
                    // the section headers disclose with, not SF Symbols'
                    // double chevron. One mark, two places, one meaning:
                    // "there is more under this".
                    Triangle()
                        .stroke(Theme.text, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                        .frame(width: 8, height: 5)
                        .padding(.trailing, 9)
                }
                .frame(height: Theme.Metric.controlHeight)
                // `width`, not `maxWidth`. A maximum with `fixedSize` under
                // it resolves to the *intrinsic* width, so every non-filling
                // pill came out as wide as its own word — Film Type 42 pt,
                // Side 44 pt, the unit pill narrower again — and the trailing
                // column had a different left edge on every row. The drawing
                // gives them one width and one left edge; this is that.
                .frame(width: fill ? nil : Theme.Metric.pickerWidth)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(plate, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: false)
        }
        .frame(height: Theme.Metric.rowHeight)
        .rowEnabled(enabled, because: reason)
    }
}

/// Side Length: a number field and a unit pill, right-aligned, and greyed
/// unless the film type is Custom.
///
/// The drawing's two shapes are different on purpose — the field is `rx 8.5`
/// against the unit pill's `rx 13.9` — because one is typed into and the
/// other is chosen from. The field is 50 pt and the unit 38.
struct UnitField: View {
    let label: String
    @Binding var value: Double
    @Binding var unit: SideUnit
    var enabled: Bool
    var reason: String = ""

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var shown: String {
        String(format: "%.\(unit.decimals)f", unit.fromMM(value))
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(Theme.Font.label).foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
                .frame(width: Theme.Metric.sliderLabelWidth, alignment: .leading)
            Spacer(minLength: 0)
            field
                .frame(width: Theme.Metric.fieldWidth, height: Theme.Metric.controlHeight)
                .background(Theme.pill,
                            in: RoundedRectangle(cornerRadius: Theme.Metric.fieldRadius, style: .continuous))
            Spacer(minLength: 4)
            Menu {
                ForEach(SideUnit.allCases) { u in
                    Button { unit = u } label: {
                        if u == unit { Label(u.title, systemImage: "checkmark") } else { Text(u.title) }
                    }
                }
            } label: {
                HStack(spacing: 0) {
                    // The drawing's unit pill is 38.3 pt wide and has to hold
                    // "mm" *and* a chevron, so its padding is tighter than
                    // every other pill's. At the menu pill's 10/9 it had 13 pt
                    // for the word and showed "…".
                    Text(unit.title).font(Theme.Font.label).foregroundStyle(Theme.Ink.tertiary)
                        .fixedSize()
                        .padding(.leading, 6)
                    Spacer(minLength: 2)
                    Triangle()
                        .stroke(Theme.text, style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                        .frame(width: 7, height: 4.5)
                        .padding(.trailing, 5)
                }
                .frame(width: Theme.Metric.unitWidth, height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .frame(height: Theme.Metric.rowHeight)
        // The **unit** stays live when the length does not: a 135 frame is
        // still 0.945 in, and reading it in inches is not editing it. Only
        // the field takes the greying.
        .rowEnabled(true)
    }

    private var field: some View {
        Group {
            if editing && enabled {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.value)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, f in if !f { commit() } }
            } else {
                Text(shown)
                    .font(Theme.Font.value)
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { text = shown; editing = true; focused = true }
            }
        }
        .lineLimit(1)
        .rowEnabled(enabled, because: reason)
    }

    private func commit() {
        if let v = Double(text.replacingOccurrences(of: ",", with: ".")) { value = unit.toMM(v) }
        editing = false
    }
}

/// The orange `CINE` mark — `.st2` in the drawing: `fill: none; stroke:
/// #eca650; stroke-width: 2px`, so an outline in the accent rather than a
/// plate. It follows a cinema film stock in the list and a cine format in the
/// Film Type pill.
struct CinePill: View {
    var body: some View {
        Text("CINE")
            .font(Theme.Font.cine)
            .foregroundStyle(Theme.accent)
            .frame(width: Theme.Metric.cinePill.width, height: Theme.Metric.cinePill.height)
            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
    }
}
