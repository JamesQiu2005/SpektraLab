//  AgentClient.swift — `SpektraLab cli …` and `SpektraLab mcp`: the two client modes of the app's own
//  executable (ARCHITECTURE.md §7.16).
//
//  Chosen before the interface starts (`SpektraLabMain`), and never touching UIKit: each is a short
//  conversation with the running app over its socket (`AgentConnection`), which opens the app hidden when
//  nothing answers. The work is the app's (`AgentExecutor`); these only spell it.
//
//  - **cli**: `SpektraLab cli <tool> ['{json arguments}']` — one call, the reply as one JSON object on
//    stdout, exit 0 done, 1 failed, 2 refused (access off included). `cli tools` lists the table with its
//    schemas, `cli help` says how; neither reaches the app.
//  - **mcp**: the Model Context Protocol, newline-delimited JSON-RPC 2.0 on stdio (1.x's `MCPServer`, its
//    framing and error shapes kept). `initialize`, `ping` and `tools/list` are answered here from the
//    static table — a client that only looks does not open the app — and `tools/call` goes to the app.
//    A tool that fails is a *result* with `isError` ("Refused: …", "Failed: …"), the protocol's rule and
//    the one that lets the model read the refusal and correct itself; JSON-RPC errors are kept for a
//    malformed request.

import Darwin
import Foundation

enum AgentClient {
    /// `arguments` are the process's, `cli` or `mcp` first. Returns the exit code.
    static func run(_ arguments: [String]) -> Int32 {
        // Before anything can print: stdout is the protocol's (`AgentOutput`).
        AgentOutput.takeStdout()
        switch arguments.first {
        case "mcp": return MCPServer().serve()
        default: return AgentCLI.run(Array(arguments.dropFirst()))
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The executable an MCP configuration names: this one, resolved.
    static var executable: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }
}

// MARK: - the command line

enum AgentCLI {
    static var usage: String {
        """
        usage: SpektraLab cli <tool> ['{json arguments}']
               SpektraLab cli tools        every tool, its summary and its JSON input schema
               SpektraLab cli help
               SpektraLab mcp              serve the Model Context Protocol on stdio

        Each call runs in the SpektraLab app on this Mac, against its library; the app is opened, hidden,
        when it is not running. Access is off until it is turned on in Settings › General › Agents.
        The reply is one JSON object; exit 0 is done, 1 failed, 2 refused.

        tools: \(AgentTools.all.map(\.name).joined(separator: ", "))

        example: SpektraLab cli list_images '{"limit": 10, "min_rating": 3}'
        """
    }

    static func run(_ argv: [String], connection: AgentConnection = AgentConnection()) -> Int32 {
        guard let command = argv.first, !["help", "-h", "--help"].contains(command) else {
            AgentOutput.write(usage + "\n")
            return 0
        }
        if command == "tools" {
            AgentOutput.write(AgentTools.listing.text(pretty: true) + "\n")
            return 0
        }
        do {
            guard argv.count <= 2 else { throw AgentError.refused("\(command) takes one JSON object of arguments, quoted as one word.") }
            var args: JSONValue = [:]
            if argv.count == 2 {
                let text = argv[1] == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : argv[1]
                do { args = try JSONValue.parse(text) } catch {
                    throw AgentError.refused("The arguments are not JSON: \(text)")
                }
            }
            // Here first: a malformed call is refused without opening the app.
            _ = try AgentTools.validate(command, args)
            let reply = try connection.call(command, args)
            var body = reply.object ?? [:]
            body["id"] = nil
            emit(.object(body))
            if reply["ok"]?.bool == true { return 0 }
            return reply["refused"]?.bool == true ? 2 : 1
        } catch let e as AgentError {
            emit(["ok": false, "refused": .bool(e.isRefusal), "error": .string(e.description)])
            return e.exitCode
        } catch {
            emit(["ok": false, "refused": false, "error": .string("\(error)")])
            return 1
        }
    }

    private static func emit(_ v: JSONValue) { AgentOutput.write(v.text(pretty: true) + "\n") }
}

// MARK: - MCP

final class MCPServer {
    static let protocolVersion = "2025-06-18"

