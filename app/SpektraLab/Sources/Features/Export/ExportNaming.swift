//  ExportNaming.swift — the Export page's rows added on 2026-11-11 (the owner; issue #111): Quality as a
//  slider, between Format and Size; the file's estimated size; and the file's name, as 1.x made it.
//
//  - **Quality is a slider** (`QualitySliderRow`), the app's one slider's track and number
//    (`SliderTrack`, `SliderField`): 1…100 in steps of one, where the menu offered six steps. PNG and TIFF
//    keep every value and say so in the row instead, as before.
//  - **The estimated size** (`ExportEstimateRow`): the file this recipe makes of the picture in front —
//    with several, the one shown, and the row says which (`ExportEstimate`).
//  - **Naming** (`ExportNamingBox`): 1.x's four chips (Original Name, Film, Paper, Date), lit when on, in the
//    order the name takes them; a chip is dragged onto another to move it (or moved from its own menu), and
//    the last one on stays on. Under them the separator, and the name the picture in front gets, whole and
//    selectable — the sample is the point of the control (1.x: a naming you cannot see the result of is
//    one you check by exporting).

import SwiftUI

/// Quality: JPEG's and HEIF's, a slider from 1 to 100. PNG and TIFF keep every value they are handed, so
/// the row says the bits they keep and has nothing to choose. Under it, what the pair costs where it costs
/// something: ProPhoto in 8 bits.
struct QualitySliderRow: View {
    @Binding var recipe: ExportRecipe

    var body: some View {
        let lossy = recipe.format.takesQuality
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(L("Quality")).font(Theme.Font.ui(14, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize()
                    .rowEnabled(lossy)
                if lossy {
                    SliderTrack(value: Binding(get: { Double(recipe.quality) },
                                               set: { recipe.quality = Int($0.rounded()).clamped(to: 1...100) }),
                                range: 1...100, rest: 95, step: 1, showsRest: false)
                        .frame(height: 28)
                        .accessibilityLabel(L("Quality"))
                        .accessibilityValue("\(recipe.quality)")
                    SliderField(shown: "\(recipe.quality)", width: 46, parse: SliderField.number(from:),
                                commit: { v in recipe.quality = Int(v.rounded()).clamped(to: 1...100) },
                                scrub: .init(value: Double(recipe.quality), mapping: SliderMapping(range: 1...100, width: 1, step: 1),
                                             began: {}, moved: { recipe.quality = Int($0.rounded()).clamped(to: 1...100) }, ended: {}))
                } else {
                    Spacer(minLength: 8)
                    Text(L("\(recipe.format.bitDepth)-bit, lossless")).font(Theme.Font.ui(14, .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                        .rowEnabled(false)
                }
            }
            .frame(minHeight: 46)
            if recipe.mayBand {
                Text(L("In 8 bits ProPhoto can band in smooth tones")).font(Theme.Font.ui(11.5, .medium))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .contain)
    }
}

/// The file's estimated size: "About 9.1 MB". `of` names the picture it is for when there are several.
struct ExportEstimateRow: View {
    /// Nil while it is worked out, or where there is no picture to work it out from.
    let bytes: Int64?
    var of: String? = nil

    var body: some View {
        let value = bytes.map { L("About \(Fmt.fileSize($0))") } ?? "—"
        DrawnBand(height: of == nil ? 46 : 68) {
            DrawnText(L("File size"), 14, .semibold).leading(14).baseline(of == nil ? 29 : 25)
            DrawnText(value, 14, .medium, Theme.secondaryText).trailingInset(14).baseline(of == nil ? 29 : 25)
            if let of {
                DrawnText(L("For \(of), the picture shown"), 11.5, .medium, Theme.dim).trailingInset(14).baseline(54)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("File size") + ", " + value)
        .accessibilityHint(of.map { L("For \($0), the picture shown") } ?? "")
    }
}

/// Naming: the four chips, the separator, and the name the picture in front gets.
struct ExportNamingBox: View {
    @Binding var recipe: ExportRecipe
    /// The name the picture in front gets with this recipe, extension and all.
    let sample: String

    private typealias Token = ExportRecipe.Naming.Token

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChipFlow(spacing: 6, lineSpacing: 6) {
                ForEach(recipe.naming.order) { chip($0) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            RowSeparator(leading: 14)
            HStack(spacing: 10) {
                Text(L("Separator")).font(Theme.Font.ui(14, .semibold)).foregroundStyle(Theme.text)
                    .fixedSize()
                Spacer(minLength: 8)
                SegmentedSwitch(options: ExportRecipe.Naming.separators, selection: $recipe.naming.separator,
                                title: Self.separatorTitle, segmentWidth: 58)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            RowSeparator(leading: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("File name")).font(Theme.Font.ui(14, .semibold)).foregroundStyle(Theme.text)
                // Whole, in as many lines as it takes: the middle of the name is where the parts are.
                Text(sample).font(Theme.Font.ui(12.5, .medium)).foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("export.naming.sample")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    /// "_", "-", and a space said as a word.
    private static func separatorTitle(_ s: String) -> String { s == " " ? L("Space") : s }

    private func chip(_ t: Token) -> some View {
        let on = recipe.naming.isOn(t)
        let last = on && recipe.naming.tokens.count == 1
        return Button { recipe.naming.toggle(t) } label: {
            // The lit weight's width, lit or not: a tap moves no chip.
            Text(t.title).font(Theme.Font.ui(12.5, .semibold)).lineLimit(1).hidden()
                .overlay {
                    Text(t.title).font(Theme.Font.ui(12.5, on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.onSelection : Theme.secondaryText)
                        .lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(on ? Theme.selection : Theme.field))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .fixedSize()
        // The last part on refuses to go: the chip says so rather than looking broken.
        .help(last ? L("A file name needs at least one part") : on ? L("Leave \(t.title) out of the name") : L("Put \(t.title) in the name"))
        .contextMenu {
            Button(L("Move Earlier")) { recipe.naming.shift(t, by: -1) }
                .disabled(recipe.naming.order.first == t)
            Button(L("Move Later")) { recipe.naming.shift(t, by: 1) }
                .disabled(recipe.naming.order.last == t)
        }
        .draggable(t.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let moving = Token(rawValue: raw), moving != t else { return false }
            recipe.naming.move(moving, before: t)
            return true
        }
        .accessibilityLabel(t.title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("export.naming.\(t.rawValue)")
    }
}

extension StockCatalog {
    /// What a frame's settings give its file's name (`ExportRecipe.Naming`): the film, and the paper it is
    /// printed on — none for a slide or a negative that is scanned, "Digital_Intermediate" where that takes
    /// the paper's place (as the frame's stock line says it, `pairText`).
    func namingContext(originalName: String, params: FilmParams, date: Date = Date(), variant: Int? = nil) -> ExportRecipe.Naming.Context {
        typealias N = ExportRecipe.Naming
        let film = N.token(stock(params.filmStock)?.name ?? params.filmStock)
        let paper: String
        if isScanned(params) {
            paper = ""
        } else if params.digitalIntermediateActive(filmIsPositive: false) {
            paper = N.token("Digital Intermediate")
        } else {
            paper = N.token(stock(params.printStock)?.name ?? params.printStock)
        }
        return N.Context(originalName: originalName, filmStock: film, printStock: paper, date: date, variant: variant)
    }
}
