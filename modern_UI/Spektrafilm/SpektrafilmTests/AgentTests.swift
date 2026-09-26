import XCTest

/// RFC-026: the edit schema, the command line and the MCP server.
///
/// The first group is pure and needs no engine. The session tests open a
/// copy of the A7 III fixture (a develop writes a sidecar, and a checkout
/// frame must not get one) and skip where it is not checked out.
@MainActor
final class AgentSchemaTests: XCTestCase {

    /// Every stored field of the edit document, by the model's own names.
    /// A struct is walked into; anything else is a leaf.
    private func storedPaths(_ value: Any, _ prefix: String) -> Set<String> {
        var out = Set<String>()
        for child in Mirror(reflecting: value).children {
            guard let name = child.label else { continue }
            let path = "\(prefix).\(name)"
            let m = Mirror(reflecting: child.value)
            if m.displayStyle == .struct, !(child.value is CGSize), !(child.value is CGPoint) {
                out.formUnion(storedPaths(child.value, path))
            } else {
                out.insert(path)
            }
        }
        return out
    }

    /// **The parity check.** A field added to the model without a row in the
    /// schema would be one an agent cannot reach and nobody would notice;
    /// a row with no field behind it would be a promise the patch cannot keep.
    func testTheSchemaCoversEveryStoredFieldAndNothingElse() {
        let model = storedPaths(FilmParams(), "params")
            .union(storedPaths(Adjustments(), "adjustments"))
            .union(storedPaths(Geometry(), "geometry"))
            .union(storedPaths(DecodeSettings(), "decode"))
        let schema = Set(AgentSchema.fields.map(\.path))
        XCTAssertEqual(model.subtracting(schema).sorted(), [], "stored fields with no schema row")
        XCTAssertEqual(schema.subtracting(model).sorted(), [], "schema rows with no stored field")
    }

    /// The schema's paths are the *encoded* names, which is what a patch is
    /// merged into. A CodingKey that renamed a field would break every edit
    /// to it while the test above stayed green.
    func testEverySchemaPathIsInTheEncodedDocument() throws {
        var g = Geometry()
        g.intendedSize = CGSize(width: 0.5, height: 0.5)
        let doc = try AgentDocument(params: FilmParams(), adjustments: Adjustments(),
                                    geometry: g, decode: DecodeSettings()).json
        for f in AgentSchema.fields {
            let v = f.path.split(separator: ".").reduce(Optional(doc)) { $0?[String($1)] }
            XCTAssertNotNil(v, "\(f.path) is not in the encoded document")
        }
    }

    func testAPatchIsValidatedWholeBeforeAnythingIsApplied() throws {
        let ok = try AgentDocument.validate(["params": ["filmStock": "kodak_portra_160", "exposureCompensationEV": 0.5],
                                             "adjustments": ["vignette": ["amount": -20]]])
        XCTAssertEqual(Set(ok), ["params.filmStock", "params.exposureCompensationEV", "adjustments.vignette.amount"])

        func refused(_ patch: JSONValue, _ contains: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try AgentDocument.validate(patch), file: file, line: line) { e in
                guard case AgentError.refused(let why) = e else { return XCTFail("not a refusal: \(e)", file: file, line: line) }
                XCTAssertTrue(why.contains(contains), "\(why)", file: file, line: line)
            }
        }
        refused(["params": ["bogus": 1]], "params.bogus is not an editable field")
        refused(["colour": [:]], "not a section")
        refused(["params": ["exposureCompensationEV": 9]], "within")
        refused(["params": ["exposureCompensationEV": .null]], "must be a number")
        refused(["params": ["filmFormatMM": 50]], "read-only")
        refused(["params": ["sceneLatitude": ["highlightKnee": 1]]], "place")
        refused(["params": ["filmStock": "kodak_2383"]], "a film id")
        refused(["params": ["printStock": "kodak_portra_400"]], "a paper id")
        refused(["geometry": ["quarterTurns": 1.5]], "integer")
        refused(["geometry": ["aspect": "golden"]], "one of")
        refused(["adjustments": ["curves": ["rgb": ["points": [[0, 0], [0.4, 0.5], [0.3, 0.6], [1, 1]]]]]], "ascending")
        refused(["params": "portra"], "must be an object")
        refused(.array([]), "must be a JSON object")
    }

    func testAMergeChangesOnlyWhatThePatchNames() throws {
        var a = Adjustments()
        a.curves.rgb.points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.6), CGPoint(x: 1, y: 1)]
        let before = AgentDocument(params: FilmParams(), adjustments: a, geometry: Geometry(), decode: DecodeSettings())
        let after = try before.merged(with: ["adjustments": ["colorBalance": ["shadows": ["hue": 200]]]])
        var want = before
        want.adjustments.colorBalance.shadows.hue = 200
        XCTAssertEqual(after, want)
        XCTAssertEqual(after.adjustments.curves, a.curves, "a sibling object survives the merge")
    }

    /// The schema's ranges are the interface's (RFC-026 §3), spot-checked
    /// against the constants the controls use.
    func testRangesAreTheInterfaces() {
        func range(_ p: String) -> ClosedRange<Double>? {
            if case .number(let r) = AgentSchema.byPath[p]?.kind { return r }
            return nil
        }
        XCTAssertEqual(range("params.effects.couplers"), EffectStrengths.couplersRange, "trap 22's ceiling")
        XCTAssertEqual(range("params.contrastMask.scale"), ContrastMaskSettings.scaleRange)
        XCTAssertEqual(range("params.preflashExposure"), 0...0.03)
        XCTAssertEqual(range("geometry.angle"), -Geometry.maxAngle...Geometry.maxAngle)
    }
}

