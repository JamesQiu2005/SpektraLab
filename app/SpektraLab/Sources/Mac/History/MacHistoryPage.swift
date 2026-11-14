//  MacHistoryPage.swift — 编辑历史, a frame's edit history (PRD-F §4), presented as *Info* is (`SheetRoute.history`).
//
//  Opened from the library grid's and Develop's browser's menu with one picture chosen (*Edit History…*, after
//  *Copy Settings*) and from the Edit menu under Undo and Redo (`DevelopMenuCommands`). What it shows is the store's,
//  read through the app's one line (`EditHistoryLine`, metadata only: 256 rows in under a millisecond), newest first:
//  the current step with a dot, the steps ahead of it (Redo's) dimmed, each step's time — with its date when it was
//  another day — its name (`HistoryLabel.text`, looked up as it is drawn, so a language switch relabels it) and where
//  it was made, and at the foot the state it all began from: *Original*, or *Earlier edits* once a step past 256
//  dropped the first. No thumbnails: each would be a develop, and only a person's act develops (MAC-LIBRARY-DATA §2e).
//
//  **Go to This Step** (or a double-click on a row) moves the cursor there, the way Lightroom's History panel does:
//  no step, the redo tail kept until the next edit, the same as that many ⌘Z or ⇧⌘Z (`AppServices.goToStep`). With the
//  frame open in Develop the page's session does it and the canvas follows; with it closed the edit is written to the
//  library and its preview developed. While an export is reading the frame it is refused, and the page says why
//  (AGENTS.md trap 34). **Clear History…** asks first, and keeps the edit as it stands as *Original*.
//
//  The page stays the history's while it is open: every write sent down the line (a step on the develop page behind
//  it, an Undo, a paste from the grid, its own Go and Clear) is counted (`EditHistoryLine.writes`), and the listing is
//  read again after it.

import QuartzCore
import SwiftUI

