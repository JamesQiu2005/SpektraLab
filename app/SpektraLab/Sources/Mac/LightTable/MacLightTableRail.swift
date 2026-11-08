//  MacLightTableRail.swift — the films on the Mac's Light Table, in a rail at its right (2026-10-24).
//
//  The owner: "What should also be referenced from the website UX is that library-like rail on the right;
//  it should be collapsible", and "a library-like rail with the rotation keeps the consistency throughout
//  our app". The website's tray holds the photos waiting; this rail holds the films **on** the table:
//
//  - **Add Photos** at its top: the Add page (`MacLightTableAddPage`).
//  - **Every film on the table**, in the order it was first laid on it (`LightTableRail.order`: choosing a
//    film brings it to the top of the pile and does not move its tile), each tile the film **as it lies**,
//    turned by its own angle (a quarter turn, or a free one), and its name and format under it. A click
//    chooses it on the table and brings it to the top, as a click on the table does; a double click zooms
//    the table to it; a right click has the table's menu (Rotate Right, Rotate Left, Take Off).
//  - **The same picture as the table**, never a second one made for the rail: each tile reads the source the
//    table's own rule picks at the tile's size (`LightTableController.pictureSource`: the kept develop, the
//    `.spkfull` read small, or the file's preview while its render is under way, with the develop ring), by
//    the table's own readers (`LightTableTextures.picture`). **Never a job**: the rail asks no render; the
//    table asks for what it shows, as before.
//  - At its foot **Spread Out** (铺开: Tidy Up — every film square, in rows, none under another) and
//    **Clear** (清空: Take All Off), each with the page's Undo.
//  - ⌥⌘0, or the bar's rail button, puts it away and brings it back; the table takes the room.

import SwiftUI

struct MacLightTableRail: View {
    let table: LightTableController
    let add: () -> Void
    let spreadOut: () -> Void
    let clear: () -> Void
    let menu: MacLightTableMenu.Actions

    static var width: CGFloat { MacMetric.pt(176) }
    private var inner: CGFloat { Self.width - 2 * MacMetric.pt(10) }

    var body: some View {
        let order = LightTableRail.order(table.model)
        VStack(spacing: 0) {
            Button(action: add) {
                HStack(spacing: MacMetric.pt(6)) {
                    Image(systemName: "plus").font(MacMetric.font(11, .bold))
                    Text(L("Add Photos")).font(MacMetric.font(12, .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity)
                .frame(minHeight: MacMetric.pt(26))
                .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(6), style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(table.model.isFull)
            .help(L("Add to Light Table"))
            .accessibilityIdentifier("lighttable.rail.add")
            .padding(MacMetric.pt(10))
            Rectangle().fill(Theme.wall).frame(height: 1)
            if order.isEmpty {
                Text(L("No films on the table.")).font(MacMetric.font(12)).foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(MacMetric.pt(14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: MacMetric.pt(6)) {
                            ForEach(order, id: \.self) { id in
                                if let it = table.model.item(id), let f = table.frame(id) {
                                    MacRailTile(table: table, item: it, frame: f, width: inner, selected: table.selected == id,
                                                progress: table.making[id], menu: menu)
                                        .id(id)
                                }
                            }
                        }
                        .padding(MacMetric.pt(10))
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: table.selected) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                }
            }
            Rectangle().fill(Theme.wall).frame(height: 1)
            HStack(spacing: MacMetric.pt(6)) {
                footButton(L("Spread Out"), symbol: "square.grid.2x2", help: L("Tidy Up"), action: spreadOut)
                    .accessibilityIdentifier("lighttable.rail.spread")
                footButton(L("Clear", as: "the table"), symbol: "minus.circle", help: L("Take All Off"), action: clear)
                    .accessibilityIdentifier("lighttable.rail.clear")
            }
            .disabled(order.isEmpty)
            .padding(MacMetric.pt(10))
        }
        .frame(width: Self.width)
        // No ground of its own: it floats on the page's panel (`MacPanelGround`, 2026-10-26).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Films on the Table"))
    }

    private func footButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(MacMetric.font(12, .medium)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, MacMetric.pt(4))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .frame(minHeight: MacMetric.pt(24))
            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(6), style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(MacRailPress())
        .help(help)
    }
}

/// One film as it lies: its picture turned by the film's angle, fitted in the rail's width.
private struct MacRailTile: View {
    let table: LightTableController
    let item: LightTableItem
    let frame: LibraryFrame
    let width: CGFloat
    let selected: Bool
    let progress: Double?
    let menu: MacLightTableMenu.Actions
    @Environment(\.displayScale) private var displayScale
    @State private var lastClick: Date?

