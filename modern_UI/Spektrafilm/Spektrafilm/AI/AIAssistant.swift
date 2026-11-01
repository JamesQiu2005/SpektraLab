//  AIAssistant.swift — the AI tab: choose a film from proofs, then refine the
//  print by its own controls (AI assistant, ARCHITECTURE §7.14).
//
//  **A model moves the sliders a person would.** Choosing a film is the film
//  list's own rule (`selectFilmStock`, then Solve); refining is a JSON merge
//  patch through `Session.applyAgentEdit`, the same validated door the CLI
//  and MCP agents use, with the interface's ranges. Nothing here writes a
//  pixel or touches a profile ("do not pollute the material model"): the
//  result is an ordinary edit, in the ordinary sidecar, that opens the same
//  in any build of the app with no AI at all.
//
//  **One way back.** The edit as it was before the first AI change on this
//  frame is kept, and "Undo AI changes" restores it as a single step
//  (`Session.restoreSidecar`), however many coalesced steps the rounds made.

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class AIAssistant {
    enum Phase: Equatable {
        case idle
        case proofing(done: Int, total: Int)
        case asking
        case refining(round: Int, of: Int)
    }

    struct Pick: Identifiable {
        let index: Int
        let candidate: ProofCandidate
        let score: Int
        let reason: String
        let thumbnail: CGImage
        var id: Int { index }
    }

    struct Recommendation {
        let url: URL
        let summary: String
        let picks: [Pick]
        let compared: Int
    }

    struct Step: Identifiable {
        let round: Int
        let rationale: String
        /// Leaf paths written this round.
        let changed: [String]
        /// Why some or all of the round was not applied.
        let refused: String?
        var id: Int { round }
    }

    let session: Session
    var phase: Phase = .idle
    /// What the person wants, in their words. May be empty.
    var intent = ""
    var includeMonochrome = false
    var recommendation: Recommendation?
    var steps: [Step] = []
    var error: String?
    private(set) var before: (url: URL, sidecar: Sidecar)?
    private var task: Task<Void, Never>?
    /// Where a call's client comes from: the settings, or a test's script.
    var makeClient: () throws -> AIClient = AISettings.client

    static let maxRounds = 3
    /// Proofs for a recommendation are smaller than the CLI's: they are
    /// shown as 300 px tiles.
    static let proofLongEdge = 512

    init(session: Session) {
        self.session = session
    }

    var busy: Bool { phase != .idle }
    var canUndo: Bool {
        guard let before, before.url == session.selection else { return false }
        return before.sidecar != session.sidecar
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    // MARK: choosing a film

    func recommendFilm() {
        start { [self] in
            let client = try makeClient()
            let catalog = session.catalog
            let candidates = ProofSheet.defaultCandidates(catalog: catalog, current: session.params,
                                                          includeMonochrome: includeMonochrome)
            guard let url = session.selection else { throw ProofSheet.Failure.nothingOpen }
            phase = .proofing(done: 0, total: candidates.count)
            let proofs = try await ProofSheet.render(session: session, candidates: candidates,
                                                     longEdge: Self.proofLongEdge) { [weak self] done, total in
                self?.phase = .proofing(done: done, total: total)
            }
            guard let sheet = ProofSheet.contactSheet(proofs, catalog: catalog),
                  let jpeg = Self.jpeg(sheet) else { throw ProofSheet.Failure.noPixels("contact sheet") }
            phase = .asking
            let answer = try await client.complete(AIRequest(
                system: AIPrompts.chooserSystem,
                parts: [.jpeg(jpeg), .text(AIPrompts.chooserUser(proofs: proofs, catalog: catalog,
                                                                 exif: session.exif, intent: intent))],
                schema: AIPrompts.chooserSchema))
            try Task.checkCancellation()
            let (summary, ranked) = try AIPrompts.readRanking(answer, count: proofs.count)
            let picks = ranked.map { r in
                let p = proofs[r.index - 1]
                return Pick(index: r.index, candidate: p.candidate, score: r.score, reason: r.reason, thumbnail: p.image)
            }
            guard session.selection == url else { return }
            recommendation = Recommendation(url: url, summary: summary, picks: picks, compared: proofs.count)
        }
    }

    /// The film list's rule, then Solve — what choosing it by hand and
    /// pressing Process does.
    func apply(_ pick: Pick) {
        guard !busy, !session.batchExporting, session.selection != nil else { return }
        remember()
        session.selectFilmStock(pick.candidate.film)
        // Always, when there is a paper: coming from a slide film, the film
        // list leaves `scanFilm` on, and only choosing a paper turns it off —
        // even when the paper kept from before is already this one.
        if let paper = pick.candidate.paper {
            session.selectPrintStock(paper)
        }
        session.solveNow()
    }

    // MARK: refining

    func refine() {
        start { [self] in
            let client = try makeClient()
            guard let url = session.selection else { throw ProofSheet.Failure.nothingOpen }
            guard session.pair == nil else { throw ProofSheet.Failure.pair }
            remember()
            steps = []
            let ws = AgentWorkspace(attachedTo: session)
            // Judge colour on a solved print, as the MCP instructions ask.
            if (session.frameStates[url] ?? .unprocessed) == .unprocessed {
                phase = .refining(round: 0, of: Self.maxRounds)
                try await ws.process()
            }
            var feedback: String?
            for round in 1...Self.maxRounds {
                try Task.checkCancellation()
                guard session.selection == url else { return }
                phase = .refining(round: round, of: Self.maxRounds)
                let preview = try await ws.preview(longEdge: AISettings.sentLongEdge)
                defer { try? FileManager.default.removeItem(at: preview) }
                let jpeg = try Data(contentsOf: preview)
                let latitude = try? await ws.latitude()
                let answer = try await client.complete(AIRequest(
                    system: AIPrompts.refinerSystem,
                    parts: [.jpeg(jpeg), .text(AIPrompts.refinerUser(
                        document: try ws.document, latitude: latitude, film: session.catalog.stock(session.params.filmStock)?.name,
                        exif: session.exif, intent: intent, history: steps, feedback: feedback,
                        round: round, of: Self.maxRounds))],
                    schema: AIPrompts.refinerSchema))
                try Task.checkCancellation()
                guard session.selection == url else { return }
                // An answer that cannot be read is a round that was not
                // applied, said back to the model — not the end of the run.
                let move: AIPrompts.Move
                do {
                    move = try AIPrompts.readMove(answer)
                } catch let e as AIError {
                    steps.append(Step(round: round, rationale: answer["rationale"]?.string ?? "", changed: [],
                                      refused: e.description))
                    feedback = e.description
                    continue
                }
                var changed: [String] = []
                var refused: [String] = []
                if let patch = move.patch {
                    do {
                        try AIPrompts.checkScope(patch)
                        changed += try await ws.edit(patch)
                    } catch let e as AgentError {
                        refused.append(e.description)
                    }
                }
                if let place = move.placement {
                    do {
                        _ = try await ws.place(highlight: place.highlight, shadow: place.shadow)
                        changed.append("params.sceneLatitude")
                    } catch let e as AgentError {
                        refused.append(e.description)
                    }
                }
                try await ws.settle()
                let why = refused.isEmpty ? nil : refused.joined(separator: " ")
                steps.append(Step(round: round, rationale: move.rationale, changed: changed, refused: why))
                feedback = why
                if move.done && why == nil { break }
            }
        }
    }

    func undoAI() {
        guard !busy, let before, before.url == session.selection else { return }
        session.restoreSidecar(before.sidecar)
        steps = []
    }

    // MARK: plumbing

    /// The edit before the first AI change on this frame.
    private func remember() {
        guard let url = session.selection else { return }
        if before?.url != url { before = (url, session.sidecar) }
    }

    private func start(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        guard !session.batchExporting else {
            error = L("A batch export is running. Try again when it finishes.", zh: "正在批量导出，请等它结束后再试。")
            return
        }
        error = nil
        task = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
            } catch let e as AIError {
                self?.error = e.localized
            } catch {
                self?.error = "\(error)"
            }
            self?.phase = .idle
            self?.task = nil
        }
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let url = FileManager.default.temporaryDirectory.appending(path: "spektralab-ai-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? ProofSheet.writeJPEG(image, to: url)) != nil else { return nil }
        return try? Data(contentsOf: url)
    }
}
