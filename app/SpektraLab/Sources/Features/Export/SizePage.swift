//  SizePage.swift — an export's size: the original's, free's 12 MP, or an edge in pixels.
//
//  The owner, 2026-10-20: "a page that allows you to choose export at full
//  size, or customizable size based on the long edge or the short edge using
//  pixel count", never larger than the original — "design the UI with
//  caution". Until then Size was a switch of three: Full, 12 MP, 2048.
//
//  - **A page of its own, pushed** (Apple's HIG: a choice that needs more than
//    a word is a list one level down), from the Size row of the Export sheet
//    and of a recipe in Settings: its back button names where it came from,
//    as every pushed page of the app's does (`SettingsPageHeader`).
//  - **One list, one choice**, ticked as the recipes' list is ticked (the
//    accent's check at the leading edge): Full size, 12 MP, Long edge, Short
//    edge. Each says, under its name, what it makes of the frame — "4,096 ×
//    2,731 · 11.2 MP" — so a number is never chosen blind; for several frames,
//    what it makes of each.
//  - **An edge is typed**, in pixels, on the number pad, in a field at the
//    row's trailing edge: a tap on the row chooses it and puts the cursor in
//    its field. The field starts empty with its number as the hint, so what
//    is typed is the number, never digits run into the old ones; left empty,
//    the number stays. The number pad has no return key, so the header says
//    Done while a field is being typed in. What is typed is followed at once
//    by the line under it.
//  - **Never larger than the original.** A number past the original's own
//    edge is held to it — the line says so — and is put back to it when
//    typing ends. Never smaller than 16 px.

import SwiftUI

struct ExportSizePage: View {
    /// The frames the size is for: one, several, or none (a recipe in Settings).
    let frames: [LibraryFrame]
    @Binding var size: ExportRecipe.Size
    /// The back button's word: where the page was pushed from.
    let backTitle: String
    /// In a sheet: the sheet's grabber over the header, and `back` instead of a navigation pop.
    var inSheet = false
    var back: (() -> Void)? = nil

    @Environment(ExportService.self) private var exporter
    @Environment(\.dismiss) private var dismiss

    private enum Edge: Hashable { case long, short }
    @State private var longText = ""
    @State private var shortText = ""
    /// A field's number while it is typed in from empty: its hint, and what it keeps if nothing is typed.
    @State private var hint: [Edge: String] = [:]
    @FocusState private var typing: Edge?

