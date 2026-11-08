//  MacLibraryActions.swift — the two library actions both Mac pages offer, in one place (the owner,
//  2026-10-26: the develop page's browser must offer Remove and 组成半格组 as the library's grid does).
//
//  The develop page draws the library's own browser, so its context menu is the library's. Two of its
//  items are acts on the app's library rather than on the page, and they ask questions: Remove's
//  confirmation and a pair's second frame. Their wording and their flows live here once; each page shows the
//  same two presentations (`macLibraryDialogs`), and both pages reach the same object.
//
//  Mac only: the window's library keeps its own (`LibraryScreen`).

import SwiftUI

@MainActor @Observable
final class MacLibraryActions {
    static let shared = MacLibraryActions()

    /// Why something was refused: a pair that cannot be made, a picture that cannot be opened.
    var refusal: String?
    /// The refusal's title, where it is not "This picture cannot be opened" (a paste's); cleared with it.
    var refusalTitle: String?
    /// The frames Remove is about to take, and whether it is asking yet.
    private(set) var removing: Set<LibraryFrame.ID> = []
    var confirmingRemoval = false
    /// A pair just made: its frame, until its row lands in the library and is chosen there.
    var landing: LibraryFrame.ID?

    /// Remove, asked first.
    func ask(_ ids: Set<LibraryFrame.ID>) {
        guard !ids.isEmpty else { return }
        removing = ids
        confirmingRemoval = true
    }

    func remove(_ model: AppServices, _ library: FrameCatalog) {
        model.remove(removing)
        removing = []
        if library.isEmpty { library.endSelecting() }
        trash(leaving, store: leavingStore)
        leaving = []
    }

    /// 从 SpektraLab 中移除 (the owner, 2026-10-27): every chosen picture goes into its source's 回收站. One
    /// SpektraLab has edited also loses its frame, its edit and preview, so that is asked first (Remove's
    /// confirmation); one it has not has nothing of SpektraLab's to lose and goes at once.
    private(set) var leaving: [MacImage.ID] = []
    private var leavingStore: (any MacLibraryData)?
    func removeFromSpektraLab(_ images: [MacImage], frames: Set<LibraryFrame.ID>, store: any MacLibraryData) {
        guard !images.isEmpty else { return }
        if frames.isEmpty { trash(images.map(\.id), store: store); return }
        leaving = images.map(\.id)
        leavingStore = store
        ask(frames)
    }

    func cancelRemoval() { leaving = []; removing = [] }

    private func trash(_ ids: [MacImage.ID], store: (any MacLibraryData)?) {
        guard let store, !ids.isEmpty else { return }
        Task {
            do { try await store.setTrashed(true, for: ids) } catch { refusal = error.localizedDescription }
        }
    }

    /// 放回: out of 回收站, as it was.
    func putBack(_ images: [MacImage], store: any MacLibraryData) {
        Task {
            do { try await store.setTrashed(false, for: images.map(\.id)) } catch { refusal = error.localizedDescription }
        }
    }

    /// 移到废纸篓, from 回收站 only, asked first: the files go to the system's Trash.
    private(set) var discarding: [MacImage.ID] = []
    private var discardingStore: (any MacLibraryData)?
    var confirmingDiscard = false
    func askDiscard(_ images: [MacImage], store: any MacLibraryData) {
        guard !images.isEmpty else { return }
        discarding = images.map(\.id)
        discardingStore = store
        confirmingDiscard = true
    }

    func discard() {
        let ids = discarding, store = discardingStore
        discarding = []
        guard let store else { return }
        Task {
            do { try await store.moveToSystemTrash(ids) } catch { refusal = error.localizedDescription }
        }
    }

    /// The words are the dialogs' (`RemovalWords`, through the environment's library).