struct MacHistoryPage: View {
    let frameID: LibraryFrame.ID
    @Environment(AppRouter.self) private var router
    @Environment(FrameCatalog.self) private var library
    @Environment(AppServices.self) private var model
    @State private var page = MacHistoryPageModel()
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L("Edit History"), subtitle: library.frame(frameID)?.fileName) { router.dismissSheet() }
            content
        }
        .onAppear { page.attach(model, frameID) }
        // Read again after every write, and for another picture: the sheet's slot is one, and SwiftUI may hand a page
        // presented for another frame the state of the last (seen in --history-check: H's rows under the pair's name).
        .task(id: Reload(frame: frameID, writes: model.history.writes)) {
            page.attach(model, frameID)
            await page.load()
        }
        .confirmationDialog(L("Clear this picture's history?"), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(L("Clear History"), role: .destructive) { page.clear() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The edit stays as it is and becomes the history's Original. The steps before it are gone, for Undo too."))
        }
        .accessibilityIdentifier("history.page")
    }

    @ViewBuilder private var content: some View {
        switch page.phase {
        case .loading:
            Spacer(minLength: 0)
        case .newer:
            message(L("History from a newer version"),
                    L("This picture's history was written by a newer SpektraLab. It is kept as it is; Undo goes back over the edits made since it was opened."))
        case .none:
            message(L("No edits yet"), L("Each change to this picture's edit is kept here, up to 256 steps, and stays after SpektraLab quits."))
        case .failed:
            message(L("The history could not be read"), L("The edit itself is kept. Close this page and open it again to try once more."))
        case .listed(let listing):
            listed(listing)
        }
    }

    private func message(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Font.ui(15, .semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Note(note, size: 12.5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history.message")
    }

    private func listed(_ listing: HistoryListing) -> some View {
        let rows = MacHistoryPageModel.rows(listing)
        return VStack(spacing: 0) {
            Text(MacHistoryPageModel.headLine(listing))
                .font(Theme.Font.ui(13, .medium)).foregroundStyle(Theme.secondaryText).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .accessibilityIdentifier("history.head")
            ScrollView {
                GroupBox {
                    ForEach(Array(rows.enumerated()), id: \.element.seq) { i, row in
                        rowView(row)
                        if i < rows.count - 1 { RowSeparator() }
                    }
                }
                .padding(.horizontal, Theme.Metric.margin)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            footer(listing)
        }
    }

    private func rowView(_ row: MacHistoryPageModel.Row) -> some View {
        let chosen = page.selected == row.seq
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The cursor's dot, in the accent: the state the frame is in.
            Circle().fill(row.isCurrent ? Theme.accent : Color.clear).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(row.time).font(Theme.Font.ui(12.5)).monospacedDigit().foregroundStyle(Theme.dim)
                .lineLimit(1)
                .layoutPriority(2)
            // A name is never cut: it wraps under itself.
            Text(row.title).font(Theme.Font.ui(13.5, row.isCurrent ? .semibold : .regular)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !row.origin.isEmpty {
                Text(row.origin).font(Theme.Font.ui(12)).foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .opacity(row.isAhead ? 0.45 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .overlay {
            if chosen {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.selectionFrame, lineWidth: 1.5)
                    .padding(2).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .modifier(MacClick { _ in page.click(row.seq) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(row.isCurrent ? L("Current") : row.isAhead ? L("Undone") : "")
        .accessibilityAction(named: L("Go to This Step")) { page.go(to: row.seq) }
        .accessibilityIdentifier("history.row.\(row.seq)")
    }

    private func footer(_ listing: HistoryListing) -> some View {
        let refusal = page.refusal
        return VStack(spacing: 6) {
            if let refusal {
                Note(refusal, size: 12, color: Theme.danger).accessibilityIdentifier("history.refusal")
            } else if page.goneStep {
                Note(L("The edit had changed since its last step, and is now the newest step. That step is no longer in the history."),
                     size: 12, color: Theme.danger).accessibilityIdentifier("history.gone")
            }
            HStack(spacing: 12) {
                TextButton(title: L("Clear History…"), color: Theme.danger, font: Theme.Font.ui(14, .semibold)) { confirmingClear = true }
                    .rowEnabled(page.canClear(listing))
                    .disabled(!page.canClear(listing))
                    .accessibilityIdentifier("history.clear")
                Spacer(minLength: 8)
                // The page's one action, in accent: as wide as its words in each language and a margin either side
                // (`CapsuleButton` fixed to its words drew them to its edges, seen in the capture of 2026-11-13).
                Button {
                    if let seq = page.selected { page.go(to: seq) }
                } label: {
                    Text(L("Go to This Step")).font(Theme.Font.button).foregroundStyle(Theme.onSelection)
                        .lineLimit(1)
                        .padding(.horizontal, 20)
                        .frame(height: 36)
                        .background(Capsule().fill(Theme.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: 0.98))
                .rowEnabled(page.canGo(listing))
                .disabled(!page.canGo(listing))
                .accessibilityIdentifier("history.go")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.wall).frame(height: 1) }
    }
}

private struct Reload: Equatable {
    let frame: LibraryFrame.ID
    let writes: Int
}

/// What the page shows and does, apart from how: the listing read, the row chosen, Go and Clear. Its own type so the
/// check drives the page's actions as its buttons do (`MacHistoryCheck`).
@MainActor
@Observable
final class MacHistoryPageModel {
    enum Phase: Equatable {
        case loading
        case listed(HistoryListing)
        /// The frame has no history yet.
        case none
        /// The store was written by a newer build (PRD-F §3.5).
        case newer
        case failed
    }

    private(set) var phase = Phase.loading
    /// The row Go to This Step goes to; the current step's until another is chosen.
    var selected: Int?
    /// Go is under way (a state read, a page's session reading past its window).
    private(set) var going = false
    /// The last Go found no such step: the edit had changed where no step was kept, and that change took the place of
    /// the steps ahead (`AppServices.goToStep`). Said under the buttons until the next Go.
    private(set) var goneStep = false
    /// How long the last listing took to read, in ms (the check's: PRD-F §5's 20 ms for 256 rows).
    @ObservationIgnored private(set) var lastLoadMillis: Double = 0
    @ObservationIgnored private weak var model: AppServices?
    @ObservationIgnored private(set) var frameID: LibraryFrame.ID?

    func attach(_ model: AppServices, _ frameID: LibraryFrame.ID) {
        if self.frameID != frameID {
            // Another picture's page: nothing of the last one's is shown or gone to.
            phase = .loading
            selected = nil
            goneStep = false
            lastClick = nil
        }
        self.model = model
        self.frameID = frameID
        #if DEBUG
        Self.shown = self
        Self.attachedAt = CACurrentMediaTime()
        #endif
    }

    #if DEBUG
    /// The page up now, for `--history-check`: it drives the page's own actions as its buttons do.
    static weak var shown: MacHistoryPageModel?
    /// When a page last attached (its `onAppear`: the sheet's content first drawn), for `--masks-check`'s transitions.
    static var attachedAt: CFTimeInterval = 0
    #endif

    /// The listing, read again: after every write the line was sent (`EditHistoryLine.writes`).
    func load() async {
        guard let model, let id = frameID else { return }
        let t0 = ContinuousClock.now
        do {
            let listing = try await model.history.ask("page") { try await $0.listing(id) }
            let d = ContinuousClock.now - t0
            lastLoadMillis = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            guard let listing else { phase = .none; selected = nil; return }
            phase = .listed(listing)
            let seqs = Set([listing.base.seq] + listing.steps.map(\.seq))
            if selected.map({ !seqs.contains($0) }) ?? true { selected = listing.cursorSeq }
        } catch let error as EditHistoryError {
            if case .newerSchema = error { phase = .newer } else { phase = .failed }
        } catch {
            phase = .failed
        }
    }

    var listing: HistoryListing? { if case .listed(let l) = phase { l } else { nil } }

    /// Why Go to This Step cannot be made now, said under the buttons: the frame is being exported.
    var refusal: String? {
        guard let model, let id = frameID else { return nil }
        return model.historyRefusal(id)
    }

    /// The page's session is reading the history or holding a gesture: its Undo waits, and so does Go.
    private var sessionBusy: Bool {
        guard let model, let id = frameID, let s = model.openSession(id) else { return false }
        return s.historyLoading || s.historyReading
    }

    func canGo(_ listing: HistoryListing) -> Bool {
        guard let selected, selected != listing.cursorSeq, refusal == nil, !going, !sessionBusy else { return false }
        return true
    }

    func canClear(_ listing: HistoryListing) -> Bool { !listing.steps.isEmpty && !going && !sessionBusy }

    /// Go to This Step, as the button and a double-click make it.
    func go(to seq: Int) {
        guard let model, let id = frameID, let listing, seq != listing.cursorSeq, refusal == nil, !going else { return }
        going = true
        goneStep = false
        Task {
            let went = await model.goToStep(id, seq)
            goneStep = !went && model.historyRefusal(id) == nil
            going = false
        }
    }

    /// A click on a row (the row's `MacClick`): it is chosen; a second on it within the double-click time (the grid's
    /// half second) goes to it.
    func click(_ seq: Int, at now: Date = Date()) {
        if let last = lastClick, last.seq == seq, now.timeIntervalSince(last.at) < 0.5 {
            lastClick = nil
            selected = seq
            go(to: seq)
            return
        }
        lastClick = (seq, now)
        selected = seq
    }
    @ObservationIgnored private var lastClick: (seq: Int, at: Date)?

    /// Clear History, once asked: the edit as it stands is the history's Original.
    func clear() {
        guard let model, let id = frameID else { return }
        model.clearHistory(id)
        selected = nil
    }

    // MARK: rows

    struct Row: Equatable {
        let seq: Int
        let title: String
        let time: String
        let origin: String
        let isCurrent: Bool
        /// A step ahead of the cursor: Redo's, dimmed.
        let isAhead: Bool
        let isBase: Bool
    }

    /// Newest first, the base last.
    static func rows(_ listing: HistoryListing, now: Date = Date()) -> [Row] {
        var out: [Row] = []
        out.reserveCapacity(listing.steps.count + 1)
        for step in listing.steps.reversed() {
            out.append(Row(seq: step.seq, title: step.label.text, time: time(step.at, now: now), origin: originWord(step.origin),
                           isCurrent: step.seq == listing.cursorSeq, isAhead: step.seq > listing.cursorSeq, isBase: false))
        }
        out.append(Row(seq: listing.base.seq, title: listing.baseIsEarlier ? L("Earlier edits") : L("Original", as: "the history"),
                       time: time(listing.base.at, now: now), origin: "",
                       isCurrent: listing.base.seq == listing.cursorSeq, isAhead: listing.base.seq > listing.cursorSeq, isBase: true))
        return out
    }

    /// "12 steps · 14 KB".
    static func headLine(_ listing: HistoryListing) -> String {
        let n = listing.steps.count
        return (n == 1 ? L("1 step") : L("\(n) steps")) + Fmt.dot + Fmt.fileSize(Int64(listing.bytes))
    }

    /// Where a step was made, as one word: 冲洗 for the develop page and its flows, 粘贴, 预设, 合成; nothing for a
    /// change made elsewhere (or a newer build's origin this one does not know).
    static func originWord(_ origin: HistoryOrigin) -> String {
        switch origin {
        case .develop, .flow: L("Develop")
        case .paste: L("Paste")
        case .preset: L("Preset")
        case .composite: L("Combine")
        case .elsewhere: ""
        }
    }

    /// 14:32 today; 11-12 23:10 another day of this year; 2025-11-12 23:10 before it. The same in every language.
    static func time(_ at: Date, now: Date, calendar: Calendar = .current) -> String {
        let format = calendar.isDate(at, inSameDayAs: now) ? "HH:mm"
            : calendar.component(.year, from: at) == calendar.component(.year, from: now) ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
        let key = format + "|" + calendar.timeZone.identifier
        if let f = formatters[key] { return f.string(from: at) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        formatters[key] = f
        return f.string(from: at)
    }

    /// One formatter a format: 257 rows drawn are 257 dates, and a formatter is costly to make.
    private static var formatters: [String: DateFormatter] = [:]
}
