//  ExportSheet.swift — the rows of an export's settings: Format, Colour, Quality, and the words
//  for a size. The Mac's Export page (`MacExportPage`) and Settings' recipes are made of them.

import SwiftUI

extension ExportRecipe {
    /// What an export opens with, from the last recipe: a preview-size recipe opens at 12 MP.
    static func opening(_ last: ExportRecipe) -> ExportRecipe {
        var r = last
        if r.size == .preview { r.size = .megapixels(ExportRecipe.twelveMegapixels) }
        return r
    }
}

// MARK: - the box's rows

/// One row of the grouped box: its label at the leading edge, its control at
/// the trailing one, and the line under it when there is one.
struct ExportRow<Control: View>: View {
    let label: String
    let height: CGFloat
    var sub: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        DrawnBand(height: height) {
            DrawnText(label, 14, .semibold).leading(14).baseline(25)
            control().trailingInset(14).top(9)
            if let sub {
                DrawnText(sub, 11.5, .medium, Theme.dim).trailingInset(14).baseline(54)
            }
        }
    }
}

private extension View {
    /// The hairline under a row, on the row's edge, as `sep` draws it.
    func separated() -> some View {
        overlay(alignment: .bottom) { RowSeparator(leading: 14).offset(y: 0.5) }
    }
}

struct FormatSwitch: View {
    @Binding var recipe: ExportRecipe
    var body: some View {
        // Four containers where the drawing has three: 58 pt a segment keeps the switch
        // inside the row beside its label.
        SegmentedSwitch(options: ExportRecipe.Format.allCases, selection: $recipe.format, title: \.rawValue, segmentWidth: 58)
    }
}

/// Colour: the space the file's numbers are in, and the profile it carries.
/// A menu, as Quality is: four spaces named in full.
struct ColourRow: View {
    @Binding var recipe: ExportRecipe

    var body: some View {
        Menu {
            ForEach(ExportRecipe.Colour.allCases, id: \.self) { colour in
                Button {
                    recipe.colour = colour
                } label: {
                    if colour == recipe.colour { Label(colour.fullName, systemImage: "checkmark") } else { Text(colour.fullName) }
                }
            }
        } label: {
            DrawnBand(height: 46) {
                DrawnText(L("Colour"), 14, .semibold).leading(14).baseline(29)
                DrawnText(recipe.colour.fullName, 14, .medium, Theme.secondaryText).trailingInset(30).baseline(29)
                Chevron().trailingInset(19).centreY(24)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(PressStyle(scale: 1))
        .menuIndicator(.hidden)
        .accessibilityLabel(L("Colour, \(recipe.colour.fullName)"))
    }
}

/// Quality: JPEG's and HEIF's. PNG and TIFF keep every value they are handed,
/// so the row says the bits they keep and has nothing to choose. Under it,
/// what the pair costs where it costs something: ProPhoto in 8 bits.
struct QualityRow: View {
    @Binding var recipe: ExportRecipe
    private static let steps = [100, 95, 90, 85, 80, 75]

    var body: some View {
        let lossy = recipe.format.takesQuality
        Menu {
            ForEach(Self.steps, id: \.self) { q in
                Button("\(q)") { recipe.quality = q }
            }
        } label: {
            DrawnBand(height: 68) {
                DrawnText(L("Quality"), 14, .semibold).leading(14).baseline(29).rowEnabled(lossy)
                DrawnText(lossy ? "\(recipe.quality)" : L("\(recipe.format.bitDepth)-bit, lossless"), 14, .medium, Theme.secondaryText)
                    .trailingInset(lossy ? 30 : 14).baseline(29).rowEnabled(lossy)
                if lossy { Chevron().trailingInset(19).centreY(24) }
                if recipe.mayBand {
                    DrawnText(L("In 8 bits ProPhoto can band in smooth tones"), 11.5, .medium, Theme.dim).trailingInset(14).baseline(54)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(PressStyle(scale: 1))
        .menuIndicator(.hidden)
        .disabled(!lossy)
        .accessibilityLabel(lossy ? L("Quality, \(recipe.quality)") : L("\(recipe.format.bitDepth)-bit, lossless"))
    }
}

/// How the export sheets say a size in words.
enum ExportWords {
    /// "full size", "12 MP", "2,048 px long edge", "1,080 px short edge",
    /// "preview size"; a size held under what was asked says what held it —
    /// the device's memory — never "full".
    static func size(_ size: ExportRecipe.Size, capped: Double?, limit: ExportService.Limit? = nil) -> String {
        if let capped, size != .preview {
            return L("\(Int(capped)) MP, this Mac's limit")
        }
        switch size {
        case .full: return L("full size")
        case .megapixels(let mp): return "\(Int(mp)) MP"
        case .longEdge(let e): return L("\(Fmt.thousands(e)) px long edge")
        case .shortEdge(let e): return L("\(Fmt.thousands(e)) px short edge")
        case .preview: return L("preview size")
        }
    }

    /// The Size row's value: "Full", "12 MP", "2,048 px long", "1,080 px short".
    static func short(_ size: ExportRecipe.Size) -> String {
        switch size {
        case .full: return L("Full")
        case .megapixels(let mp): return "\(Int(mp)) MP"
        case .longEdge(let e): return L("\(Fmt.thousands(e)) px long")
        case .shortEdge(let e): return L("\(Fmt.thousands(e)) px short")
        case .preview: return L("Preview")
        }
    }
}

/// Apple's share sheet, with the files the export wrote.
struct SystemShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    /// A share ran to its end. Not called when the sheet is only closed.
    var shared: () -> Void = {}
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let shared = self.shared
        sheet.completionWithItemsHandler = { _, completed, _, _ in if completed { shared() } }
        return sheet
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