    /// 组成半格组 Make Half-Frame Pair, from a picture's menu (`MacLibraryPage.makePair` until
    /// 2026-10-26): the frames of the chosen pictures (made for those without, as Develop makes them),
    /// then `AppServices.makePair`. Two fill the holes in the library's order
    /// and the pair lands as a row beside them, chosen (`landing`); one asks for the second
    /// (`PairWay.ask`, the window library's *Pair With*), which then opens the pair's darkroom as it does there.
    func makePair(_ images: [MacImage], store: any MacLibraryData, model: AppServices) {
        guard (1...2).contains(images.count), !images.contains(where: { $0.kind == .pair }) else { return }
        Task {
            do {
                let (frames, _) = try await store.frames(for: images.map(\.id), focus: images[0].id)
                let ids = images.compactMap { frames[$0.id] }
                guard let first = ids.first, !ids.contains(where: { model.library.frame($0)?.isPair != false }) else { return }
                if ids.count > 1 {
                    guard let pair = model.makePair(ids[0], ids[1]) else {
                        refusal = L("This half-frame pair could not be made.")
                        return
                    }
                    landing = pair
                } else {
                    PairWay.ask(for: first, on: model.router)
                }
            } catch {
                refusal = error.localizedDescription
            }
        }
    }

    /// The library a pair's frames are judged by (`model.library`, the app's one store).
    private func isPair(_ id: LibraryFrame.ID, _ model: AppServices) -> Bool? {
        model.library.frame(id)?.isPair
    }

    // MARK: Copy and Paste Settings (the owner, 2026-11-05)

    /// ⌘C: the frame's settings into the clipboard with the groups last ticked on the Copy Settings sheet
    /// (`ClipboardGroup.remembered`), and no sheet. Capture One's ⇧⌘C copies at once too, with the groups
    /// its Adjustments Clipboard tool has ticked; here the ticks are changed on the sheet, which ⇧⌘C and
    /// the menus' Copy Settings open.
    func copySettings(of frameID: LibraryFrame.ID, model: AppServices) {
        model.copySettings(of: frameID, groups: ClipboardGroup.remembered())
    }

    /// What the last paste onto pictures that are not open says, for a while: in the sidebar's activity
    /// line (图库) and in the info strip under the picture while several are chosen (all three modes).
    /// Their tiles keep their old develop until each is opened or exported (the Mac's rule, below), so
    /// without it a paste of Light alone onto nine frames changes nothing on screen (the review, 2026-11-05).
    private(set) var notice: Notice?
    /// A notice: what was done, and what to expect of it, which a narrow strip leaves off whole.
    struct Notice: Equatable {
        var said: String
        var more: String?
        var line: String { more.map { said + " " + $0 } ?? said }
    }
    private var noticeShown: Task<Void, Never>?
    /// A paste that is making frames, until it has pasted onto them. Another paste waits behind it for the
    /// pictures that still have no frame (`pasteSettings`).
    private var making: Task<Void, Never>?
    /// How many pictures the pastes in flight are making frames for (the notice's "Pasting…" line).
    private var makingCount = 0

