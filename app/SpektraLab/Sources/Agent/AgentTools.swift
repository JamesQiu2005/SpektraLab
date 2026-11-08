//  AgentTools.swift — the one table of what an agent can ask SpektraLab for (ARCHITECTURE.md §7.16).
//
//  The command line (`SpektraLab cli <tool> '{…}'`) and the MCP server (`SpektraLab mcp`) are two
//  spellings of these calls, and both are only clients: each call goes over the app's socket and runs
//  in the running app, on its main actor, against its own library (`AgentServer`, `AgentExecutor`).
//  A catalog's database is held by the app's own `spklib-host`, so no second process may open one.
//
//  The table is the contract: a name, a one-line summary an agent reads to choose, and a JSON Schema
//  for the arguments. `validate` holds a call to its schema *whole* — an unknown key, a missing one, a
//  wrong type or a value out of range — before anything is opened, so a typo costs a refusal and not
//  half a change. It runs twice: in the client (a malformed call never launches the app) and in the app
//  (the socket is a door of its own). The executor's checks that need the library (does this picture
//  exist, can this film be printed on that paper) come after it and also before anything changes.
//
//  Foundation only: the client modes run before UIKit is touched, and `tools/agent_selftest.swift`
//  compiles this file alone.

import Foundation

/// Why a call did not do what it asked. `refused` is the caller's to fix (access off, an argument out of
/// range, a read-only source) and exits 2; `failed` is ours (the app could not be reached, an export
/// went wrong) and exits 1 — 1.x's split, kept.
enum AgentError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case failed(String)

    var description: String {
        switch self {
        case .refused(let s), .failed(let s): s
        }
    }
    var isRefusal: Bool { if case .refused = self { true } else { false } }
    var exitCode: Int32 { isRefusal ? 2 : 1 }
}

struct AgentTool {
    let name: String
    let summary: String
    /// JSON Schema properties, and which are required.
    let properties: [String: JSONValue]
    let required: [String]
    /// It changes a frame's edit or makes files from frames: refused while an export batch runs (trap 34's
    /// rule, `MacExportRun.isRunning`), as the window's own Develop is.
    var touchesFrames = false

