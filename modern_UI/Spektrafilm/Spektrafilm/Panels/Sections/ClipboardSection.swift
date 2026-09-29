//  ClipboardSection.swift — RFC-027's settings clipboard, under the navigator.
//
//  Capture One's adjustments clipboard with the user's seven groups. The boxes
//  choose what the **next copy** takes; the line under them says what the
//  clipboard **holds**, which a box changed after copying does not alter.
//  That line is the answer to the user report this came from — "I can't say
//  what got copied".
//
//  Collapsed by default. Built from the rail's own parts only: `ToggleRow`,
//  the metadata ink, and the Navigator's pill.

import SwiftUI

struct ClipboardSection: View {
    @Bindable var session: Session

    var body: some View {
        PanelSection(L(.sectionClipboard), key: "clipboard", initiallyExpanded: false) {
            RailRows {
                ForEach(ClipboardGroup.offered) { group in
                    ToggleRow(label: group.title,
                              isOn: Binding(get: { session.clipboardGroups.contains(group) },
                                            set: { on in
                                                if on { session.clipboardGroups.insert(group) }
                                                else { session.clipboardGroups.remove(group) }
                                            }),
                              help: group.help)
                }
                Text(holds)
                    .font(Theme.Font.meta)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                HStack(spacing: 8) {
                    pill(L(.clipCopy), help: L(.clipCopyHelp), enabled: session.canCopySettings) {
                        session.copySettings()
                    }
                    pill(pasteTitle, help: L(.clipPasteHelp), enabled: session.canPasteSettings) {
                        session.pasteSettings()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var holds: String {
        guard let clip = session.clipboard else { return L(.clipEmpty) }
        return String(format: L(.clipHolds), clip.sourceName, clip.groups.count)
    }

    private var pasteTitle: String {
        let n = session.pasteTargets.count
        return n > 1 ? String(format: L(.clipPasteTo), n) : L(.clipPaste)
    }

    /// The Navigator's *Fit* pill, the rail's one button shape.
    private func pill(_ title: String, help: String, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.value)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: Theme.Metric.controlHeight)
                .background(Theme.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .rowEnabled(enabled)
        .help(help)
    }
}