    /// Paste Settings onto every one of `images` (the owner, 2026-11-05: "if multiple images is selected,
    /// pasting would mean pasting the copied setting to all selected images"), from a cell's menu or ⌘V,
    /// in 图库, 冲洗 and 编辑 alike. The clip is the one held at the press, whenever the paste lands.
    ///
    /// - The pictures that have a frame are pasted onto at once, in this event.
    /// - A picture SpektraLab has never opened has no frame to hold an edit: one is made for it, as
    ///   Develop and Export make theirs (`MacLibraryData.frames(for:focus:)`, one arrival, nothing
    ///   queued), `CatalogSourcesStore.carryLimit` at a time — a carry's limit, so ⌘A ⌘V over a catalog of
    ///   800 never-opened pictures pastes onto all 800 (the review, 2026-11-05: it pasted onto none, and
    ///   said Develop's "Choose 500 pictures…"). Each batch is pasted onto as its frames arrive.
    /// - One paste makes frames at a time: a second one (⌘V again while 200 RAWs are probed, the menu and
    ///   then the key) waits for the first and finds the frames it made, so no file gets two frames.
    /// - An offline picture without a frame is left out, and one that cannot be read; each said so.
    /// - A frame whose develop page is open is pasted through its session, so the page moves with it and
    ///   one Undo takes it back (the bar's Paste); every other is pasted in the library, which saves it.
    /// - Each frame pasted onto outside a page has its preview developed again (the owner, 2026-11-05:
    ///   a tile that kept the old picture until it was opened "would make user wonder what is actually
    ///   happening"). A paste is a person's act on those frames, `DevelopCause.asked` — the 2026-10-24
    ///   rule is against develops nobody asked for (an import, a launch, a sweep), not against this.
    ///   One `importDevelop` at the preview tier each, in the order pasted, priority 5: behind the
    ///   page's edits, Edit's render, an export and the cards; one at a time, each yielding to a page
    ///   edit (`RenderQueue`). Opening one cancels its own (`OpenFrameSession.open`); a second paste
    ///   replaces the queued ones; Stop on the activity line takes them out (`stopPreviews`).
    func pasteSettings(onto images: [MacImage], store: any MacLibraryData, model: AppServices) {
        guard let clip = model.library.clipboard, !images.isEmpty else { return }
        if let line = clip.missingMaterialsLine {
            refusalTitle = L("Settings cannot be pasted")
            refusal = line
            return
        }
        var known: [LibraryFrame.ID] = []
        var frameless: [MacImage] = []
        for image in images {
            if let id = image.develop?.frameID, model.library.frame(id) != nil { known.append(id) } else { frameless.append(image) }
        }
        // The ones that have their frame (every one, the usual case in 冲洗/编辑): now.
        let generation = stops
        let pasted = paste(clip, onto: known, model: model, stops: generation)
        guard !frameless.isEmpty else { tell(pasted); return }
        let before = making
        makingCount += frameless.count
        say(Notice(said: L("Pasting settings onto \(makingCount) pictures…")), for: nil)
        making = Task { [weak self] in
            await before?.value
            await self?.make(frameless, clip: clip, pasted: pasted, store: store, model: model, stops: generation)
        }
    }

