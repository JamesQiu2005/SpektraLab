// agent_selftest.swift -- the agent interface's own parts, without the app (ARCHITECTURE.md §7.16):
// Sources/Agent/{JSONValue, AgentTools, AgentWire, AgentClient, AgentServer}.swift.
//
//   - the tool table: every tool's schema is an object schema that refuses unknown keys, and a call is held
//     to it whole (unknown tool, unknown key, missing key, wrong type, range, enum, null, list items);
//   - the socket's path: one per bundle id, one per test home, never past `sun_path`'s 104 bytes;
//   - the socket itself, end to end: `AgentServer` over a stand-in `execute`, `AgentConnection` and the CLI
//     against it -- several requests on one connection, each id answered, a line that is not JSON refused,
//     the file 0600, a stale file removed, a second server refused while the first answers, and the CLI's
//     exit codes (0 done, 1 failed, 2 refused);
//   - MCP's framing (`MCPServer.handle`): initialize, ping, tools/list, a notification unanswered, the
//     JSON-RPC errors, and a tool's failure as an `isError` result.
//
// Compiled and run by tools/selftest.sh. `--self-test` runs the socket part against a stand-in app that
// says yes to everything, whatever it is asked: it passes only when the checks notice.
import Darwin
import Foundation

/// The app's log, which this test does not keep.
enum LogCategory { case app }
enum Log {
    static func note(_ c: LogCategory, _ m: String, _ f: [String: Any] = [:]) {}
    static func warn(_ c: LogCategory, _ m: String, _ f: [String: Any] = [:]) {}
}

@main
struct AgentSelfTest {
    nonisolated(unsafe) static var passed = 0, failed = 0
    static func expect(_ ok: Bool, _ what: String) {
        if ok { passed += 1 } else { failed += 1; print("FAILED  \(what)") }
    }

    static func refusal(_ tool: String, _ args: JSONValue?) -> String? {
        do { _ = try AgentTools.validate(tool, args); return nil } catch let e as AgentError {
            return e.isRefusal ? e.description : "failed, not refused: \(e)"
        } catch { return "\(error)" }
    }

