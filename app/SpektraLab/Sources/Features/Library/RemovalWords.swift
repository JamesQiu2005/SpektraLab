//  RemovalWords.swift — what Remove says, wherever it is asked (the library page, the develop page's
//  browser, 2026-10-26): one wording, so a frame going is the same act in both places. The window's
//  library and the Mac's pages all ask through here.
//
//  A half-frame pair names its frames and never owns them: what goes is the pair (`PairWords`). And a
//  frame that goes leaves a hole in a pair that stays — said before it goes, with the original's fate:
//  an original copied in is the only copy; one in Photos or a folder stays where it is.

import Foundation

@MainActor
enum RemovalWords {
    static func title(_ ids: Set<LibraryFrame.ID>, library: FrameCatalog) -> String {
        let pairs = ids.filter { library.frame($0)?.isPair == true }.count
        if let title = PairWords.removalTitle(pairs: pairs, of: ids.count) { return title }
        return ids.count == 1 ? L("Remove this frame?") : L("Remove \(ids.count) frames?")
    }

    static func message(_ ids: Set<LibraryFrame.ID>, library: FrameCatalog) -> String {
        let all = ids.compactMap { library.frame($0) }
        let pairs = all.filter(\.isPair).count
        let frames = all.filter { !$0.isPair }
        var said: [String] = []
        if !frames.isEmpty {
            said.append(message(of: frames))
            let going = Set(frames.map(\.id))
            let leavesHole = library.frames.contains { item in
                guard let pair = item.pair, !ids.contains(item.id) else { return false }
                return [pair.left?.frame, pair.right?.frame].contains { $0.map(going.contains) ?? false }
            }
            if leavesHole { said.append(PairWords.removalLeavesHole(frames: frames.count)) }
        }
        if pairs > 0 { said.append(PairWords.removalNote(pairs: pairs)) }
        return said.joined(separator: " ")
    }

    private static func message(of frames: [LibraryFrame]) -> String {
        let copied = frames.filter { $0.source == .copiedIn }.count
        if copied == 0 { return L("Its edit and preview copy go. The original stays where it is.") }
        if copied == frames.count {
            return frames.count == 1 ? L("It was copied into SpektraLab, so its original goes with it.")
                                     : L("They were copied into SpektraLab, so their originals go with them.")
        }
        return L("\(copied) of them were copied into SpektraLab; their originals go with them. The rest stay where they are.")
    }
}