@MainActor
final class AgentCLITests: XCTestCase {

    func testACommandLineIsAToolCall() throws {
        let (tool, args, preview) = try AgentCLI.parse(["edit", "/x/a.ARW", "--patch", #"{"adjustments":{"exposure":0.5}}"#,
                                                        "--preview", "/x/p.jpg"])
        XCTAssertEqual(tool, "edit_image")
        XCTAssertEqual(args["path"], "/x/a.ARW")
        XCTAssertEqual(args["patch"], ["adjustments": ["exposure": 0.5]])
        XCTAssertEqual(args["preview"], true)
        XCTAssertEqual(preview?.path, "/x/p.jpg")

        let (t2, a2, _) = try AgentCLI.parse(["place", "/x/a.ARW", "--highlight", "1.5", "--shadow", "0"])
        XCTAssertEqual(t2, "place_scene")
        XCTAssertEqual(a2["highlight"], 1.5)
        XCTAssertEqual(a2["preview"], false, "no --preview, no preview rendered")
    }

    func testEveryToolHasACommandAndBack() {
        for t in AgentTools.all {
            XCTAssertEqual(AgentTools.command(t.command)?.name, t.name)
        }
        XCTAssertEqual(Set(AgentTools.all.map(\.name)).count, AgentTools.all.count)
    }

    func testMistakesAreRefusals() {
        for argv in [["bogus"], ["edit", "/x/a.ARW", "--flag"], ["info"], ["preview", "/x/a.ARW"],
                     ["place", "/x/a.ARW", "--highlight", "lots"], ["edit", "/x/a.ARW", "--patch", "{nope"]] {
            XCTAssertThrowsError(try AgentCLI.parse(argv), "\(argv)") { e in
                XCTAssertEqual((e as? AgentError)?.exitCode, 2, "\(argv): \(e)")
            }
        }
    }

    /// The switch is off by default and read at every call.
    func testTheSwitchRefusesEveryToolWhileOff() async throws {
        let saved = UserDefaults.standard.object(forKey: AgentAccess.key)
        defer { UserDefaults.standard.set(saved, forKey: AgentAccess.key) }
        UserDefaults.standard.removeObject(forKey: AgentAccess.key)
        XCTAssertFalse(AgentAccess.enabled, "off unless the person turned it on")

        let ws = AgentWorkspace()
        for t in AgentTools.all {
            do {
                _ = try await AgentTools.call(t.name, ["path": "/nonexistent.ARW"], in: ws)
                XCTFail("\(t.name) ran with access off")
            } catch let e as AgentError {
                XCTAssertEqual(e, .refused(AgentAccess.refusal), t.name)
            }
        }
        XCTAssertNil(ws.url, "a refused call opened nothing")
    }

    func testTheInstalledCommandRunsThisExecutableThroughTheApp() {
        XCTAssertTrue(AgentAccess.script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(AgentAccess.script.contains("' cli \"$@\""), "the cli door, arguments passed through")
        XCTAssertFalse(AgentAccess.executable.isEmpty)
    }
}

@MainActor
final class MCPTests: XCTestCase {

