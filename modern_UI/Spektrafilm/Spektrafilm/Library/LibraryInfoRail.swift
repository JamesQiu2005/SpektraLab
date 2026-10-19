//  LibraryInfoRail.swift — the Library's right rail: the selected photo's
//  preview, File, Capture, Capture One (read-only), SpektraLab, and Develop.
//
//  Whose picture is shown is said, not implied (the design's rule 4): the
//  preview is the file's own embedded one, and Capture One's adjustments are
//  never applied — SpektraLab develops the original.

import AppKit
import SwiftUI

struct LibraryInfoRail: View {
    @Bindable var library: LibraryModel
    let develop: (String?) -> Void

    var body: some View {
        if let row = library.selectedRow {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        preview(row)
                        fileSection(row)
                        if hasCaptureFacts(row) { captureSection(row) }
                        if row.isCaptureOne || library.isCaptureOne { captureOneSection(row) }
                        spektraLabSection(row)
                    }
                    .padding(12)
                }
                Hairline(tier: .region)
                actions(row)
                    .padding(12)
            }
        } else {
            VStack {
                Text(library.isOpen ? L("No photo selected", zh: "未选择照片") : "")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detail: LibraryImageDetail? { library.detail }

    private func preview(_ row: LibraryImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Metric.wellRadius).fill(Theme.navigatorWell)
                LibraryThumbnail(url: row.url, maxPixel: 640, offline: row.isOffline)
                    .padding(Theme.Metric.navigatorInset)
                if row.isOffline {
                    Text(L("Offline", zh: "离线"))
                        .font(Theme.Font.small)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0xC2453D)))
                }
            }
            .frame(height: Theme.Metric.navigatorHeight)
            Text(L("Embedded preview", zh: "内嵌预览"))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }

    private func fileSection(_ row: LibraryImage) -> some View {
        LibrarySection(title: L("File", zh: "文件")) {
            field(L("Name", zh: "名称"), row.fileName)
            field(L("Folder", zh: "文件夹"), row.url.deletingLastPathComponent().path)
            if let w = detail?.width, let h = detail?.height { field(L("Dimensions", zh: "尺寸"), "\(w) × \(h)") }
            if let s = detail?.fileSize { field(L("Size", zh: "大小"), ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)) }
        }
    }

    private func captureSection(_ row: LibraryImage) -> some View {
        LibrarySection(title: L("Capture", zh: "拍摄")) {
            if let cam = detail?.camera {
                if let m = [cam.make, cam.model].compactMap({ $0 }).joined(separator: " ").nilIfEmpty { field(L("Camera", zh: "相机"), m) }
                if let lens = cam.lens { field(L("Lens", zh: "镜头"), lens) }
            }
            if let e = detail?.exposure, let line = Self.exposureLine(e) { field(L("Exposure", zh: "曝光"), line) }
            if let f = detail?.exposure?.focalLength { field(L("Focal Length", zh: "焦距"), "\(Int(f.rounded())) mm") }
            if let t = row.capturedLocal { field(L("Taken", zh: "拍摄时间"), t.replacingOccurrences(of: "T", with: " ")) }
        }
    }

    /// A section with nothing in it is not drawn: a photo added without its
    /// metadata has no Capture facts to show.
    private func hasCaptureFacts(_ row: LibraryImage) -> Bool {
        row.capturedLocal != nil || detail?.camera?.model != nil || detail?.camera?.lens != nil
            || detail?.exposure.flatMap(Self.exposureLine) != nil || detail?.exposure?.focalLength != nil
    }

    private func captureOneSection(_ row: LibraryImage) -> some View {
        LibrarySection(title: "Capture One", trailing: AnyView(
            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Theme.Ink.tertiary))) {
            let v = detail?.variants.first { $0.uuid == library.variant(of: row)?.uuid }
            field(L("Rating", zh: "评级"), stars(v?.captureOne?.rating ?? row.rating))
            if let tag = v?.captureOne?.colorTag ?? row.colorTag, tag > 0 {
                HStack {
                    label(L("Colour Tag", zh: "色标"))
                    LibraryColorTag.swatch(tag).frame(width: 9, height: 9)
                }
            }
            if let albums = detail?.albums, !albums.isEmpty {
                field(L("Collections", zh: "汇集"), albums.compactMap(\.name).joined(separator: ", "))
            }
            field(L("Adjustments", zh: "调整"), L("Stay in Capture One", zh: "仅在 Capture One 中"))
        }
    }

    private func spektraLabSection(_ row: LibraryImage) -> some View {
        LibrarySection(title: "SpektraLab") {
            let chosen = library.variant(of: row)
            field(L("Print", zh: "印相"), (chosen?.hasEdit ?? false) ? L("Developed", zh: "已显影") : L("Not developed", zh: "未显影"))
            if row.variants.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    label(L("Variants", zh: "变体"))
                    ForEach(row.variants.sorted { $0.position < $1.position }) { v in
                        Button { library.choose(variant: v.uuid, for: row.uuid) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: v.uuid == chosen?.uuid ? "largecircle.fill.circle" : "circle")
                                    .font(Theme.Font.small)
                                Text(L("Variant", zh: "变体") + " \(v.position)")
                                    .font(Theme.Font.body)
                                Spacer()
                                if v.hasEdit { Text(L("Print", zh: "印相")).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary) }
                            }
                            .foregroundStyle(Theme.Ink.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !library.readOnly {
                HStack(spacing: 4) {
                    label(L("Rating", zh: "评级"))
                    Spacer()
                    ForEach(1...5, id: \.self) { n in
                        Button { Task { await library.setRating((chosen?.rating ?? 0) == n ? nil : n) } } label: {
                            Text("★").font(Theme.Font.body)
                                .foregroundStyle((chosen?.rating ?? row.rating) >= n ? Theme.Ink.primary : Theme.Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) {
                    label(L("Colour Tag", zh: "色标"))
                    Spacer()
                    ForEach(1...7, id: \.self) { t in
                        let on = (chosen?.colorTag ?? row.colorTag) == t
                        Button { Task { await library.setColorTag(on ? nil : t) } } label: {
                            LibraryColorTag.swatch(t).frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(on ? Theme.selection : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button(L("New Variant", zh: "新建变体")) { Task { await library.newVariant() } }
                .buttonStyle(.plain)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private func actions(_ row: LibraryImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if row.isOffline {
                Text(L("Original offline", zh: "原片离线"))
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(L("Show in Finder", zh: "在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                    .disabled(row.isOffline)
                if library.isCaptureOne, let path = library.info?.origin.path {
                    Button(L("Open in Capture One", zh: "在 Capture One 中打开")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Ink.secondary)
            Button { develop(row.uuid) } label: {
                Text(L("Develop", zh: "显影") + "  ⏎")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.onSelection)
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .disabled(!library.canDevelop(row))
            .opacity(library.canDevelop(row) ? 1 : Theme.disabledOpacity)
        }
    }

    // MARK: pieces

    private func label(_ s: String) -> some View {
        Text(s).font(Theme.Font.small).foregroundStyle(Theme.Ink.tertiary)
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(name).frame(width: 74, alignment: .leading)
            Text(value)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func stars(_ n: Int) -> String { n > 0 ? String(repeating: "★", count: n) : L("None", zh: "无") }

    static func exposureLine(_ e: LibraryImage.Exposure) -> String? {
        var parts: [String] = []
        if let s = e.shutter, s > 0 { parts.append(s >= 1 ? String(format: "%.0f s", s) : "1/\(Int((1 / s).rounded())) s") }
        if let a = e.aperture { parts.append(String(format: "f/%g", a)) }
        if let iso = e.iso { parts.append("ISO \(Int(iso))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
