//  DemoLibrary.swift — deterministic sample frames for page checks and the optional demo library.
//  The pictures are the owner's photographs in SampleSources/. Their fixed dates, stocks and states
//  let the harness reproduce a page without reading the person's library. Normal launch opens the
//  person's own library; these samples do not replace it.

import Foundation

enum DemoLibrary {
    enum Scenario: String, CaseIterable, Sendable {
        /// B2: two frames today, six on Sunday, one developing.
        case home
        /// B3: five frames arriving from a card.
        case importing
        /// F2: a linked disk unplugged, one original missing.
        case offline
        /// B1: nothing yet.
        case empty
    }

    struct Seed {
        var frames: [LibraryFrame]
        var selectedID: LibraryFrame.ID?
        var linkedFolders: [LinkedFolder]
        var storage: StorageReport
        var importBanner: FrameCatalog.ImportBanner?
        var now: () -> Date
    }

    static let portra = "kodak_portra_400", provia = "fujifilm_provia_100f", kodachrome = "kodak_kodachrome_64"
    static let supra = "kodak_supra_endura"

    /// The drawings' "today" is 30 September 2026 (1 October once the card is
    /// imported). `now` nil dates the library against the real clock instead,
    /// so on a host the grid still reads Today and the right weekday.
    static func seed(_ scenario: Scenario, now pinned: Date? = nil) -> Seed {
        let calendar = Calendar.current
        let drawnToday = scenario == .home ? date(2026, 9, 30, 12, 0) : date(2026, 10, 1, 18, 0)
        let now = pinned ?? Date()
        // Shift every drawn date by the same whole number of days.
        let shift = pinned == nil
            ? (calendar.dateComponents([.day], from: calendar.startOfDay(for: drawnToday),
                                       to: calendar.startOfDay(for: now)).day ?? 0)
            : 0
        func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            calendar.date(byAdding: .day, value: shift, to: date(2026, m, d, h, min)) ?? date(2026, m, d, h, min)
        }

        var order = 0
        func frame(_ picture: String, name: String, taken: Date, film: String = portra, camera: String,
                   exposure: String, size: PixelSize, source: FrameOrigin = .photos,
                   original: OriginalState = .available, develop: DevelopState = .developed) -> LibraryFrame {
            order += 1
            var edit = FrameEdit.default
            edit.params.printStock = supra
            edit.params.load(film: film, recommendingPaper: false)
            edit.frameSeed = order
            return LibraryFrame(id: UUID(), fileName: name, captureDate: taken, camera: camera, exposure: exposure,
                                originalSize: size, previewSize: size.scaled(toLongEdge: DevicePolicy.current.previewLongEdge),
                                isRAW: true, source: source, original: original, picture: .sample(picture),
                                // design/src/scene_raw_srgb.jpg is this photograph before the film.
                                originalPicture: picture == "street.jpg" ? .sample("feed.jpg") : nil,
                                // Arrival order is the drawing's left-to-right order within a day,
                                // whatever the capture times are.
                                develop: develop, edit: edit, importedAt: Date(timeIntervalSinceReferenceDate: Double(order)))
        }
        let z7 = "NIKON Z 7_2", z7Size = PixelSize(width: 6000, height: 4000)
        let gr = "RICOH GR IV", grSize = PixelSize(width: 6192, height: 4128)
        let card = FrameOrigin.linkedFolder(disk: "SANDISK SSD", path: "DCIM › 100RICOH")

        // Sunday 28 September: the frames every scenario has.
        var bund = frame("bund.jpg", name: "_DSC0061.NEF", taken: at(9, 28, 18, 42), camera: z7,
                         exposure: "1/250 s · f/5.6 · ISO 100", size: z7Size)
        // The drawing's develop page: Film Exp. +0.3, Yellow +0.10, Magenta +0.05.
        bund.edit.params.exposureCompensationEV = 0.3
        bund.edit.params.yFilterShift = 0.10
        bund.edit.params.mFilterShift = 0.05

        var frames: [LibraryFrame] = []
        var banner: FrameCatalog.ImportBanner?
        var folders = [
            LinkedFolder(id: UUID(), volume: "SANDISK SSD", path: "DCIM", kind: .disk, frameCount: 48,
                         isConnected: scenario != .offline),
            LinkedFolder(id: UUID(), volume: "iCloud Drive", path: "Scans", kind: .iCloud, frameCount: 12,
                         isConnected: true, stillInCloud: 3),
        ]

