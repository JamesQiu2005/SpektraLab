//  MacCombineMenu.swift — 合成 (Combine): a double exposure or a half-frame pair of the pictures chosen
//  (PRD-D §3.6; design/layers/LAYERS-SPEC.md §6.1, §6.2).
//
//  One name for the two pieces a library makes of photographs, in 图库 only: a labelled pull-down on the
//  window's bar and the same two items in a picture's menu. Each item says what it makes and, with two
//  pictures chosen, **which goes where** — the order they were picked in, kept (R6): the first is a double's
//  bottom and a pair's left. One picture chosen asks for the second (`SecondExposurePicker`; the pair's
//  *Pair With*). A pair or a double is not combined again, and the items say so rather than vanish.

import SwiftUI

/// The two items, wherever they are listed.
struct MacCombineItems: View {
    /// The chosen pictures, in the order they were picked.
    let chosen: [MacImage]
    let makeDouble: (([MacImage]) -> Void)?
    let makePair: ([MacImage]) -> Void
    @Environment(FrameCatalog.self) private var library

    /// Why nothing can be made of what is chosen, or nil.
    private var refusal: String? {
        guard (1...2).contains(chosen.count) else { return L("Choose one or two photographs") }
        let composite = chosen.contains { $0.kind == .pair || $0.develop.flatMap { library.frame($0.frameID) }?.isComposite == true }
        return composite ? L("A pair or a double exposure cannot be combined again") : nil
    }

    private func name(_ image: MacImage) -> String { (image.fileName as NSString).deletingPathExtension }

    var body: some View {
        let refusal = refusal
        if let makeDouble {
            Button { makeDouble(chosen) } label: {
                Label(L("Double Exposure"), systemImage: "square.2.layers.3d")
                Text(refusal ?? (chosen.count == 2
                                 ? DoubleExposure.Layer.bottom.title + " " + name(chosen[0]) + Fmt.dot + DoubleExposure.Layer.top.title + " " + name(chosen[1])
                                 : L("Two exposures on one frame of film")))
            }
            .disabled(refusal != nil)
            .accessibilityIdentifier("combine.double")
        }
        Button { makePair(chosen) } label: {
            Label(L("Half-Frame Pair"), systemImage: "rectangle.split.2x1")
            Text(refusal ?? (chosen.count == 2
                             ? L("Left frame") + " " + name(chosen[0]) + Fmt.dot + L("Right frame") + " " + name(chosen[1])
                             : L("Two half frames on one piece of film")))
        }
        .disabled(refusal != nil)
        .accessibilityIdentifier("combine.pair")
    }
}

/// 合成 on the window's bar, in 图库: a labelled pull-down, so the bar says what it is.
struct MacCombineMenu: View {
    let chosen: [MacImage]
    let makeDouble: ([MacImage]) -> Void
    let makePair: ([MacImage]) -> Void

    var body: some View {
        Menu {
            MacCombineItems(chosen: chosen, makeDouble: makeDouble, makePair: makePair)
        } label: {
            HStack(spacing: MacMetric.pt(5)) {
                Image(systemName: "square.2.layers.3d").font(.system(size: MacMetric.pt(12), weight: .medium))
                Text(L("Combine")).font(.system(size: MacMetric.pt(12.5), weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: MacMetric.pt(8), weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, MacMetric.pt(11))
            .frame(height: MacMetric.pt(28))
            .background(Capsule().fill(Theme.card))
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L("Combine"))
        .accessibilityIdentifier("combine.menu")
    }
}

/// **A photograph asked for, on the Mac**: the library's own rows — the pictures the browser shows, a frame made
/// for the one chosen as Develop makes one (`MacLibraryData.frames`) — where the window pages' picker
/// (`PairFramePicker`) lists the app's frames, which on the Mac are only the pictures opened so far. Pick, then
/// confirm; a double click does both (the owner's decision 6). A pair or a double is not offered: a piece is
/// not a photograph. A picture the piece already holds is marked, and can still be chosen.
struct MacPhotoPicker: View {
    let title: String
    let subtitle: String
    /// The frames the piece already holds, and what their tiles say.
    var marked: Set<LibraryFrame.ID> = []
    var markedText = ""
    /// "Create", "Add", "Replace".
    let confirm: String
    let close: () -> Void
    let choose: (LibraryFrame.ID) -> Void
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    @State private var picked: MacImage.ID?
    @State private var working = false

    private var rows: [MacImage] {
        MacLibraryUI.store(model).images.filter { image in
            image.kind != .pair && image.develop.flatMap { library.frame($0.frameID) }?.isComposite != true
                && !["spektradouble", "spektrapair"].contains(image.url.pathExtension.lowercased())
        }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle, onClose: close)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 8)], spacing: 8) {
                    ForEach(rows) { image in
                        let isMarked = image.develop.map { marked.contains($0.frameID) } ?? false
                        VStack(spacing: 4) {
                            MacFileThumb(url: image.url, box: CGSize(width: 132, height: 92))
                                .frame(height: 92)
                                .frame(maxWidth: .infinity)
                            Text(isMarked ? markedText : image.fileName)
                                .font(Theme.Font.ui(11.5, isMarked ? .semibold : .regular))
                                .foregroundStyle(isMarked ? Theme.text : Theme.secondaryText)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(picked == image.id ? Theme.card : .clear))
                        .overlay {
                            if picked == image.id {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.selectionFrame, lineWidth: 1.5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { picked = image.id; create(image.id) }
                        .onTapGesture { picked = image.id }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(image.fileName + (isMarked ? ", " + markedText : ""))
                        .accessibilityAddTraits(picked == image.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            FoldRule()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                CapsuleButton(title: L("Cancel"), primary: false, height: 34, width: 110, action: close)
                CapsuleButton(title: confirm, height: 34, width: 110, enabled: picked != nil && !working) {
                    if let picked { create(picked) }
                }
                .accessibilityIdentifier("photo-picker.confirm")
            }
            .padding(.horizontal, 16).frame(height: 58)
        }
        .accessibilityIdentifier("photo-picker")
    }

    /// The picture's frame, made if it has none, then handed back.
    private func create(_ id: MacImage.ID) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let (frames, _) = try await MacLibraryUI.store(model).frames(for: [id], focus: id)
                if let frame = frames[id] { choose(frame) }
            } catch {
                MacLibraryActions.shared.refusal = error.localizedDescription
                close()
            }
        }
    }
}
