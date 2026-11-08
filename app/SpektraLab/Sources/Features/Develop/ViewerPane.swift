//  ViewerPane.swift — the photo on a wide window window: the editor's page with the column put away.
//
//  PAGES.md §3, Viewer (W-V1): ‹ Library and "3 of 14" over the picture; at the right the bar,
//  ⓘ, ♡, 🗑, ···, Share and Develop (accent: an action); the picture fitted on black, zoomed and
//  panned as on the develop page (`DevelopCanvas`, the host viewer's own); the film and paper over
//  the filmstrip; the filmstrip at the foot. Develop brings the column in on the same frame, in place.
//
//  It holds no session and asks the engine for nothing: the picture is the frame's kept develop and
//  the strip's tiles are thumbnails. Keys: ← → the frame, ⌘B or Return the column (Develop).

import SwiftUI

struct ViewerPane: View {
    let frameID: LibraryFrame.ID

    @Environment(DevelopController.self) private var pad
    @Environment(AppServices.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(ExportService.self) private var exporter
    @Environment(WindowShape.self) private var window
    @State private var confirmingRemoval = false

    static let bar: CGFloat = 50

    var body: some View {
        VStack(spacing: 0) {
            if let frame = library.frame(frameID) {
                topBar(frame).clearsWindowControls().frame(height: Self.bar)
                DevelopCanvas(frame: frame, edit: frame.edit, split: .constant(0.5))
                    .id(frame.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                stockLine(frame).frame(height: 32)
                if !pad.stripHidden { filmstrip(frame) }
            } else {
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .background { keys }
        .focusable()
        .focusEffectDisabled()
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(L("Remove from Library"), role: .destructive) { model.remove([frameID]) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    /// The filmstrip. as tall as the develop
    /// page's was dragged (`PaneDividers`), and dragged here too by the line over it.
    private func filmstrip(_ frame: LibraryFrame) -> some View {
        let splits = PaneDividers.shared
        let height = splits.filmstrip(in: window.size.height)
        return BrowserFilmstrip(ids: pad.ids, current: frame.id, height: height) { pad.select($0) }
            .overlay(alignment: .top) {
                DividerGrip(way: .upAndDown, value: height, range: PaneDividers.filmstripRange(in: window.size.height),
                               grows: -1, label: L("Filmstrip height"),
                               set: { splits.filmstripHeight = $0 }, ended: { splits.save() })
                    .frame(height: DividerGrip.reach)
                    .offset(y: -DividerGrip.reach / 2)
            }
    }

    // MARK: the bar

    private func topBar(_ frame: LibraryFrame) -> some View {
        HStack(spacing: 8) {
            Button { router.back() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(pad.opening.back.title).lineLimit(1)
                }
                .font(Theme.Font.ui(15, .medium))
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityIdentifier("pad.viewer.back")
            .frame(maxWidth: .infinity, alignment: .leading)
            // "3 of 14" gives way first in a narrow window, so the ways onward never squeeze.
            if window.size.width >= 700 { FrameCounter() }
            HStack(spacing: 4) {
                barSymbol(pad.stripHidden ? "rectangle.bottomthird.inset.filled" : "rectangle.bottomhalf.inset.filled",
                          pad.stripHidden ? L("Show the filmstrip") : L("Hide the filmstrip")) {
                    withAnimation(.smooth(duration: 0.25)) { pad.stripHidden.toggle() }
                }
                barSymbol("info.circle", L("Info")) { router.present(.info(frame.id)) }
                barSymbol(frame.isFavourite ? "heart.fill" : "heart", frame.isFavourite ? L("Unfavourite") : L("Favourite")) {
                    library.toggleFavourite(frame.id)
                }
                barSymbol("trash", L("Remove")) { confirmingRemoval = true }
                Menu {
                    Button(L("Copy Settings")) { router.present(.copySettings(frame.id)) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(L("More"))
                barSymbol("square.and.arrow.up", L("Share")) { share(frame) }
                CapsuleButton(title: L("Develop"), height: 34, width: 104) { pad.develop() }
                    .accessibilityIdentifier("pad.viewer.develop")
                    .padding(.leading, 6)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }

    private func barSymbol(_ name: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 18))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    /// Film · paper, with the film's dot, and when it was taken: the host viewer's line.
    private func stockLine(_ frame: LibraryFrame) -> some View {
        let p = frame.edit.params
        return HStack(spacing: 8) {
            StockDot(color: StockCatalog.shared.stock(p.filmStock)?.color ?? Theme.card)
            Text(StockCatalog.shared.pairText(p)).foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            Text(Fmt.stamp(frame.captureDate)).foregroundStyle(Theme.dim)
        }
        .font(Theme.Font.ui(12))
        .lineLimit(1)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var keys: some View {
        HiddenKeyEquivalent(title: L("Previous photo"), key: .leftArrow, enabled: pad.neighbour(-1) != nil) {
            if let id = pad.neighbour(-1) { pad.select(id) }
        }
        HiddenKeyEquivalent(title: L("Next photo"), key: .rightArrow, enabled: pad.neighbour(1) != nil) {
            if let id = pad.neighbour(1) { pad.select(id) }
        }
        HiddenKeyEquivalent(title: L("Develop"), key: "b", modifiers: .command) { pad.develop() }
        HiddenKeyEquivalent(title: L("Develop"), key: .return) { pad.develop() }
    }

    // MARK: actions

    /// The develop page's Share: the recipe of the day, to the share sheet.
    private func share(_ frame: LibraryFrame) {
        if exporter.isExporting { router.present(.exporting); return }
        var recipe = settings.recipe
        recipe.destination = .share
        exporter.start([frame.id], recipe: recipe)
        router.present(.exporting)
    }

    /// The Library's words for removing one frame (`LibraryScreen`).
    private var removalTitle: String {
        let pairs = library.frame(frameID)?.isPair == true ? 1 : 0
        return PairWords.removalTitle(pairs: pairs, of: 1) ?? L("Remove this frame?")
    }

    private var removalMessage: String {
        guard let frame = library.frame(frameID) else { return "" }
        if frame.isPair { return PairWords.removalNote(pairs: 1) }
        var said = [frame.source == .copiedIn ? L("It was copied into SpektraLab, so its original goes with it.")
                                               : L("Its edit and preview copy go. The original stays where it is.")]
        let leavesHole = library.frames.contains { item in
            guard let pair = item.pair else { return false }
            return pair.left?.frame == frame.id || pair.right?.frame == frame.id
        }
        if leavesHole { said.append(PairWords.removalLeavesHole(frames: 1)) }
        return said.joined(separator: " ")
    }
}

/// "3 of 14": the open frame's place in the filmstrip.
struct FrameCounter: View {
    @Environment(DevelopController.self) private var pad

    var body: some View {
        if let (i, n) = pad.place {
            Text(L("\(i + 1) of \(n)"))
                .font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.dim)
                .monospacedDigit()
                .fixedSize()
                .accessibilityLabel(L("Photo \(i + 1) of \(n)"))
        }
    }
}