        switch scenario {
        case .empty:
            folders = []
        case .home:
            frames = [
                bund,
                frame("t3.jpg", name: "_DSC0058.NEF", taken: at(9, 28, 16, 5), film: provia, camera: z7,
                      exposure: "1/500 s · f/8 · ISO 100", size: z7Size),
                frame("t7.jpg", name: "_DSC0057.NEF", taken: at(9, 28, 15, 40), camera: z7,
                      exposure: "2 s · f/11 · ISO 64", size: z7Size),
                frame("t8.jpg", name: "_DSC0052.NEF", taken: at(9, 28, 9, 12), film: kodachrome, camera: z7,
                      exposure: "1/125 s · f/8 · ISO 64", size: z7Size),
                frame("t6.jpg", name: "_DSC0049.NEF", taken: at(9, 28, 8, 30), camera: z7,
                      exposure: "1/320 s · f/5.6 · ISO 100", size: z7Size),
                frame("t2.jpg", name: "_DSC0044.NEF", taken: at(9, 28, 20, 14), camera: z7,
                      exposure: "8 s · f/8 · ISO 64", size: z7Size),
                // Today
                frame("street.jpg", name: "_DSC0102.NEF", taken: at(9, 30, 10, 20), camera: z7,
                      exposure: "1/400 s · f/8 · ISO 100", size: PixelSize(width: 4000, height: 6000),
                      develop: .developing(progress: 0.62)),
                frame("t5.jpg", name: "_DSC0103.NEF", taken: at(9, 30, 11, 2), camera: z7,
                      exposure: "1/640 s · f/8 · ISO 100", size: z7Size),
            ]
        case .importing, .offline:
            let off: OriginalState = scenario == .offline ? .offline(disk: "SANDISK SSD") : .available
            func state(_ s: DevelopState) -> DevelopState { scenario == .offline ? .developed : s }
            let arrived = [
                frame("t6.jpg", name: "R0000412.DNG", taken: at(10, 1, 16, 2), camera: gr,
                      exposure: "1/250 s · f/5.6 · ISO 200", size: grSize, source: card, original: off),
                frame("t7.jpg", name: "R0000413.DNG", taken: at(10, 1, 16, 5), camera: gr,
                      exposure: "1 s · f/8 · ISO 100", size: grSize, source: card, original: off,
                      develop: state(.developing(progress: 0.62))),
                frame("t8.jpg", name: "R0000414.DNG", taken: at(10, 1, 16, 11), camera: gr,
                      exposure: "1/125 s · f/8 · ISO 100", size: grSize, source: card, original: off,
                      develop: state(.queued)),
                frame("t3.jpg", name: "R0000415.DNG", taken: at(10, 1, 16, 40), camera: gr,
                      exposure: "1/500 s · f/8 · ISO 100", size: grSize, source: card,
                      original: scenario == .offline ? .missing : .available, develop: state(.queued)),
                frame("t2.jpg", name: "R0000416.DNG", taken: at(10, 1, 17, 3), camera: gr,
                      exposure: "4 s · f/8 · ISO 100", size: grSize, source: card, original: off,
                      develop: state(.queued)),
            ]
            frames = [
                bund,
                frame("t5.jpg", name: "_DSC0058.NEF", taken: at(9, 28, 16, 5), film: provia, camera: z7,
                      exposure: "1/500 s · f/8 · ISO 100", size: z7Size),
                frame("street.jpg", name: "_DSC0057.NEF", taken: at(9, 28, 15, 40), camera: z7,
                      exposure: "1/400 s · f/8 · ISO 100", size: PixelSize(width: 4000, height: 6000)),
            ] + arrived
            if scenario == .importing {
                banner = .init(imported: 5, developed: 1, frameIDs: arrived.map(\.id))
            }
        }

        return Seed(frames: frames, selectedID: frames.first?.id,
                    linkedFolders: folders,
                    // An empty darkroom keeps nothing; the others keep what the drawings say.
                    storage: scenario == .empty
                        ? StorageReport(copiedInOriginals: 0, workingCopies: 0, previewCopies: 0, cache: 0)
                        : StorageReport(copiedInOriginals: gb(1.2), copiedInFrames: 37,
                                        workingCopies: gb(2.1), previewCopies: gb(3.4), cache: gb(0.2)),
                    importBanner: banner,
                    now: pinned.map { p in { p } } ?? Date.init)
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Calendar.current.date(from: c) ?? Date()
    }

    private static func gb(_ v: Double) -> Int64 { Int64(v * 1_073_741_824) }
}
