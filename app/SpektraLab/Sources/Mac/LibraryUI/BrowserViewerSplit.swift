//  BrowserViewerSplit.swift — the viewer beside the browser (Capture One's, 2026-10-24).
//
//  The owner: "an optional split of large preview and the library view". With the viewer shown
//  (the header's switch, ⌥⌘V) the chosen picture is drawn large at the left of the grid, and the grid
//  is a browser of `MacLibraryBrowser.browserWidth` beside it; under the picture, Capture One's line:
//  the exposure, the file's name, the rating and the colour label. A picture opened in Develop is drawn
//  as its frame (its develop), any other by its file's embedded preview — as the grid's cells are.
//  A double click opens it in Develop, as a cell's does.

import SwiftUI

struct BrowserViewerSplit: View {
    /// The picture the keys move from (`MacLibraryBrowser.primary`); nil when nothing is chosen.
    let image: MacImage?
    let open: (MacImage) -> Void
    /// How many pictures are chosen: the strip under the picture says so above one (`MacInfoStrip`).
    var chosen = 1
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let pad = MacMetric.pt(12)
                let box = CGSize(width: max(geo.size.width - pad * 2, 1), height: max(geo.size.height - pad * 2, 1))
                ZStack {
                    if let image {
                        picture(image, in: box)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(image) }
                    } else {
                        Text(L("No image selected")).font(MacMetric.font(13)).foregroundStyle(Theme.dim)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .top) {
                    if image?.isOffline == true {
                        Label(L("Not connected"), systemImage: "externaldrive.badge.xmark")
                            .font(MacMetric.font(12, .medium)).foregroundStyle(Theme.text)
                            .padding(.horizontal, MacMetric.pt(8)).frame(height: MacMetric.pt(22))
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: MacMetric.pt(5), style: .continuous))
                            .padding(.top, pad)
                    }
                }
            }
            MacInfoStrip(image: image.map(MacInfoStrip.Item.init), chosen: chosen, status: image.flatMap(statusLine))
        }
        .background(Theme.background)
    }

    @ViewBuilder private func picture(_ image: MacImage, in box: CGSize) -> some View {
        if let id = image.develop?.frameID, let kept = library.frame(id) {
            let frame = MacShownFrame.of(kept, model: model)
            let a = MacShownFrame.aspect(frame)
            let fit = box.width / box.height > a ? CGSize(width: box.height * a, height: box.height)
                                                 : CGSize(width: box.width, height: box.width / a)
            FrameView(frame: frame, pointSize: max(fit.width, fit.height), contentMode: .fit)
                .frame(width: fit.width, height: fit.height)
                .overlay { MacDevelopVeil(frame: frame, ring: MacMetric.pt(30), words: true) }
        } else {
            MacFileThumb(url: image.url, box: box)
        }
    }

    /// The develop's line for a picture the library has made a frame of — the open page's own while one
    /// is open on it (`MacShownFrame`), else as the library keeps it; none for a file not yet a frame.
    private func statusLine(_ image: MacImage) -> (text: String, busy: Bool)? {
        guard let id = image.develop?.frameID, let kept = library.frame(id) else { return nil }
        if let session = model.openSession(id) { return (session.status.text, session.status.busy) }
        switch kept.develop {
        case .developing: return (L("Developing"), true)
        case .queued, .waiting: return (L("Waiting to develop"), true)
        case .developed, .failed: break
        }
        // A develop of an edit it no longer has (a paste whose develop was stopped, or the app quit first):
        // not "Developed · <the pasted film>" over the old picture.
        if MacPreviewStaleness.outOfDate(kept, model: model) { return (L("Preview out of date"), false) }
        let s = DevelopStatus.of(nil, frame: kept, hasDevelop: kept.shownDevelop != nil)
        return (s.text, s.busy)
    }
}

/// A frame as the develop page's canvas has it (trap 33: every surface that shows the frame shows the
/// canvas's frame). The owner, 2026-10-25, of the export page opened from Develop: "why in export, the
/// preview is the original image, not the already edited one on the canvas?" While a develop page is open
/// on a frame, its develop lives in the page's session (`OpenFrameSession.developed`) and reaches the
/// library only when the page is left (`OpenFrameSession.leave`'s `keep`); a surface drawn over the page
/// read the library's frame, which for a frame never developed before is its camera's preview. So a
/// frame with a page open on it is drawn with that page's develop and edit; any other as the library keeps it.
@MainActor
enum MacShownFrame {
    static func of(_ frame: LibraryFrame, model: AppServices) -> LibraryFrame {
        guard !frame.isPair, let session = model.openSession(frame.id), let developed = session.developed else { return frame }
        var f = frame
        f.developed = developed
        f.edit = session.edit
        return f
    }