    var inputSchema: JSONValue {
        ["type": "object", "properties": .object(properties),
         "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }
}

enum AgentTools {
    // MARK: the shared argument shapes

    private static let imageID: JSONValue = [
        "type": "string",
        "description": "A picture's id as list_images gives it, \"<source id>/<image id>\"; a bare image id means the selected source.",
    ]
    private static let images: JSONValue = ["type": "array", "items": imageID, "minItems": 1, "maxItems": 500,
                                            "description": "Picture ids from list_images (1 to 500)."]
    private static let sourceID: JSONValue = ["type": "string", "description": "A source id from list_sources; the selected source when left out."]
    static let colourNames = ["none", "red", "orange", "yellow", "green", "blue", "pink", "purple"]

    static let all: [AgentTool] = [
        .init(name: "list_sources",
              summary: "The library's sources (SpektraLab catalogs and sessions, Capture One catalogs and sessions, linked folders): id, name, kind, status, image count, whether read-only, which one is selected.",
              properties: [:], required: []),
        .init(name: "open_source",
              summary: "Select a source in the window, by id, or open one from disk by path: a .spkcatalog, a SpektraLab session folder, a .cocatalog, a Capture One session or any folder (linked where it is; nothing is copied).",
              properties: ["id": ["type": "string", "description": "A source id from list_sources."],
                           "path": ["type": "string", "description": "An absolute path to a catalog, a session or a folder."]],
              required: []),
        .init(name: "create_catalog",
              summary: "Make a new SpektraLab catalog, <folder>/<name>.spkcatalog, and select it. Imports into it are referenced where the files are, unless copied.",
              properties: ["name": ["type": "string", "minLength": 1, "description": "The catalog's name."],
                           "folder": ["type": "string", "description": "An absolute path to the folder it is made in."]],
              required: ["name", "folder"]),
        .init(name: "create_session",
              summary: "Make a new SpektraLab session (a folder with Capture, Selects, Output and Trash) in a folder, and select it. Imports into it are copied into Capture, unless referenced.",
              properties: ["name": ["type": "string", "minLength": 1, "description": "The session's name."],
                           "folder": ["type": "string", "description": "An absolute path to the folder it is made in."]],
              required: ["name", "folder"]),
        .init(name: "list_collections",
              summary: "A source's collections, flattened in the window's order (All Images, Recent Imports, Trash, albums, projects, folders) with their depth. Selects that source in the window.",
              properties: ["source": sourceID], required: []),
        .init(name: "list_images",
              summary: "Pictures of a collection (All Images when none is named), filtered and paged: id, file name, path, kind, rating, colour label, capture time, trashed, offline, and the film, paper and develop state SpektraLab has for it. Selects that source, collection and filter in the window; filters not given are cleared.",
              properties: ["source": sourceID,
                           "collection": ["type": "string", "description": "A collection id from list_collections."],
                           "text": ["type": "string", "description": "File name contains."],
                           "min_rating": ["type": "integer", "minimum": 0, "maximum": 5, "description": "At least this many stars."],
                           "color_labels": ["type": "array", "items": ["type": "string", "enum": .array(colourNames.map(JSONValue.string))],
                                            "description": "Any of these colour labels (\"none\" is no label)."],
                           "offset": ["type": "integer", "minimum": 0, "description": "Rows to skip (default 0)."],
                           "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Rows to return (default 100, at most 500)."]],
              required: []),
        .init(name: "import_images",
              summary: "Import files into a SpektraLab catalog or session (a folder's own files, one level, for a folder path). mode \"reference\" leaves them where they are, \"copy\" copies them in; the source's default when left out (a catalog references, a session copies). Returns how many were added.",
              properties: ["paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 2000,
                                     "description": "Absolute paths of picture files or folders."],
                           "source": sourceID,
                           "mode": ["type": "string", "enum": ["copy", "reference"], "description": "Copy in, or reference where they are."]],
              required: ["paths"]),
        .init(name: "trash_images",
              summary: "Move pictures to their source's Trash collection (SpektraLab catalogs, sessions and folders; Capture One's are read-only). No file is moved or deleted; restore_images puts them back.",
              properties: ["images": images], required: ["images"]),
        .init(name: "restore_images",
              summary: "Take pictures out of their source's Trash collection, back where they were.",
              properties: ["images": images], required: ["images"]),
        .init(name: "set_rating",
              summary: "Set the star rating, 0 to 5. null hands a Capture One picture back to Capture One's own rating.",
              properties: ["images": images,
                           "rating": ["type": ["integer", "null"], "minimum": 0, "maximum": 5, "description": "0 to 5 stars, or null."]],
              required: ["images", "rating"]),
        .init(name: "set_color_label",
              summary: "Set the colour label. \"none\" is no label; null hands a Capture One picture back to Capture One's own label.",
              properties: ["images": images,
                           "color": ["type": ["string", "null"], "enum": .array(colourNames.map(JSONValue.string) + [.null]),
                                     "description": "none, red, orange, yellow, green, blue, pink or purple; or null."]],
              required: ["images", "color"]),
        .init(name: "list_recipes",
              summary: "The export recipes, by name, in the order Export lists them; the first is export_images' default.",
              properties: [:], required: []),
        .init(name: "export_images",
              summary: "Export pictures as developed in SpektraLab, each rendered again from its original with a saved recipe (the first when none is named), into a folder (made when missing; a name already there gets -2). Waits until the batch ends and reports each picture's file or problem.",
              properties: ["images": images,
                           "recipe": ["type": "string", "description": "A recipe name from list_recipes."],
                           "folder": ["type": "string", "description": "An absolute path of the folder the files go into."]],
              required: ["images", "folder"], touchesFrames: true),
        .init(name: "list_stocks",
              summary: "The films and papers by id (kind, positive, monochrome), and the Digital Intermediate. A slide (positive) film is scanned, never printed; a black-and-white film prints only on a black-and-white paper, a colour film only on a colour one.",
              properties: [:], required: []),
        .init(name: "get_develop",
              summary: "A picture's develop settings in SpektraLab: film, paper (none when scanned), Digital Intermediate, Film Exposure, develop state. A picture never opened in SpektraLab says what a new frame would start with.",
              properties: ["image": imageID], required: ["image"]),
        .init(name: "set_develop",
              summary: "Change a picture's film, paper, Digital Intermediate or Film Exposure, as Develop's strips do (a film brings its own paper; a paper that cannot print the film is refused), and develop its preview again. Makes the picture's SpektraLab frame if it has none; the original file is never written.",
              properties: ["image": imageID,
                           "film": ["type": "string", "description": "A film id from list_stocks."],
                           "paper": ["type": "string", "description": "A paper id from list_stocks."],
                           "digital_intermediate": ["type": "boolean", "description": "true: scan the negative as a Digital Intermediate instead of printing it (colour negatives only); false: print it on its paper."],
                           "film_exposure_ev": ["type": "number", "minimum": -8, "maximum": 8, "description": "Film Exposure, stops (-8 to 8)."]],
              required: ["image"], touchesFrames: true),
    ]

