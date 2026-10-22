# User command line and local agents

Windows builds include `spektralab-cli.cmd` plus `agents/node.exe` and the
bundled application code. Users do not install Node, npm, Python or Vulkan SDK.
Enable **Settings → Agents** before use. Access starts off and is checked for
every tool call, including calls on an already running MCP server.

The Settings page shows the exact command and MCP configuration. “Install
command” writes the owned wrapper to `~/.local/bin/spektralab.cmd`; it does not
change PATH or overwrite another program. Run the displayed full path or add
that directory to PATH yourself. After moving the app, reinstall the wrapper.

```
spektralab-cli.cmd status
spektralab-cli.cmd schema
spektralab-cli.cmd stocks
spektralab-cli.cmd info "D:\Photos\frame.ARW"
spektralab-cli.cmd process "D:\Photos\frame.ARW"
spektralab-cli.cmd edit "D:\Photos\frame.ARW" --patch @edit.json --preview "D:\Output\preview.jpg"
spektralab-cli.cmd latitude "D:\Photos\frame.ARW"
spektralab-cli.cmd place "D:\Photos\frame.ARW" --highlight 1 --shadow 0
spektralab-cli.cmd export "D:\Photos\frame.ARW" --recipe "TIFF 16-bit — ProPhoto" --to "D:\Output"
```

`edit.json` contains only the edited fields, for example
`{"params":{"filmStock":"kodak_portra_160"},"adjustments":{"exposure":0.2}}`.
The schema lists permitted values. Unknown fields, read-only fields, invalid
ranges and malformed curves are refused without saving. Scene Placement goes
through the engine Fit. Decode changes use the same LibRaw/Lensfun path, and
exports use the same immutable snapshot, ProPhoto/GPU processing and native
encoders as the window. JPEG previews are sRGB; actual export follows its recipe.

CLI stdout contains one JSON response. Exit codes are 0 success, 1 processing
failure, 2 refused request (including disabled access). `--patch -` reads JSON
from stdin; `get`, `reset`, `preview -o` and `recipes` are also available.
Explicit preview destinations are never overwritten. Export collision handling
follows the saved recipe, and the original photograph is always protected.

`mcp` serves newline JSON-RPC 2.0 over stdio with the pinned Mac tool names,
`tools/list`, `tools/call`, `prompts/list` and the `edit_photo` prompt. It handles
one call at a time and retains only one engine session. Returned previews are
small JPEGs; full exports stay in the backend. A tool error is `isError: true`.
Temporary MCP previews are removed after their image payload is read.

Sidecar reads and writes run through the app executable's narrow file service,
using the exact GUI `SidecarStore` identity, move recovery and atomic writes.
No sidecar is written beside the original. An OS-owned workspace lock excludes
GUI batches and concurrent agent operations and releases on process exit.
External edits produce a small app journal, while optimistic GUI save checks
prevent an unsaved editor from silently overwriting them.
The journal retains the last 64 unique paths and an overflow flag. The window
checks it on focus and every two seconds, invalidates affected thumbnails and
reloads clean selected snapshots. Dirty edits are retained with an explicit
reload/conflict choice. A batch holds its lease from frozen snapshot capture
through completion, cancellation or failure.

The two pixel-affecting app preferences, effect scale after crop and DI blue
compensation, are mirrored atomically from GUI settings. Each tool freezes that
pair of flags once. A missing first-use file uses the same GUI defaults; an
unreadable or malformed existing file is an error, never a silent alternate
render. Partial pairs may be inspected, but image processing requires both
source holes; pair-hole edits remain in the window.

## Build and validation

`npm run build:agent` produces the bundled script without requiring a separately
installed runtime. `node scripts/build-agent.mjs APP_DIRECTORY --runtime` stages
the portable runtime, license, exact version and SHA-256 manifest. Packaging
requires Node **24.19.0**, with the full version-matched upstream license; the
source bundle itself targets Node 22. The installer staging script includes
the same `agents` resources. Release builders must retain the runtime manifest
and `NODE-LICENSE.txt`.

`tsconfig.agent.json`, `agent/schema.test.ts`, and `agent/smoke.py` cover strict
schema/merge rules, MCP errors, opt-in and live revocation, real sidecars,
Process/Fit, Unicode JPEG/export paths, source protection and process-death lock
recovery. The native smoke requires an actual built app and engine. Windows
RTX testing does not establish Metal pixel parity or Linux package layout;
those remain separate platform checks.