    /// The shape the frame is drawn in: its develop's, which carries what the frame's own size does not —
    /// a film edge's canvas (`LibraryFrame.displaySize` is the cut picture's) — through Edit's crop; with no
    /// develop, the picture's.
    static func aspect(_ frame: LibraryFrame) -> CGFloat {
        guard !frame.isPair, let d = frame.developed, d.size.width > 0, d.size.height > 0 else {
            return CGFloat(max(frame.displayAspect, 0.05))
        }
        let base = CGSize(width: d.size.width, height: d.size.height)
        let out = frame.edit.printCrop.isIdentity ? base : frame.edit.printCrop.onFinished(base).outputSize(for: base)
        return max(out.width / max(out.height, 1), 0.05)
    }
}

/// Over a frame that is waiting for its develop, or developing: the develop ring, and on a large picture
/// the word — so the picture under it is never taken for the developed one. Dimmed only while it develops
/// (2026-11-05): a paste onto 300 pictures queues 300, and a grid of dimmed tiles read as broken; waiting,
/// the empty ring alone says it.
struct MacDevelopVeil: View {
    let frame: LibraryFrame
    let ring: CGFloat
    var words = false
    var body: some View {
        if frame.develop.isBusy {
            let progress: Double? = { if case .developing(let p) = frame.develop { p } else { nil } }()
            let running = { if case .developing = frame.develop { true } else { false } }()
            ZStack {
                Color.black.opacity(running ? 0.5 : 0)
                VStack(spacing: MacMetric.pt(8)) {
                    // Undimmed, the ring has its own dark ground, so it shows on a sky or a white wall too.
                    ProgressRing(progress: progress, diameter: ring, lineWidth: ring < 24 ? 2 : 2.5)
                        .background { if !running { Circle().fill(Color.black.opacity(0.45)).frame(width: ring + MacMetric.pt(6), height: ring + MacMetric.pt(6)) } }
                    if words {
                        Text(running ? L("Developing") : L("Waiting to develop")).font(MacMetric.font(12, .medium)).foregroundStyle(Theme.text)
                            .padding(.horizontal, running ? 0 : MacMetric.pt(6)).padding(.vertical, running ? 0 : MacMetric.pt(2))
                            .background { if !running { Capsule().fill(Color.black.opacity(0.45)) } }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// A frame showing a develop of an edit it no longer has: a paste whose develop was stopped, or the app
/// quit before it ran (a develop's state is not kept across a launch). Its tile is marked and its line
/// says so, and Develop Previews makes it again (`MacLibraryActions.developPreviews`). The stamp is a
/// hash of the whole wire, so it is worked out once per frame and kept while what it is made of holds.
@MainActor
enum MacPreviewStaleness {
    private struct Key: Equatable {
        var edit: FrameEdit
        var kept: String
        var longEdge: Int
        var cropIsFrame: Bool
        var engine: String
        var source: URL?
        var size: PixelSize
        /// Settings › Develop's body, which a film edge with no seed of its own is drawn with (`bodySeed`).
        var bodySeed: Int
    }
    private static var memo: [LibraryFrame.ID: (key: Key, stale: Bool)] = [:]

    static func outOfDate(_ f: LibraryFrame, model: AppServices) -> Bool {
        let d = model.darkroom
        let body = d.bodySeed()     // read every time: the view then follows a change of it
        guard !f.develop.isBusy, let kept = f.shownDevelop, d.makesPictures, model.openSession(f.id) == nil else { return false }
        // A pair's stamp is of its two frames as well: not kept (there are few, and its key would need both).
        if f.isPair { return d.needsDevelop(f) }
        let key = Key(edit: f.edit, kept: kept.stamp, longEdge: f.previewDevelopLongEdge(f.edit), cropIsFrame: d.cropIsFrame(),
                      engine: d.identity, source: f.picture.fileURL, size: f.originalSize, bodySeed: body)
        if let m = memo[f.id], m.key == key { return m.stale }
        let stale = d.needsDevelop(f)
        memo[f.id] = (key, stale)
        return stale
    }
}

/// Five places, the rating's filled: Capture One's way of saying a rating, and of saying there is none.
struct MacRatingDots: View {
    let rating: Int
    var body: some View {
        HStack(spacing: MacMetric.pt(3)) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "circle.fill")
                    .font(MacMetric.font(i <= rating ? 9 : 3))
                    .frame(width: MacMetric.pt(9))
                    .foregroundStyle(i <= rating ? Theme.secondaryText : Theme.faint)
            }
        }
        .accessibilityLabel(MacWords.rating(rating))
    }
}

/// A colour label: a small rounded square, so it is never read as a film's round dot (`StockDot`).
struct MacColorTag: View {
    let label: MacColorLabel?
    var body: some View {
        if let label, let colour = MacWords.color(label.rawValue) {
            RoundedRectangle(cornerRadius: MacMetric.pt(1.5), style: .continuous).fill(colour)
                .frame(width: MacMetric.pt(8), height: MacMetric.pt(8))
                .accessibilityLabel(MacWords.colorName(label.rawValue))
        }
    }
}
