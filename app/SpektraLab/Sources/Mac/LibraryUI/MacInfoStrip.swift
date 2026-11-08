//  MacInfoStrip.swift — the line under the picture, one view in all three modes (the owner, 2026-10-27).
//
//  Capture One's line under the viewer: the exposure, the develop's own line ("● Developed · Kodak
//  Portra 400 · Kodak Professional Portra Endura" — the develop column's foot until 2026-10-27), the
//  file's name, and the rating and colour label at the right. It stands under the canvas, the canvas's
//  whole width, in 图库 (under the viewer), 冲洗 and 编辑 alike, so the column keeps no status row.
//  With more than one picture chosen it says how many, and nothing about any one of them.
//
//  Nothing is cut short (the standing rule: no "…"): the parts are measured against the strip's width
//  in the pass that draws it, and what does not fit is left off whole — the exposure's parts first,
//  last part first; then the develop line's parts from its end (the paper, then the film); the name
//  and the rating last of all.

import SwiftUI
import UIKit

struct MacInfoStrip: View {
    /// What the strip says of one picture: a library row's, or a frame's name alone where the picture
    /// is not a row of the library (one opened from elsewhere).
    struct Item {
        var id: MacImage.ID?
        var fileName: String
        var exposure: String?
        var rating = 0
        var colorLabel: MacColorLabel?
        var rated = true
        init(_ image: MacImage) {
            id = image.id; fileName = image.fileName; exposure = image.exposure; rating = image.rating; colorLabel = image.colorLabel
        }
        init(name: String) { fileName = name; rated = false }
    }

    let image: Item?
    /// How many pictures are chosen; above one the strip says so and nothing else.
    let chosen: Int
    /// The develop's line and whether it is working (`DevelopStatus`); nil where there is none to say.
    var status: (text: String, busy: Bool)? = nil
    @Environment(AppServices.self) private var model

    private var selectedImages: [MacImage] {
        let rows = MacLibraryUI.store(model).images
        let selected = rows.filter { MacLibraryBrowser.shared.selection.contains($0.id) }
        if !selected.isEmpty { return selected }
        return rows.filter { $0.id == image?.id }
    }

    private var metadata: some View {
        HStack(spacing: MacMetric.pt(6)) {
            MacMetadataPicker(field: .rating, images: selectedImages, compact: true)
            MacMetadataPicker(field: .color, images: selectedImages, compact: true)
        }
        .fixedSize()
    }

    static var height: CGFloat { MacMetric.pt(28) }

    private var pad: CGFloat { MacMetric.pt(10) }
    private var gap: CGFloat { MacMetric.pt(14) }
    private static let size: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.height)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.wall).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.infostrip")
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        if chosen > 1 {
            HStack {
                // A paste onto the chosen pictures says so here for a while (`MacLibraryActions.notice`), in
                // 冲洗 and 编辑 too, where the sidebar's line is not shown; then the count again. What does
                // not fit is left off whole: the second sentence, then the notice.
                let count = Text(L("\(chosen.formatted()) photos selected")).font(MacMetric.font(Self.size, .medium))
                    .foregroundStyle(Theme.text).fixedSize()
                if let notice = MacLibraryActions.shared.notice {
                    ViewThatFits(in: .horizontal) {
                        Text(notice.line).fixedSize()
                        Text(notice.said).fixedSize()
                        count
                    }
                    .font(MacMetric.font(Self.size)).foregroundStyle(Theme.secondaryText)
                } else {
                    count
                }
                Spacer(minLength: 0)
                metadata
            }
            .padding(.horizontal, pad)
        } else if let image {
            let fit = Fit(image: image, status: status, room: width - pad * 2, gap: gap)
            let name = Text(image.fileName).font(MacMetric.font(Self.size, .medium)).foregroundStyle(Theme.text).fixedSize()
            ZStack {
                HStack(spacing: 0) {
                    leading(fit)
                    if fit.name && !fit.centred { name }
                    Spacer(minLength: 0)
                    if fit.rating {
                        metadata
                    }
                }
                // Centred, the name stands in the strip's middle, whatever the two sides hold.
                if fit.name && fit.centred { name }
            }
            .padding(.horizontal, pad)
            .frame(width: width)
        } else {
            Text(L("No image selected")).font(MacMetric.font(Self.size)).foregroundStyle(Theme.dim)
        }
    }

    /// The exposure and the develop's line, as far as they fit.
    @ViewBuilder private func leading(_ fit: Fit) -> some View {
        if !fit.exposure.isEmpty {
            Text(fit.exposure).font(MacMetric.font(Self.size)).foregroundStyle(Theme.secondaryText).fixedSize()
            Spacer().frame(width: gap)
        }
        if let line = fit.status {
            HStack(spacing: MacMetric.pt(5)) {
                Circle().fill(status?.busy == true ? Theme.accent : Theme.secondaryText)
                    .frame(width: MacMetric.pt(6), height: MacMetric.pt(6))
                Text(line).font(MacMetric.font(Self.size)).foregroundStyle(Theme.secondaryText).fixedSize()
            }
            Spacer().frame(width: gap)
        }
    }

    /// What fits, measured as it is drawn (`UIFont` at the font's size in the page's own points).
    struct Fit {
        var exposure = ""
        var status: String?
        var rating = true
        var centred = false
        var name = true

        @MainActor
        init(image: Item, status line: (text: String, busy: Bool)?, room: CGFloat, gap: CGFloat) {
            let size = MacInfoStrip.size / MacMetric.scale
            func w(_ s: String, _ weight: UIFont.Weight = .regular) -> CGFloat {
                ceil((s as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]).width)
            }
            let name = w(image.fileName, .medium)
            // Both menus stay present, including a neutral swatch for No Label. Reserve their hit
            // areas before secondary text so a narrow canvas cannot hide its metadata controls.
            let rated = MacMetric.pt(134)
            let dot = MacMetric.pt(6) + MacMetric.pt(5)
            rating = image.rated
            var left = room - (rating ? rated + gap : 0)
            if name + gap <= left { left -= name + gap } else { self.name = false }
            // The develop's line, whole or from its end, then the exposure in what is left.
            let parts = line.map { $0.text.components(separatedBy: Fmt.dot) } ?? []
            var statusW: CGFloat = 0
            for n in stride(from: parts.count, through: 1, by: -1) {
                let s = parts.prefix(n).joined(separator: Fmt.dot)
                let sw = dot + w(s) + gap
                if sw <= left { status = s; statusW = sw; break }
            }
            left -= statusW
            let exp = (image.exposure ?? "").components(separatedBy: " · ").filter { !$0.isEmpty }
            var expW: CGFloat = 0
            for n in stride(from: exp.count, through: 1, by: -1) {
                let s = exp.prefix(n).joined(separator: " · ")
                let ew = w(s) + gap
                if ew <= left { exposure = s; expW = ew; break }
            }
            // The name in the middle where the left side's parts leave it room to be.
            let side = (room - name) / 2
            centred = statusW + expW <= side - gap / 2 && (rating ? rated : 0) <= side
        }
    }
}
