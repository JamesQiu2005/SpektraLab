//  BrowseView.swift — the Browse state: the session as a worklist.
//
//  The app lands here when a folder (or several files) is opened. Nothing is
//  decoded, nothing is rendered: the grid is the confirmation step that the
//  first build was missing, which made opening a folder commit to a 7 s
//  film-side render of the alphabetically-first frame and a 363 MB TIFF
//  (HANDOFF-FRONTEND-POLISH §2, frontend SPEC §5.1).
//
//  The three thumbnail states are the filmstrip's: unprocessed shows the
//  embedded preview, processed shows the rendered print, stale shows the
//  print with a hollow pip after an edit. Clicking a cell is the explicit act
//  that enters Print.
//
//  The framing is the filmstrip's too, from the same `Session.framing(of:)`:
//  a plain click picks one frame and opens it, ⌘-click toggles one frame's
//  membership in the picked set without leaving the grid. A grid whose
//  selection disagreed with the strip's would be a batch the person cannot
//  see, so both ask the one function rather than each deciding.

import AppKit
import SwiftUI

enum BrowseSort: String, CaseIterable, Identifiable {
    case name = "Name", date = "Capture date"
    var id: String { rawValue }
}

struct BrowseView: View {
    @Bindable var session: Session
    @AppStorage("ui2.browseSort") private var sortRaw = BrowseSort.name.rawValue
    private var sort: BrowseSort { BrowseSort(rawValue: sortRaw) ?? .name }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 186, maximum: 250), spacing: 16)],
                          spacing: 16) {
                    ForEach(sorted) { frame in
                        BrowseCell(session: session, frame: frame,
                                   framing: session.framing(of: frame.id))
                            // The same gesture as the filmstrip's, on the same
                            // rule: a plain click picks one and opens it, ⌘
                            // adds or removes one and leaves the canvas alone.
                            .onTapGesture {
                                session.click(frame.id,
                                              command: NSEvent.modifierFlags.contains(.command))
                            }
                            .contextMenu {
                                Button("Develop") { session.click(frame.id) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([frame.id]) }
                                Divider()
                                Button("Reset to defaults") { Sidecar.remove(for: frame.id); session.refreshState(for: frame.id) }
                                Button("Remove from session") { session.remove(frame.id) }
                            }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
            // The breadcrumb: the folder when the session is one, else the
            // selection that was dropped.
            Text(session.libraryTitle)
                .font(Theme.Font.sectionTitle).foregroundStyle(Theme.text).lineLimit(1)
            Text("· \(session.frames.count) frames")
                .font(Theme.Font.caption).foregroundStyle(Theme.dim)
            // The empty middle of the header drags the window, as a toolbar
            // does; the titlebar is hidden.
            WindowDragHandle().frame(minWidth: 8, maxWidth: .infinity)
            Menu {
                ForEach(BrowseSort.allCases) { s in
                    Button(s.rawValue) { sortRaw = s.rawValue }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(sort.rawValue).font(Theme.Font.caption).foregroundStyle(Theme.text)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 9).frame(height: 20)
                .background(Theme.field, in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var sorted: [Frame] {
        switch sort {
        case .name:
            return session.frames
        case .date:
            return session.frames.sorted {
                let a = (try? $0.id.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.id.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
        }
    }
}

struct BrowseCell: View {
    @Bindable var session: Session
    let frame: Frame
    /// How the editor marks this cell: on the canvas, in the picked set, or
    /// neither. Also from `Session`, so the grid and the filmstrip agree by
    /// construction. The export page leaves it `.none` and uses `chosen`.
    var framing: FrameFraming = .none
    @State private var image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Theme.well)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .padding(1)
                } else {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay {
                if framing.isFramed {
                    // The filmstrip's scale, on this cell's 4 pt corner: 1.5
                    // for the frame on the canvas, a weaker 1 for the rest of
                    // the set.
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.selectionFrame, lineWidth: framing.lineWidth)
                        .opacity(framing.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            HStack(spacing: 4) {
                Text(frame.name).font(Theme.Font.caption).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .help(frame.name)
        .task(id: frame.id) {
            image = await ThumbnailCache.shared.thumbnail(for: frame.id, maxPixel: 512)
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
            guard (n.object as? URL) == frame.id else { return }
            Task { image = await ThumbnailCache.shared.thumbnail(for: frame.id, maxPixel: 512) }
        }
    }

    /// Same three states as the filmstrip (frontend SPEC §5.1): no pip =
    /// never rendered, filled = the print matches the sidecar, hollow = the
    /// parameters changed after the print was made.
    @ViewBuilder private var badge: some View {
        switch session.frameStates[frame.id] ?? .unprocessed {
        case .unprocessed: EmptyView()
        case .processed: Circle().fill(Theme.text).frame(width: 7, height: 7).shadow(radius: 1)
        case .stale: Circle().stroke(Theme.text, lineWidth: 1.4).frame(width: 7, height: 7).shadow(radius: 1)
        }
    }
}