    static func main() async {
        let breaking = CommandLine.arguments.contains("--self-test")
        AgentOutput.handle = FileHandle(forWritingAtPath: "/dev/null")!
        if !breaking {
            table()
            paths()
            mcp()
        }
        await socket(breaking: breaking)
        if breaking {
            // The stand-in says yes to everything: the socket's checks must have caught it.
            let caught = failed
            print("agent --self-test: \(caught) failures caught")
            exit(caught >= 4 ? 0 : 1)
        }
        print("agent: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: the table

    static func table() {
        let names = AgentTools.all.map(\.name)
        expect(Set(names).count == names.count, "every tool has its own name")
        for want in ["list_sources", "open_source", "create_catalog", "create_session", "list_collections", "list_images",
                     "import_images", "trash_images", "restore_images", "set_rating", "set_color_label", "export_images",
                     "get_develop", "set_develop", "list_stocks"] {
            expect(names.contains(want), "the table has \(want)")
        }
        for name in ["empty_trash", "move_to_system_trash", "delete_images", "remove_source"] {
            expect(!names.contains(name), "no tool deletes: \(name) is not in the table")
        }
        for t in AgentTools.all {
            expect(t.inputSchema["additionalProperties"] == .bool(false), "\(t.name) refuses unknown keys")
            expect(t.required.allSatisfy { t.properties[$0] != nil }, "\(t.name)'s required keys are its properties")
            expect(!t.summary.isEmpty && !t.summary.contains("\n"), "\(t.name) has a one-line summary")
        }
        expect(AgentTools.named("set_develop")?.touchesFrames == true && AgentTools.named("export_images")?.touchesFrames == true,
               "set_develop and export_images wait for an export batch")
        expect(AgentTools.named("list_images")?.touchesFrames == false, "a listing does not wait for an export batch")

        expect(refusal("list_sources", nil) == nil, "no arguments is {}")
        expect(refusal("list_sources", [:]) == nil, "{} is {}")
        expect(refusal("nope", [:])?.contains("No tool named nope") == true, "an unknown tool is refused")
        expect(refusal("list_sources", ["x": 1])?.contains("takes no argument x") == true, "an unknown key is refused")
        expect(refusal("list_sources", [1]) != nil, "arguments that are not an object are refused")
        expect(refusal("set_rating", ["images": ["a"]])?.contains("needs rating") == true, "a missing key is refused")
        expect(refusal("set_rating", ["images": ["a"], "rating": 3]) == nil, "a rating of 3 is taken")
        expect(refusal("set_rating", ["images": ["a"], "rating": .null]) == nil, "a null rating is taken")
        expect(refusal("set_rating", ["images": ["a"], "rating": 6])?.contains("at most 5") == true, "a rating of 6 is refused")
        expect(refusal("set_rating", ["images": ["a"], "rating": 2.5])?.contains("integer") == true, "a rating of 2.5 is refused")
        expect(refusal("set_rating", ["images": ["a"], "rating": "3"]) != nil, "a rating in words is refused")
        expect(refusal("set_rating", ["images": [], "rating": 3])?.contains("at least 1") == true, "no pictures is refused")
        expect(refusal("set_rating", ["images": [3], "rating": 3])?.contains("[0]") == true, "a picture id that is a number is refused")
        expect(refusal("set_color_label", ["images": ["a"], "color": "purple"]) == nil, "purple is a label")
        expect(refusal("set_color_label", ["images": ["a"], "color": .null]) == nil, "a null label is taken")
        expect(refusal("set_color_label", ["images": ["a"], "color": "teal"])?.contains("one of") == true, "teal is not a label")
        expect(refusal("list_images", ["limit": 501])?.contains("at most 500") == true, "a page of 501 is refused")
        expect(refusal("list_images", ["color_labels": ["red", "mauve"]]) != nil, "a list with an unknown label is refused")
        expect(refusal("import_images", ["paths": ["/a"], "mode": "move"]) != nil, "an import mode of move is refused")
        expect(refusal("set_develop", ["image": "a", "film_exposure_ev": 8.5])?.contains("at most 8") == true, "+8.5 EV is refused")
        expect(refusal("set_develop", ["image": "a", "digital_intermediate": "yes"]) != nil, "a DI of yes is refused")
        expect(refusal("create_catalog", ["name": "  ", "folder": "/tmp"])?.contains("empty") == true, "a blank name is refused")
        expect(refusal("trash_images", ["images": .array(Array(repeating: "a", count: 501))]) != nil, "501 pictures are refused")
    }

    // MARK: the socket's path

    static func paths() {
        let tmp = "/var/folders/_r/kh65qxmd0hsfxqth40f627580000gn/T/"
        let release = AgentWire.socketPath(bundleID: "com.spektralab.mac", environment: [:], temporary: tmp)
        let debug = AgentWire.socketPath(bundleID: "com.spektralab.mac.local", environment: [:], temporary: tmp)
        expect(release != debug, "a Debug build and a release never share a socket")
        expect(release == tmp + "spektralab-com.spektralab.mac.sock", "the release's socket is \(release)")
        let homeA = AgentWire.socketPath(bundleID: "com.spektralab.mac.local", environment: ["CFFIXED_USER_HOME": "/tmp/a"], temporary: tmp)
        let homeB = AgentWire.socketPath(bundleID: "com.spektralab.mac.local", environment: ["CFFIXED_USER_HOME": "/tmp/b"], temporary: tmp)
        expect(homeA != homeB && homeA != debug, "each test home has its own socket")
        expect(homeA == AgentWire.socketPath(bundleID: "com.spektralab.mac.local", environment: ["CFFIXED_USER_HOME": "/tmp/a"], temporary: tmp),
               "a home's socket is the same from run to run")
        let long = AgentWire.socketPath(bundleID: String(repeating: "x", count: 90), environment: [:], temporary: tmp)
        expect(long.utf8.count < 104 && AgentWire.address(long) != nil, "a long bundle id still fits sun_path (\(long.utf8.count) bytes)")
        expect(AgentWire.address("/" + String(repeating: "y", count: 120)) == nil, "a path past sun_path is refused, never cut")
    }

    // MARK: the socket, end to end

    static func socket(breaking: Bool) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        // A stale file where the socket goes, as an app that ended without closing it leaves one.
        FileManager.default.createFile(atPath: path, contents: Data())

        let server = AgentServer()
        let started = server.start(path: path) { tool, args in
            if breaking { return ["ok": true, "result": "yes"] }
            switch tool {
            case "list_sources": return ["ok": true, "result": ["echo": args ?? .null]]
            case "trash_images": return ["ok": false, "refused": true, "error": "read one way"]
            default: return ["ok": false, "refused": false, "error": "the export went wrong"]
            }
        }
        expect(started, "the server starts over a stale socket file")
        var info = stat()
        expect(stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && (info.st_mode & 0o777) == 0o600,
               "the socket is a socket, mode 0600")
        expect(!AgentServer().start(path: path) { _, _ in .null }, "a second server leaves an answering socket alone")

        // Off the main thread: the server runs each request on the main actor, which this await leaves free.
        let results = await Task.detached { () -> [String: JSONValue] in
            let c = AgentConnection(path: path)
            c.mayLaunch = false
            var out: [String: JSONValue] = [:]
            out["one"] = try? c.call("list_sources", ["n": 1])
            out["two"] = try? c.call("list_sources", ["n": 2])
            out["refused"] = try? c.call("trash_images", [:])
            out["failed"] = try? c.call("export_images", [:])
            // A line that is not JSON, by hand.
            if let raw = rawExchange(path, "this is not json\n") { out["raw"] = try? JSONValue.parse(raw) }
            out["codes"] = .array([
                .number(Double(AgentCLI.run(["list_sources"], connection: c))),
                .number(Double(AgentCLI.run(["trash_images", #"{"images":["a"]}"#], connection: c))),
                .number(Double(AgentCLI.run(["export_images", #"{"images":["a"],"folder":"/tmp/x"}"#], connection: c))),
                .number(Double(AgentCLI.run(["set_rating", #"{"images":["a"],"rating":9}"#], connection: c))),
                .number(Double(AgentCLI.run(["list_sources", "{not json"], connection: c))),
            ])
            return out
        }.value
        expect(results["one"]?["ok"] == .bool(true) && results["one"]?["result"]?["echo"]?["n"] == .number(1),
               "the first call is run with its own arguments")
        expect(results["two"]?["result"]?["echo"]?["n"] == .number(2), "a second call on one connection is run too")
        expect(results["one"]?["id"] == .number(1) && results["two"]?["id"] == .number(2), "each reply carries its request's id")
        expect(results["refused"]?["ok"] == .bool(false) && results["refused"]?["refused"] == .bool(true), "a refusal comes back refused")
        expect(results["failed"]?["refused"] == .bool(false), "a failure comes back as one")
        expect(results["raw"]?["ok"] == .bool(false) && results["raw"]?["refused"] == .bool(true), "a line that is not JSON is refused")
        expect(results["codes"] == [0, 2, 1, 2, 2], "the CLI's exit codes are 0 done, 2 refused, 1 failed: \(results["codes"]?.text() ?? "none")")
        server.stop()
        expect(!FileManager.default.fileExists(atPath: path), "stop removes the socket file")

        // Nothing at the path, and no launching: a clear failure, not a hang.
        let nothing = await Task.detached { () -> String in
            let c = AgentConnection(path: dir.appendingPathComponent("none.sock").path)
            c.mayLaunch = false
            do { _ = try c.call("list_sources", [:]); return "answered" } catch { return "\(error)" }
        }.value
        if !breaking { expect(nothing.contains("not running"), "no app and no launch says so: \(nothing)") }
    }

    /// One line written to the socket by hand, and the line that comes back.
    static func rawExchange(_ path: String, _ line: String) -> String? {
        guard var addr = AgentWire.address(path) else { return nil }
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(s) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, AgentWire.writeAll(s, Data(line.utf8)) else { return nil }
        return AgentLineReader(fd: s).next()
    }

    // MARK: MCP

    static func mcp() {
        let c = AgentConnection(path: "/nonexistent/agent-selftest.sock")
        c.mayLaunch = false
        let server = MCPServer(connection: c, send: { _ in })
        func reply(_ line: String) -> JSONValue? { server.handle(line).flatMap { try? JSONValue.parse($0) } }

        let initial = reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        expect(initial?["result"]?["protocolVersion"] == "2025-03-26", "initialize echoes the client's protocol version")
        expect(initial?["result"]?["serverInfo"]?["name"] == "spektralab", "the server is spektralab")
        expect(initial?["result"]?["capabilities"]?["tools"] != nil, "the server offers tools")
        expect(reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{}}"#)?["result"]?["protocolVersion"] == "2025-06-18",
               "initialize without a version answers 2025-06-18")
        expect(reply(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)?["result"] == [:], "ping answers {}")
        let list = reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)?["result"]?["tools"]
        if case .array(let tools)? = list {
            expect(tools.count == AgentTools.all.count, "tools/list lists every tool")
            expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" && $0["description"]?.string != nil }, "each with its schema and summary")
        } else { expect(false, "tools/list answers a list") }
        expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "a notification is not answered")
        expect(reply("not json")?["error"]?["code"] == -32700, "a line that is not JSON is a parse error")
        expect(reply(#"{"jsonrpc":"2.0","id":4}"#)?["error"]?["code"] == -32600, "a request with no method is invalid")
        expect(reply(#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)?["error"]?["code"] == -32601, "an unknown method is not found")
        expect(reply(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{}}"#)?["error"]?["code"] == -32602, "a call with no name is refused")
        let bad = reply(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"set_rating","arguments":{"images":["a"],"rating":9}}}"#)
        expect(bad?["result"]?["isError"] == true && bad?["result"]?["content"]?.text().contains("Refused: set_rating: rating must be at most 5") == true,
               "a malformed call is a refused result, made without the app")
        let away = reply(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_sources","arguments":{}}}"#)
        expect(away?["result"]?["isError"] == true && away?["result"]?["content"]?.text().contains("Failed: ") == true,
               "a call with no app to answer is a failed result")
        expect(away?["id"] == 8 && away?["jsonrpc"] == "2.0", "the result carries the request's id")
    }
}
