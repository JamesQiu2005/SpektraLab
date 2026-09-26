//  NavigatorSection.swift — the frame in miniature, Lightroom's navigator.
//
//  v4 (2026-09-26) heads the left rail with it. The picture is the frame's
//  **print** (the thumbnail every develop refreshes, not the RAW), letter-
//  boxed in a well a step darker than the plot ground. Past fit, the part of
//  the frame on the canvas is framed and the rest is dimmed; a click or a drag
//  anywhere in the well puts that point at the canvas's centre. **Fit** is the
//  one button, and it is `zoomToFit` — the same ⌘0 the top bar's pill has.

import SwiftUI

struct NavigatorSection: View {
    @Bindable var session: Session
    @State private var image: CGImage?

    var body: some View {
        PanelSection(L(.sectionNavigator), key: "navigator") {
            VStack(alignment: .leading, spacing: Theme.Metric.navigatorButtonGap) {
                NavigatorWell(session: session, image: image)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Metric.navigatorHeight, maxHeight: .infinity)
                Button { session.zoomToFit() } label: {
                    Text(L(.helpFit))
                        .font(Theme.Font.value)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: Theme.Metric.controlHeight)
                        .background(Theme.pill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .rowEnabled(session.selection != nil && !session.isFit && !session.zoomLocked)
                .help(L(.helpFit) + " (⌘0)")
            }
            .padding(.horizontal, Theme.Metric.navigatorInset)
        }
        .task(id: session.selection) { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailUpdated)) { n in
            guard let url = session.selection, (n.object as? URL) == url else { return }
            Task { await load() }
        }
    }

    private func load() async {
        guard let url = session.selection else { image = nil; return }
        image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: 640)
    }
}

private struct NavigatorWell: View {
    @Bindable var session: Session
    let image: CGImage?

    var body: some View {
        GeometryReader { geo in
            let pic = pictureRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.navigatorWell)
                if let image, let pic {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: pic.width, height: pic.height)
                        .offset(x: pic.minX, y: pic.minY)
                    if let seen = visible(in: pic) {
                        // Everything off the canvas, dimmed; what is on it,
                        // framed. Even-odd, so the frame's inside is a hole.
                        Path { p in p.addRect(pic); p.addRect(seen) }
                            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                        Rectangle().path(in: seen)
                            .stroke(Theme.text, lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard let pic, pic.width > 0, pic.height > 0 else { return }
                        let n = CGPoint(x: ((g.location.x - pic.minX) / pic.width).clamped(to: 0...1),
                                        y: ((g.location.y - pic.minY) / pic.height).clamped(to: 0...1))
                        session.centreView(onNormalised: n)
                    }
            )
        }
    }

    /// The thumbnail fitted into the well, centred.
    private func pictureRect(in size: CGSize) -> CGRect? {
        guard let image, image.width > 0, image.height > 0 else { return nil }
        let s = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// The canvas's view of the frame, in the well's coordinates; nil at fit,
    /// where the frame is the whole picture and a box round it says nothing.
    private func visible(in pic: CGRect) -> CGRect? {
        let v = session.viewportSnapshot
        guard !session.isFit, v.image.width > 0, v.image.height > 0, v.scale > 0 else { return nil }
        let w = v.image.width * v.scale, h = v.image.height * v.scale
        let x0 = max(0, -v.offset.x / w), y0 = max(0, -v.offset.y / h)
        let x1 = min(1, (v.viewport.width - v.offset.x) / w), y1 = min(1, (v.viewport.height - v.offset.y) / h)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: pic.minX + x0 * pic.width, y: pic.minY + y0 * pic.height,
                      width: (x1 - x0) * pic.width, height: (y1 - y0) * pic.height)
    }
}