    private let connection: AgentConnection
    private let send: (String) -> Void

    init(connection: AgentConnection = AgentConnection(), send: @escaping (String) -> Void = { AgentOutput.write($0 + "\n") }) {
        self.connection = connection
        self.send = send
    }

    /// Serve until stdin closes. Returns the exit code. Requests are answered one at a time, in order: the
    /// app runs them one at a time anyway.
    func serve() -> Int32 {
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line) { send(reply) }
        }
        return 0
    }

    /// One line in, at most one line out (a notification gets none).
    func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(trimmed), message.object != nil else {
            return error(nil, -32700, "Parse error")
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            // A response to something we never send, or garbage.
            return id == nil ? nil : error(id, -32600, "Invalid Request")
        }
        let params = message["params"] ?? [:]
        guard let id else { return nil }   // notifications: initialized, cancelled, …

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string
            return result(id, [
                "protocolVersion": .string(asked ?? Self.protocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "spektralab", "title": "SpektraLab", "version": .string(AgentClient.appVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": AgentTools.listing])
        case "tools/call":
            guard let name = params["name"]?.string else { return error(id, -32602, "tools/call needs a name") }
            return result(id, call(name, params["arguments"] ?? [:]))
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    private func call(_ name: String, _ args: JSONValue) -> JSONValue {
        do {
            _ = try AgentTools.validate(name, args)
            let reply = try connection.call(name, args)
            if reply["ok"]?.bool == true {
                return ["content": [["type": "text", "text": .string((reply["result"] ?? .null).text(pretty: true))]], "isError": false]
            }
            let refused = reply["refused"]?.bool == true
            return failure(refused, reply["error"]?.string ?? "No reason was given.")
        } catch let e as AgentError {
            return failure(e.isRefusal, e.description)
        } catch {
            return failure(false, "\(error)")
        }
    }

    private func failure(_ refused: Bool, _ why: String) -> JSONValue {
        ["content": [["type": "text", "text": .string((refused ? "Refused: " : "Failed: ") + why)]], "isError": true]
    }

    private func result(_ id: JSONValue, _ r: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": r]).text()
    }

    private func error(_ id: JSONValue?, _ code: Int, _ message: String) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id ?? .null,
                          "error": ["code": .number(Double(code)), "message": .string(message)]]).text()
    }

    // MARK: guidance for the model

    static let instructions = """
    SpektraLab is a photo library and an analogue darkroom: a photograph is exposed onto a film stock, \
    developed, and printed onto a paper. These tools work through the SpektraLab app on this Mac, on the \
    person's own library, and what they change is seen in the app's window as it happens.

    The library is sources (SpektraLab catalogs and sessions, Capture One catalogs and sessions read \
    one way, linked folders), each with collections. Start with list_sources, then list_collections and \
    list_images; a picture's id is "<source id>/<image id>". Listing selects what it lists in the window. \
    Rate, label, import, trash and restore with the tools of those names; a Capture One source takes \
    ratings and labels only. Nothing here deletes a file: trash_images moves pictures to their source's \
    Trash, and restore_images brings them back.

    To change a picture's look, list_stocks, then set_develop with a film and a paper (or the Digital \
    Intermediate), and Film Exposure; get_develop reads them back. Export only when asked, with \
    list_recipes and export_images into the folder the person names.

    Every tool is refused until the person turns on Settings › General › Agents in SpektraLab; say so if \
    a call is refused for that reason.
    """
}

// MARK: - stdout

/// The process's real stdout. In a client mode, file descriptor 1 is pointed at stderr as the first thing
/// that happens, so a stray `print` anywhere (a framework's own) cannot corrupt the JSON or the MCP stream
/// a caller is parsing; the protocol writes to the descriptor saved here. (1.x's, as it was.)
enum AgentOutput {
    nonisolated(unsafe) static var handle = FileHandle.standardOutput

    static func takeStdout() {
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { return }
        dup2(STDERR_FILENO, STDOUT_FILENO)
        handle = FileHandle(fileDescriptor: saved, closeOnDealloc: false)
    }

    static func write(_ s: String) {
        handle.write(Data(s.utf8))
    }
}
