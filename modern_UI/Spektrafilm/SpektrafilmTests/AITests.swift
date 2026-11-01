import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// ARCHITECTURE §7.14: the AI assistant. The first group is pure — metrics,
/// the two wire formats, the ranking and the refinement's scope — and needs no
/// engine or network. The session group prints proofs of a synthetic frame on
/// a real engine, so it needs no fixture checkout and does not skip.
@MainActor
final class AIUnitTests: XCTestCase {

    // MARK: metrics

    private func metrics(_ pixels: [(UInt8, UInt8, UInt8)]) -> ImageMetrics {
        let bytes: [UInt8] = pixels.flatMap { p -> [UInt8] in [p.0, p.1, p.2, 255] }
        return bytes.withUnsafeBufferPointer { ImageMetrics(rgba: $0) }
    }

    func testMetricsOnKnownPixels() {
        let white = metrics(Array(repeating: (255, 255, 255), count: 4))
        XCTAssertEqual(white.highlightClip, 1)
        XCTAssertEqual(white.shadowClip, 0)
        XCTAssertEqual(white.meanLuma, 1, accuracy: 1e-9)

        let black = metrics(Array(repeating: (0, 0, 0), count: 4))
        XCTAssertEqual(black.shadowClip, 1)
        XCTAssertEqual(black.highlightClip, 0)

        // A dark red is not a crushed shadow: one channel is well above the floor.
        let darkRed = metrics([(120, 2, 2)])
        XCTAssertEqual(darkRed.shadowClip, 0)

        let grey = metrics(Array(repeating: (128, 128, 128), count: 9))
        XCTAssertEqual(grey.contrast, 0, accuracy: 1e-9)
        XCTAssertEqual(grey.colorfulness, 0, accuracy: 1e-9)
        XCTAssertEqual(grey.castRG, 0, accuracy: 1e-9)

        let half = metrics([(0, 0, 0), (255, 255, 255)])
        XCTAssertEqual(half.contrast, 0.5, accuracy: 1e-9)

        let warm = metrics(Array(repeating: (200, 150, 80), count: 4))
        XCTAssertGreaterThan(warm.castYB, 0, "orange leans warm")
        XCTAssertGreaterThan(warm.castRG, 0)
        // A flat patch has no spread, so only the mean term is left:
        // 0.3·√(rg² + yb²) with rg = 50, yb = 175 − 80 = 95.
        XCTAssertEqual(warm.colorfulness, 0.3 * (50.0 * 50 + 95 * 95).squareRoot(), accuracy: 1e-9)
    }

    // MARK: the Anthropic wire

    private struct Recorder: AITransport, @unchecked Sendable {
        final class Box: @unchecked Sendable { var url: URL?; var headers: [String: String] = [:]; var body: JSONValue? }
        let box = Box()
        let reply: AIHTTPResponse
        func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse {
            box.url = url; box.headers = headers
            box.body = try JSONValue.parse(String(decoding: body, as: UTF8.self))
            return reply
        }
    }

    private func reply(_ status: Int, _ json: JSONValue) -> AIHTTPResponse {
        AIHTTPResponse(status: status, body: Data(json.text().utf8))
    }

    private let schema: JSONValue = ["type": "object", "additionalProperties": false, "required": ["ok"],
                                     "properties": ["ok": ["type": "boolean"]]]

    func testTheAnthropicRequestCarriesTheImageTheSchemaAndTheFallback() async throws {
        let rec = Recorder(reply: reply(200, ["stop_reason": "end_turn", "content": [
            ["type": "thinking", "thinking": ""],
            ["type": "text", "text": "{\"ok\": true}"],
        ]]))
        let client = AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "sk-test", transport: rec)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let out = try await client.complete(AIRequest(system: "sys", parts: [.jpeg(jpeg), .text("hi")], schema: schema))
        XCTAssertEqual(out["ok"]?.bool, true, "the thinking block is not the answer")

