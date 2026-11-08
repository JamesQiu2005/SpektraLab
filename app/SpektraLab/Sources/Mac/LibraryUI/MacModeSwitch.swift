//  MacModeSwitch.swift — 图库 · 冲洗 · 编辑, one row for the whole window (the owner, 2026-10-26).
//
//  Capture One's one window: the picture in the middle, the library at the right, and the tools at the
//  left under whichever tool the person is using. The mode is that row — the develop page's column
//  header wears it (冲洗/编辑 here, 图库 leading back to the library), and the library page's column
//  wears the same one, so the window's three faces are one control wherever the person stands.
//
//  Drawn as the develop page's `surfaceSwitch` has been since 2026-10-19: a card capsule, the mode in
//  front wearing the white selection. Mac only; the window and the reference device keep 冲洗 · 编辑.

import SwiftUI

enum WorkspaceMode: String, CaseIterable, Hashable {
    case library, develop, edit

    var title: String {
        switch self {
        case .library: L("Library")
        case .develop: L("Develop")
        case .edit: L("Edit")
        }
    }
}

/// `current` wears the white capsule; `choose` is what a press asks for (`.library` pops the window back
/// to the library, where that mode is not a page state but the page). `enabled` is the page's: the
/// library cannot open a picture it has none of (the owner, 2026-10-26).
struct MacModeSwitch: View {
    let current: WorkspaceMode
    var enabled: (WorkspaceMode) -> Bool = { _ in true }
    /// Why a mode stands down, in place (the owner, 2026-10-27: "say why in place, no silent no-op").
    var unavailable: (WorkspaceMode) -> String? = { _ in nil }
    let choose: (WorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceMode.allCases, id: \.self) { mode in
                let on = current == mode
                let allowed = enabled(mode)
                Button { choose(mode) } label: {
                    Text(mode.title)
                        .font(MacMetric.font(12, .medium))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(on ? Theme.onSelection : allowed ? Theme.secondaryText : Theme.faint)
                        .frame(maxWidth: .infinity)
                        .frame(height: MacMetric.pt(22))
                        .background {
                            if on { Capsule().fill(Theme.selection) }
                        }
                        .padding(.horizontal, 2)
                        .frame(height: MacMetric.pt(30))
                        .contentShape(Rectangle())
                }
                .disabled(!allowed)
                .help(allowed ? "" : (unavailable(mode) ?? ""))
                .accessibilityHint(allowed ? "" : (unavailable(mode) ?? ""))
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("mac.mode.\(mode.rawValue)")
            }
        }
        .background { Capsule().fill(Theme.card).frame(height: MacMetric.pt(26)) }
    }
}

/// The surface the mode row asked for when it opened a picture from the library: read once by the develop
/// page it opens, which otherwise opens on Develop (`DevelopWorkspace`'s `onAppear`). The row says 编辑, so
/// the page it opens is the Edit surface — not the one the page happens to keep (the owner, 2026-10-26).
@MainActor
enum MacDevelopWanted {
    static var surface: DevelopSurface?
}