    static func named(_ name: String) -> AgentTool? { all.first { $0.name == name } }

    // MARK: validating a call

    /// The call held to its tool's schema, whole: the arguments as an object, or the refusal that names
    /// the first thing wrong. Nothing is looked up; that is the executor's, after this.
    static func validate(_ name: String, _ arguments: JSONValue?) throws -> [String: JSONValue] {
        guard let tool = named(name) else {
            throw AgentError.refused("No tool named \(name). `SpektraLab cli tools` lists them.")
        }
        let args: [String: JSONValue]
        switch arguments {
        case nil, .null?: args = [:]
        case .object(let o)?: args = o
        default: throw AgentError.refused("\(name)'s arguments must be a JSON object.")
        }
        if let extra = args.keys.sorted().first(where: { tool.properties[$0] == nil }) {
            throw AgentError.refused("\(name) takes no argument \(extra).")
        }
        if let missing = tool.required.first(where: { args[$0] == nil }) {
            throw AgentError.refused("\(name) needs \(missing).")
        }
        for key in args.keys.sorted() {
            if let problem = check(args[key]!, against: tool.properties[key]!) {
                throw AgentError.refused("\(name): \(key) \(problem).")
            }
        }
        return args
    }

    /// What is wrong with `value` under `schema` (the subset the table uses: type, a list of types, enum,
    /// minimum/maximum, minLength, items, minItems/maxItems), or nil.
    static func check(_ value: JSONValue, against schema: JSONValue) -> String? {
        let types: [String]
        switch schema["type"] {
        case .string(let t)?: types = [t]
        case .array(let ts)?: types = ts.compactMap(\.string)
        default: types = []
        }
        if !types.isEmpty, !types.contains(where: { matches(value, $0) }) {
            let words = ["string": "a string", "integer": "an integer", "number": "a number", "boolean": "true or false",
                         "array": "a list", "object": "an object", "null": "null"]
            return "must be " + types.map { words[$0] ?? $0 }.joined(separator: " or ")
        }
        if case .array(let allowed)? = schema["enum"], !allowed.contains(value) {
            return "must be one of " + allowed.map { $0 == .null ? "null" : $0.text() }.joined(separator: ", ")
        }
        if let d = value.number {
            if let lo = schema["minimum"]?.number, d < lo { return "must be at least \(format(lo))" }
            if let hi = schema["maximum"]?.number, d > hi { return "must be at most \(format(hi))" }
        }
        if let s = value.string, let least = schema["minLength"]?.number, s.trimmingCharacters(in: .whitespacesAndNewlines).count < Int(least) {
            return "must not be empty"
        }
        if case .array(let items) = value {
            if let least = schema["minItems"]?.number, items.count < Int(least) { return "needs at least \(Int(least)) item\(least == 1 ? "" : "s")" }
            if let most = schema["maxItems"]?.number, items.count > Int(most) { return "takes at most \(Int(most)) items" }
            if let item = schema["items"] {
                for (i, v) in items.enumerated() {
                    if let problem = check(v, against: item) { return "[\(i)] \(problem)" }
                }
            }
        }
        return nil
    }

    private static func matches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object), ("number", .number): true
        // An integer is a number with nothing after the point (JSON has one number type).
        case ("integer", .number(let d)): d.rounded() == d && abs(d) < 1e15
        default: false
        }
    }

    private static func format(_ d: Double) -> String { d.rounded() == d ? String(Int(d)) : String(d) }

    /// The tools as `cli tools` prints them and MCP's `tools/list` sends them.
    static var listing: JSONValue {
        .array(all.map { t in ["name": .string(t.name), "description": .string(t.summary), "inputSchema": t.inputSchema] })
    }
}
