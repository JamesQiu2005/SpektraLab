//  MacSettingsStorage.swift — Settings › Storage on the Mac: what the app keeps, its three budgets, and
//  their usage.
//
//  The window's Storage page and its two limit pages as one group (`StoragePage.swift`): the total and its
//  bar, then a row per part with what it takes and, for the three parts that have one, its budget beside
//  it as a pop-up button:
//  - **Working copies** (`AppServices.setWorkingCopiesLimit`): originals brought here to develop at full
//    size, and the RAWs' proxies; the oldest go first past the budget. *Clear Working Copies* takes them.
//  - **Preview copies** (`AppServices.setPreviewCopiesLimit`): everything under `Previews`.
//  - **Full-size renders** (`AppSettings.fullRenderCacheLimit`, set through
//    `AppServices.setFullRenderCacheLimit`): the `.spkfull` files of the pictures looked at most recently
//    (`FullRender`). What it takes is counted here, from the files themselves, wherever under the app's
//    folder they are (`FullRenderUsage`); a part whose folder holds some of them is shown without them,
//    so the parts add up to the total.
//  The budgets' choices are the window's and more, since a Mac's disk is larger (a 100 MP RAW's full render
//  is about 1 GB). The controls' own setters are `budgets(_:)`, which `--settings-check` drives.
//
//  **Previews** (2026-11-05, `LibraryPreviews`): a picture's preview — its kept develop, at Develop's
//  Preview size — is kept with the catalog or session it was opened from, as Capture One keeps its
//  previews, not under the app's folder. The group says so for the library selected in the library
//  (its name, where its previews are, how many and how large), with *Show in Finder* once the folder is
//  there and *Delete Previews* (`deletePreviews(_:)`, the button's own action, which `--settings-check`
//  drives). They are no budget's: a library's previews are its own, as Capture One's are, and go with it.
//  *Preview copies* is now the previews of pictures in no library, Develop's cards, pairs' guides and
//  Edit's copies.
//
//  Review, 2026-11-05: a Finder folder's, a Capture One session's and a Capture One catalog's previews are
//  kept in SpektraLab's own library for each (`Libraries/Sources`, `Libraries/Linked`), which is inside the
//  app's folder. They are a part of their own in *On this Mac* (`LibraryPreviews.measureOwn`), so the total
//  counts them, listed in Sources or not; they are kept out of the *Preview copies* budget on purpose: a
//  budget sweeps by age, and a library's previews are swept by nobody but *Delete Previews* (another Mac's
//  frames' previews would look like orphans; `LibraryPreviews`). *Every library* lists each source's
//  previews, measured every 30 s. *Delete Previews* asks first: it removes the previews for every Mac that
//  opens the library.

import SwiftUI

/// The `.spkfull` files under the app's folder, and how much of them lies in each part the library
/// measures (`LibraryPersistence.storageReport`), so a part can be shown without them.
struct FullRenderUsage: Equatable, Sendable {
    var bytes: Int64 = 0
    var files = 0
    var inWorkingCopies: Int64 = 0
    var inPreviews: Int64 = 0
    var inOriginals: Int64 = 0
    var inCache: Int64 = 0

    /// Measured off the main thread: a walk of the app's folder and the caches, sizes only.
    static func measure() async -> FullRenderUsage {
        await Task.detached(priority: .utility) {
            var u = FullRenderUsage()
            let fm = FileManager.default
            let working = ImportService.workingCopies.standardizedFileURL.path + "/"
            let previews = ImportService.previews.standardizedFileURL.path + "/"
            let originals = ImportService.originals.standardizedFileURL.path + "/"
            // The app's own folders only (`LibraryPersistence.cacheFolders`): walking `~/Library/Caches` whole
            // read every app's caches every 5 s.
            let roots = [ImportService.root] + LibraryPersistence.cacheFolders
            for (i, root) in roots.enumerated() {
                guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
                for case let file as URL in files where file.lastPathComponent.hasSuffix(FullRender.suffix) {
                    guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                    let n = Int64(v.fileSize ?? 0)
                    u.bytes += n
                    u.files += 1
                    let path = file.standardizedFileURL.path
                    if i >= 1 { u.inCache += n }
                    else if path.hasPrefix(working) { u.inWorkingCopies += n }
                    else if path.hasPrefix(previews) { u.inPreviews += n }
                    else if path.hasPrefix(originals) { u.inOriginals += n }
                }
            }
            return u
        }.value
    }
}

