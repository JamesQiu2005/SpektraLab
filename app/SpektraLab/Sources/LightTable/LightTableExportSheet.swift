//  LightTableExportSheet.swift — Share on the light table: Poster or Contact Sheet, then the system's sheet.
//
//  The owner, 2026-10-17: "allow the user to choose different exports … we click into the sharing,
//  and we may choose this. Grey out options that's not selectable, particularly for the poster
//  version." The table's *Share* opens this sheet; its button draws the picture offscreen and hands
//  the **file** to Apple's share sheet (`UIActivityViewController`), so Save to Files keeps a PNG's
//  transparency and its full size.
//
//      ┌ Share                                  ⓧ ┐   the app's sheet: `SheetHeader`, its plot colour
//      │ 8 films · A4 (· Landscape)               │
//      │ [   Poster   |   Contact Sheet    ]      │   the two pictures (`SegmentedSwitch`, as Save to)
//      │ ┌ Style    [With Light Table|Layout Only]│   one grouped box, the Export sheet's rows
//      │ │ Format                     [PNG | JPG] │
//      │ │ Size                         2,000 px  │
//      │ │ 1,000 ───────●──────────────── 5,000   │   1,000 to 5,000 by 100 (HIG: a slider with its value)
//      │ └ File 2,316 × 3,203  ·  7.4 MP          │   the file's real pixels, the shadow's margin included
//      │ what this picture is, and why a row is grey  │
//      │ (            Share Contact Sheet        ) │   the accent capsule; Stop while it draws
//      └──────────────────────────────────────────┘
//
//  - **Poster**: Style, Format and Size are shown with the poster's fixed values (the table with its
//    rim, JPG, 1,568 × 2,400) and greyed, as the Export sheet greys what cannot be chosen.
//  - **With Light Table**: JPG greyed (no transparency in a JPG), the note says so.
//  - **Layout Only**: everything open.
//  - The last choice is remembered (`@AppStorage`, the device's own defaults: a convenience, not a
//    setting). While it draws, the note becomes the status line with the share done, and the
//    button *Stop*; leaving the sheet stops it too.
//
//  Presented by UIKit over the table's page (`present`), dressed as `spkSheet` dresses the app's
//  sheets, so the page itself changes only in its Share button's action.

import SwiftUI
import UIKit

extension LightTableExportKind {
    var title: String { self == .poster ? L("Poster") : L("Contact Sheet") }
}

extension LightTableExportStyle {
    var title: String { self == .withTable ? L("With Light Table") : L("Layout Only") }
}

struct LightTableExportSheet: View {
    let table: LightTableController
    /// Closes the sheet.
    let close: () -> Void
    /// The file made, to the system's share sheet; `done(true)` once it was used, and the file goes.
    let hand: (URL, @escaping (Bool) -> Void) -> Void

    enum Keys {
        static let kind = "lighttable.export.kind"
        static let style = "lighttable.export.style"
        static let format = "lighttable.export.format"
        static let shortEdge = "lighttable.export.shortEdge"
    }

    @AppStorage(Keys.kind) private var kind = LightTableExportKind.poster
    @AppStorage(Keys.style) private var style = LightTableExportStyle.withTable
    @AppStorage(Keys.format) private var format = LightTableExportFormat.jpg
    @AppStorage(Keys.shortEdge) private var shortEdge = LightTableExportPlan.defaultShortEdge
    /// 0…1 while the picture is drawn; nil otherwise.
    @State private var progress: Double?
    @State private var cancel: LightTableExportCancel?
    @State private var problem: String?

    /// The sheet's height above the home indicator: `present`'s detent.
    static let height: CGFloat = 470

    private var choice: LightTableExportChoice {
        LightTableExportChoice(kind: kind, style: style, format: format, shortEdge: LightTableExportPlan.clampShortEdge(shortEdge))
    }