    private func json(_ s: String?) throws -> JSONValue { try JSONValue.parse(try XCTUnwrap(s)) }

    func testTheHandshakeAndTheToolList() async throws {
        let server = MCPServer(send: { _ in })
        let hello = try json(await server.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#))
        XCTAssertEqual(hello["id"], 1)
        XCTAssertEqual(hello["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertNotNil(hello["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(hello["result"]?["serverInfo"]?["name"], "spektralab")

        let none = await server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(none, "a notification gets no reply")

        let list = try json(await server.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        guard case .array(let tools)? = list["result"]?["tools"] else { return XCTFail("no tools") }
        XCTAssertEqual(tools.compactMap { $0["name"]?.string }, AgentTools.all.map(\.name))
        for t in tools {
            XCTAssertEqual(t["inputSchema"]?["type"], "object", "\(t["name"] ?? .null)")
        }
    }

    func testErrorsAreProtocolOrToolShaped() async throws {
        let saved = UserDefaults.standard.object(forKey: AgentAccess.key)
        defer { UserDefaults.standard.set(saved, forKey: AgentAccess.key) }
        UserDefaults.standard.set(false, forKey: AgentAccess.key)
        let server = MCPServer(send: { _ in })

        let unknown = try json(await server.handle(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#))
        XCTAssertEqual(unknown["error"]?["code"], -32601)
        let garbage = try json(await server.handle("{nope"))
        XCTAssertEqual(garbage["error"]?["code"], -32700)

        // A tool that is refused is a *result* the model can read, not an error.
        let call = try json(await server.handle(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_schema","arguments":{}}}"#))
        XCTAssertNil(call["error"])
        XCTAssertEqual(call["result"]?["isError"], true)
        XCTAssertTrue(call["result"]?["content"].flatMap { if case .array(let a) = $0 { a.first?["text"]?.string } else { nil } }?
            .contains("Settings ▸ Agents") ?? false)
    }

    func testThePromptCarriesTheSentence() async throws {
        let server = MCPServer(send: { _ in })
        let r = try json(await server.handle(#"{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"edit_photo","arguments":{"path":"/p/a.ARW","instruction":"a cold winter morning"}}}"#))
        let text = r["result"]?["messages"].flatMap { if case .array(let a) = $0 { a.first?["content"]?["text"]?.string } else { nil } }
        XCTAssertTrue(text?.contains("a cold winter morning") ?? false)
        XCTAssertTrue(text?.contains("/p/a.ARW") ?? false)
    }
}

/// The edit applied to a real session: the interface's rules hold for an agent.
@MainActor
final class AgentSessionTests: XCTestCase {

    private func frame() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "tests/Test_image/A7m3/DSC03710.ARW")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "A7m3/DSC03710.ARW is not in this checkout")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    func testAnEditFollowsTheInterfacesRulesAndIsSaved() async throws {
        let url = try frame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session

        // A film brings its declared paper, as the film list does.
        let written = try s.applyAgentEdit(["params": ["filmStock": "kodak_vision3_500t", "filmFrame": "120"],
                                            "geometry": ["angle": 3]])
        XCTAssertEqual(Set(written), ["params.filmStock", "params.filmFrame", "geometry.angle"])
        XCTAssertEqual(s.params.printStock, s.catalog.stock("kodak_vision3_500t")?.targetPrint)
        XCTAssertEqual(s.params.sideLengthMM, 56, "a preset shows its own side length")
        XCTAssertTrue(s.geometry.fits(in: s.sourceImageSize), "a straightened crop is fitted inside the frame")
        XCTAssertLessThan(s.geometry.crop.width, 1)

        // A slide film takes no paper, and the refusal writes nothing.
        try s.applyAgentEdit(["params": ["filmStock": "fujifilm_provia_100f"]])
        XCTAssertTrue(s.params.scanFilm)
        let before = s.agentDocument
        XCTAssertThrowsError(try s.applyAgentEdit(["params": ["printStock": "kodak_2383", "exposureCompensationEV": 1]]))
        XCTAssertEqual(s.agentDocument, before, "nothing of a refused edit was applied")

        // Saved where the window reads it.
        s.flushSave()
        XCTAssertEqual(Sidecar.load(for: url)?.params.filmStock, "fujifilm_provia_100f")
    }
}
