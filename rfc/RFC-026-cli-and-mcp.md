# RFC-026 — The command line and the MCP server: agents edit, they do not generate

| | |
|---|---|
| **Status** | **Implemented 2026-09-26 for 1.1.1.** The CLI, the MCP server over stdio, and Settings ▸ Agents are in. §9 lists what is deliberately left for a phase 2. |
| **Decision** | SpektraLab's binary has three front doors: the window, `spektralab <command>` and `spektralab mcp`. All three drive **the same `Session`**, so anything a person can do to a photograph, an agent can do too, by the same code. |
| **Scope** | Opening frames, reading and changing every edit a person can make, Process (auto-exposure and filter pack), Latitude and Scene Placement, previewing the finished print, and exporting through the user's recipes. |
| **Not in scope** | Generating or inpainting pixels; talking to a network; driving the open window live (§9). |
| **Related** | RFC-016 (the log an agent's session writes too), RFC-018 (the recipes), RFC-023 / 024 / 025 (the controls it exposes), the v4 frontend. |

## 0. Why

The ambition is a **one-sentence photo edit that is an edit, not a generation**:
*"Make this feel like a Portra print from an overcast day, and keep the sky."*
The agent does not paint the answer. It chooses a film, a paper, an exposure
and a grade, as a darkroom printer would. Every pixel still comes out of the
film-and-paper model, so the result is a photograph someone could have
printed, and every step is a setting a person can open, read and change.

That needs two things this app already has, and one it did not:

- **The engine is already headless.** The test suite drives a real `Session`
  with no window: open, develop, Process, export.
- **Every edit is already data**, in the sidecar: `params` (film, paper,
  effects, enlarger, Scene Placement, Tone Mask), `adjustments` (the
  Post-Dev grade), `geometry` (crop, straighten, turns), `decode` (camera
  white balance, lens correction).
- **Missing: a door.** A person will seldom want the CLI when the window is
  right there. It exists anyway, for scripting and batches. Its real job is
  to be the **foundation of the MCP server**, which any agent — Claude
  Desktop, Claude Code, others — can connect to.

## 1. The one rule: parity by construction

> Whatever a person can do in the window, an agent can do through the CLI and
> MCP — and it goes through the same code.

This is enforced by **not writing a second implementation**:

- The CLI and the MCP server run a headless `Session` in the app's own
  binary. Open is `Session.open`. Process is `Session.solveNow`. An edit
  assigns `session.params` or `session.adjustments`. Export is
  `Exporter.export(session:…)`. The canvas, the export page and an agent's
  render are one code path, so the export-matches-canvas bar holds for
  agents without a separate proof.
- Edits land in **the same sidecar** the window reads. Something an agent
  did is there when the frame is next opened in the app, and the reverse.
- **A test enforces the rule** (`AgentSchemaTests`). Every stored field of
  `FilmParams`, `EffectStrengths`, `ContrastMaskSettings`,
  `SceneLatitudeSettings` and `Adjustments` has to be described in the agent
  schema, so adding a control to the window without exposing it fails CI.

## 2. Shape

```text
SpektraLab.app/Contents/MacOS/SpektraLab
  ├─ launched normally            → the window (unchanged)
  ├─ `cli …` (what `spektralab` runs) → AgentCLI.run  → headless Session
  └─ `mcp`                            → MCPServer    → the same, over JSON-RPC on stdio
```

A small `@main` entry point (`SpektraLabEntry`, in `SpektrafilmApp.swift`)
decides before anything is built. In CLI or MCP mode no `NSApplication`,
window or menu ever exists, and there is no Dock icon. The CLI checks the
access switch before it creates a `Session`, so a refused call never boots the
engine. File descriptor 1 is pointed at stderr as the first thing that
happens; the protocol writes to a saved copy of the real stdout, so a stray
`print` anywhere in the app cannot corrupt the JSON a caller is parsing.

The CLI and the MCP server share one table, `AgentTools`: a command line is
parsed into a tool name and a JSON argument object, and both go through
`AgentTools.call`. A thing one front door can do and the other cannot is not
a state the code can reach.

**One render at a time.** An agent's `Session` is a second engine beside the
window's. The concurrent multi-GB jobs behind the panic on 2026-09-12 are the
reason each process does one frame at a time; batches run in sequence.

## 3. The edit document

An edit is a JSON **merge patch** over the frame's sidecar sections, using the
sidecar's own names:

```json
{ "params":      { "filmStock": "kodak_portra_400", "printStock": "kodak_supra_endura",
                   "contrastMask": { "active": true, "highlights": 1.0 } },
  "adjustments": { "exposure": 0.3, "saturation": -10 },
  "geometry":    { "angle": -1.2 } }
```

Objects merge; values replace. The whole patch is validated before anything
is applied, so a typo cannot half-apply: an unknown key, a `null`, a
read-only field or a value outside its range is refused by path, with the
reason, and nothing is written. **`spektralab schema`** lists every field,
with its path, its type, its range or choices, one sentence of what it does,
and, for a read-only field, why.

**The ranges are the interface's, not the wire's.** A person cannot drag Exp.
Comp. to +8 or the couplers past 1.5 (trap 22), so neither can an agent. A
value outside the range is refused, not clamped: an agent that asked for
+6 EV should hear that it did not get it.

**Each change goes through the setter the panel calls**, so the interface's
rules hold:

- A film brings its declared paper (`Session.selectFilmStock`, moved out of
  the film list so both callers share it).
- A slide film is scanned, and a paper for it is refused.
- The Film Type fields derive `filmFormatMM`, which is read-only.
- A straightened or moved crop is fitted inside the frame.
- A decode Kelvin or tint makes the white balance Custom.

The read-only fields are:

- `filmFormatMM`, which is derived.
- The whole of `sceneLatitude`: the Fit writes it, through `place`.
- `contrastMask.scheme`: `gaussian` is the only product scheme.
- `geometry.intendedSize`: crop edits keep it, as a drag does.

Scene Placement is the one edit that is not a plain value. Pull-backs go
through the Fit, exactly as in the window, and a refused value returns the
engine's reason instead of being written (`place`).

## 4. The command line

```text
spektralab status                         is agent access on, where is the app
spektralab schema                         every editable field (JSON)
spektralab stocks                         films and papers: id, name, positive/negative, cine, declared paper
spektralab recipes                        the user's export recipes
spektralab info     <image>               size, RAW or not, camera white balance, EXIF, film, paper, state
spektralab get      <image>               the edit document
spektralab edit     <image> --patch <json|@file|-> [--preview <out.jpg>]
spektralab reset    <image>               film, print, grade and geometry to defaults (the decode stays)
spektralab process  <image> [--preview <out.jpg>]   Process: meter + the filter pack for the paper
spektralab latitude <image>               the Latitude measurement (JSON)
spektralab place    <image> --highlight <stops> --shadow <stops> [--preview <out.jpg>]
spektralab preview  <image> -o <out.jpg> [--long-edge 1024]
spektralab export   <image> [--recipe <name>] [--to <dir>]
spektralab mcp                            the MCP server on stdio
```

Every command prints **one JSON object on stdout**. Exit codes:
0 done, 1 failed, 2 refused (agent access off, a Fit refusal, an unknown
field), with the reason in the JSON.

## 5. The MCP server

JSON-RPC 2.0 over stdio, per the Model Context Protocol: `initialize`,
`tools/list`, `tools/call` and `prompts/list` / `prompts/get`.

**The tools are the CLI's commands.** `get_schema`, `list_stocks`,
`list_recipes`, `describe_image`, `get_edit`, `edit_image`, `reset_edit`,
`process_image`, `measure_latitude`, `place_scene`, `preview_image`,
`export_image`.

**The agent has to see.** `preview_image`, and by default every tool that
changes the picture (`edit_image`, `reset_edit`, `process_image`,
`place_scene`), returns the finished print as an MCP **image content block**:
a 1024 px JPEG in sRGB, so any client shows it right. It is rendered through
`Exporter`, so what the agent sees is what an export would write, downscaled.
A one-sentence edit is a loop: look, change, look again. Without eyes, the
agent could only guess.

**Small replies.** `edit_image` returns the paths it wrote and what each now
holds. That is not always what was asked for: a film brings its paper, and a
crop is fitted to the angle. The whole document is one `get_edit` away,
rather than repeated into the model's context on every step.

**A refusal is a tool result** with `isError`, in words the model can act on:
`The Fit refused this placement: … (highlight minimum 1.37 stops)`. JSON-RPC
errors are kept for a malformed request.

**The prompt.** `prompts/get edit_photo` (arguments `path` and
`instruction`) gives a client the workflow in the app's own terms:

1. Describe the image, read the schema, then Process.
2. Choose the film and paper that carry the look.
3. Get the exposure and the scene's placement right.
4. Only then grade.
5. Change a few fields per call and look at every preview.
6. Stop when the preview matches the instruction, and say what was chosen.

The server's `instructions` say the same in two paragraphs. Tool descriptions
carry each stage's physical meaning, so a model does not treat a paper change
like a curve.

## 6. Settings ▸ Agents

A page of its own in Settings, which is now paged like Capture One's
(General, Rendering, Memory, Diagnostics, Agents):

- **Allow command line and agent access**: off by default. Off, every
  command except `status` refuses with exit 2 and names this setting; the MCP
  server answers `initialize` and then fails each tool call with the same
  words. It is read at each call, so turning it off takes effect for a
  running server too.
- **Install `spektralab`**: a two-line script at `~/.local/bin/spektralab`
  that runs `<binary> cli "$@"`, with Reinstall and Remove. It needs no
  administrator rights. It is **not a symlink**: run through a symlink, the
  executable's path is the link's, so `Bundle.main` would not find the app
  around it, and with it neither the engine's resources nor the defaults
  domain the switch lives in. Install replaces only a script it wrote; any
  other file at that path is left alone and the page says so.
- **Connect an agent**: the exact lines for Claude Code
  (`claude mcp add spektralab -- <binary> mcp`) and Claude Desktop (the JSON
  entry), each with a copy button and pointing at this app's own binary.
- **Tools**: each tool's name and the first sentence of its description.

The paging itself: a toolbar of icon tabs, with the chosen page on a plate
and its icon in the accent. Each page is made of plain groups, a small grey
title and a hairline, and nothing collapses. The chosen page is remembered
(`ui2.settingsPage`), and `--snapshot … --settings <page>` captures one.

## 7. Safety

- **Local only.** The server speaks stdio to the client that launched it and
  opens no port and no network connection.
- **Paths are the caller's.** It reads the images it is given and writes
  sidecars to the app's own store and exports where the recipe says (or to
  `--to`). It never deletes; a recipe's existing-file policy applies.
