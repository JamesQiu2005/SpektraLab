//  Filmstrip.swift — the library. Thumbnails at one height, a white frame on
//  the open frame and a weaker one on the rest of the picked set, a
//  three-state badge bottom-right (nothing / filled dot / hollow dot:
//  unprocessed / processed / stale), chevrons at both ends, and the folder
//  name with a count at the far left when there is room.
//
//  The open thumbnail gets the frame and **nothing else** (PRD §5): the
//  badge is suppressed there. It is not redundant on an unpicked one — it
//  is the only place the strip says which frames have a print behind them and
//  which are stale — but on the open frame a second mark next to the white
//  frame reads as more state to decode, and the frame already says the one
//  thing that cell needs to say. A *picked* frame keeps its badge: a batch is
//  exactly where "which of these already has a print" is worth reading, and
//  unlike the open frame it is not otherwise the whole of what the cell says.
//
//  Which of the three marks a cell gets is `Session.framing(of:)`, not a
//  comparison made here — the Browse grid asks the same function, so the two
//  surfaces cannot draw a different set from the same state.
//
//  `LazyHStack` so a 500-image folder builds only what is visible; thumbnails
//  come from ImageIO off the main actor and are replaced by the rendered print
//  once a frame has been through the engine.

import AppKit
import SwiftUI

struct Filmstrip: View {
    @Bindable var session: Session

    var body: some View {
        HStack(spacing: 0) {
            edgeButton("chevron.left") { session.selectRelative(-1) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(session.frames) { frame in
                            FilmstripCell(frame: frame,
                                          framing: session.framing(of: frame.id),
                                          state: session.frameStates[frame.id] ?? .unprocessed)
                                .id(frame.id)
                                // The modifier is read here rather than
                                // declared as a second gesture: a plain
                                // `TapGesture` on macOS matches a ⌘-click too,
                                // so stacking one would fire both and a
                                // ⌘-click would collapse the set as well.
                                .onTapGesture {
                                    session.click(frame.id,
                                                  command: NSEvent.modifierFlags.contains(.command))
                                }
                                .contextMenu {
                                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([frame.id]) }
                                    Button("Reset to defaults") {
                                        if frame.id == session.selection { session.resetParams(); session.resetAdjustments() }
                                        else { Sidecar.remove(for: frame.id) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Theme.Metric.filmstripHeight)
                }
                .onChange(of: session.selection) { _, new in
                    if let new { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            edgeButton("chevron.right") { session.selectRelative(1) }
        }
        .overlay(alignment: .center) {
            // Always in the tree, hidden by opacity. As a `if
            // frames.isEmpty { … }` inside an overlay builder it was observed
            // still on screen next to a loaded thumbnail: the branch had been
            // taken when the strip was empty and was not re-evaluated when it
            // filled. Opacity depends on the same value every pass, so it
            // cannot go stale.
            Text("Drop a folder or images here, or press ⌘O.")
                .font(Theme.Font.label).foregroundStyle(Theme.dim)
                .opacity(session.frames.isEmpty ? 1 : 0)
                .allowsHitTesting(false)
        }
        .panelCard()
    }

    private func edgeButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                .frame(width: 18, height: Theme.Metric.filmstripHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.frames.isEmpty)
    }
}

struct FilmstripCell: View {
    let frame: Frame
    /// Whether this cell is on the canvas, in the picked set, or neither —
    /// one value from `Session.framing(of:)` rather than two booleans, so the
    /// strip and the grid cannot spell the same state two ways.
    let framing: FrameFraming
    let state: FrameState
    @State private var image: CGImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                        .aspectRatio(3 / 2, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(Theme.dim))
                }
            }
            .frame(height: Theme.Metric.thumbHeight)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(Theme.selectionFrame, lineWidth: framing.lineWidth)
                .opacity(framing.opacity))
            // Hidden by opacity rather than taken out of the tree, the same
            // way the empty-strip caption below is: a branch that was decided
            // when the strip was in a different state is the defect this file
            // has already had once.
            badge.padding(4).opacity(framing.suppressesBadge ? 0 : 1)
        }
        .help(frame.name)
        .task(id: frame.id) {
            image = await ThumbnailCache.shared.thumbnail(for: frame.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
            guard (n.object as? URL) == frame.id else { return }
            Task { image = await ThumbnailCache.shared.thumbnail(for: frame.id) }
        }
    }

    @ViewBuilder private var badge: some View {
        switch state {
        case .unprocessed: EmptyView()
        case .processed: Circle().fill(Theme.text).frame(width: 6, height: 6).shadow(radius: 1)
        case .stale: Circle().stroke(Theme.text, lineWidth: 1.2).frame(width: 6, height: 6).shadow(radius: 1)
        }
    }
}
