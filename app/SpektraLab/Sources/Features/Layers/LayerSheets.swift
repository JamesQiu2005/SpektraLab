//  LayerSheets.swift — what the 图层 panel puts over the page: the sheet that asks for a photograph, the
//  refusal an export of an unfilled piece gets, and one exposure shown alone on the canvas
//  (design/layers/LAYERS-SPEC.md §6.3, §6.5, §6.6; the UX review's R9, R10).

import SwiftUI

extension View {
    /// The 图层 panel's sheet and alert for this page's frame (`LayersStage.asking`, `.refused`).
    func layerSheets(session: OpenFrameSession, frame: LibraryFrame) -> some View {
        modifier(LayerSheets(session: session, frame: frame))
    }
}

struct LayerSheets: ViewModifier {
    let session: OpenFrameSession
    let frame: LibraryFrame
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    private var stage: LayersStage { .shared }
    private var has: (UUID) -> Bool { { library.frame($0) != nil } }

    func body(content: Content) -> some View {
        let piece = session.layerPiece
        content
            .spkSheet(item: Binding(get: { stage.asking?.frame == frame.id ? stage.asking : nil }, set: { stage.asking = $0 }),
                      detents: [.large]) { asking in
                picker(asking, piece: piece).appEnvironment(model)
            }
            .alert(L("“\(frame.stem)” can’t be exported"),
                   isPresented: Binding(get: { stage.refused?.frame == frame.id }, set: { if !$0 { stage.refused = nil } }),
                   presenting: stage.refused) { refused in
                if refused.pick.isPicture {
                    Button({ if case .double = piece { L("Add Exposure") + "…" } else { L("Add Frame") + "…" } }()) {
                        session.pick(row: refused.pick)
                        stage.asking = .init(frame: frame.id, pick: refused.pick)
                    }
                }
                Button(L("OK"), role: .cancel) {}
            } message: { _ in
                Text(LayerRules.refusal(piece, has: has) ?? "")
            }
    }

    @ViewBuilder private func picker(_ asking: LayersStage.Asking, piece: LayerPiece) -> some View {
        let name = LayerRules.rows(piece, has: has).first { $0.pick == asking.pick }?.name ?? ""
        switch (piece, asking.pick) {
        case (.pair(let pair), .frame(let side)):
            MacPhotoPicker(title: pair[side] == nil ? L("Add Frame") : L("Replace Frame"), subtitle: name,
                           marked: Set(HalfFramePair.Side.allCases.compactMap { pair[$0]?.frame }), markedText: L("In this pair"),
                           confirm: pair[side] == nil ? L("Add") : L("Replace"),
                           close: { stage.asking = nil }) { chosen in
                if let photo = library.frame(chosen), !photo.isComposite {
                    model.changePair(frame.id) { piece, look in
                        piece.fill(side, with: PairStart.hole(for: photo), look: &look.params)
                    }
                }
                stage.asking = nil
            }
        case (.double(let double), .exposure(let position)):
            MacPhotoPicker(title: double[position] == nil ? L("Add Exposure") : L("Replace \(name)"),
                           subtitle: double[position] == nil ? name
                               : L("Choose a photograph for \(name); the old one stays in the library"),
                           marked: Set(DoubleExposure.Position.allCases.compactMap { double[$0]?.frame }),
                           markedText: L("In this double exposure"),
                           confirm: double[position] == nil ? L("Add") : L("Replace"),
                           close: { stage.asking = nil }) { chosen in
                model.replaceDouble(frame.id, position, with: chosen)
                stage.asking = nil
            }
        default:
            EmptyView()
        }
    }
}

/// **One exposure alone** over the canvas (R9; gap G3: `OpenFrameSession.alone` had no reader): that exposure
/// as it develops by itself (`AppServices.developAlone`), fitted as the canvas fits its picture, under a tag
/// that says which. The double stays under it until the develop lands, and is what shows again when the eye
/// is put out. Developed again when the piece or the look moves.
struct LayerAloneOverlay: View {
    let session: OpenFrameSession
    let frame: LibraryFrame
    let position: DoubleExposure.Position
    let aspect: CGFloat
    @Environment(AppServices.self) private var model
    @State private var image: CGImage?
    @State private var developing = false

    private struct Key: Equatable {
        var position: DoubleExposure.Position
        var double: DoubleExposure?
        var edit: FrameEdit
    }

    var body: some View {
        GeometryReader { geo in
            let picture = ArrangeOverlay.fit(aspect: aspect, in: geo.size)
            ZStack(alignment: .topLeading) {
                if let image {
                    Theme.background
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: picture.width, height: picture.height)
                        .offset(x: picture.minX, y: picture.minY)
                        .accessibilityIdentifier("layers.alone.picture")
                }
                HStack(spacing: 6) {
                    if developing { ProgressView().controlSize(.small) }
                    Text(position == .top ? L("Top alone") : L("Bottom alone"))
                        .font(Theme.Font.ui(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                }
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Theme.card))
                .offset(x: picture.minX + 10, y: picture.minY + 10)
                .accessibilityIdentifier("layers.alone.tag")
            }
        }
        .allowsHitTesting(false)
        .task(id: Key(position: position, double: session.double?.developed, edit: session.edit)) {
            developing = true
            // The pointer may still be on a control: one develop for where it rests.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let made = await model.developAlone(frame.id, position)
            guard !Task.isCancelled else { return }
            if let made { image = made }
            developing = false
        }
    }
}