    static var pad: CGFloat { MacMetric.pt(6) }
    static var maxHeight: CGFloat { MacMetric.pt(118) }

    var body: some View {
        let box = CGSize(width: width - 2 * Self.pad, height: Self.maxHeight)
        let t = LightTableRail.tile(item, box: box)
        let edge = LightTableSteps.step(for: Double(max(t.picture.width, t.picture.height) * displayScale))
        VStack(spacing: MacMetric.pt(4)) {
            MacRailPicture(table: table, id: item.id, edge: edge, aspect: item.w / max(item.h, 1e-6))
                .frame(width: t.picture.width, height: t.picture.height)
                .rotationEffect(.radians(t.angle))
                .frame(width: box.width, height: t.extent.height)
                .overlay {
                    if let progress {
                        ProgressRing(progress: progress < 0 ? nil : progress, diameter: MacMetric.pt(18), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
            Text(frame.stem + Fmt.dot + LightTablePane.formatName(frame))
                .font(MacMetric.font(10.5)).foregroundStyle(selected ? Theme.text : Theme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .padding(Self.pad)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous).fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous)
                        .strokeBorder(Theme.selectionFrame, lineWidth: 1.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { click() }
        .contextMenu {
            Button { menu.rotateRight(item.id) } label: { Label(L("Rotate Right"), systemImage: "rotate.right") }
            Button { menu.rotateLeft(item.id) } label: { Label(L("Rotate Left"), systemImage: "rotate.left") }
            Divider()
            Button { menu.takeOff(item.id) } label: { Label(L("Take Off"), systemImage: "minus.circle") }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(table.caption(item.id))
        .accessibilityValue(LightTablePane.isSquare(item.rot) ? L("Not turned") : L("Turned \(LightTablePane.angle(item.rot))"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("lighttable.rail.tile")
    }

    /// A click chooses the film on the table and brings it to the top; a second within the double-click
    /// time zooms the table to it.
    private func click() {
        let now = Date()
        if let last = lastClick, now.timeIntervalSince(last) < 0.45 {
            lastClick = nil
            table.zoomToFilm(item.id)
            return
        }
        lastClick = now
        table.select(item.id)
        table.bringToTop(item.id)
    }
}

/// A tile's picture: the table's source for the film at the tile's size, read by the table's readers.
private struct MacRailPicture: View {
    let table: LightTableController
    let id: UUID
    let edge: Int
    let aspect: Double
    @State private var image: CGImage?

    var body: some View {
        // Read again when the table's pictures change (a render landed, an edit) or the film's own does.
        let source = table.pictureSource(id, edge: edge)
        let key = "\(table.picturesChanged)|\(edge)|\(source.key)"
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Theme.plot)
            }
        }
        .task(id: key) {
            if let hit = MacRailPictures.shared.cached(source, edge: edge) { image = hit; return }
            let made = await MacRailPictures.shared.read(source, edge: edge)
            guard !Task.isCancelled else { return }
            if let made { image = made }
        }
    }
}

/// The rail's pictures, read once at a tile's size and kept while the page is open (a few dozen small ones).
@MainActor
final class MacRailPictures {
    static let shared = MacRailPictures()
    private var kept: [String: CGImage] = [:]
    private var order: [String] = []
    /// How many were read (never a job: the table's readers, from what is on disk), for the check.
    private(set) var reads = 0
    /// Each tile's picture as it was last read: where it came from, by film.
    private(set) var readFrom: [String: String] = [:]
    static let limit = 120

    func cached(_ source: LightTableSource, edge: Int) -> CGImage? { kept["\(edge)|\(source.key)"] }

    func read(_ source: LightTableSource, edge: Int) async -> CGImage? {
        let key = "\(edge)|\(source.key)"
        if let hit = kept[key] { return hit }
        reads += 1
        let image: CGImage?
        if case .film = source {
            image = LightTableTextures.filmPicture(source, edge: edge)
        } else {
            image = await Task.detached(priority: .userInitiated) { autoreleasepool { LightTableTextures.picture(source, edge: edge) } }.value
        }
        readFrom[source.key] = LightTableTextures.origin(source)
        guard let image else { return nil }
        kept[key] = image
        order.append(key)
        while order.count > Self.limit { kept[order.removeFirst()] = nil }
        return image
    }

    /// The page closed: every picture let go of.
    func empty() {
        kept = [:]
        order = []
    }
}

private struct MacRailPress: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : Theme.disabledOpacity)
    }
}
