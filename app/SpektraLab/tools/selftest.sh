#!/bin/bash
# selftest.sh -- compile the scheduler's own sources with tools/scheduler_selftest.swift and run it;
# then the Latitude card's and Scene Placement's (tools/latitude_selftest.swift: what is drawn from the
# engine's reply, and the app's solve of a placement against the engine's own)
# the host's cut of a decode for a film edge (tools/host_cut_selftest.swift: every pixel of the cut
# against the model's place for it), an export's own arithmetic and its saved recipes
# (tools/export_selftest.swift: what is decoded for the size a recipe names, and the recipes' file),
# and the develop page's (tools/develop_selftest.swift: every panel's parts and every note's line, a slide film scanned and never printed over the bundle's own
# catalogue), a double exposure's keeping, guide and darkroom rules (tools/double_selftest.swift,
# tools/double_darkroom_selftest.swift), and a half-frame pair's picture under its hole (tools/piece_selftest.swift:
# every pixel of the hole, as the app's host places it, against the pair's own arithmetic for it),
# the Film Edge flow's steps (tools/film_edge_steps_selftest.swift: every step open from a fresh open, the
# film edge written alike by a jump and by Next, and the options a choice greys, the frame number's held
# against the app's port of the engine's layout),
# Develop's strips (tools/stock_previews_selftest.swift: which cards, a slide with no paper and silver on
# silver, what each card is rendered from and its key, the size it keeps),
# and what the app keeps on disk and lets go of (tools/storage_selftest.swift: the working copies'
# limit, which of them go and which never do, and the launch's tidy of the files no frame names),
# the canvas's HDR rendition and Edit's live picture kept to the last edit (tools/hdr_latch_selftest.sh, issue #123: red on 2.4.0's rules),
# a frame's edit history (tools/history_selftest.swift: the list and its cursor at 256 steps; tools/history_store_selftest.swift:
# the store on disk and in memory, a kill between steps, a newer build's file, the reconciliation guard;
# tools/history_label_selftest.swift: every field of a revision named),
# a RAW's lens correction where Core Image has none (tools/lens_profile_selftest.sh: a Sony ARW's own parameters and a DNG's
# opcodes read and applied, against Adobe's measured profile and Core Image's own; SKIPPED without RAW_decode_tests),
# the film path's RAW decode over the owner's samples (tools/raw_samples_check.sh: every file decodes, the black repair finds
# the DC-S1M2 and nothing else, every other file bit for bit as before it, the DC-S1M2's repaired shadows neutral, the fade
# on a made-up ramp, the lens column; SKIPPED without RAW_decode_tests),
# Check for Updates' arithmetic (tools/update_selftest.swift: which release is newer, what a manifest must hold),
# Settings' Supporters (tools/supporters_selftest.swift: the shipped Resources/Supporters.json decodes, and the
# page lists every entry with its note, over the shipped file and a fixture of its own),
# the agents' command line and MCP server (tools/agent_selftest.swift: the tool table and a call held to it whole,
# the socket's path, the socket end to end over a stand-in app, the CLI's exit codes, MCP's framing),
# the app's own log (tools/log_selftest.swift: a line with no file's name in it, the session's file
# and its 7 days, how the session before ended, what is due to send, and the zip), which readings of
# the app's memory become records (tools/memory_selftest.swift),
# the app's language (tools/language_selftest.swift: which of the four the system's language list asks for, what a
# launch settles on and keeps, a sentence's arguments), and its words (tools/localization_check.py: every
# sentence in four languages, in the right script, looked up where it is shown), and Layer 2, Edit's Light,
# Curve and Colour (tools/layer2_selftest.swift: the desktop's maths and its tests, the parametric curve,
# the kernels on this Mac's GPU against a reference -- neutral to the bit, a preview's size against an
# export's -- an edit of schema 3 loading, the clipboard's three groups, the log's names for them).
# And the files a person's work is kept in (tools/persisted_check.swift: a 2.1.4 library's edit, pair,
# clipboard, presets, recipes and Light Table, tools/persisted_2.1.4, read by this tree's own types and
# written back the same, a retired word read as what it stands for, an unreadable file set aside), with
# tools/persisted_names.py: every key, raw value, defaults key and engine or spklib-host field 2.1.4 had
# is still spelled somewhere in Sources (tools/persisted_names_baseline.tsv).
#
# Every one of them is compiled with Model/Localization.swift, the lookup the pages' words go through:
# with no bundle and no language chosen it gives each sentence back in English, which is what these
# checks compare (LOCALIZATION.md).
#
#   tools/selftest.sh [--self-test]
#
# macOS, no Xcode project: the scheduler, its cost model and the simulated engine have no UIKit in them,
# the card's reading and a placement's solve are made from the
# engine's reply without the engine (three replies it made, and its fits of four real frames, are kept
# in tools/engine_replies), and the cut is Core Image's on this Mac. The develop page's checks are
# compiled with -D DEBUG.
#
# Since 2026-11-14 the commands are tools/selftests.json and `tools/gate.py selftest` runs them: each build cached by
# the contents of what it reads (tools/gate/swiftc), -Onone except where tools/gate/keep-O.txt keeps -O, several builds
# and runs at once. A full run was 965 s on this Mac, 753 s of it the builds one after another.
#   tools/selftest.sh                      every step
#   tools/selftest.sh --changed [REF]      the steps a change since REF (default main) reaches
#   tools/selftest.sh --only ID,ID         those steps
#   tools/selftest.sh --plan …             what would run, and why
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -B "$here/tools/gate.py" selftest "$@"