- **The switch is the consent.** Off by default, and legible in one place.

## 8. Tests

All in `SpektrafilmTests/AgentTests.swift`:

- **`AgentSchemaTests`**: every stored field of the four sections has a
  schema row and every row has a field, walked by reflection (§1). It was
  checked that the test fails: with a row deleted, it names the field. Also:
  every schema path is in the encoded document, so a CodingKey rename cannot
  pass; a patch is validated whole, with thirteen refusal shapes; a merge
  changes only what it names; and the ranges are the controls' constants.
- **`AgentCLITests`**:
  - A command line parses into the tool call.
  - Every tool has exactly one command.
  - Mistakes are refusals, exit 2.
  - With the switch off, every tool is refused and opens nothing.
  - The installed script passes its arguments through to the `cli` door.
- **`MCPTests`**: the handshake and the tool list over the in-memory
  `handle`. A notification gets no reply; the protocol errors are −32601 and
  −32700; a refused tool is a result, not an error; the prompt carries the
  sentence.
- **`AgentSessionTests`**, on a copy of the A7 III fixture:
  - A film brings its declared paper.
  - A preset frame shows its own side length.
  - A straightened crop fits.
  - A slide film refuses a paper, and the refused edit changes nothing.
  - The edit is saved where the window reads it.

By hand, on the same frame, from the built binary (Debug build):

| Command | Time |
|---|---|
| `info` | 1.1 s |
| `process` with a preview | 3.1 s |
| `edit` of film, exposure, straighten and saturation, with a preview | 3.0 s |
| `latitude` | 2.0 s |
| `export` of the full-resolution JPEG | 2.7 s |

Five malformed edits were refused with exit 2 before anything was opened. An
MCP session over a pipe ran the handshake, the tool list, a refused
placement, an edit with its image block, the prompt and an unknown method.

## 9. Phase 2, deliberately not here

- **Live control of the open window.** Today an agent's `Session` is its own
  process. An edit reaches the window when the frame is next opened, and the
  window saving a frame it has open would overwrite an edit made meanwhile.
  Phase 2 routes MCP calls into the running app's `Session` over XPC, so a
  person watches the agent work and can take over at any step.
- **Masks** (withdrawn behind `FeatureFlags.masks` in the window too).
- **Deterministic grain** for byte-identical reruns: the engine's exact
  sampler is not on the wire.
- **Batch planning**: the agent reads a folder, groups frames and applies a
  look per group. It is possible with today's tools, but a dedicated tool
  would keep the context small.
