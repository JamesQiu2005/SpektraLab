"""P4, mechanised: no node a band-able stage can reach may read the plane.

The amendment to RFC-020 states P4 as a rule addressed to whoever writes the
next node: a node that acquires an image-global statistic must declare itself
whole-frame, or take its statistic from the meter tier. **Nothing fired if they
ignored it.** The only enforcement was §6's hash, and §6's hash catches a new
global *only* if some parity case exercises that node at a non-default
parameter -- which is precisely why `node_boost` slipped past
`strip_executor.py` at the shipped `boost_ev = 0` and was caught instead by
`parity_render`'s 27-case axis. That is too thin a thread for a principle
step 6 leans on, so this probe makes the rule mechanical.

**The property, exactly:** no function reachable from a stage whose table entry
says `band_able` may compute anything over the plane's pixels -- neither by a
GPU reduction nor by a copy of the plane to the host. "Declares itself
whole-frame" is not a marker in the code; it *is* the stage table, so the
property is checkable as reachability from that table.

Three things make the check honest rather than decorative:

1. **It is a source check, not a run.** It needs no dylib, no engine, no
   fixture, so it fires on the addition rather than on the consequence, and it
   fires whatever the node's parameters are. That is the whole point of doing
   it this way instead of leaning on the hash.
2. **The sink list is verified against the tree, not trusted.** A rename that
   empties it would otherwise turn this file into a guard that cannot fire,
   which is this repo's repeat defect. Each named sink must still be *defined*
   in `pipeline.cpp`, or the probe fails and says the list has rotted.
3. **The parser is pinned too.** The stage tables must parse to exactly the
   entries they have today, and every table row must name a function that
   exists. A regex that stops matching is indistinguishable from a clean tree.

`--self-test` mutates the source in memory and asserts the verdict flips the
way it must -- including the negative control, where a benign edit has to stay
green. Each mutation is asserted to have applied, because a mutation that
silently misses its anchor makes the self-test vacuous in exactly the way the
self-test exists to prevent.

What it deliberately does *not* catch: a node that reads frame-level state
which is not derived from pixels -- `pixel_size_um_`, the tier ratio, a seed,
a setup table. Those are constants of the render, a band reads the same values,
and `unsharp`, `glare`, `lens_blur`, `grain` and `dir_couplers` all rely on
that. The line is "computed from the plane's pixels", not "read from outside".
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "src" / "pipeline" / "pipeline.cpp"

# The family of "computes something over the plane's pixels", by the function
# that does it. `exposure_sample_y` reaches `read_back` transitively, and the
# closure is transitive, so naming one would do; naming all three makes the
# failure message say which read happened rather than which helper was called.
SINKS = {
    "device_max": "reduces the plane to one number (dispatches spk_reduce_max)",
    "read_back": "copies the plane's pixels to the host",
    "exposure_sample_y": "reads the plane's luma to the host",
}

EXPECTED_TABLE_ROWS = 10  # five film stages, five print stages

# `if (cond) {` and its relatives have the shape of a definition -- a name, a
# parenthesised something, then a brace -- and are skipped by name so a call
# path never reads `... -> for -> device_max`.
KEYWORDS = {"if", "for", "while", "switch", "catch", "else", "do", "return",
            "sizeof", "SPK_NODE", "SPK_FAIL"}


def blank_literals(src: str) -> str:
    """Comments, strings and char literals replaced by spaces, offsets kept.

    Offsets and newlines are preserved so every index in the blanked text is
    the same index in the real file, and a line number stays a line number.
    Comments go first and are skipped while scanning strings, so an apostrophe
    in prose cannot open a char literal.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            for j in range(i, min(i + 2, n)):
                out[j] = " "
            i += 2
        elif c in "\"'":
            quote = c
            out[i] = " "
            i += 1
            while i < n and src[i] != quote:
                if src[i] == "\\":
                    out[i] = " "
                    i += 1
                if i < n and src[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                i += 1
        else:
            i += 1
    return "".join(out)


def match_brace(src: str, open_index: int) -> int:
    """Index just past the `}` matching the `{` at `open_index`, or -1."""
    depth = 0
    for i in range(open_index, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


def skip_parens(src: str, open_index: int) -> int:
    """Index just past the `)` matching the `(` at `open_index`, or -1."""
    depth = 0
    for i in range(open_index, len(src)):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


def definitions(src: str) -> dict[str, tuple[int, int, int]]:
    """name -> (body_start, body_end, line) for every function defined here.

    A definition is a `name(` whose matching `)` is followed, whitespace and
    `const` aside, by `{`. That is what separates `bool Pipeline::node_grain(`
    from the `&Pipeline::node_grain` in a table entry, which is followed by a
    comma.
    """
    found: dict[str, tuple[int, int, int]] = {}
    # The prefix class holds a return type and a qualifier but not a newline,
    # so a name is only ever matched on the line that opens its signature --
    # `SPK_NODE(node_boost(` matches `SPK_NODE`, never `node_boost`.
    for m in re.finditer(r"(?m)^[\w:<>,\t\*& ]*?(\w+)\s*\(", src):
        name = m.group(1)
        if name in KEYWORDS:
            continue
        paren = src.find("(", m.end(1) - 1)
        close = skip_parens(src, paren)
        if close < 0:
            continue
        tail = re.match(r"\s*(const\s*)?(noexcept\s*)?(override\s*)?\{", src[close:])
        if not tail:
            continue
        brace = close + tail.end() - 1
        end = match_brace(src, brace)
        if end < 0:
            continue
        # The keyword-bearing prefix means statements like `if (x) {` are not
        # reachable: those are indented, and `re` here anchors at a line start,
        # so the collected names are function names -- `if`, `while`, `for` and
        # `SPK_NODE` do get collected and are simply never called as functions.
        line = src.count("\n", 0, m.start()) + 1
        found.setdefault(name, (brace + 1, end - 1, line))
    return found


def calls_in(body: str, known: set[str]) -> set[str]:
    """Identifiers in `body` that name a function defined in this file."""
    return {m.group(1) for m in re.finditer(r"\b(\w+)\s*\(", body)} & known


def reachable(text: str, defs: dict[str, tuple[int, int, int]],
              roots: list[str]) -> dict[str, list[str]]:
    """sink -> one call path to it, over all roots together."""
    known = set(defs)
    hits: dict[str, list[str]] = {}
    seen: set[str] = set()
    stack = [(r, [r]) for r in roots]
    while stack:
        name, path = stack.pop()
        if name in seen or name not in defs:
            continue
        seen.add(name)
        body = text[defs[name][0]:defs[name][1]]
        for callee in calls_in(body, known):
            if callee in SINKS:
                hits.setdefault(callee, path + [callee])
            stack.append((callee, path + [callee]))
    return hits


def stage_table(src: str) -> list[tuple[str, bool, str]]:
    return [(m.group(1), m.group(2) == "true", m.group(3)) for m in
            re.finditer(r'\{\s*"(\w+)",\s*(true|false),\s*&Pipeline::(\w+)\s*\}', src)]


def check(src: str) -> tuple[list[str], list[str]]:
    """(failures, notes) for a given source text."""
    text = blank_literals(src)
    defs = definitions(text)
    # The table is read from the raw source: its stage names are string
    # literals, and the blanker has just replaced every one of them with space.
    rows = stage_table(src)
    failures: list[str] = []
    notes: list[str] = []

    # The parser, pinned. A regex that quietly stops matching leaves an empty
    # root set and a green light over nothing.
    if len(rows) != EXPECTED_TABLE_ROWS:
        failures.append(f"the stage tables parsed to {len(rows)} rows, not "
                        f"{EXPECTED_TABLE_ROWS}; the parser has come off the source")
    for name, _, fn in rows:
        if fn not in defs:
            failures.append(f"stage {name} names {fn}, which is not defined in pipeline.cpp")

    # The sink list, verified against the tree rather than trusted.
    for sink, why in SINKS.items():
        if sink not in defs:
            failures.append(f"the sink list has rotted: {sink} ({why}) is not defined "
                            f"any more, so this probe is no longer guarding it")

    for name, band_able, fn in rows:
        if fn not in defs:
            continue
        hits = reachable(text, defs, [fn])
        if band_able and hits:
            for sink, path in hits.items():
                failures.append(f"{name} is band-able and reaches {sink} "
                                f"({SINKS[sink]}) via {' -> '.join(path)}")
        elif hits:
            notes.append(f"{name} is whole-frame, as its table entry says: "
                         + "; ".join(f"{sink} via {' -> '.join(path)}" for sink, path in hits.items()))
        else:
            notes.append(f"{name} reaches no sink")

    return failures, notes


def self_test(src: str) -> int:
    """Assert the verdict flips for the right reasons, in both directions."""
    cases = [
        ("the whole-frame marker removed from film_boost_and_blurs",
         '{"film_boost_and_blurs",   false,', '{"film_boost_and_blurs",   true, ',
         "band-able and reaches"),
        ("a sink renamed under the probe",
         "bool Pipeline::device_max(", "bool Pipeline::device_maximum(",
         "sink list has rotted"),
        ("a stage row naming a function that is not there",
         '{"print_output",      true,  &Pipeline::print_output},',
         '{"print_output",      true,  &Pipeline::print_outputty},',
         "is not defined in pipeline.cpp"),
        ("a benign edit (a stage turned whole-frame)",
         '{"print_output",      true,', '{"print_output",      false,',
         None),
    ]
    bad = 0
    for what, old, new, want in cases:
        if src.count(old) != 1:
            print(f"FAIL  self-test case {what!r}: its anchor appears "
                  f"{src.count(old)} times, so the mutation never applied")
            bad += 1
            continue
        failures, _ = check(src.replace(old, new))
        if want is None:
            ok = not failures
            detail = "clean" if ok else f"{failures[0]}"
        else:
            hit = [f for f in failures if want in f]
            ok = bool(hit)
            detail = hit[0] if hit else (failures[0] if failures else "nothing failed")
        print(f"{'ok  ' if ok else 'FAIL'}  self-test: {what} -- {detail}")
        bad += 0 if ok else 1
    return bad


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=SOURCE)
    parser.add_argument("--self-test", action="store_true",
                        help="mutate the source in memory and assert the verdict flips")
    args = parser.parse_args()

    src = args.source.read_text()
    print(f"source: {args.source}")

    if args.self_test:
        print("self-test: the mutations below are in memory only; the file is not written\n")
        bad = self_test(src)
        print(f"\n{bad} failed")
        return 1 if bad else 0

    failures, notes = check(src)
    for note in notes:
        print(f"note  {note}")
    for f in failures:
        print(f"FAIL  {f}")
    ok = not failures
    print(f"\n{'P4 holds: no band-able stage can reach a plane-wide read' if ok else str(len(failures)) + ' failed'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
