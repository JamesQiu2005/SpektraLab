//  AgentCLI.swift — `spektralab <command>` (RFC-026 §4).
//
//  Each command is an `AgentTools` call with its arguments spelled as flags.
//  Output is one JSON object on stdout; exit 0 is done, 1 is failed (ours),
//  2 is refused (the caller's to fix, including access being off).

import Foundation

enum AgentCLI {
    static let usage = """
    usage: spektralab <command> [file] [options]

      status                                 is access on, and where is the app
      schema                                 every editable field, with ranges
      stocks                                 films and papers by id
      recipes                                export recipes by name
      info     <file>                        describe an image
      get      <file>                        its edit document
      edit     <file> --patch JSON|@file|-   merge-patch the edit  [--preview out.jpg]
      reset    <file>                        film, print, grade, geometry to defaults
      process  <file>                        the Process button    [--preview out.jpg]
      latitude <file>                        what the film and paper hold
      place    <file> --highlight S --shadow S   Scene Placement through the Fit
      preview  <file> -o out.jpg [--long-edge N] the finished print, sRGB JPEG
      export   <file> [--recipe NAME] [--to DIR]  export with a recipe
      mcp                                    serve MCP over stdio

    Edits are saved where SpektraLab reads them. Access is off until it is
    turned on in SpektraLab ▸ Settings ▸ Agents.
    """

    /// Parse and run; returns the exit code.
    @MainActor
    static func run(_ argv: [String]) async -> Int32 {
        guard let command = argv.first, !["help", "-h", "--help"].contains(command) else {
            AgentOutput.write(usage + "\n"); return 0
        }
        if command == "mcp" { return await MCPServer().serve() }
        if command == "status" {
            emit(["ok": true, "access": .bool(AgentAccess.enabled),
                  "version": .string(appVersion), "executable": .string(AgentAccess.executable)])
            return 0
        }
        do {
            let (name, args, previewOut) = try parse(argv)
            // Before the workspace: a refused call should not boot the engine.
            guard AgentAccess.enabled else { throw AgentError.refused(AgentAccess.refusal) }
            let result = try await AgentTools.call(name, args, in: AgentWorkspace())
            var body = result.body.object ?? ["result": result.body]
            if let p = result.preview, name != "preview_image" {
                // Asked for with --preview: keep it where the caller said.
                if let out = previewOut {
                    try? FileManager.default.removeItem(at: out)
                    try FileManager.default.moveItem(at: p, to: out)
                    body["preview"] = .string(out.path)
                } else {
                    try? FileManager.default.removeItem(at: p)
                }
            }
            body["ok"] = true
            emit(.object(body))
            return 0
        } catch let e as AgentError {
            emit(["ok": false, "refused": .bool(e.exitCode == 2), "error": .string(e.description)])
            return e.exitCode
        } catch {
            emit(["ok": false, "refused": false, "error": .string("\(error)")])
            return 1
        }
    }

    /// A command line as a tool call. Pure, so it is testable without an engine.
    static func parse(_ argv: [String]) throws -> (tool: String, args: JSONValue, preview: URL?) {
        guard let command = argv.first, let tool = AgentTools.command(command) else {
            throw AgentError.refused("Unknown command \(argv.first ?? ""). `spektralab help` lists them.")
        }
        var rest = Array(argv.dropFirst())
        var args: [String: JSONValue] = [:]
        var preview: URL?
        if tool.properties["path"] != nil {
            guard let file = rest.first, !file.hasPrefix("-") else {
                throw AgentError.refused("\(command) needs a file.")
            }
            args["path"] = .string(absolute(file))
            rest.removeFirst()
        }
        func value(_ flag: String) throws -> String {
            guard !rest.isEmpty else { throw AgentError.refused("\(flag) needs a value.") }
            return rest.removeFirst()
        }
        func number(_ flag: String) throws -> JSONValue {
            let s = try value(flag)
            guard let d = Double(s) else { throw AgentError.refused("\(flag) must be a number; got \(s).") }
            return .number(d)
        }
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            switch (tool.name, flag) {
            case ("edit_image", "--patch"):
                args["patch"] = try readPatch(try value(flag))
            case ("edit_image", "--preview"), ("process_image", "--preview"),
                 ("reset_edit", "--preview"), ("place_scene", "--preview"):
                preview = URL(fileURLWithPath: absolute(try value(flag)))
            case ("place_scene", "--highlight"): args["highlight"] = try number(flag)
            case ("place_scene", "--shadow"): args["shadow"] = try number(flag)
            case ("preview_image", "-o"), ("preview_image", "--output"):
                args["output"] = .string(absolute(try value(flag)))
            case ("preview_image", "--long-edge"): args["long_edge"] = try number(flag)
            case ("export_image", "--recipe"): args["recipe"] = .string(try value(flag))
            case ("export_image", "--to"): args["folder"] = .string(absolute(try value(flag)))
            default:
                throw AgentError.refused("\(command) takes no option \(flag).")
            }
        }
        if tool.properties["preview"] != nil { args["preview"] = .bool(preview != nil) }
        if tool.name == "preview_image", args["output"] == nil {
            throw AgentError.refused("preview needs -o out.jpg.")
        }
        return (tool.name, .object(args), preview)
    }

    /// `--patch '{…}'`, `--patch @edit.json`, or `--patch -` for stdin.
    private static func readPatch(_ s: String) throws -> JSONValue {
        let text: String
        if s == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else if s.hasPrefix("@") {
            guard let t = try? String(contentsOfFile: absolute(String(s.dropFirst())), encoding: .utf8) else {
                throw AgentError.refused("Cannot read \(s.dropFirst()).")
            }
            text = t
        } else {
            text = s
        }
        do { return try JSONValue.parse(text) } catch {
            throw AgentError.refused("--patch is not JSON: \(error.localizedDescription)")
        }
    }

    private static func absolute(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private static func emit(_ v: JSONValue) {
        AgentOutput.write(v.text(pretty: true) + "\n")
    }
}

/// The process's real stdout. In agent mode, file descriptor 1 is pointed at
/// stderr as the first thing that happens, so a stray `print` anywhere in the
/// app cannot corrupt the JSON (or the MCP stream) a caller is parsing; the
/// protocol writes to the descriptor saved here.
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
