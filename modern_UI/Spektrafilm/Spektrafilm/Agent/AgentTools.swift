//  AgentTools.swift — the one table of what an agent can ask for (RFC-026 §4, §5).
//
//  The CLI and the MCP server are two spellings of these calls: a command
//  line is parsed into a tool name and a JSON argument object, and an MCP
//  `tools/call` already is one. Both then come through `call`, so a thing the
//  command line can do and the MCP server cannot (or the reverse) is not a
//  state this code can reach.

import Foundation

struct AgentTool {
    let name: String
    /// The CLI's spelling.
    let command: String
    let summary: String
    /// JSON Schema properties, and which are required.
    let properties: [String: JSONValue]
    let required: [String]

    var inputSchema: JSONValue {
        ["type": "object", "properties": .object(properties),
         "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
}

/// What a call produced: a JSON body, and the path of a preview to show
/// with it when one was asked for.
struct AgentResult {
    var body: JSONValue
    var preview: URL?
}

enum AgentTools {
    private static let path: JSONValue = ["type": "string", "description": "Absolute path of the image file (RAW, TIFF, JPEG, …)."]
    private static let wantPreview: JSONValue = ["type": "boolean", "description": "Return a 1024 px preview of the result (default true)."]

    static let all: [AgentTool] = [
        .init(name: "get_schema", command: "schema",
              summary: "Every editable field: its path in the edit document, type, range and meaning. Read this before editing.",
              properties: [:], required: []),
        .init(name: "list_stocks", command: "stocks",
              summary: "The films and papers by id. A film's declaredPaper is the one it is printed on by default; a slide film (type positive) is scanned, not printed.",
              properties: [:], required: []),
        .init(name: "list_recipes", command: "recipes",
              summary: "The person's export recipes, by name.",
              properties: [:], required: []),
        .init(name: "describe_image", command: "info",
              summary: "Open an image and describe it: size, RAW or not, camera white balance, EXIF, the film and paper it is set to, and whether it has been processed.",
              properties: ["path": path], required: ["path"]),
        .init(name: "get_edit", command: "get",
              summary: "The image's current edit document {params, adjustments, geometry, decode}, as stored in its sidecar and shown in the app.",
              properties: ["path": path], required: ["path"]),
        .init(name: "edit_image", command: "edit",
              summary: "Change the edit with a JSON merge patch over the edit document, e.g. {\"params\": {\"filmStock\": \"kodak_portra_160\"}, \"adjustments\": {\"exposure\": 0.3}}. Only the keys given change. Unknown keys, read-only fields and out-of-range values are refused and nothing is written. The edit is saved where the app reads it.",
              properties: ["path": path, "patch": ["type": "object", "description": "A JSON merge patch; see get_schema."],
                           "preview": wantPreview],
              required: ["path", "patch"]),
        .init(name: "reset_edit", command: "reset",
              summary: "Put the film, print, grade and geometry back to their defaults. The decode (white balance, lens correction) stays.",
              properties: ["path": path, "preview": wantPreview], required: ["path"]),
        .init(name: "process_image", command: "process",
              summary: "The Process button: develop, meter and solve the enlarger's filter pack for the chosen film and paper. Do this once before judging colour; it resets the Y/M filter shifts.",
              properties: ["path": path, "preview": wantPreview], required: ["path"]),
        .init(name: "measure_latitude", command: "latitude",
              summary: "How much of the scene the film and paper hold, in stops from mid-grey: the medium's boundaries, the fraction of the frame beyond each, and the pull-backs the engine suggests.",
              properties: ["path": path], required: ["path"]),
        .init(name: "place_scene", command: "place",
              summary: "Scene Placement: pull the scene's highlights and/or shadows (stops, 0 = off) into the medium, through the engine's Fit. A placement the Fit refuses is not applied. Both 0 removes the placement.",
              properties: ["path": path,
                           "highlight": ["type": "number", "minimum": 0, "maximum": 6, "description": "Stops the scene's top is pulled back."],
                           "shadow": ["type": "number", "minimum": 0, "maximum": 6, "description": "Stops the scene's bottom is pulled up."],
                           "preview": wantPreview],
              required: ["path", "highlight", "shadow"]),
        .init(name: "preview_image", command: "preview",
              summary: "Render the finished print as a small sRGB JPEG and return it, so you can see what the edit looks like.",
              properties: ["path": path,
                           "long_edge": ["type": "integer", "minimum": 64, "maximum": 4096, "description": "Pixels on the long edge (default 1024)."],
                           "output": ["type": "string", "description": "Also keep the JPEG at this path."]],
              required: ["path"]),
        .init(name: "export_image", command: "export",
              summary: "Export the finished print with one of the person's recipes (the first when none is named), optionally into another folder. Returns the files written.",
              properties: ["path": path,
                           "recipe": ["type": "string", "description": "A recipe name from list_recipes."],
                           "folder": ["type": "string", "description": "Write here instead of the recipe's folder."]],
              required: ["path"]),
    ]

    static func named(_ name: String) -> AgentTool? { all.first { $0.name == name } }
    static func command(_ command: String) -> AgentTool? { all.first { $0.command == command } }

    // MARK: dispatch

    @MainActor
    static func call(_ name: String, _ args: JSONValue, in ws: AgentWorkspace) async throws -> AgentResult {
        guard AgentAccess.enabled else { throw AgentError.refused(AgentAccess.refusal) }
        guard let tool = named(name) else { throw AgentError.refused("No tool named \(name).") }
        // A batch export owns the open frame until it finishes; anything that
        // opens, edits or exports would change what the run is writing.
        if ws.session.batchExporting, !["get_schema", "list_stocks", "list_recipes"].contains(name) {
            throw AgentError.refused("A batch export is running in the app. Try again when it finishes.")
        }
        let a = args.object ?? [:]
        if let extra = a.keys.first(where: { tool.properties[$0] == nil }) {
            throw AgentError.refused("\(name) takes no argument \(extra).")
        }
        if let missing = tool.required.first(where: { a[$0] == nil }) {
            throw AgentError.refused("\(name) needs \(missing).")
        }
        func string(_ k: String) throws -> String? {
            guard let v = a[k] else { return nil }
            guard let s = v.string else { throw AgentError.refused("\(k) must be a string.") }
            return s
        }
        func number(_ k: String) throws -> Double? {
            guard let v = a[k] else { return nil }
            guard let d = v.number else { throw AgentError.refused("\(k) must be a number.") }
            return d
        }
        let previewWanted = a["preview"]?.bool ?? true
        // A malformed edit is refused before anything is opened, so a caller
        // correcting a typo does not wait on a decode to hear about it.
        if name == "edit_image" {
            guard let patch = a["patch"], patch.object != nil else { throw AgentError.refused("patch must be a JSON object.") }
            _ = try AgentDocument.validate(patch)
        }
        if let file = try string("path") { try await ws.open(file) }

        func withPreview(_ body: JSONValue) async throws -> AgentResult {
            AgentResult(body: body, preview: previewWanted ? try await ws.preview() : nil)
        }

        switch name {
        case "get_schema":
            return AgentResult(body: AgentSchema.json)
        case "list_stocks":
            return AgentResult(body: AgentWorkspace.stocksJSON())
        case "list_recipes":
            return AgentResult(body: ["recipes": AgentWorkspace.recipesJSON()])
        case "describe_image":
            return AgentResult(body: try ws.describe())
        case "get_edit":
            return AgentResult(body: try ws.document)
        case "edit_image":
            guard let patch = a["patch"], patch.object != nil else { throw AgentError.refused("patch must be a JSON object.") }
            let written = try await ws.edit(patch)
            // What each written field holds now, which is not always what was
            // asked: a film brings its paper, a crop is fitted to the angle.
            // The whole document is one `get_edit` away.
            let doc = try ws.document
            var now: [String: JSONValue] = [:]
            for path in written + ["params.printStock", "params.scanFilm", "params.filmFormatMM"] {
                now[path] = path.split(separator: ".").reduce(Optional(doc)) { $0?[String($1)] }
            }
            if written.contains(where: { $0.hasPrefix("geometry.") }) { now["geometry.crop"] = doc["geometry"]?["crop"] }
            return try await withPreview(["written": .array(written.map(JSONValue.string)), "now": .object(now)])
        case "reset_edit":
            try await ws.reset()
            return try await withPreview(["edit": try ws.document])
        case "process_image":
            try await ws.process()
            return try await withPreview(["info": try ws.describe()])
        case "measure_latitude":
            return AgentResult(body: try await ws.latitude())
        case "place_scene":
            let body = try await ws.place(highlight: try number("highlight") ?? 0, shadow: try number("shadow") ?? 0)
            return try await withPreview(body)
        case "preview_image":
            let edge = try number("long_edge").map { Int($0) } ?? 1024
            let keep = try string("output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let file = try await ws.preview(to: keep, longEdge: edge)
            return AgentResult(body: ["preview": .string(file.path)], preview: file)
        case "export_image":
            let files = try await ws.export(recipe: try string("recipe"), to: try string("folder"))
            return AgentResult(body: ["files": .array(files.map { .string($0.path) })])
        default:
            throw AgentError.refused("No tool named \(name).")
        }
    }
}