    /// The frames of `images`, made `carryLimit` at a time, each batch pasted onto as it arrives.
    private func make(_ images: [MacImage], clip: SettingsClip, pasted: Pasted, store: any MacLibraryData, model: AppServices, stops generation: Int) async {
        var total = pasted
        var offline = 0, unreadable = 0
        var failure: String?
        var start = 0
        while start < images.count {
            let batch = Array(images[start..<min(start + CatalogSourcesStore.carryLimit, images.count)])
            start += batch.count
            do {
                let made = try await store.frames(for: batch.map(\.id), focus: nil).frames
                total += paste(clip, onto: batch.compactMap { made[$0.id] }, model: model, stops: generation)
                // Left out: offline when its file is not there, unreadable when it is (`adoptLibraryFiles`
                // makes no frame of a file it cannot probe).
                for image in batch where made[image.id] == nil {
                    if FileManager.default.fileExists(atPath: image.url.path) { unreadable += 1 } else { offline += 1 }
                }
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        makingCount -= images.count
        tell(total)
        let lines = [failure,
                     offline > 0 ? L("\(offline) of the pictures are offline: they kept their settings.") : nil,
                     unreadable > 0 ? L("\(unreadable) of the pictures could not be read: they kept their settings.") : nil]
            .compactMap { $0 }
        if !lines.isEmpty {
            refusalTitle = L("Settings cannot be pasted")
            refusal = lines.joined(separator: "\n")
        }
    }

    /// How many frames one paste reached, how many of them through their open page, and how many previews
    /// it owes again (fed to the queue a few at a time, `feed`).
    struct Pasted {
        var frames = 0, paged = 0, developing = 0
        static func += (a: inout Pasted, b: Pasted) { a.frames += b.frames; a.paged += b.paged; a.developing += b.developing }
    }

    /// `stops`: how many Stops there had been when the paste was pressed. A Stop since leaves the rest of
    /// it undeveloped (a paste of 800 making its frames 500 at a time fed its second batch after a Stop):
    /// those frames are pasted, and marked out of date (`MacPreviewStaleness`) for Develop Previews.
    private func paste(_ clip: SettingsClip, onto frames: [LibraryFrame.ID], model: AppServices, stops generation: Int) -> Pasted {
        guard !frames.isEmpty else { return Pasted() }
        var library: Set<LibraryFrame.ID> = []
        for id in frames {
            if let session = model.openSession(id) { model.applyLook(clip, to: session) } else { library.insert(id) }
        }
        let before = Dictionary(library.compactMap { id in model.library.frame(id).map { (id, $0.edit) } }, uniquingKeysWith: { a, _ in a })
        let redo = Set(model.library.paste(onto: library, clip: clip))
        // What must be developed again: what `paste` says (a film-side change), and a frame with no develop
        // of its own whose edit the paste changed at all — Edit's layer alone has nothing to lie on there
        // (`Layer2Copies` copies a develop). In the order pasted (the grid's), so the tiles fill in order.
        var owed: [LibraryFrame.ID] = []
        var seen: Set<LibraryFrame.ID> = []
        for id in frames where library.contains(id) && seen.insert(id).inserted {
            // A pair too: `prepare` develops its two frames' piece, as the window's Select paste does.
            guard let f = model.library.frame(id) else { continue }
            let changed = before[id].map { $0 != f.edit } ?? false
            if redo.contains(id) || (changed && f.shownDevelop == nil) { owed.append(id) }
        }
        if generation != stops { owed = [] }
        feed(owed, model: model)
        #if DEBUG
        NSLog("[clipboard] pasted onto %ld frames (%ld through a page), %ld previews owed", frames.count, frames.count - library.count, owed.count)
        #endif
        return Pasted(frames: Set(frames).count, paged: frames.count - library.count, developing: owed.count)
    }

    /// Previews owed by pastes, not yet handed to the queue, in order.
    private var owedPreviews: [LibraryFrame.ID] = []
    private var feeding: Task<Void, Never>?
    /// Owed previews the queue could not take (the original away or unreadable), since the feed began.
    private var feedRefused = 0

    /// The owed previews into the queue, `chunk` at a time with the main thread let go between: preparing
    /// one develop (its wire, its decode, its stamp) takes about 2.4 ms here (measured 2026-11-05, 500 in
    /// 1.2 s), so ⌘A ⌘V over 2,000 pictures handed over at once held the window for some 5 s.
    private func feed(_ ids: [LibraryFrame.ID], model: AppServices) {
        guard !ids.isEmpty else { return }
        owedPreviews.removeAll { ids.contains($0) }
        owedPreviews.append(contentsOf: ids)
        guard feeding == nil else { return }
        feedRefused = 0
        feeding = Task { [weak self] in
            let chunk = 16
            while let self, !self.owedPreviews.isEmpty {
                let next = Array(self.owedPreviews.prefix(chunk))
                self.owedPreviews.removeFirst(next.count)
                for id in next {
                    // Opened meanwhile: its page develops it (and cancels the library's, `OpenFrameSession.open`);
                    // opened and closed meanwhile, its page may have left a picture of this edit already.
                    guard let f = model.library.frame(id), model.openSession(id) == nil, model.darkroom.needsDevelop(f) else { continue }
                    model.develop(id)
                    if model.library.frame(id)?.develop.isBusy != true { self.feedRefused += 1 }
                }
                try? await Task.sleep(for: .milliseconds(4))
            }
            guard let self else { return }
            self.feeding = nil
            let refused = self.feedRefused
            #if DEBUG
            NSLog("[clipboard] previews fed, %ld could not be developed", refused)
            #endif
            if refused > 0 {
                self.say(Notice(said: refused == 1 ? L("1 could not be developed now: it keeps its earlier preview.")
                                                   : L("\(refused) could not be developed now: they keep their earlier preview.")),
                         for: .seconds(8))
            }
        }
    }

    /// Stop on the activity line: every preview develop still to run or running is taken out (the
    /// Mac's full-size renders of the page and its neighbours are not touched). Their tiles keep the
    /// preview they had, marked out of date (`MacPreviewStaleness`).
    func stopPreviews(model: AppServices) {
        stops += 1
        owedPreviews.removeAll()
        model.stopPreviewDevelops()
        // The notice no longer says they are developing.
        if let n = notice, n.more != nil { say(Notice(said: n.said, more: L("Stopped: their previews keep the earlier picture.")), for: .seconds(8)) }
    }

    /// How many times Stop was pressed (`paste`'s `stops`).
    private var stops = 0

    /// **Develop Previews** (a picture's menu): the chosen pictures whose preview is not of their edit
    /// (after a Stop, or a paste the app was quit during), developed again; a page's own frame is left to
    /// its page. How many were asked.
    @discardableResult
    func developPreviews(of frames: [LibraryFrame.ID], model: AppServices) -> Int {
        let owed = frames.filter { id in
            model.library.frame(id).map { !$0.develop.isBusy && model.openSession(id) == nil && model.darkroom.needsDevelop($0) } ?? false
        }
        // Through the feed, as a paste's: 500 at once held the window for over a second.
        feed(owed, model: model)
        return owed.count
    }

    /// The notice of a paste that reached frames outside their page; none when the page itself shows it.
    private func tell(_ landed: Pasted) {
        // Pastes that overlap (one still making frames when another lands) are told as one, when the
        // last lands: neither's count is lost.
        told += landed
        if makingCount > 0 { say(Notice(said: L("Pasting settings onto \(makingCount) pictures…")), for: nil); return }
        let pasted = told
        told = Pasted()
        guard pasted.frames > pasted.paged else {
            if notice != nil { say(nil, for: nil) }
            return
        }
        let said = pasted.frames == 1 ? L("Settings pasted onto 1 picture.") : L("Settings pasted onto \(pasted.frames) pictures.")
        var more: [String] = []
        let outside = pasted.frames - pasted.paged
        if pasted.developing > 0 {
            more.append(pasted.developing == outside ? (outside == 1 ? L("Its preview is developing.") : L("Their previews are developing."))
                        : pasted.developing == 1 ? L("1 preview is developing.") : L("\(pasted.developing) previews are developing."))
        }
        say(Notice(said: said, more: more.isEmpty ? nil : more.joined(separator: " ")), for: .seconds(8))
    }

    /// What the pastes landed since the notice last said so (`tell`).
    private var told = Pasted()

    /// `line` in the notice, for `time` (nil: until it is said otherwise).
    private func say(_ line: Notice?, for time: Duration?) {
        noticeShown?.cancel()
        notice = line
        guard let time, line != nil else { return }
        noticeShown = Task { [weak self] in
            try? await Task.sleep(for: time)
            guard !Task.isCancelled, let self, self.notice == line else { return }
            self.notice = nil
        }
    }

    #if DEBUG
    /// A check waits for the pastes in flight (`--clipboard-check`).
    func pastesLanded() async { await making?.value; await feeding?.value }
    #endif
}

/// Both presentations, once: the refusal alert and Remove's confirmation, for whichever Mac page draws
/// the library's browser (`MacLibraryPage`, the develop page). What they are about is `RemovalWords`'.
struct MacLibraryDialogs: ViewModifier {
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    private var actions: MacLibraryActions { MacLibraryActions.shared }

    func body(content: Content) -> some View {
        content
            .alert(actions.refusalTitle ?? L("This picture cannot be opened"),
                   isPresented: Binding(get: { actions.refusal != nil },
                                        set: { if !$0 { actions.refusal = nil; actions.refusalTitle = nil } })) {
                Button(L("OK"), role: .cancel) {}
            } message: {
                Text(actions.refusal.map { L(shown: $0) } ?? "")
            }
            .confirmationDialog(RemovalWords.title(actions.removing, library: library),
                                isPresented: Binding(get: { actions.confirmingRemoval },
                                                     set: { actions.confirmingRemoval = $0 }),
                                titleVisibility: .visible) {
                Button(L("Remove from SpektraLab"), role: .destructive) { actions.remove(model, library) }
                Button(L("Cancel"), role: .cancel) { actions.cancelRemoval() }
            } message: {
                Text(RemovalWords.message(actions.removing, library: library))
            }
            .confirmationDialog(actions.discarding.count == 1 ? L("Move this picture to the Trash?")
                                                              : L("Move \(actions.discarding.count) pictures to the Trash?"),
                                isPresented: Binding(get: { actions.confirmingDiscard },
                                                     set: { actions.confirmingDiscard = $0 }),
                                titleVisibility: .visible) {
                Button(L("Move to Trash"), role: .destructive) { actions.discard() }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("The files go to the system's Trash, where Finder can still put them back."))
            }
    }
}

extension View {
    /// The library's two questions, drawn by whichever Mac page shows its browser.
    func macLibraryDialogs() -> some View { modifier(MacLibraryDialogs()) }
}
