# SpektraLab 2 for Windows — the first run on Windows

For whoever first installs `SpektraLab_2.0.0-alpha.1_x64-setup.exe` on a Windows PC. Everything below
was built and checked on a Mac only (PRD-W0 §1.1): the installer was listed, never run; the app, the
engine host and the library helper were cross-built and have never started on Windows. Each item is
something no check on the Mac could see. Write down what you see against each, with the PC (CPU, GPU,
driver, RAM, Windows build, display scale) at the top.

What *was* verified on the Mac, so you need not repeat it: the interface against the design (Playwright,
T2/T2b/T3, mock backends); the Rust layer with the real engine host (MoltenVK) and the real library
helper (T5a); the real app on macOS driving itself through a RAW develop, the canvas, an export and the
Library (T5b); the installer's members, file types, versions and the helper's bytes (T6).

## The window (frameless, app-drawn title bar)

- [ ] Drag the window by the title bar, by the empty space beside the menus and by the title text; not by
      a menu name or a caption button.
- [ ] Resize from every edge and corner; the cursor changes at each.
- [ ] Maximise and restore with the caption button and with a double-click on the title bar; the corner
      radius goes square when maximised.
- [ ] Snap layouts: hover the maximise button (Windows 11) and **Win+Z**; Win+←/→/↑/↓; drag to a screen
      edge. Snapped narrow, the rails fold as `win_snapped*.svg` draws.
- [ ] Minimise, then restore from the taskbar.
- [ ] F11 full screen and back; Ctrl+B and Ctrl+Shift+F.

## DPI and displays

- [ ] 100 %, 125 %, 150 % (and 175 % if the display allows) in Settings › Display › Scale: the title bar is
      32 epx, the rails 320, the filmstrip 80; no clipped or "…" text, in English and 简体中文.
- [ ] Move the window between two monitors of different scale: it re-lays out without a blurred canvas.
- [ ] A wide-gamut display: the canvas's colour (sRGB vs Display P3 path) looks right against an export.

## WebView2 and keys

- [ ] Alt shows the access keys; Alt+F / F10 opens File; arrow keys move in a menu; Esc closes it.
- [ ] Ctrl+Z / Ctrl+Shift+Z, Ctrl+E (export), Ctrl+, (Settings), Ctrl+C/Ctrl+V settings, ←/→ between frames.
- [ ] Typing in a field (a recipe name, a number) keeps ←/→/Delete in the field (trap 32), and Ctrl+A
      selects the field's text, not the frames.
- [ ] No WebView2 default shows through: no browser context menu, no Ctrl+P print dialog, no Ctrl+F find
      bar, no zoom on Ctrl+wheel outside the canvas, no F5 reload.
- [ ] A machine without the WebView2 runtime (rare on Windows 11): the installer fetches it silently.

## The two helpers

- [ ] Starting the app shows **no console window** — neither `spektralab-host.exe` nor `spklib-host.exe`
      (both are console programs started with `CREATE_NO_WINDOW`). Check again after Settings › Engine ›
      Restart, and after opening a Library (the first library call starts `spklib-host.exe`).
- [ ] Task Manager: one `spektralab-host.exe` and at most one `spklib-host.exe` under SpektraLab; both
      gone when the app quits (also after closing the window with the app mid-render).
- [ ] Kill `spektralab-host.exe` in Task Manager during a develop: the status line says it failed, the
      host comes back, Try Again develops (on the Mac this is T5a's "kill the host mid-job").

## A RAW develops

- [ ] Open a RAW (File › Open, a drag onto the window, open-with from Explorer): the status line goes
      *Developing · Portra 400* → *Developed · Portra 400 · Portra Endura*; the last picture stays meanwhile.
- [ ] A slider drag folds into one develop at the end (not one per step); a film card pick develops.
- [ ] Zoom to 100 %: the full view lands (the badge says full).
- [ ] A frame from each camera you have; a TIFF and a JPEG.
- [ ] Settings › Engine: the GPU's name, and the scheduler's numbers (below).

## Export

- [ ] Export one frame (JPEG sRGB) into a folder of your choice, and a batch of three: the toolbar ring
      moves, Stop after this frame stops the rest, the files open in another viewer.
- [ ] A 16-bit TIFF; a file name with 简体中文 characters; a folder on another drive; a network share.

## The Library

- [ ] Add a folder: its pictures appear; nothing is written inside the folder (its library lives in
      `%LOCALAPPDATA%\SpektraLab\Libraries\Folders\`).
- [ ] Create a SpektraLab catalog, add pictures, rate, make an album, close and reopen it.
- [ ] Open a **Capture One for Windows** catalog (`.cocatalog`): it reads, it is read-only (a rating key
      says so and writes nothing), and the catalog folder's files are unchanged afterwards (compare
      sizes and modified times before and after). A Capture One session: probe only, as on the Mac.
- [ ] A path with 简体中文 characters, a `\\?\` long path, and a catalog on a USB drive that is then
      unplugged (the folder row says Offline).

## Memory budget — every number here is unmeasured on Windows

The scheduler plans every render against a budget (`crates/spk-scheduler/README.md`, "The desktop PC
policy"). On Windows the policy is `desktop_pc(installed RAM, GPU memory)` and **all of its numbers are
placeholders until measured on a PC**; Settings › Engine › Scheduler shows them and lists them as
unmeasured:

- [ ] Note the budget Settings › Engine shows, and `scheduler-log.jsonl` in the log folder
      (Settings › Diagnostics › Open): `predictedPeakBytes` against what Task Manager shows for
      `spektralab-host.exe` at the peak of a full-size render and an export, on a 24 MP and a ≥45 MP RAW.
- [ ] `PC_ALLOWANCE_SHARE_OF_RAM` (0.5), `PC_MIN_ALLOWANCE_MB` (4 GB), `PC_GPU_RESERVE_BYTES` (768 MB),
      `PC_GPU_BYTES_PER_PIXEL` (72), `PC_TIME_RATIO` (1.0): are the predicted seconds near the measured?
      Does a 100 MP RAW wait for memory on a 16 GB PC, and does it then run?
- [ ] The Windows memory probe (`GlobalMemoryStatusEx`, private commit) has never run: do its readings in
      the job log look like Task Manager's?
- [ ] The v1 host reports no GPU memory, so a dedicated GPU's VRAM is not part of the budget yet.
