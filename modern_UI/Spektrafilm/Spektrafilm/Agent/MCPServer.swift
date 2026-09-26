//  MCPServer.swift — `spektralab mcp`: the Model Context Protocol over stdio
//  (RFC-026 §5).
//
//  Newline-delimited JSON-RPC 2.0 on stdin/stdout. One workspace for the
//  server's life, so a frame an agent opened stays developed between calls
//  and an edit is a reprint rather than a fresh develop. Requests are handled
//  one at a time, in order: there is one frame on one engine, as there is in
//  the window.
//
//  A tool that fails is a *result* with `isError`, not a JSON-RPC error —
//  the protocol's rule, and the one that lets the model read the refusal and
//  correct itself. JSON-RPC errors are kept for a malformed request.

import Foundation

@MainActor
final class MCPServer {
    static let protocolVersion = "2025-06-18"

    private let workspace: AgentWorkspace
    private let send: (String) -> Void

    init(workspace: AgentWorkspace? = nil, send: @escaping (String) -> Void = { AgentOutput.write($0 + "\n") }) {
        self.workspace = workspace ?? AgentWorkspace()
        self.send = send
    }

    /// Serve until stdin closes. Returns the exit code.
    func serve() async -> Int32 {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                if let reply = await handle(line) { send(reply) }
            }
        } catch {
            FileHandle.standardError.write(Data("spektralab mcp: \(error)\n".utf8))
            return 1
        }
        workspace.session.flushSave()
        return 0
    }

    /// One line in, at most one line out (a notification gets none).
    func handle(_ line: String) async -> String? {
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
                "capabilities": ["tools": [:], "prompts": [:]],
                "serverInfo": ["name": "spektralab", "title": "SpektraLab", "version": .string(AgentCLI.appVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": .array(AgentTools.all.map { t in
                ["name": .string(t.name), "description": .string(t.summary), "inputSchema": t.inputSchema]
            })])
        case "tools/call":
            guard let name = params["name"]?.string else { return error(id, -32602, "tools/call needs a name") }
            return result(id, await call(name, params["arguments"] ?? [:]))
        case "prompts/list":
            return result(id, ["prompts": [Self.editPrompt]])
        case "prompts/get":
            guard params["name"]?.string == "edit_photo" else { return error(id, -32602, "No such prompt") }
            let a = params["arguments"] ?? [:]
            return result(id, Self.editPromptMessages(path: a["path"]?.string ?? "<path>",
                                                     instruction: a["instruction"]?.string ?? ""))
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    private func call(_ name: String, _ args: JSONValue) async -> JSONValue {
        do {
            let r = try await AgentTools.call(name, args, in: workspace)
            var content: [JSONValue] = [["type": "text", "text": .string(r.body.text(pretty: true))]]
            if let p = r.preview, let data = try? Data(contentsOf: p) {
                content.append(["type": "image", "mimeType": "image/jpeg", "data": .string(data.base64EncodedString())])
                // A preview the caller did not ask to keep is ours to remove.
                if args["output"] == nil { try? FileManager.default.removeItem(at: p) }
            }
            return ["content": .array(content), "isError": false]
        } catch {
            let refused = (error as? AgentError)?.exitCode == 2
            return ["content": [["type": "text", "text": .string((refused ? "Refused: " : "Failed: ") + "\(error)")]],
                    "isError": true]
        }
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
    SpektraLab simulates analogue film: a photograph is exposed onto a film stock, developed, and printed \
    onto a paper through an enlarger, then graded like a scan of the print. Every edit here is the same \
    edit the app's window makes, saved where the app reads it; nothing is ever written over the original.

    To edit a photograph from one sentence: describe_image, then get_schema, then process_image once \
    (this meters and neutralises the print). Choose a film and paper (list_stocks) for the look asked for, \
    then refine with small edit_image patches, looking at each returned preview before the next. Prefer \
    the physical controls — film, paper, Film Exposure, enlarger exposure and Y/M filters, Scene Placement \
    (measure_latitude, place_scene), Tone Mask — over the grade (adjustments), which is the scan's. \
    Export only when asked.
    """

    static let editPrompt: JSONValue = [
        "name": "edit_photo",
        "title": "Edit a photo from one sentence",
        "description": "Edit a photograph in SpektraLab to match a description, the way a printer would.",
        "arguments": [
            ["name": "path", "description": "The image file.", "required": true],
            ["name": "instruction", "description": "What the print should look like.", "required": true],
        ],
    ]

    static func editPromptMessages(path: String, instruction: String) -> JSONValue {
        let text = """
        Edit the photograph at \(path) in SpektraLab so that: \(instruction)

        Work like a printer, not a filter: pick the film and paper that carry the look, get the exposure \
        and the scene's placement right, and only then grade. Start with describe_image, get_schema and \
        process_image. Change a few fields per edit_image call and look at the preview each time. Stop \
        when the preview matches the instruction, and say which film, paper and settings you chose and why.
        """
        return ["description": "Edit a photo from one sentence",
                "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
    }
}