    static let smallestEdge = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GroupBox(radius: 14) {
                        choice(.full, L("Full size"), line: line(.full)) { EmptyView() }
                        .choiceSeparated()
                        choice(.megapixels(ExportRecipe.twelveMegapixels), "\(Int(ExportRecipe.twelveMegapixels)) MP",
                               line: line(.megapixels(ExportRecipe.twelveMegapixels))) { EmptyView() }
                            .choiceSeparated()
                        edgeRow(.long)
                            .choiceSeparated()
                        edgeRow(.short)
                    }
                    .padding(.horizontal, Theme.Metric.margin)
                    .padding(.top, 20)
                    Note(note).padding(.horizontal, 20).padding(.top, 10)
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .background((inSheet ? Theme.sheet : Theme.background).ignoresSafeArea())
        // In the sheet, a drag from the leading edge goes back, as a pushed page's does.
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { v in
            guard inSheet, v.startLocation.x < 32, v.translation.width > 80, abs(v.translation.height) < 60 else { return }
            goBack()
        })
        .onAppear(perform: load)
        .macPageActions(confirm: { if typing != nil { typing = nil } else { goBack() } }, cancel: goBack)
        .onChange(of: typing) { was, now in
            // Typing ended in a field: its number held to what it can be, and shown as that.
            if let was, was != now { commit(was) }
            // A field begun: empty, its number the hint; and it chooses its row, as a tap on the row does.
            if let now, now != was {
                hint[now] = now == .long ? longText : shortText
                if now == .long { longText = "" } else { shortText = "" }
                pick(edgeSize(now))
            }
        }
    }

    // MARK: the header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if inSheet {
                Capsule().fill(Theme.text.opacity(0.28)).frame(width: 36, height: 5)
                    .frame(maxWidth: .infinity).padding(.top, 7).padding(.bottom, 6)
            }
            HStack(spacing: 0) {
                Button { goBack() } label: {
                    HStack(spacing: 8) {
                        Icon(.back).frame(width: 8)
                        Text(backTitle).font(Theme.Font.ui(15)).foregroundStyle(Theme.text)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 12)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(L("Back to \(backTitle)"))
                Spacer()
                if typing != nil {
                    Button { typing = nil } label: {
                        Text(L("Done")).font(Theme.Font.ui(15, .semibold)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 20).frame(height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
            }
            Text(L("Size")).font(Theme.Font.pageTitle).foregroundStyle(Theme.text)
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goBack() {
        typing = nil
        commit(.long); commit(.short)
        if let back { back() } else { dismiss() }
    }

    // MARK: the rows

    /// One choice: the tick, its name and what it makes, and what stands at its trailing edge.
    @ViewBuilder private func choice<Trailing: View>(_ value: ExportRecipe.Size, _ title: String, line: String,
                                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        let picked = sameKind(size, value)
        Button { pick(value) } label: {
            row(picked: picked, title: title, line: line, trailing: trailing)
        }
        .buttonStyle(PressStyle(scale: 1))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func row<Trailing: View>(picked: Bool, title: String, line: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Icon(.menuCheck, size: 18, color: Theme.accent).opacity(picked ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.listLabel).foregroundStyle(Theme.text).lineLimit(1)
                Text(line).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }

    /// Long edge, Short edge: the row chooses it and puts the cursor in its field.
    private func edgeRow(_ edge: Edge) -> some View {
        let value = edgeSize(edge)
        let picked = sameKind(size, value)
        let title = edge == .long ? L("Long edge") : L("Short edge")
        return Button {
            pick(value)
            typing = edge
        } label: {
            row(picked: picked, title: title, line: line(value, typed: edge)) {
                HStack(spacing: 6) {
                    TextField("", text: edge == .long ? $longText : $shortText,
                              prompt: Text(hint[edge] ?? "").foregroundStyle(Theme.dim))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(Theme.Font.ui(15, .medium)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .focused($typing, equals: edge)
                        .padding(.horizontal, 10)
                        .frame(width: 92, height: 34)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(typing == edge ? Theme.accent : Theme.rule, lineWidth: typing == edge ? 1.5 : 1))
                        .accessibilityLabel(L("\(title), in pixels"))
                        .onChange(of: edge == .long ? longText : shortText) { _, text in typed(edge, text) }
                    Text("px").font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.dim)
                }
            }
        }
        .buttonStyle(PressStyle(scale: 1))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    // MARK: choosing

    private func pick(_ value: ExportRecipe.Size) {
        if typing != nil, !isEdge(value) { typing = nil }
        size = value
    }

    /// What was typed: digits only, five at most; the size follows at once,
    /// held to what it can be, while its row is the one chosen.
    private func typed(_ edge: Edge, _ text: String) {
        let digits = String(text.filter(\.isNumber).prefix(5))
        if digits != text {
            if edge == .long { longText = digits } else { shortText = digits }
            return
        }
        let value = edgeSize(edge)
        if typing == edge || sameKind(size, value) { size = value }
    }

    /// Typing ended: the field shows the number the file is made at.
    private func commit(_ edge: Edge) {
        // Nothing typed: the number it had.
        let text = edge == .long ? longText : shortText
        let n = Int(text) ?? Int(hint[edge] ?? "") ?? (edge == .long ? 2048 : 1080)
        hint[edge] = nil
        let held = String(heldEdge(edge, n))
        if edge == .long { longText = held } else { shortText = held }
        let value = edgeSize(edge)
        if sameKind(size, value) { size = value }
    }

    private func load() {
        longText = String(heldEdge(.long, { if case .longEdge(let e) = size { e } else { 2048 } }()))
        shortText = String(heldEdge(.short, { if case .shortEdge(let e) = size { e } else { 1080 } }()))
    }

    // MARK: sizes

    /// The edge a field names, held between 16 px and the largest original's edge.
    private func heldEdge(_ edge: Edge, _ n: Int) -> Int {
        let most = edge == .long ? largest.long : largest.short
        return min(max(n, Self.smallestEdge), max(most, Self.smallestEdge))
    }

    private func edgeSize(_ edge: Edge) -> ExportRecipe.Size {
        let text = edge == .long ? longText : shortText
        let n = heldEdge(edge, Int(text) ?? Int(hint[edge] ?? "") ?? (edge == .long ? 2048 : 1080))
        return edge == .long ? .longEdge(n) : .shortEdge(n)
    }

    /// The largest file of the frames at Full: no field names more than it.
    /// (A frame in its film is larger than its picture: the film is in the file.)
    /// No frames (a recipe in Settings): any edge, up to five digits.
    private var largest: (long: Int, short: Int) {
        guard !frames.isEmpty else { return (99_999, 99_999) }
        let full = frames.prefix(24).map { f -> PixelSize in
            var r = ExportRecipe()
            r.size = .full
            return exporter.outputSize(f, r)
        } + frames.dropFirst(24).map(\.originalSize)
        return (full.map(\.longEdge).max() ?? 0, full.map(\.shortEdge).max() ?? 0)
    }

    private func isEdge(_ s: ExportRecipe.Size) -> Bool {
        switch s { case .longEdge, .shortEdge: true; default: false }
    }

    /// Two sizes of one kind: a long edge is a long edge, whatever its number.
    private func sameKind(_ a: ExportRecipe.Size, _ b: ExportRecipe.Size) -> Bool {
        switch (a, b) {
        case (.longEdge, .longEdge), (.shortEdge, .shortEdge): true
        default: a == b
        }
    }

    // MARK: words

    /// What a size makes: of the one frame, "8,256 × 5,504 · 45.4 MP, the original";
    /// of several, what it makes of each.
    private func line(_ value: ExportRecipe.Size, typed edge: Edge? = nil) -> String {
        guard frames.count == 1, let frame = frames.first else {
            switch value {
            case .full: return L("Each frame at its original's size")
            case .megapixels(let mp): return L("Each frame at \(Int(mp)) MP")
            case .longEdge(let e): return L("Each frame \(Fmt.thousands(e)) px on its long edge")
            case .shortEdge(let e): return L("Each frame \(Fmt.thousands(e)) px on its short edge")
            case .preview: return ""
            }
        }
        var recipe = ExportRecipe()
        recipe.size = value
        let original = frame.edit.filmEdge.effective ? L(", the original in its film") : L(", the original")
        let out = exporter.outputSize(frame, recipe)
        var words = out.text + Fmt.dot + Fmt.megapixels(out.megapixels)
        switch exporter.limit(frame, recipe) {
        case .device?: words += L(", this Mac's limit")
        case nil:
            if value == .full { words += original }
            else if let edge, let asked = Int(edge == .long ? longText : shortText),
                    asked > (edge == .long ? largest.long : largest.short) {
                words += L(", no larger than the original")
            }
        }
        return words
    }

    private var note: String {
        var words: String
        if frames.count == 1, let frame = frames.first {
            words = L("Never larger than the original: \(frame.originalSize.text).")
            // A film's edge is drawn round the picture: the file is the film, larger than the picture.
            if frame.edit.filmEdge.effective { words += " " + L("Its film edge is drawn round it.") }
        } else {
            words = L("Each frame is made no larger than its original.")
        }
        return words
    }
}

/// The Size row: what the size is, what it makes, and the page it opens.
struct ExportSizeRow: View {
    let size: ExportRecipe.Size
    /// What it makes, under it: the file's real size. Nil keeps the row one line high.
    var line: String? = nil
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            DrawnBand(height: line == nil ? 46 : 68) {
                DrawnText(L("Size"), 14, .semibold).leading(14).baseline(line == nil ? 29 : 25)
                DrawnText(ExportWords.short(size), 14, .medium, Theme.secondaryText).trailingInset(30).baseline(line == nil ? 29 : 25)
                Chevron().trailingInset(19).centreY(line == nil ? 24 : 20)
                if let line {
                    DrawnText(line, 11.5, .medium, Theme.dim).trailingInset(14).baseline(54)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 1))
        .accessibilityLabel(L("Size, \(ExportWords.short(size))"))
        .accessibilityHint(line ?? "")
    }
}

private extension View {
    /// The hairline under a choice, from where its name begins (past the tick).
    func choiceSeparated() -> some View {
        overlay(alignment: .bottom) { RowSeparator(leading: 40).offset(y: 0.5) }
    }
}
