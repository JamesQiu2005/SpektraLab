// The Info panel and the persistent picture strip edit the same library metadata.
// Capture One rows write SpektraLab's mirror overrides, never the Capture One source document.
import SwiftUI

struct MacMetadataPicker: View {
    enum Field: String { case rating, color }
    let field: Field
    let images: [MacImage]
    var compact = false
    @Environment(AppServices.self) private var model

    private var ratings: Set<Int> { Set(images.map(\.rating)) }
    private var colors: Set<MacColorLabel?> { Set(images.map { $0.colorLabel == .unlabelled ? nil : $0.colorLabel }) }
    private var title: String { field == .rating ? L("Rating") : L("Colour Label") }
    private var editable: Bool { !images.isEmpty && images.allSatisfy { image in
        MacLibraryUI.store(model).sources.first { $0.id == image.id.source }?.isHelperBacked == true
    } }

    var body: some View {
        Menu {
            if field == .rating {
                ForEach(0...5, id: \.self) { rating in
                    Button { setRating(rating) } label: {
                        if ratings == [rating] { Label(MacWords.rating(rating), systemImage: "checkmark") }
                        else { Text(MacWords.rating(rating)) }
                    }
                }
            } else {
                Button { setColor(.unlabelled) } label: {
                    if colors == [nil] { Label(L("None"), systemImage: "checkmark") } else { Text(L("None")) }
                }
                ForEach(MacColorLabel.allCases.filter { $0 != .unlabelled }, id: \.self) { color in
                    Button { setColor(color) } label: {
                        Label(MacWords.colorName(color.rawValue), systemImage: colors == [color] ? "checkmark" : "circle.fill")
                            .tint(MacWords.color(color.rawValue))
                    }
                }
            }
        } label: {
            HStack(spacing: MacMetric.pt(4)) {
                if compact {
                    if field == .rating {
                        if ratings.count > 1 { Text(L("Mixed")).font(MacMetric.font(11)) }
                        else { MacRatingDots(rating: images.first?.rating ?? 0) }
                    } else {
                        RoundedRectangle(cornerRadius: MacMetric.pt(2))
                            .fill(colors.count == 1 ? (MacWords.color(images.first?.colorLabel?.rawValue ?? 0) ?? Theme.faint) : Theme.dim)
                            .frame(width: MacMetric.pt(10), height: MacMetric.pt(10))
                    }
                } else {
                    Text(field == .rating ? (ratings.count > 1 ? L("Mixed") : MacWords.rating(images.first?.rating ?? 0))
                         : (colors.count > 1 ? L("Mixed") : MacWords.colorName(images.first?.colorLabel?.rawValue ?? 0)))
                        .font(MacMetric.font(12)).foregroundStyle(Theme.text)
                }
                Image(systemName: "chevron.down").font(MacMetric.font(8, .semibold)).foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, MacMetric.pt(3))
            .frame(minHeight: MacMetric.pt(24))
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .disabled(!editable)
        .accessibilityLabel(title)
        .accessibilityValue(field == .rating ? (ratings.count > 1 ? L("Mixed") : MacWords.rating(images.first?.rating ?? 0))
                             : (colors.count > 1 ? L("Mixed") : MacWords.colorName(images.first?.colorLabel?.rawValue ?? 0)))
        .accessibilityIdentifier("mac.metadata.\(field.rawValue)")
    }

    private func setRating(_ value: Int) {
        let ids = images.map(\.id)
        Task {
            do { try await MacLibraryUI.store(model).setRating(value, for: ids) }
            catch { MacLibraryActions.shared.refusal = error.localizedDescription }
        }
    }
    private func setColor(_ value: MacColorLabel?) {
        let ids = images.map(\.id)
        Task {
            do { try await MacLibraryUI.store(model).setColorLabel(value, for: ids) }
            catch { MacLibraryActions.shared.refusal = error.localizedDescription }
        }
    }
}
