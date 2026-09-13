//  FormatPicker.swift — the dark pill with an up/down chevron (the Camera
//  section's Format row). A generic "pill menu" used wherever a value is
//  chosen from a short list.

import SwiftUI

struct PillMenu<T: Hashable>: View {
    let label: String
    let options: [T]
    let title: (T) -> String
    @Binding var selection: T
    /// The label column. The editor's panels take the drawing's 70 pt; the
    /// export page's is 64.5 — its own drawing — and every row on a page has
    /// to pass the same one or the pills stop lining up.
    var labelWidth: CGFloat = Theme.Metric.sliderLabelWidth
    /// The face both the label and the value are drawn in. The export page's
    /// drawing sets everything bold where the editor's sets semibold.
    var font: Font = Theme.Font.label

    var body: some View {
        HStack(spacing: 0) {
            Text(label).font(font).foregroundStyle(Theme.text)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            Menu {
                ForEach(options, id: \.self) { o in
                    Button { selection = o } label: {
                        if o == selection { Label(title(o), systemImage: "checkmark") } else { Text(title(o)) }
                    }
                }
            } label: {
                HStack {
                    Text(title(selection)).font(font).foregroundStyle(Theme.text).padding(.leading, 12)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text).padding(.trailing, 8)
                }
                .frame(height: 14)
                .frame(maxWidth: .infinity)
                .background(Theme.field, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .frame(height: Theme.Metric.rowHeight)
    }
}