        XCTAssertEqual(rec.box.url, AIClient.anthropicEndpoint)
        XCTAssertEqual(rec.box.headers["x-api-key"], "sk-test")
        XCTAssertEqual(rec.box.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(rec.box.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(rec.box.body)
        XCTAssertEqual(body["model"]?.string, "claude-opus-5-5")
        XCTAssertEqual(body["system"]?.string, "sys")
        XCTAssertEqual(body["fallbacks"]?.string, "default")
        XCTAssertEqual(body["output_config"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(body["output_config"]?["format"]?["schema"], schema)
        XCTAssertNil(body["thinking"], "Opus 5.5 rejects a disabled thinking setting; none is sent")
        guard case .array(let msgs)? = body["messages"], case .array(let content)? = msgs.first?["content"] else {
            return XCTFail("no user content")
        }
        XCTAssertEqual(content.first?["type"]?.string, "image")
        XCTAssertEqual(content.first?["source"]?["media_type"]?.string, "image/jpeg")
        XCTAssertEqual(content.first?["source"]?["data"]?.string, jpeg.base64EncodedString())
        XCTAssertEqual(content.last?["text"]?.string, "hi")
    }

    func testOnlyTheModelsThatTakeItAskForTheFallback() {
        let haiku = AIClient(kind: .anthropic, model: "claude-haiku-5-5", baseURL: "", apiKey: "k")
        XCTAssertNil(haiku.anthropicHeaders()["anthropic-beta"])
        XCTAssertNil(haiku.anthropicBody(AIRequest(system: "", parts: [], schema: schema))["fallbacks"])
    }

    func testAnthropicFailuresAreNamed() {
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(200, ["stop_reason": "refusal", "content": [],
                                                                    "stop_details": ["category": "cyber"]]))) {
            XCTAssertEqual($0 as? AIError, .refused("cyber"))
        }
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(200, ["stop_reason": "max_tokens", "content": []]))) {
            XCTAssertEqual($0 as? AIError, .truncated)
        }
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(401, ["error": ["message": "invalid x-api-key"]]))) {
            XCTAssertEqual($0 as? AIError, .http(401, "invalid x-api-key"))
        }
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(200, ["stop_reason": "end_turn",
                                                                    "content": [["type": "text", "text": "no json here"]]])))
    }

    func testNoKeyIsRefusedBeforeAnythingIsSent() async {
        let rec = Recorder(reply: reply(200, [:]))
        let client = AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "", transport: rec)
        do {
            _ = try await client.complete(AIRequest(system: "", parts: [], schema: schema))
            XCTFail("sent without a key")
        } catch {
            guard case .notConfigured? = error as? AIError else { return XCTFail("\(error)") }
        }
        XCTAssertNil(rec.box.url)
    }

    // MARK: the OpenAI-compatible wire

    func testTheOpenAIRequestAndAFencedAnswer() async throws {
        let rec = Recorder(reply: reply(200, ["choices": [["finish_reason": "stop",
                                                           "message": ["content": "```json\n{\"ok\": true}\n```"]]]]))
        let client = AIClient(kind: .openAICompatible, model: "vision-model", baseURL: "http://localhost:11434/v1/",
                              apiKey: "", transport: rec)
        let out = try await client.complete(AIRequest(system: "sys", parts: [.jpeg(Data([1, 2, 3]))], schema: schema))
        XCTAssertEqual(out["ok"]?.bool, true)
        XCTAssertEqual(rec.box.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(rec.box.headers["authorization"], "a local server with no key gets no header")
        let body = try XCTUnwrap(rec.box.body)
        XCTAssertEqual(body["response_format"]?["type"]?.string, "json_object")
        guard case .array(let msgs)? = body["messages"], case .array(let content)? = msgs.last?["content"] else {
            return XCTFail("no user content")
        }
        XCTAssertEqual(msgs.first?["role"]?.string, "system")
        XCTAssertEqual(content.first?["image_url"]?["url"]?.string, "data:image/jpeg;base64,AQID")
        XCTAssertTrue(content.last?["text"]?.string?.contains("\"additionalProperties\"") == true,
                      "the schema travels in the prompt")
    }

    func testAKeyIsABearerToken() async throws {
        let rec = Recorder(reply: reply(200, ["choices": [["message": ["content": "{\"ok\": false}"]]]]))
        let client = AIClient(kind: .openAICompatible, model: "m", baseURL: "https://api.openai.com/v1",
                              apiKey: "sk-x", transport: rec)
        _ = try await client.complete(AIRequest(system: "", parts: [], schema: schema))
        XCTAssertEqual(rec.box.headers["authorization"], "Bearer sk-x")
        XCTAssertThrowsError(try AIClient.readOpenAI(reply(200, ["choices": [["finish_reason": "length",
                                                                               "message": ["content": "{"]]]]))) {
            XCTAssertEqual($0 as? AIError, .truncated)
        }
    }

    // MARK: reading answers

    func testARankingKeepsTilesThatExistEachOnce() throws {
        let answer: JSONValue = ["summary": "s", "ranking": [
            ["index": 3, "score": 91, "reason": "a"], ["index": 3, "score": 80, "reason": "dup"],
            ["index": 0, "score": 70, "reason": "none"], ["index": 9, "score": 70, "reason": "past the end"],
            ["index": 1, "score": 140, "reason": "b"],
        ]]
        let (summary, ranked) = try AIPrompts.readRanking(answer, count: 4)
        XCTAssertEqual(summary, "s")
        XCTAssertEqual(ranked, [.init(index: 3, score: 91, reason: "a"), .init(index: 1, score: 100, reason: "b")])
        XCTAssertThrowsError(try AIPrompts.readRanking(["ranking": [["index": 7, "score": 1, "reason": ""]]], count: 4))
    }

    func testARefinementMayOnlyTouchItsOwnFields() throws {
        XCTAssertNoThrow(try AIPrompts.checkScope(["params": ["yFilterShift": 0.04, "printBrightnessStops": 0.2],
                                                   "adjustments": ["contrast": 6, "colorBalance": ["shadows": ["hue": 200, "saturation": 0.1]]]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["params": ["filmStock": "kodak_portra_160"]]),
                             "the film is the chooser's")
        XCTAssertThrowsError(try AIPrompts.checkScope(["geometry": ["angle": 2]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["decode": ["temperature": 5000]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["params": ["yFilterShift": 5]]), "the interface's range holds")
    }

    func testAMoveIsReadStrictly() throws {
        let none = try AIPrompts.readMove(["rationale": "fine", "patch_json": "{}", "placement": .null, "done": true])
        XCTAssertNil(none.patch)
        XCTAssertNil(none.placement)
        XCTAssertTrue(none.done)

        let move = try AIPrompts.readMove(["rationale": "r", "patch_json": "{\"adjustments\":{\"exposure\":0.2}}",
                                           "placement": ["highlight": 9, "shadow": 0], "done": false])
        XCTAssertEqual(move.patch, ["adjustments": ["exposure": 0.2]])
        XCTAssertEqual(move.placement?.highlight, 6, "clamped to the Fit's range")
        XCTAssertEqual(move.placement?.shadow, 0)

        let zero = try AIPrompts.readMove(["rationale": "", "patch_json": "", "placement": ["highlight": 0, "shadow": 0], "done": false])
        XCTAssertNil(zero.placement, "both sides 0 is no placement, not a reset")

        XCTAssertThrowsError(try AIPrompts.readMove(["rationale": "", "patch_json": "[1]", "placement": .null, "done": false]))

        // A compatible model that hands the patch over as an object.
        let object = try AIPrompts.readMove(["rationale": "", "patch_json": ["adjustments": ["contrast": 4]],
                                             "placement": .null, "done": false])
        XCTAssertEqual(object.patch, ["adjustments": ["contrast": 4]])
    }

    // MARK: which films

    func testTheDefaultCandidatesAreFairAndPrintable() {
        let catalog = StockCatalog.shared
        var current = FilmParams()
        current.filmStock = "kodak_portra_800_push1"
        current.printStock = "kodak_supra_endura"
        current.scanFilm = false
        let c = ProofSheet.defaultCandidates(catalog: catalog, current: current)
        XCTAssertEqual(c.first, ProofCandidate(film: "kodak_portra_800_push1", paper: "kodak_supra_endura"),
                       "what the frame has now is always one of the answers, first")
        XCTAssertEqual(Set(c.map(\.film)).count, c.count, "one proof per film")
        XCTAssertFalse(c.dropFirst().contains { $0.film.contains("_push") }, "push processes are the same emulsion")
        XCTAssertFalse(c.contains { catalog.stock($0.film)?.isMonochrome == true }, "black and white only when asked")
        for x in c {
            let film = catalog.stock(x.film)
            if film?.isPositive == true {
                XCTAssertNil(x.paper, "\(x.film) is scanned")
            } else {
                let paper = try? XCTUnwrap(x.paper)
                XCTAssertTrue(paper.map { catalog.canPrint(film: x.film, on: $0) } ?? false, "\(x.film)")
            }
        }
        let mono = ProofSheet.defaultCandidates(catalog: catalog, current: current, includeMonochrome: true)
        XCTAssertTrue(mono.contains { $0.film == "kodak_tri_x_400" && $0.paper == "ilford_multigrade_iv_rc" })
        XCTAssertThrowsError(try ProofSheet.candidates(films: ["kodak_portra_400", "no_such_film"], catalog: catalog))
    }

    func testAProofIsANeutralPrint() {
        var p = FilmParams()
        p.exposureCompensationEV = 1.5
        p.yFilterShift = 0.2
        p.grainActive = true
        p.glareActive = true
        p.filmEdge.active = true
        p.sceneLatitude.active = true
        let q = ProofSheet.proofParams(from: p)
        XCTAssertEqual(q.exposureCompensationEV, 0)
        XCTAssertEqual(q.yFilterShift, 0)
        XCTAssertTrue(q.autoExposure)
        XCTAssertFalse(q.grainActive, "grain at proof size is aliasing")
        XCTAssertFalse(q.glareActive, "glare is the one unseeded stage (AGENTS.md trap 1)")
        XCTAssertFalse(q.filmEdge.active)
        XCTAssertEqual(q.sceneLatitude, SceneLatitudeSettings())
    }

    func testTheToolTableListsCompare() throws {
        let tool = try XCTUnwrap(AgentTools.named("compare_stocks"))
        XCTAssertEqual(tool.command, "compare")
        let (name, args, preview) = try AgentCLI.parse(["compare", "/tmp/x.tif", "--films", "kodak_portra_400, kodak_gold_200",
                                                        "--mono", "--long-edge", "512", "--preview", "/tmp/s.jpg"])
        XCTAssertEqual(name, "compare_stocks")
        XCTAssertEqual(args["films"], ["kodak_portra_400", "kodak_gold_200"])
        XCTAssertEqual(args["include_monochrome"], true)
        XCTAssertEqual(args["long_edge"], 512)
        XCTAssertEqual(preview?.path, "/tmp/s.jpg")
    }
}

/// Proofs on a real engine, of a frame drawn here — so nothing is skipped.
@MainActor
final class AISessionTests: XCTestCase {

    /// A 1200×800 PNG: a grey ramp across, a band of saturated patches, and a
    /// dark corner, so every film renders something to tell apart.
    private func syntheticFrame() throws -> URL {
        let w = 1200, h = 800
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0..<w {
            let v = CGFloat(x) / CGFloat(w - 1)
            ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let patches: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.2, 0.7, 0.3), (0.2, 0.3, 0.8),
                                                      (0.9, 0.75, 0.6), (0.9, 0.8, 0.2), (0.4, 0.6, 0.5)]
        for (i, c) in patches.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 60 + i * 180, y: 300, width: 150, height: 200))
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "synthetic.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// **The isolation promise.** Printing proofs runs on an engine of its
    /// own: the frame's edit, its undo history and the canvas's engine
    /// session are exactly as they were.
    func testProofsLeaveTheSessionAlone() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        try await ws.develop()
        let s = ws.session
        let sidecar = s.sidecar
        let canUndo = s.canUndo
        let engineSession = s.serviceSessionIDForExport

        let candidates = try ProofSheet.candidates(films: ["kodak_portra_400", "fujifilm_velvia_100", "kodak_vision3_500t"])
        var ticks: [Int] = []
        let proofs = try await ProofSheet.render(session: s, candidates: candidates, longEdge: 384) { done, _ in ticks.append(done) }

        XCTAssertEqual(proofs.map(\.candidate), candidates)
        XCTAssertEqual(ticks, [1, 2, 3])
        for p in proofs {
            XCTAssertEqual(max(p.image.width, p.image.height), 384, "\(p.candidate.film) at the asked size")
            XCTAssertNotNil(p.latitude, "\(p.candidate.film): the engine measured the scene")
        }
        XCTAssertNotEqual(proofs[0].metrics, proofs[1].metrics, "two films print differently")

        XCTAssertEqual(s.sidecar, sidecar, "the edit is untouched")
        XCTAssertEqual(s.canUndo, canUndo, "no undo step was taken")
        XCTAssertEqual(s.serviceSessionIDForExport, engineSession)
        // The engine behind the canvas still holds this frame, at its own size:
        // a proof run on the shared client would have replaced it with a proof.
        let sid = try XCTUnwrap(engineSession)
        let again = try await s.client.render(.reprint, RenderRequest(sessionID: sid))
        XCTAssertEqual(again.texture.map { max($0.width, $0.height) }, 1200,
                       "the canvas's engine session was not replaced")

        let sheet = try XCTUnwrap(ProofSheet.contactSheet(proofs))
        XCTAssertGreaterThan(sheet.width, sheet.height / 2)
    }

    /// Proofs are a neutral print with the stochastic stages off, so the same
    /// film twice is the same picture (AGENTS.md trap 1).
    func testAProofReproduces() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let c = try ProofSheet.candidates(films: ["kodak_gold_200"])
        let a = try await ProofSheet.render(session: ws.session, candidates: c, longEdge: 256)
        let b = try await ProofSheet.render(session: ws.session, candidates: c, longEdge: 256)
        XCTAssertEqual(a[0].metrics, b[0].metrics)
    }

    /// A model's answers in order, one per request, and what it was sent.
    private final class Script: AITransport, @unchecked Sendable {
        var replies: [JSONValue]
        var sent: [JSONValue] = []
        init(_ replies: [JSONValue]) { self.replies = replies }
        func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse {
            sent.append(try JSONValue.parse(String(decoding: body, as: UTF8.self)))
            let next = replies.isEmpty ? ["rationale": "", "patch_json": "{}", "placement": .null, "done": true] : replies.removeFirst()
            let wire: JSONValue = ["stop_reason": "end_turn", "content": [["type": "text", "text": .string(next.text())]]]
            return AIHTTPResponse(status: 200, body: Data(wire.text().utf8))
        }
    }

    /// An unreadable round, an out-of-scope round and a good round: the first
    /// two are reported and fed back, the run goes on, the third is applied,
    /// and Undo AI changes puts every writable field back.
    func testARefinementSurvivesABadRoundAndUndoes() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let script = Script([
            ["rationale": "garbled", "patch_json": "{not json", "placement": .null, "done": false],
            ["rationale": "film", "patch_json": "{\"params\":{\"filmStock\":\"kodak_gold_200\"}}", "placement": .null, "done": false],
            ["rationale": "warmer", "patch_json": "{\"params\":{\"yFilterShift\":0.05},\"adjustments\":{\"contrast\":7}}",
             "placement": .null, "done": true],
        ])
        let assistant = AIAssistant(session: s)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        let film = s.params.filmStock
        let before = try s.agentDocument.json

        assistant.refine()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertNil(assistant.error, assistant.error ?? "")
        XCTAssertEqual(assistant.steps.count, 3)
        XCTAssertNotNil(assistant.steps[0].refused, "the unreadable round is reported")
        XCTAssertNotNil(assistant.steps[1].refused, "the film is not the refiner's")
        XCTAssertNil(assistant.steps[2].refused)
        XCTAssertEqual(Set(assistant.steps[2].changed), ["params.yFilterShift", "adjustments.contrast"])
        XCTAssertEqual(s.params.filmStock, film)
        XCTAssertEqual(s.params.yFilterShift, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s.adjustments.contrast, 7)
        // Each refusal was said back in the next request.
        XCTAssertEqual(script.sent.count, 3)
        let third = script.sent[2].text()
        XCTAssertTrue(third.contains("was refused"), "the second refusal travels with the third request")

        assistant.undoAI()
        let after = try s.agentDocument.json
        for field in AgentSchema.fields where field.readOnly == nil {
            let path = field.path.split(separator: ".").map(String.init)
            XCTAssertEqual(path.reduce(Optional(after)) { $0?[$1] }, path.reduce(Optional(before)) { $0?[$1] }, field.path)
        }
    }

    /// Applying a negative from a slide film prints it: the film list leaves
    /// `scanFilm` on, and the paper the slide kept may already be the one.
    func testApplyingANegativeAfterASlidePrintsIt() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        s.selectFilmStock("kodak_portra_400")
        s.selectPrintStock("kodak_portra_endura")
        s.selectFilmStock("fujifilm_velvia_100")
        XCTAssertTrue(s.params.scanFilm)
        XCTAssertEqual(s.params.printStock, "kodak_portra_endura", "the slide keeps the paper it does not use")

        let tile = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let pick = AIAssistant.Pick(index: 1, candidate: ProofCandidate(film: "kodak_portra_400", paper: "kodak_portra_endura"),
                                    score: 90, reason: "", thumbnail: tile)
        AIAssistant(session: s).apply(pick)
        XCTAssertEqual(s.params.filmStock, "kodak_portra_400")
        XCTAssertFalse(s.params.scanFilm, "printed on the paper, not scanned")
        try await ws.settle()
    }

    /// Restoring an earlier edit is one step, and Undo takes it back.
    func testRestoringAnEditIsOneUndoableStep() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let before = s.sidecar
        _ = try await ws.edit(["adjustments": ["contrast": 20, "exposure": 0.5], "params": ["yFilterShift": 0.1]])
        try await Task.sleep(for: .milliseconds(600))
        _ = try await ws.edit(["adjustments": ["saturation": 15]])
        let edited = s.sidecar
        XCTAssertNotEqual(edited, before)

        s.restoreSidecar(before)
        XCTAssertEqual(s.sidecar.params, before.params)
        XCTAssertEqual(s.sidecar.adjustments, before.adjustments)
        s.undo()
        XCTAssertEqual(s.sidecar.adjustments, edited.adjustments, "Undo takes the restore back in one step")
    }
}