    private var poster: Bool { kind == .poster }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L("Share"), subtitle: subtitle) {
                cancel?.cancel()
                close()
            }
            // On a host on its side the sheet is shorter than its rows: they scroll, the button stays
            // at the foot. Upright they fit, and nothing moves.
            ScrollView {
                VStack(spacing: 0) {
                    SegmentedSwitch(options: LightTableExportKind.allCases, selection: $kind, title: \.title, height: 32, track: Theme.card)
                        .padding(.horizontal, Theme.Metric.margin)
                        .padding(.top, 8)
                        .allowsHitTesting(progress == nil)
                        .accessibilityIdentifier("lighttable.export.kind")
                    GroupBox(radius: 14) {
                        styleRow
                        RowSeparator(leading: 14)
                        formatRow
                        RowSeparator(leading: 14)
                        sizeRow
                    }
                    .padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, 16)
                    Group {
                        if let progress {
                            VStack(alignment: .leading, spacing: 10) {
                                StatusLine(text: L("Drawing \(dimensions)") + Fmt.dot + "\(Int((progress * 100).rounded()))%")
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Theme.card)
                                        Capsule().fill(Theme.accent).frame(width: max(4, geo.size.width * progress))
                                    }
                                }
                                .frame(height: 4)
                                .accessibilityHidden(true)
                            }
                        } else {
                            Note(problem ?? note, color: problem == nil ? Theme.dim : Theme.danger)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            Group {
                if progress != nil {
                    CapsuleButton(title: L("Stop"), primary: false, height: 48) { cancel?.cancel() }
                } else {
                    CapsuleButton(title: poster ? L("Share Poster") : L("Share Contact Sheet"), height: 48) { start() }
                        .accessibilityIdentifier("lighttable.export.share")
                }
            }
            .padding(.horizontal, Theme.Metric.margin)
            .padding(.bottom, SheetLayout.buttonBottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.sheet.ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .foregroundStyle(Theme.text)
        .appColorScheme()
        .onDisappear { cancel?.cancel() }
    }

    // MARK: the rows

    private var styleRow: some View {
        row(L("Style"), enabled: !poster && progress == nil) {
            SegmentedSwitch(options: LightTableExportStyle.allCases, selection: poster ? .constant(.withTable) : $style,
                            title: \.title, segmentWidth: 118)
        }
    }

    private var formatRow: some View {
        // With Light Table is PNG only: JPG is shown, greyed, and cannot be chosen.
        let selection: Binding<LightTableExportFormat> = poster ? .constant(.jpg) : (style == .withTable ? .constant(.png) : $format)
        return row(L("Format"), enabled: !poster && progress == nil) {
            SegmentedSwitch(options: LightTableExportFormat.allCases, selection: selection, title: \.title, segmentWidth: 58,
                            disabled: !poster && style == .withTable ? [.jpg] : [])
        }
    }

    private var sizeRow: some View {
        let range = Double(LightTableExportPlan.shortEdges.lowerBound)...Double(LightTableExportPlan.shortEdges.upperBound)
        let value = Binding<Double>(
            get: { Double(poster ? posterShort : choice.shortEdge) },
            set: { shortEdge = LightTableExportPlan.clampShortEdge(Int($0.rounded())) })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Size")).font(Theme.Font.ui(14, .semibold))
                Spacer(minLength: 8)
                Text(poster ? dimensions : "\(Fmt.thousands(choice.shortEdge)) px")
                    .font(Theme.Font.ui(14, .medium)).monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(height: 30)
            Slider(value: value, in: range, step: Double(LightTableExportPlan.shortEdgeStep)) {
                Text(L("Size"))
            } minimumValueLabel: {
                Text(Fmt.thousands(LightTableExportPlan.shortEdges.lowerBound)).font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.dim)
            } maximumValueLabel: {
                Text(Fmt.thousands(LightTableExportPlan.shortEdges.upperBound)).font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.dim)
            }
            .tint(Theme.accent)
            .accessibilityValue(poster ? dimensions : L("\(Fmt.thousands(choice.shortEdge)) pixels"))
            Text(fileLine).font(Theme.Font.ui(11.5, .medium)).foregroundStyle(Theme.dim).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .rowEnabled(!poster && progress == nil)
    }

    private func row<C: View>(_ label: String, enabled: Bool, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.Font.ui(14, .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .rowEnabled(enabled)
    }

    // MARK: words

    /// "8 films  ·  A4", "8 films  ·  A5  ·  Landscape".
    private var subtitle: String { LightTablePane.films(table.model.pile.count) + Fmt.dot + LightTablePane.tableName(table.model) }

    private var pixels: (width: Int, height: Int) { LightTableExport.pixels(choice, half: table.model.half) }

    private var posterShort: Int { let p = LightTableExportPlan.posterPixels(half: table.model.half); return min(p.width, p.height) }

    /// "1,568 × 2,400".
    private var dimensions: String { "\(Fmt.thousands(pixels.width)) × \(Fmt.thousands(pixels.height))" }

    /// "File 2,316 × 3,203  ·  7.4 MP", "JPG  ·  1,568 × 2,400".
    private var fileLine: String {
        let mp = Fmt.megapixels(Double(pixels.width) * Double(pixels.height) / 1e6)
        return L("File \(dimensions)") + Fmt.dot + mp
    }

    /// What the picture is, and why a row is grey.
    private var note: String {
        switch (kind, style) {
        case (.poster, _):
            L("A picture to share: the table on a white desk, with the SpektraLab mark and a code to the app. Its style, format and size are fixed.")
        case (.contactSheet, .withTable):
            L("The table with its rim and its light, on a clear ground under a soft shadow. PNG only: a JPG cannot keep the clear ground. Size is the table's short edge; the shadow adds a margin.")
        case (.contactSheet, .layoutOnly):
            L("The \(table.model.paper.name) sheet alone, flat, with its scale and every film at its size. Size is the sheet's short edge; it prints at \(table.model.paper.name).")
        }
    }

    // MARK: drawing

    private func start() {
        guard progress == nil else { return }
        problem = nil
        let c = LightTableExportCancel()
        cancel = c
        progress = 0
        let choice = self.choice
        Task { @MainActor in
            do {
                let made = try await LightTableExport.run(choice, table: table, cancel: c) { p in
                    if progress != nil { progress = p }
                }
                progress = nil
                cancel = nil
                hand(made.url) { used in
                    try? FileManager.default.removeItem(at: made.url.deletingLastPathComponent())
                    if used { close() }
                }
            } catch {
                progress = nil
                cancel = nil
                switch error as? LightTableExportFailure {
                case .cancelled: break
                case .memory: problem = L("There is not enough memory for this size just now. Try a smaller one.")
                default: problem = L("The picture could not be made.")
                }
            }
        }
    }
}