struct MacSettingsStorage: View {
    @Environment(AppServices.self) private var model
    @Environment(FrameCatalog.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var full = FullRenderUsage()
    @State private var measuredFull = false
    @State private var previews = MacPreviewsUsage()
    @State private var measuredPreviews = false
    @State private var deleting = false
    @State private var confirmingDelete = false
    /// The previews in SpektraLab's own libraries for folders and Capture One (`LibraryPreviews.measureOwn`).
    @State private var ownPreviews: (files: Int, bytes: Int64) = (0, 0)
    /// Every source's previews, by source (*Every library*); measured every 30 s.
    @State private var everyLibrary: [MacSource.ID: MacPreviewsUsage] = [:]

    /// One budget: what its pop-up button offers, and the calls the button makes.
    struct Budget: Identifiable {
        let id: String
        let title: String
        let choices: [Int64]
        /// The budget held now, as the library's report has it (the button's value).
        let held: @MainActor () -> Int64
        /// What `AppSettings` keeps for it.
        let kept: @MainActor () -> Int64
        let set: @MainActor (Int64) -> Void
    }

    /// The three budgets, through `AppServices`'s own setters.
    @MainActor static func budgets(_ model: AppServices) -> [Budget] {
        func gb(_ n: [Int]) -> [Int64] { n.map { Int64($0) << 30 } }
        return [
            Budget(id: "workingCopies", title: L("Working copies"), choices: gb([2, 5, 10, 20, 50]),
                   held: { model.library.storage.workingCopiesLimit }, kept: { model.settings.workingCopiesLimit },
                   set: { model.setWorkingCopiesLimit($0) }),
            Budget(id: "previewCopies", title: L("Preview copies"), choices: gb([5, 10, 20, 50]),
                   held: { model.library.storage.previewCopiesLimit }, kept: { model.settings.previewCopiesLimit },
                   set: { model.setPreviewCopiesLimit($0) }),
            Budget(id: "fullRenders", title: L("Full-size renders"), choices: gb([2, 4, 8, 16, 32, 64]),
                   held: { model.settings.fullRenderCacheLimit }, kept: { model.settings.fullRenderCacheLimit },
                   set: { model.setFullRenderCacheLimit($0) }),
        ]
    }

    /// The bar's greys, light to dark: the window page's four, one between for the full renders, and one for
    /// the previews of SpektraLab's own libraries.
    private static let shades: [Color] = [Theme.secondaryText, Color(hex: 0xA8A6A2), Color(hex: 0x9A9894), Color(hex: 0x8C8A86),
                                          Color(hex: 0x6F6E6B), Color(hex: 0x46453F)]

    private struct Part {
        let title: String
        let bytes: Int64
        let budget: Budget?
        let line: String
        let keys: [String]
    }

    private var parts: [Part] {
        let s = library.storage
        let budgets = Self.budgets(model)
        return [
            Part(title: L("Copied-in originals"), bytes: max(0, s.copiedInOriginals - full.inOriginals), budget: nil,
                 line: L("The only copy of shares and files copied in. Never cleared."), keys: ["Copied-in originals"]),
            Part(title: L("Working copies"), bytes: max(0, s.workingCopies - full.inWorkingCopies), budget: budgets[0],
                 line: L("Originals copied here to develop at full size; oldest go first."),
                 keys: ["Working copies", "Working copies up to", " of %@ GB"]),
            Part(title: L("Preview copies"), bytes: max(0, s.previewCopies - full.inPreviews), budget: budgets[1],
                 line: L("Pictures in no library: their previews. And Develop's film and paper cards, pairs' guides and Edit's copies. A library's previews are kept in it (below)."),
                 keys: ["Preview copies", "Preview copies up to"]),
            Part(title: L("Previews of folders and Capture One"), bytes: ownPreviews.bytes, budget: nil,
                 line: L("Kept in SpektraLab's own library for each Finder folder and Capture One catalog or session, on this Mac. No budget: Delete Previews, below, takes a library's."),
                 keys: ["Own library previews"]),
            Part(title: L("Full-size renders"), bytes: full.bytes, budget: budgets[2],
                 line: L("The full-size develop of the pictures looked at most recently, so a zoom or an export of them again does not wait. Past the budget, the one looked at longest ago goes."),
                 keys: ["Full-size renders"]),
            Part(title: L("Thumbnails and cache"), bytes: max(0, s.cache - full.inCache), budget: nil, line: L("Rebuilt whenever needed."),
                 keys: ["Thumbnails and cache"]),
        ]
    }

    /// The parts together: the library's total, any full render outside the folders it measures, and the
    /// previews in SpektraLab's own libraries (which no part of the library's report holds).
    private var total: Int64 {
        library.storage.total + max(0, full.bytes - full.inWorkingCopies - full.inPreviews - full.inOriginals - full.inCache)
            + ownPreviews.bytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(18)) {
            MacSettingsGroup(title: L("On this Mac"),
                             footer: L("They come back when a frame needs them. Originals in your folders and catalogs are never moved or deleted. "
                                       + "This Mac develops up to \(Int(DevicePolicy.current.developCapMegapixels)) MP.")) {
                VStack(alignment: .leading, spacing: MacMetric.pt(6)) {
                    Text(L("\(Fmt.gigabytes(total)) on this Mac")).font(MacMetric.font(13, .semibold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    bar
                }
                .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
                .padding(.vertical, MacMetric.pt(9))
                .overlay(alignment: .bottom) { MacSettingsHairline() }
                .macSettingsItem("Storage", "Limits", "%@ on this Mac")
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    partRow(part, shade: Self.shades[i], last: i == parts.count - 1)
                        .macSettingsItem(part.keys)
                }
            } accessory: {
                Button(L("Clear Working Copies")) {
                    withAnimation(.easeOut(duration: 0.2)) { model.clearWorkingCopies() }
                }
                .buttonStyle(MacSettingsButtonStyle())
                .disabled(library.storage.workingCopies <= 0)
                .macSettingsItem("Clear Working Copies")
            }
            previewsGroup
            everyLibraryGroup
            MacSettingsGroup(title: L("Where")) {
                MacSettingsRow(label: (ImportService.root.path as NSString).abbreviatingWithTildeInPath, last: true) {
                    Button(L("Show in Finder")) { UIApplication.shared.open(ImportService.root) }
                        .buttonStyle(MacSettingsButtonStyle())
                }
            }
        }
        .task {
            guard !isSnapshot else { return }
            library.measureStorage()
            // The full renders come and go as pictures are looked at, and a library's previews as its pictures
            // are developed: measured again while the page is shown.
            var round = 0
            while !Task.isCancelled {
                full = await FullRenderUsage.measure()
                measuredFull = true
                ownPreviews = await Task.detached(priority: .utility) { LibraryPreviews.measureOwn(store: LibraryHost.defaultStore) }.value
                if !deleting {
                    previews = await MacPreviewsUsage.measure(model.macLibrary.selectedSource?.previewHome)
                    measuredPreviews = true
                    // Every library's: a listing of each one's previews folder, some on other disks, so less often.
                    if round % 6 == 0 { everyLibrary = await Self.measureEvery(model.macLibrary.sources) }
                }
                round += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(L("Delete this library's previews?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(L("Delete Previews"), role: .destructive) { deleteSelectedPreviews() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This removes the previews kept in the library for every Mac that opens it. Each picture is developed again when it is next opened, exported or laid on the Light Table. Edits are kept."))
        }
    }

    /// Every source's previews, one after another off the main thread (sizes only).
    private static func measureEvery(_ sources: [MacSource]) async -> [MacSource.ID: MacPreviewsUsage] {
        var all: [MacSource.ID: MacPreviewsUsage] = [:]
        for s in sources {
            guard let home = s.previewHome else { continue }
            all[s.id] = await MacPreviewsUsage.measure(home)
        }
        return all
    }

    private func deleteSelectedPreviews() {
        deleting = true
        Task {
            await Self.deletePreviews(model)
            previews = await MacPreviewsUsage.measure(model.macLibrary.selectedSource?.previewHome)
            everyLibrary = await Self.measureEvery(model.macLibrary.sources)
            ownPreviews = await Task.detached(priority: .utility) { LibraryPreviews.measureOwn(store: LibraryHost.defaultStore) }.value
            deleting = false
        }
    }

    // MARK: the selected library's previews

    /// *Delete Previews*, as its button does it: the selected library's (`AppServices.deletePreviews`). What went.
    @discardableResult
    @MainActor static func deletePreviews(_ model: AppServices) async -> (files: Int, bytes: Int64)? {
        guard let home = model.macLibrary.selectedSource?.previewHome else { return nil }
        return await model.deletePreviews(of: home)
    }

    @ViewBuilder private var previewsGroup: some View {
        let source = model.macLibrary.selectedSource
        let home = source?.previewHome
        MacSettingsGroup(title: L("Previews"), footer: previewsFooter(source)) {
            if let source, let home {
                MacSettingsValueRow(label: source.name, value: previewsUsage(home))
                    .macSettingsItem("Library previews")
                MacSettingsRow(label: (home.folder.path as NSString).abbreviatingWithTildeInPath, last: true) {
                    // Finder opens the folder itself, inside the package: the package opened would be the
                    // catalog, opened by whichever SpektraLab Finder picks.
                    Button(L("Show in Finder")) { UIApplication.shared.open(home.folder) }
                        .buttonStyle(MacSettingsButtonStyle())
                        .disabled(!(previews.home == home && previews.hasFolder))
                }
                .macSettingsItem("Library previews folder")
            } else {
                MacSettingsRow(label: L("No catalog or session is open."), last: true)
                    .macSettingsItem("Library previews")
            }
        } accessory: {
            // Asked first (`confirmingDelete`): it takes the previews of every Mac that opens the library.
            Button(L("Delete Previews")) { confirmingDelete = true }
            .buttonStyle(MacSettingsButtonStyle(kind: .destructive))
            .disabled(home == nil || deleting || !(previews.home == home && previews.files > 0))
            .macSettingsItem("Delete Previews")
        }
    }

    /// "12 previews, 38 MB"; "Counting" until measured for this library; "Not reachable" where its disk is away.
    private func previewsUsage(_ home: PreviewHome) -> String {
        guard measuredPreviews, previews.home == home else { return L("Counting") }
        return Self.words(previews)
    }

    private static func words(_ usage: MacPreviewsUsage) -> String {
        guard usage.isThere else { return L("Not reachable") }
        // A preview is a few hundred KB to a few MB: a tenth of a MB until there are ten of them.
        let mb = Double(usage.bytes) / 1_048_576
        let size = usage.bytes >= 1 << 30 ? Fmt.gigabytes(usage.bytes) : String(format: mb < 10 ? "%.1f MB" : "%.0f MB", mb)
        return usage.files == 1 ? L("1 preview, \(size)") : L("\(usage.files) previews, \(size)")
    }

    /// Each source's previews, the selected one's among them: what every library keeps, at a glance.
    @ViewBuilder private var everyLibraryGroup: some View {
        let listed = model.macLibrary.sources.filter { $0.previewHome != nil }
        if !listed.isEmpty {
            MacSettingsGroup(title: L("Every library"),
                             footer: L("Measured every 30 seconds. A library removed from Sources keeps its previews inside it; for a folder or a Capture One library they stay on this Mac, counted above.")) {
                ForEach(Array(listed.enumerated()), id: \.element.id) { i, s in
                    MacSettingsValueRow(label: s.name, value: everyLibrary[s.id].map(Self.words) ?? L("Counting"),
                                        last: i == listed.count - 1)
                }
            }
            .macSettingsItem("Every library's previews")
        }
    }

    /// Where the previews are, said plainly for the kind of library selected.
    private func previewsFooter(_ source: MacSource?) -> String {
        let rule = L("A picture's preview is its develop at Develop's Preview size. It is kept with the catalog or session the picture was opened from, as Capture One keeps its previews: it moves, is copied and is deleted with it. Deleted, a preview is made again when its picture is next opened.")
        switch source?.kind {
        case .captureOneCatalog?:
            return rule + " " + L("Capture One's catalog is never written: this one's previews are kept in SpektraLab's own library for it.")
        case .captureOneSession?, .folder?:
            return rule + " " + L("For a folder, they are kept in SpektraLab's own library for it, on this Mac.")
        case .catalog?, .session?:
            return rule
        default:
            return L("Each catalog and session keeps the previews of its pictures inside it. Pictures in no library keep theirs on this Mac, in Preview copies.")
        }
    }

    /// The parts end to end, on a track that stands for the largest of 12 GB, the budgets together, and
    /// the total.
    private var bar: some View {
        let budgets = Self.budgets(model).reduce(Int64(0)) { $0 + $1.held() }
        let scale = Double(max(12 << 30, budgets, total))
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    Rectangle().fill(Self.shades[i]).frame(width: max(0, geo.size.width * CGFloat(Double(part.bytes) / scale)))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: MacMetric.pt(8), alignment: .leading)
            .background(Theme.card)
            .clipShape(Capsule())
        }
        .frame(height: MacMetric.pt(8))
        .accessibilityHidden(true)
    }