/// The whole loop against a real model: proofs, a ranking, three rounds of
/// refinement and the undo. **Opt-in** — it needs a model and costs whatever
/// that model costs — so it skips unless `SPK_AI_E2E` names an
/// OpenAI-compatible base URL and `SPK_AI_MODEL` a vision model, e.g. a local
/// Ollama:
///
///     TEST_RUNNER_SPK_AI_E2E=http://localhost:11434/v1 TEST_RUNNER_SPK_AI_MODEL=gemma4:e4b \
///     TEST_RUNNER_SPK_AI_IMAGE=/path/to/photo.jpg xcodebuild … test \
///         -only-testing:SpektrafilmTests/AIEndToEndTests
@MainActor
final class AIEndToEndTests: XCTestCase {
    func testChooseRefineAndUndo() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SPK_AI_E2E"], let model = env["SPK_AI_MODEL"] else {
            throw XCTSkip("SPK_AI_E2E and SPK_AI_MODEL are not set")
        }
        let source = try XCTUnwrap(env["SPK_AI_IMAGE"].map(URL.init(fileURLWithPath:)), "SPK_AI_IMAGE")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-ai-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)

        let saved = (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel)
        addTeardownBlock { @MainActor in
            (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel) = saved
        }
        AISettings.enabled = true
        AISettings.provider = .openAICompatible
        AISettings.openAIBaseURL = base
        AISettings.openAIModel = model

        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let assistant = AIAssistant(session: s)
        assistant.intent = env["SPK_AI_INTENT"] ?? "warm and cinematic"
        let before = s.sidecar

        func finish() async throws {
            let deadline = Date().addingTimeInterval(900)
            try await Task.sleep(for: .milliseconds(50))
            while assistant.busy {
                XCTAssertLessThan(Date(), deadline, "the assistant did not finish")
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        assistant.recommendFilm()
        try await finish()
        XCTAssertNil(assistant.error, assistant.error ?? "")
        let rec = try XCTUnwrap(assistant.recommendation)
        print("E2E summary:", rec.summary)
        for p in rec.picks { print("E2E pick \(p.index) \(p.candidate.film) \(p.score): \(p.reason)") }
        XCTAssertFalse(rec.picks.isEmpty)
        XCTAssertEqual(s.sidecar, before, "recommending changes nothing")

        let pick = rec.picks[0]
        assistant.apply(pick)
        try await ws.settle()
        XCTAssertEqual(s.params.filmStock, pick.candidate.film)

        assistant.refine()
        try await finish()
        XCTAssertNil(assistant.error, assistant.error ?? "")
        for step in assistant.steps {
            print("E2E round \(step.round): \(step.rationale) | changed \(step.changed) | refused \(step.refused ?? "-")")
        }
        XCTAssertFalse(assistant.steps.isEmpty)
        s.flushSave()
        let preview = try await ws.preview(to: URL(fileURLWithPath: "/tmp/spk-test/e2e-refined.jpg"), longEdge: 1024)
        print("E2E preview:", preview.path)

        XCTAssertTrue(assistant.canUndo)
        assistant.undoAI()
        // Every field a person (or an agent) can write is back. The fields the
        // app resolves for itself (`readOnly`, e.g. the date back's camera) are
        // re-derived after a render and are not part of the edit.
        let now = try s.agentDocument.json, then = try AgentDocument(before).json
        for field in AgentSchema.fields where field.readOnly == nil {
            let path = field.path.split(separator: ".").map(String.init)
            let a = path.reduce(Optional(now)) { $0?[$1] }, b = path.reduce(Optional(then)) { $0?[$1] }
            XCTAssertEqual(a, b, "Undo AI changes puts \(field.path) back")
        }
    }
}
