//  InfoSheet.swift — B5 Info. the page layout (`info_sheet` in gen_flow.py)
//
//  What the camera recorded, what you changed, where the original lives, and
//  what this render is — four groups of 40 pt rows, the label quiet on the
//  left and the value on the right.
//
//  It says only what is true of this build. *This render · Effects* names
//  what the picture on the page went through: a demo frame is one SpektraLab
//  really developed (film in full, the print colour-only, as the reference device prints
//  — ARCHITECTURE §6.2), and so is a frame the engine has developed here. A
//  frame the engine has not reached yet, and any frame where no engine runs,
//  shows its camera's own preview, and Info says so rather than claim a
//  develop it did not get.
//
//  A frame read in place from Photos offers **Copy into Spek** under *Where* (2026-10-21): its original
//  is brought and kept in the app, so the photo may be deleted from Photos (`AppServices.copyIntoSpek`).
//  The row says while it works, and goes once *Original* says *In SpektraLab*.

import SwiftUI

struct InfoSheet: View {
    let frameID: LibraryFrame.ID
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(RenderQueue.self) private var scheduler
    @Environment(AppServices.self) private var model
    @State private var copying = false
    @State private var copyFailed = false

    var body: some View {
        VStack(spacing: 0) {
            if let frame = library.frame(frameID) {
                SheetHeader(title: frame.fileName, subtitle: Fmt.longStamp(frame.captureDate)) { router.dismissSheet() }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(groups(frame).enumerated()), id: \.offset) { i, group in
                            InfoGroup(title: group.title, rows: group.rows)
                                .padding(.top, i == 0 ? 18.3 : 19.4)
                            if i == 2, frame.readsFromPhotos || copying { copyIntoSpek(frame) }
                        }
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            } else {
                SheetHeader(title: L("Info")) { router.dismissSheet() }
            }
        }
    }

    private struct InfoSection { let title: String; let rows: [InfoRow.Model] }

    /// *Copy into Spek*: a row in accent under *Where*, and what it does said under it.
    private func copyIntoSpek(_ frame: LibraryFrame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupBox {
                Button {
                    guard !copying else { return }
                    copying = true
                    copyFailed = false
                    Task {
                        let kept = await model.copyIntoSpek([frame.id])
                        copying = false
                        copyFailed = kept == 0
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(copying ? L("Copying into SpektraLab…") : L("Copy into SpektraLab"))
                            .font(Theme.Font.ui(13.5, .semibold)).foregroundStyle(copying ? Theme.dim : Theme.accent)
                        Spacer(minLength: 0)
                        if copying { ProgressView().controlSize(.small).tint(Theme.dim) }
                        else { Icon(.copyIn, size: 18, color: Theme.accent) }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 1))
                .disabled(copying)
                .accessibilityIdentifier("info.copy-into-spek")
            }
            Text(copyFailed ? L("Photos would not give this photo's original. Try again when it has downloaded.")
                            : L("Keeps the original in SpektraLab, so the photo can be deleted from Photos."))
                .font(Theme.Font.note).foregroundStyle(copyFailed ? Theme.danger : Theme.dim)
                .padding(.horizontal, 20)
        }
        .padding(.horizontal, Theme.Metric.margin)
        .padding(.top, 8)
    }

    /// What the app keeps of this frame. The design keeps a preview copy of
    /// every frame; this build makes one only for a photo read in place from
    /// Photos (a linked folder's file is read where it is, a copied-in file is
    /// its own picture), so a frame this build brought in says what is really
    /// here. (A Photos frame's working copy is not kept: it is here while the
    /// frame is worked on, and goes: `WorkingCopies`.) A demo frame says what
    /// the drawings say.
    private func keptHere(_ frame: LibraryFrame) -> String {
        guard !frame.isDemo else { return frame.source.keptText }
        switch frame.source {
        case .photos: return L("The edit and a preview copy")
        case .linkedFolder: return L("The edit")
        case .copiedIn: return L("The original and the edit")
        }
    }

    /// What the picture on the page went through. Only a develop that is
    /// kept counts: until the engine has made one, the picture is the
    /// camera's own.
    private func effects(_ frame: LibraryFrame) -> String {
        if frame.isDemo { return L("Film in full · print colour-only") }
        guard scheduler.engine.makesPictures else { return L("None: no engine in this build") }
        return frame.developed != nil ? L("Film in full · print colour-only") : L("None: not developed yet")
    }

    private func groups(_ frame: LibraryFrame) -> [InfoSection] {
        let catalog = StockCatalog.shared
        let p = frame.edit.params
        // What Export makes at full size here: the crop, capped at this
        // device's limit, never called full when it is less.
        let full = frame.displaySize.scaled(toMegapixels: DevicePolicy.current.developCapMegapixels)
        let fullText = full == frame.displaySize
            ? L("\(full.text), on export")
            : L("\(full.text), this Mac's limit")
        let away = !frame.original.isAvailable && frame.original != .inCloud
        return [
            InfoSection(title: L("Capture"), rows: [
                .init(L("Camera"), frame.camera ?? L("Not recorded")),
                .init(L("Exposure"), frame.exposure ?? L("Not recorded")),
            ]),
            InfoSection(title: L("Develop"), rows: [
                .init(L("Film"), catalog.stock(p.filmStock)?.name ?? L("Unknown")),
                .init(L("Print", as: "the paper"), catalog.stock(p.printStock)?.name ?? L("Unknown")),
                .init(L("Changed"), frame.edit.changedText),
            ]),
            InfoSection(title: L("Where"), rows: [
                .init(L("Original", as: "the file"), frame.source.whereText, colour: away ? Theme.danger : Theme.text),
                .init(L("Kept here"), keptHere(frame)),
            ]),
            InfoSection(title: L("This render"), rows: [
                .init(L("Preview"), frame.previewSize.text),
                .init(L("Full size"), fullText),
                .init(L("Effects"), effects(frame)),
            ]),
        ]
    }
}

/// A section label over a box of rows.
private struct InfoGroup: View {
    let title: String
    let rows: [InfoRow.Model]

    var body: some View {
        VStack(spacing: 0) {
            SectionLabel(title).padding(.horizontal, 20)
            GroupBox {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    if i < rows.count - 1 { InfoRow(model: row).hairlineBelow() } else { InfoRow(model: row) }
                }
            }
            .padding(.horizontal, Theme.Metric.margin)
            .padding(.top, 5.5)
        }
    }
}

/// A 40 pt row: the label in secondary ink, the value in primary ink at the
/// trailing edge. A value too long for one line wraps under itself rather
/// than leave its frame.
private struct InfoRow: View {
    struct Model {
        let label: String
        let value: String
        var colour: Color = Theme.text
        init(_ label: String, _ value: String, colour: Color = Theme.text) {
            self.label = label; self.value = value; self.colour = colour
        }
    }
    let model: Model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.label).font(Theme.Font.ui(13.5)).foregroundStyle(Theme.secondaryText)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Text(model.value).font(Theme.Font.ui(13.5)).foregroundStyle(model.colour)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }
}