// MARK: - presenting it

@MainActor
enum LightTableExportPresenter {
    private final class Holder { weak var host: UIViewController? }

    /// The sheet over whatever is in front: the table's page.
    static func present(_ table: LightTableController, onClose: (() -> Void)? = nil) {
        guard let top = topController() else { return }
        let holder = Holder()
        let sheet = LightTableExportSheet(
            table: table,
            close: { holder.host?.dismiss(animated: true) },
            hand: { url, done in share(url, over: holder.host, done) })
        let host = UIHostingController(rootView: sheet)
        holder.host = host
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = UIColor(Theme.sheet)
        host.modalPresentationStyle = .pageSheet
        if let s = host.sheetPresentationController {
            s.detents = [.custom(identifier: .init("lighttable.export")) { ctx in min(LightTableExportSheet.height, ctx.maximumDetentValue) }]
            s.preferredCornerRadius = Theme.Metric.sheetRadius
            s.prefersGrabberVisible = false            // `SheetHeader` draws the drawing's own
        }
        top.present(host, animated: true)
    }

    /// Apple's share sheet with the file, over the export sheet.
    static func share(_ url: URL, over host: UIViewController?, _ done: @escaping (Bool) -> Void) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, completed, _, _ in done(completed) }
        guard let over = host ?? topController() else { done(false); return }
        sheet.popoverPresentationController?.sourceView = over.view
        over.present(sheet, animated: true)
    }

    static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