    private func partRow(_ part: Part, shade: Color, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: MacMetric.pt(3)) {
            HStack(alignment: .center, spacing: MacMetric.pt(10)) {
                Circle().fill(shade).frame(width: MacMetric.pt(9), height: MacMetric.pt(9))
                Text(part.title).font(MacMetric.font(13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(usage(part)).font(MacMetric.font(12)).monospacedDigit().foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                if let budget = part.budget {
                    MacSettingsPopUp(label: budget.title,
                                     options: budget.choices.map { ($0, "\($0 >> 30) GB") },
                                     selection: Binding(get: { budget.held() }, set: { budget.set($0) }),
                                     other: "\(budget.held() >> 30) GB")
                        .accessibilityIdentifier("mac.settings.budget.\(budget.id)")
                }
            }
            MacSettingsCaption(part.line).padding(.leading, MacMetric.pt(19))
        }
        .padding(.horizontal, MacMetric.pt(MacSettingsMetric.inset))
        .padding(.vertical, MacMetric.pt(6))
        .frame(minHeight: MacMetric.pt(MacSettingsMetric.row))
        .overlay(alignment: .bottom) {
            if !last { MacSettingsHairline().padding(.leading, MacMetric.pt(MacSettingsMetric.inset + 19)) }
        }
    }

    /// "1.2 GB" (a budget's "of 5 GB" is its pop-up button beside it); the full renders say "Counting"
    /// until they are counted.
    private func usage(_ part: Part) -> String {
        if part.budget?.id == "fullRenders", !measuredFull { return L("Counting") }
        return Fmt.gigabytes(part.bytes)
    }
}
