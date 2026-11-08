#!/usr/bin/env python3
"""persisted_names.py -- the names on disk and on the wire that a rename must not move.

Standard library only. Scans the app's `Sources/` (Swift) and finds:

  1. every Codable / Encodable / Decodable type, with its CodingKeys (and whether each key is a literal
     or still the case's Swift name), the stored properties whose Swift name *is* the key (no
     CodingKeys), and the enums whose case names are encoded (String raw values that default to the
     case name; enums with payloads, whose case names and labels are keys);
  2. every UserDefaults / @AppStorage key, literal or resolved through a constant;
  3. which file or message each Codable type reaches (a curated root table, closed over the
     stored-property type graph), and every `decode(X.self, from:` call site, so a new root shows up;
  4. a risk score per persisted name, and the riskiest N.

Usage:
  persisted_names.py <Sources> [--json OUT.json] [--markdown OUT.md] [--top 20]
  persisted_names.py <Sources> --check persisted_names_baseline.tsv
      exit 1 if a key of the baseline is no longer produced by the tree (tools/selftest.sh runs this)
  persisted_names.py <Sources> --check persisted_names_baseline.tsv --write-baseline NEW.tsv
      the baseline as the tree has it now, its retired rows kept: for a key added on purpose

**The baseline** (`persisted_names_baseline.tsv`) is what 2.1.4 kept, one `format<TAB>key<TAB>kind` row
each, as the JSON spells it: `$.frames[].edit.params.filmStock`, an enum value as `...aspect=square`, a
payload case as `...source.linkedFolder.disk`; a UserDefaults key; an engine or spklib-host field. A
fourth column `retired: <why>` marks a row the tree may no longer produce because the app reads that word
as another on purpose (`ExportRecipe.Destination.retired`); it never fails the check. Only the formats in
`BASELINE_FORMATS` are held: the person's files, the two wires and the defaults. The logs, the caches and
the bundle's own tables are not (a renamed key there costs a re-render, or an update of a log reader).

It compares *key strings* per format, never Swift names, so renaming a property that carries an explicit
CodingKeys literal passes, and renaming one whose key is its own name fails. A rename of a format's root
type makes that whole format read as gone: the check prints MISSING ROOT for it, and `--rename-map MAP.tsv`
(rows `type<TAB>old<TAB>new`, and `file<TAB>old path<TAB>new path` for the `@file:` root) moves the roots
with the rename until FORMATS below is edited to match.

The parser is a Swift lexer good enough for this codebase (comments, nested block comments, string
literals with interpolation, multi-line and raw strings), not a compiler. Its blind spots are listed in
the output's `limits`; the runtime half of the gate is `tools/persisted_check.swift`.
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sys
from collections import defaultdict

# --------------------------------------------------------------------------------------------------
# lexing


class Src:
    def __init__(self, path: str, rel: str, text: str):
        self.path, self.rel, self.text = path, rel, text
        self.masked, self.strings = mask(text)
        self.string_at = {s["start"]: s for s in self.strings}
        self.line_starts = [0] + [i + 1 for i, c in enumerate(text) if c == "\n"]
        self.match = brace_matches(self.masked)

    def line(self, off: int) -> int:
        return bisect.bisect_right(self.line_starts, off)

    def line_text(self, off: int) -> str:
        n = self.line(off)
        a = self.line_starts[n - 1]
        b = self.line_starts[n] - 1 if n < len(self.line_starts) else len(self.text)
        return self.text[a:b]


def mask(text: str):
    """Return (masked, strings). Comments become spaces; a string literal keeps its quote characters
    and its contents become 'S' (newlines kept), so braces and keywords inside either are invisible.
    Offsets are preserved, so the masked text and the source index alike."""
    out = list(text)
    strings = []
    n = len(text)

    def blank(a, b, ch=" "):
        for k in range(max(a, 0), min(b, n)):
            if out[k] != "\n":
                out[k] = ch

    def scan_string(i):
        """i at the first '#' or '"'. Returns (end, value, interpolated)."""
        hashes = 0
        while i < n and text[i] == "#":
            hashes += 1
            i += 1
        multi = text.startswith('"""', i)
        q = '"""' if multi else '"'
        i += len(q)
        close = q + "#" * hashes
        esc = "\\" + "#" * hashes
        value = []
        interp = False
        while i < n:
            if text.startswith(close, i):
                return i + len(close), "".join(value), interp
            if text.startswith(esc, i):
                j = i + len(esc)
                if j < n and text[j] == "(":
                    interp = True
                    depth = 0
                    k = j
                    value.append("\\(")
                    while k < n:
                        c = text[k]
                        if c == '"' or (c == "#" and re.match(r'#+"', text[k:k + 6])):
                            k, _, _ = scan_string(k)
                            value.append("…")
                            continue
                        if c == "(":
                            depth += 1
                        elif c == ")":
                            depth -= 1
                            if depth == 0:
                                k += 1
                                break
                        if depth > 0 and k > j:
                            value.append(c)
                        k += 1
                    value.append(")")
                    i = k
                    continue
                if j < n:
                    value.append({"n": "\n", "t": "\t", "0": "\0"}.get(text[j], text[j]))
                i = j + 1
                continue
            if not multi and text[i] == "\n":
                return i, "".join(value), interp  # unterminated: stop at the line
            value.append(text[i])
            i += 1
        return i, "".join(value), interp

    i = 0
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 0
            j = i
            while j < n:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                    continue
                if text.startswith("*/", j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                    continue
                j += 1
            blank(i, j)
            i = j
            continue
        if c == '"' or (c == "#" and re.match(r'#+"', text[i:i + 6])):
            if c == "#" and i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
                i += 1
                continue
            end, value, interp = scan_string(i)
            q0 = text.index('"', i)
            ql = 3 if text.startswith('"""', q0) else 1
            hashes = q0 - i
            body_a, body_b = q0 + ql, end - ql - hashes
            blank(i, q0)                       # the leading #s
            blank(body_a, body_b, "S")         # the contents
            blank(end - hashes, end)           # the trailing #s
            strings.append({"start": i, "end": end, "value": value, "interp": interp})
            i = end
            continue
        i += 1
    return "".join(out), strings


def brace_matches(masked: str):
    m, stack = {}, []
    for i, c in enumerate(masked):
        if c == "{":
            stack.append(i)
        elif c == "}" and stack:
            m[stack.pop()] = i
    return m


# --------------------------------------------------------------------------------------------------
# declarations

DECL_RE = re.compile(
    r"(?<![\w.])(struct|class|enum|actor|extension|protocol)\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)")
NOT_NAMES = {"func", "var", "let", "case", "init", "subscript", "static", "override", "final", "private",
             "public", "internal", "fileprivate", "open", "nonisolated", "mutating", "convenience",
             "required", "typealias"}
CODABLE = {"Codable", "Encodable", "Decodable"}
RAW_TYPES = {"String", "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
             "UInt64", "Double", "Float", "Character", "CGFloat"}


def split_top(s: str, sep=","):
    out, depth, cur = [], 0, []
    for c in s:
        if c in "<([":
            depth += 1
        elif c in ">)]":
            depth -= 1
        if c == sep and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
    out.append("".join(cur))
    return [x.strip() for x in out if x.strip()]


class Decl:
    def __init__(self, src, kind, name, start, open_, close, conformances, generic):
        self.src, self.kind, self.name, self.start = src, kind, name, start
        self.open, self.close = open_, close
        self.conformances, self.generic = conformances, generic
        self.parent = None
        self.qual = name

    @property
    def line(self):
        return self.src.line(self.start)


def find_decls(src: Src):
    decls = []
    m = src.masked
    for mo in DECL_RE.finditer(m):
        kind, name = mo.group(1), mo.group(2)
        if name in NOT_NAMES:
            continue
        j = mo.end()
        brace = m.find("{", j)
        if brace < 0:
            continue
        header = m[j:brace]
        h = header.lstrip()
        generic = ""
        if h.startswith("<"):
            depth = 0
            for k, c in enumerate(h):
                if c == "<":
                    depth += 1
                elif c == ">":
                    depth -= 1
                    if depth == 0:
                        generic, h = h[:k + 1], h[k + 1:]
                        break
        h = h.strip()
        conf = []
        if h.startswith(":"):
            body = re.split(r"\bwhere\b", h[1:])[0]
            conf = [re.sub(r"\s+", " ", x) for x in split_top(body)]
        elif h and not h.startswith("where"):
            continue  # not a declaration (`enum` in a pattern, `class` as a modifier, ...)
        close = src.match.get(brace)
        if close is None:
            continue
        decls.append(Decl(src, kind, name, mo.start(), brace, close, conf, generic))
    decls.sort(key=lambda d: d.start)
    for d in decls:
        best = None
        for p in decls:
            if p is not d and p.open < d.start < p.close and (best is None or p.open > best.open):
                best = p
        d.parent = best
    for d in decls:
        if d.kind == "extension":
            d.qual = d.name
        else:
            chain, p = [d.name], d.parent
            while p is not None:
                chain.append(p.name)
                if p.kind == "extension":
                    break
                p = p.parent
            d.qual = ".".join(reversed(chain))
    return decls


def flat_body(src: Src, d: Decl):
    """The body at its own depth: nested brace contents blanked (braces kept). Returns (text, base)."""
    a, b = d.open + 1, d.close
    m = src.masked
    out = list(m[a:b])
    depth = 0
    for k in range(a, b):
        c = m[k]
        if c == "{":
            depth += 1
            if depth > 1:
                out[k - a] = " "
            continue
        if c == "}":
            depth -= 1
            if depth >= 1:
                out[k - a] = " "
            continue
        if depth >= 1 and c != "\n":
            out[k - a] = " "
    return "".join(out), a


PROP_RE = re.compile(
    r"(?:^|;)[ \t]*((?:(?:@\w+(?:\([^)\n]*\))?|public|private|fileprivate|internal|open|static|class|final|lazy|"
    r"weak|unowned|nonisolated|override|dynamic|required)(?:\((?:set|unsafe)\))?\s+)*)(let|var)\s+([A-Za-z_]\w*)",
    re.M)
CASE_RE = re.compile(r"^[ \t]*(?:indirect\s+)?case\s+", re.M)


def infer_type(init: str):
    init = init.strip()
    mi = re.match(r"\[?\s*([A-Z]\w*(?:\.[A-Z]\w*)*)\s*[\](.]", init)
    if mi:
        return mi.group(1)
    if init.startswith('"'):
        return "String"
    if re.match(r"-?\d+\.\d", init):
        return "Double"
    if re.match(r"-?\d", init):
        return "Int"
    if re.match(r"(true|false)\b", init):
        return "Bool"
    return ""


def parse_props(src: Src, d: Decl):
    """Stored and computed properties declared at the body's own depth, including comma lists
    (`var x, y: Double`, `var a = 1, b = 2`): Swift gives `var a, b: T` the type T for both."""
    text, base = flat_body(src, d)
    props = []
    for mo in PROP_RE.finditer(text):
        mods, kw = mo.group(1), mo.group(2)
        static = bool(re.search(r"\b(static|class)\b", mods))
        wrappers = re.findall(r"@(\w+)", mods)
        seg_start = mo.start(3)
        segs = []          # (name_off, a, b) offsets into text of each `name[: T][= init]`
        depth, j = 0, mo.end()
        nxt_brace = False
        while j < len(text):
            c = text[j]
            if c in "([<":
                depth += 1
            elif c in ")]>":
                if not (c == ">" and text[j - 1] == "-"):
                    depth -= 1
            elif depth <= 0 and c == "," and re.match(r"\s*[A-Za-z_]\w*\s*[:=,]", text[j + 1:j + 80]):
                segs.append((seg_start, j))
                seg_start = j + 1 + (len(text[j + 1:]) - len(text[j + 1:].lstrip()))
            elif depth <= 0 and c == "{":
                nxt_brace = True
                break
            elif depth <= 0 and c in "\n;":
                break
            j += 1
        segs.append((seg_start, j))
        parsed = []
        for a, b in segs:
            seg = src.text[base + a: base + b]
            nm = re.match(r"\s*([A-Za-z_]\w*)", seg)
            if not nm:
                continue
            rest = seg[nm.end():]
            typ, init, has_init = "", "", False
            # split `: T = init` at the first depth-0 `=`
            dd = 0
            eq = None
            for q, c in enumerate(rest):
                if c in "([<":
                    dd += 1
                elif c in ")]>":
                    if not (c == ">" and q > 0 and rest[q - 1] == "-"):
                        dd -= 1
                elif dd <= 0 and c == "=" and rest[q:q + 2] != "==" and (q == 0 or rest[q - 1] not in "!<>="):
                    eq = q
                    break
            head = rest[:eq] if eq is not None else rest
            if eq is not None:
                has_init, init = True, rest[eq + 1:]
            h = head.strip()
            if h.startswith(":"):
                typ = h[1:].strip()
            parsed.append({"name": nm.group(1), "typ": typ, "init": init, "has_init": has_init,
                           "off": base + a + nm.start(1)})
        # `var a, b: T`: a takes T from the next segment that names one
        nxt_t = ""
        for p in reversed(parsed):
            if p["typ"]:
                nxt_t = p["typ"]
            elif not p["has_init"]:
                p["typ"] = nxt_t
        for i, p in enumerate(parsed):
            inferred = False
            typ = p["typ"]
            if not typ and p["has_init"]:
                typ, inferred = infer_type(p["init"]), True
            computed = False
            if i == len(parsed) - 1 and nxt_brace and not p["has_init"] and kw == "var":
                inner_open = base + j
                inner_close = src.match.get(inner_open, inner_open)
                inner = src.masked[inner_open + 1:inner_close].strip()
                computed = not re.match(r"(didSet|willSet)\b", inner)
            props.append({
                "name": p["name"], "kw": kw, "type": re.sub(r"\s+", " ", typ), "type_inferred": inferred,
                "static": static, "computed": computed, "has_default": p["has_init"], "wrappers": wrappers,
                "line": src.line(p["off"]), "file": src.rel,
            })
    return props


def parse_cases(src: Src, d: Decl):
    text, base = flat_body(src, d)
    cases = []
    for mo in CASE_RE.finditer(text):
        k = mo.end()
        depth, j = 0, k
        while j < len(text):
            c = text[j]
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            elif depth <= 0 and c in "\n;":
                if c == "\n" and text[k:j].rstrip().endswith(","):
                    j += 1          # `case a, b,` continues on the next line
                    continue
                break
            j += 1
        stmt_m = text[k:j]
        items, depth, cur_a = [], 0, 0
        for idx, c in enumerate(stmt_m + ","):
            if c in "([":
                depth += 1
            elif c in ")]":
                depth -= 1
            if c == "," and depth == 0:
                items.append((cur_a, idx))
                cur_a = idx + 1
        for a, b in items:
            raw_m = stmt_m[a:b]
            nm = re.match(r"\s*`?([A-Za-z_]\w*)`?", raw_m)
            if not nm:
                continue
            name = nm.group(1)
            pos = nm.end()                     # offset inside raw_m
            assoc = None
            pa = re.match(r"\s*\(", raw_m[pos:])
            if pa:
                depth = 0
                a0 = pos
                for q in range(pos, len(raw_m)):
                    c = raw_m[q]
                    if c == "(":
                        depth += 1
                        if depth == 1:
                            a0 = q
                    elif c == ")":
                        depth -= 1
                        if depth == 0:
                            assoc = src.text[base + k + a + a0 + 1: base + k + a + q]
                            pos = q + 1
                            break
            raw = None
            eq = re.match(r"\s*=\s*", raw_m[pos:])
            if eq:
                off = base + k + a + pos + eq.end()
                s = src.string_at.get(off)
                if s is not None:
                    raw = {"string": s["value"]}
                else:
                    raw = {"literal": src.text[off: base + k + b].strip()}
            cases.append({"name": name, "assoc": re.sub(r"\s+", " ", assoc) if assoc is not None else None,
                          "raw": raw, "line": src.line(base + k + a + nm.start(1))})
    return cases


# --------------------------------------------------------------------------------------------------
# the model


class Type:
    def __init__(self, qual):
        self.qual = qual
        self.decls = []
        self.exts = []
        self.conformances = set()

    @property
    def main(self):
        return self.decls[0] if self.decls else None

    @property
    def kind(self):
        return self.main.kind if self.main else "extension-only"


def build(srcs):
    decls = [d for s in srcs for d in find_decls(s)]
    types = {}
    for d in decls:
        t = types.setdefault(d.qual, Type(d.qual))
        (t.exts if d.kind == "extension" else t.decls).append(d)
        for c in d.conformances:
            t.conformances.add(c)
    codable_like = set(CODABLE)
    changed = True
    while changed:
        changed = False
        for t in types.values():
            if t.kind == "protocol" and t.qual not in codable_like and (
                    {c.split(".")[-1] for c in t.conformances} & codable_like):
                codable_like.add(t.qual)
                changed = True
    return decls, types, codable_like


def codable_kind(t: Type, codable_like):
    cs = {c.split(".")[-1] for c in t.conformances}
    refined = bool(cs & (codable_like - CODABLE))
    has_e = bool(cs & {"Codable", "Encodable"}) or refined
    has_d = bool(cs & {"Codable", "Decodable"}) or refined
    if has_e and has_d:
        return "Codable"
    return "Encodable" if has_e else "Decodable" if has_d else None


def resolve(name: str, scope: str, types):
    """Swift-ish lookup of a type name from inside `scope` (a qualified name)."""
    parts = scope.split(".") if scope else []
    for i in range(len(parts), -1, -1):
        cand = ".".join(parts[:i] + [name]) if i else name
        if cand in types:
            return cand
    return None


TYPE_IDENT_RE = re.compile(r"\b([A-Z]\w*(?:\.[A-Z]\w*)*)")


# --------------------------------------------------------------------------------------------------
# formats (curated roots). A root is a type whose encoded JSON is a file, a wire message or a hash.

FORMATS = [
    {"id": "library.json", "class": "disk", "where": "<Application Support>/<bundle id>/library.json",
     "writer": "Services/LibraryPersistence.swift", "roots": ["StoredLibrary"],
     "note": "THE library: every frame, its FrameEdit (the edit), its half-frame pair, its kept develop; "
             "linked folders with bookmarks. JSON, sortedKeys, dates ISO 8601."},
    {"id": "MacLibrary/sources.json", "class": "disk", "where": "<root>/MacLibrary/sources.json",
     "writer": "Mac/Library/CatalogSourcesStore.swift", "roots": ["CatalogSourcesStore.Registry"],
     "note": "The Mac library's sources (catalogs, sessions, folders, Capture One links). An unreadable "
             "list is set aside beside itself, never overwritten."},
    {"id": "MacLibrary/pairs.json", "class": "disk", "where": "<root>/MacLibrary/pairs.json",
     "writer": "Mac/Library/MacPairRows.swift", "roots": ["CatalogSourcesStore.PairRecord"],
     "note": "Where each half-frame pair's catalog row went."},
    {"id": "MacLibrary/moved.json", "class": "disk", "where": "<root>/MacLibrary/moved.json",
     "writer": "Mac/Migration/MacLibraryMove.swift", "roots": ["MacLibraryMove.Record"],
     "note": "The record of the app-library -> .spkcatalog move."},
    {"id": ".spektrapair", "class": "disk", "where": "<root>/Pairs/<name>.spektrapair",
     "writer": "Model/HalfFramePair.swift + Mac/Library/MacPairRows.swift", "roots": ["HalfFramePair"],
     "note": "A pair's recipe; its catalog row (spklib kind `pair`) points at the file. HalfFramePair's "
             "JSON plus a merged `spektralab` object (JSONSerialization, literal keys)."},
    {"id": "look-presets.json", "class": "disk", "where": "<root>/look-presets.json",
     "writer": "Services/PresetStore.swift", "roots": ["PresetStore.File"],
     "note": "Saved looks (LookPreset -> SettingsClip -> FrameEdit)."},
    {"id": "export-recipes.json", "class": "disk", "where": "<root>/export-recipes.json",
     "writer": "Services/ExportRecipeStore.swift", "roots": ["ExportRecipe"],
     "note": "Export recipes ([ExportRecipe])."},
    {"id": "lighttable.json", "class": "disk", "where": "<root>/lighttable.json",
     "writer": "LightTable/LightTableStore.swift", "roots": ["StoredTable"],
     "note": "The Light Table's kept table."},
    {"id": "defaults:scheduler.costCorrections.v1", "class": "defaults-blob",
     "where": "UserDefaults key scheduler.costCorrections.v1 (Data)",
     "writer": "Scheduler/CostModel.swift", "roots": ["CostModel.Correction"],
     "note": "The scheduler's learnt cost corrections; a failed read only resets them."},
    {"id": "UserDefaults raw values", "class": "defaults", "where": "UserDefaults (com.spektralab.mac*)",
     "writer": "found by the scan: an enum read back with X(rawValue:) or stored as x.rawValue at a defaults call",
     "roots": [],
     "note": "A preference: a renamed raw value falls back to the default (the setting is forgotten)."},
    {"id": "cache:SPKFULL1", "class": "cache", "where": "full-render tile cache files",
     "writer": "Engine/FullRender.swift", "roots": ["FullRender.Header"],
     "note": "Cache: a renamed key makes every kept full render unreadable (made again)."},
    {"id": "cache:raw-proxy", "class": "cache", "where": "RAW proxy cache files",
     "writer": "Engine/RawProxy.swift", "roots": ["RawProxy.Header"],
     "note": "Cache: a renamed key re-decodes every RAW once."},
    {"id": "bundle:catalog", "class": "bundle", "where": "app bundle stock catalogue (tools/gen_catalog.py)",
     "writer": "tools/gen_catalog.py (reader Model/Stock.swift)", "roots": ["Stock", "StockCatalog.Wrapper"],
     "note": "Generated by a repo tool: a rename must change the generator in the same commit."},
    {"id": "engine-wire", "class": "wire", "where": "C ABI JSON to/from the engine (API-SPEC)",
     "writer": "Engine/SceneLatitude.swift, Model/FilmParams.swift, Scheduler/SpkEngine.swift",
     "roots": ["SceneLatitudeRequest", "SceneLatitudeReply", "ParamValue"],
     "note": "Field names are the engine's. FilmParams.wire / delta are string literals (listed separately)."},
    {"id": "spklib-host", "class": "wire", "where": "vendor/spklib/macos/spklib-host JSON lines",
     "writer": "Mac/Library/LibraryAPI.swift, Mac/Library/LibraryHost.swift",
     "roots": ["@file:Mac/Library/LibraryAPI.swift"],
     "note": "The helper's replies. Field names are spklib's (API-SPEC-library-helper.md), not ours."},
    {"id": "logs", "class": "log", "where": "the app's JSONL logs + logs receiver (tools/logs_*.py)",
     "writer": "Scheduler/JobLogFile.swift, Diagnostics/LogRecords.swift",
     "roots": ["JobRecord", "MemoryReading", "RunMeasurement", "FrameEdit"],
     "note": "Not user data, but tools/logs_*.py and the receiver read these names."},
    {"id": "hash:Adjustments.key", "class": "derived-hash",
     "where": "SHA-256 of Adjustments' JSON -> pair print stamps, Light Table full-read keys",
     "writer": "Model/Adjustments.swift (key), LightTable/LightTableFullRead.swift", "roots": ["Adjustments"],
     "note": "A rename moves every hash: kept develops/caches miss once and are made again (no data loss)."},
]

CLASS_WEIGHT = {"disk": 10, "defaults-blob": 4, "defaults": 4, "wire": 7, "bundle": 5, "cache": 2, "log": 2,
                "derived-hash": 3}
# formats whose loss is the user's own work
CROWN = {"library.json": 10, ".spektrapair": 6, "look-presets.json": 6, "export-recipes.json": 4,
         "lighttable.json": 5, "MacLibrary/sources.json": 6, "MacLibrary/pairs.json": 3,
         "MacLibrary/moved.json": 3}
# what a renamed key does to a reader: "required" -- the decode throws, so the whole file (or
# message) is unreadable; "value" -- a stored enum value no longer decodes, which throws too;
# "optional" -- read as absent, silently reset to its default and written back without it.
SEVERITY = {"required": 8, "value": 6, "optional": 0, "not decoded": -4, "encoded only": -2}
EDIT_CORE = {"FrameEdit", "FilmParams", "Adjustments", "Geometry", "CropRect", "FilmEdgeSettings",
             "DateBackSettings", "DecodeSettings", "HalfFramePair", "StoredFrame", "StoredLibrary",
             "SettingsClip", "CurveSet", "Curve", "HSLSet", "HSLBand", "ColorBalance", "ColorZone",
             "EffectStrengths", "SceneLatitudeSettings", "ContrastMaskSettings", "ChannelMixer",
             "MixerRow", "Vignette", "ParametricCurve", "ParametricSet", "RawExposureFacts"}


# --------------------------------------------------------------------------------------------------
# UserDefaults

DEFAULTS_METHODS = r"(object|bool|integer|double|float|string|stringArray|array|dictionary|data|url|removeObject)"
GET_RE = re.compile(r"([\w.()\[\]?!]*)\.%s\(\s*forKey:\s*" % DEFAULTS_METHODS)
SET_RE = re.compile(r"([\w.()\[\]?!]*)\.set\(")
WRAP_RE = re.compile(r"@(AppStorage|SceneStorage)\(\s*")
NOT_DEFAULTS_RECV = re.compile(r"(cache|Cache|filter|Filter|layer|Layer|dict|Dict|json|object|info|userInfo|"
                               r"props|properties|values|archiver|coder|aDecoder|aCoder|keychain|window|app|"
                               r"event|panel|controller)$")
DEFAULTS_HINT = re.compile(r"UserDefaults|defaults|Defaults|\.standard\b|\bd\b|\bud\b|\bstore\b|suite")


def arg_extent(masked: str, a: int):
    depth, j = 0, a
    while j < len(masked):
        c = masked[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return j
            depth -= 1
        elif c == "," and depth == 0:
            return j
        j += 1
    return j


def owner_of(decls_in_file, off):
    best = None
    for d in decls_in_file:
        if d.open < off < d.close and (best is None or d.open > best.open):
            best = d
    return best.qual if best else ""


def collect_constants(srcs, decls_by_file):
    """(owner qual, name) -> string value, for `let|var NAME[: String] = "…"` (and `, NAME2 = "…"` after
    it), and string arrays `let NAME[: [String]] = ["…", …]` (value None, `values` the list)."""
    consts = {}
    rx = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*\[?\s*String\s*\]?\s*)?=\s*")
    for s in srcs:
        for mo in rx.finditer(s.masked):
            a = mo.end()
            owner = owner_of(decls_by_file[s.rel], mo.start())
            name = mo.group(1)
            if s.masked[a:a + 1] == "[":
                close = s.masked.find("]", a)
                inner = s.masked[a + 1:close] if close > 0 else ""
                if close > 0 and inner.strip() and re.fullmatch(r'[\sS",]*', inner):
                    vals = [st["value"] for st in s.strings if a < st["start"] < close]
                    consts[(owner, name)] = {"value": None, "values": vals, "interp": False, "file": s.rel,
                                             "line": s.line(mo.start()), "tail": ""}
                continue
            st = s.string_at.get(a)
            if st is None:
                continue
            b = arg_extent(s.masked, a)
            nl = s.masked.find("\n", st["end"])
            if 0 <= nl < b:
                b = nl
            tail = s.text[st["end"]:b].strip()
            consts[(owner, name)] = {"value": st["value"], "interp": st["interp"], "file": s.rel,
                                     "line": s.line(mo.start()), "tail": tail}
            pos = st["end"]
            while True:  # `static let a = "x", b = "y"`
                m2 = re.match(r"\s*,\s*([A-Za-z_]\w*)\s*(?::\s*String\s*)?=\s*", s.masked[pos:pos + 200])
                if not m2:
                    break
                st2 = s.string_at.get(pos + m2.end())
                if st2 is None:
                    break
                consts[(owner, m2.group(1))] = {"value": st2["value"], "interp": st2["interp"], "file": s.rel,
                                                "line": s.line(pos), "tail": ""}
                consts[(owner, name)]["tail"] = ""
                pos = st2["end"]
    return consts


ALIASES = {}


def typealiases(srcs):
    out = {}
    for s in srcs:
        for mo in re.finditer(r"\btypealias\s+([A-Z]\w*)\s*=\s*([A-Z]\w*(?:\.[A-Z]\w*)*)", s.masked):
            out.setdefault(mo.group(1), mo.group(2))
    return out


def resolve_key_expr(expr, owner, consts, types):
    expr = expr.strip()
    m = re.fullmatch(r"(?:(Self|self|[A-Z]\w*(?:\.[A-Z]\w*)*)\.)?([a-z_]\w*)", expr)
    if not m:
        return None, "computed"
    tname, name = m.group(1), m.group(2)
    if tname and tname in ALIASES:
        tname = ALIASES[tname]
    if tname in (None, "Self", "self"):
        parts = owner.split(".") if owner else []
        scopes = [".".join(parts[:i]) for i in range(len(parts), -1, -1)]
    else:
        q = resolve(tname, owner, types) or tname
        scopes = [q] + [".".join(owner.split(".")[:i] + [tname]) for i in range(len(owner.split(".")), 0, -1)]
        scopes += sorted(k for k in {o for o, _ in consts} if k.split(".")[-1] == tname.split(".")[-1])
    for sc in scopes:
        c = consts.get((sc, name))
        if c:
            return c, "constant"
    if tname in (None, "Self", "self"):
        # a constant of an extension of the owner declared elsewhere (owner `A.B` extended as `B`)
        last = owner.split(".")[-1] if owner else ""
        for (o, n), v in consts.items():
            if n == name and o.split(".")[-1] == last:
                return v, "constant(extension)"
    return None, "unresolved"


def resolve_local(s, start, name, owner, consts, types):
    """A key held in a local: `let name = A ? B : C`, `let name = X`, or `for name in X`, within the
    60 lines before the call."""
    lo = s.line_starts[max(0, s.line(start) - 60)]
    window = s.masked[lo:start]
    found = None
    for mo in re.finditer(r"\b(?:let|var)\s+%s\s*(?::\s*String\s*)?=\s*|\bfor\s+%s\s+in\s+" % (name, name), window):
        found = mo
    if not found:
        return None, "unresolved"
    a = lo + found.end()
    if found.group(0).startswith("for"):
        b = s.masked.find("{", a)
    else:
        b = s.masked.find("\n", a)
    expr = s.text[a:b].strip()
    parts = [expr]
    tern = re.match(r"(.*?)\?\s*(.+?)\s*:\s*(.+)$", expr)
    if tern:
        parts = [tern.group(2).strip(), tern.group(3).strip()]
    vals = []
    for p in parts:
        if p.startswith('"'):
            off = s.text.find(p, a, b)
            st = s.string_at.get(off)
            if st is None:
                return None, "unresolved(local)"
            vals.append(st["value"])
            continue
        c, _ = resolve_key_expr(p, owner, consts, types)
        if c is None:
            return None, "unresolved(local)"
        vals += c["values"] if c.get("value") is None else [c["value"]]
    return {"value": None, "values": vals, "interp": False, "tail": ""}, "local"


def scan_defaults(srcs, decls_by_file, consts, types):
    sites = []
    for s in srcs:
        m = s.masked
        found = []
        for mo in GET_RE.finditer(m):
            found.append(("get:" + mo.group(2), mo.group(1), mo.end(), mo.start(), ""))
        for mo in SET_RE.finditer(m):
            a = mo.end()
            b = arg_extent(m, a)
            if b < len(m) and m[b] == ",":
                fk = re.match(r"\s*forKey:\s*", m[b + 1:b + 40])
                if fk:
                    found.append(("set", mo.group(1), b + 1 + fk.end(), mo.start(), s.text[a:b].strip()))
        for mo in WRAP_RE.finditer(m):
            found.append(("@" + mo.group(1), "", mo.end(), mo.start(), ""))
        for kind, recv, a, start, value_expr in found:
            if not kind.startswith("@"):
                r = recv.split(".")[-1] if recv else ""
                if r and NOT_DEFAULTS_RECV.search(r):
                    continue
                line = s.line_text(start)
                ctx = s.masked[max(0, start - 800):start]
                if not (DEFAULTS_HINT.search(recv) or re.search(r"UserDefaults|defaults", line)
                        or (recv == "" and re.search(r"UserDefaults", ctx))):
                    continue
            b = arg_extent(m, a)
            expr = s.text[a:b].strip()
            owner = owner_of(decls_by_file[s.rel], start)
            st = s.string_at.get(a)
            key, how, interp = None, None, False
            if st is not None and s.text[st["end"]:b].strip() == "":
                key, how, interp = st["value"], "literal", st["interp"]
            elif st is not None:
                key, how, interp = st["value"] + " " + s.text[st["end"]:b].strip(), "literal+expr", True
            else:
                c, how = resolve_key_expr(expr, owner, consts, types)
                if not c and re.fullmatch(r"[a-z_]\w*", expr):
                    c, how = resolve_local(s, start, expr, owner, consts, types)
                if c and c.get("value") is None and c.get("values"):
                    key, interp, how = " | ".join(c["values"]), False, how + "(each of)"
                elif c:
                    key, interp = c["value"], c["interp"]
                    if c.get("tail"):
                        key += " " + c["tail"]
                elif "+" in expr:
                    vals = []
                    for p in [p.strip() for p in expr.split("+")]:
                        if p.startswith('"'):
                            vals.append(p.strip('"'))
                        else:
                            c2, _ = resolve_key_expr(p, owner, consts, types)
                            vals.append(c2["value"] if c2 else "<%s>" % p)
                    key, how, interp = "".join(vals), "concatenation", True
            line_txt = s.line_text(start)
            found_enums = set(re.findall(r"\b([A-Z]\w*(?:\.[A-Z]\w*)*?)(?:\.init)?\(rawValue:", line_txt))
            found_enums |= set(re.findall(r"\b([A-Z]\w*(?:\.[A-Z]\w*)*)\.\w+\.rawValue", line_txt))
            # `x.rawValue` stored: x's declared type in this file
            for nm in re.findall(r"\b([a-z_]\w*)\.rawValue", value_expr + " " + (line_txt if kind.startswith("@") else "")):
                dm = re.search(r"\b(?:var|let)\s+%s\s*:\s*([A-Z]\w*(?:\.[A-Z]\w*)*)|\b(?:var|let)\s+%s\s*=\s*"
                               r"([A-Z]\w*(?:\.[A-Z]\w*)*)\.\w+" % (nm, nm), s.masked)
                if dm:
                    found_enums.add(dm.group(1) or dm.group(2))
            enums = []
            for e in sorted(found_enums):
                r_ = resolve(e, owner, types) or next((q for q in types if q.split(".")[-1] == e.split(".")[-1]), None)
                enums.append(r_ or e)
            sites.append({"file": s.rel, "line": s.line(start), "api": kind, "receiver": recv,
                          "expr": expr, "key": key, "resolved_by": how, "interpolated": interp,
                          "owner": owner, "raw_value_enums": enums, "value_expr": value_expr[:120]})
    return sites


# --------------------------------------------------------------------------------------------------
# engine wire literals


def scan_wire_literals(srcs):
    """`("name", .double(..)` tuples (FilmParams.wire and friends) and `"name": .double(` delta entries."""
    out = []
    rx = re.compile(r'"([a-z][a-z0-9_]*)"\s*(?:,|:)\s*\.(double|bool|string)\(')
    for s in srcs:
        for st in s.strings:
            mo = rx.match(s.text, st["start"])
            if mo:
                ch = "spklib-host" if s.rel.startswith("Mac/Library/") else "engine-wire"
                out.append({"field": mo.group(1), "kind": mo.group(2), "channel": ch, "file": s.rel,
                            "line": s.line(st["start"])})
    return out


# --------------------------------------------------------------------------------------------------
# analysis


def load(root):
    srcs = []
    for dp, dn, fn in os.walk(root):
        dn.sort()
        for f in sorted(fn):
            if f.endswith(".swift"):
                p = os.path.join(dp, f)
                with open(p, encoding="utf-8", errors="replace") as fh:
                    srcs.append(Src(p, os.path.relpath(p, root), fh.read()))
    return srcs


def analyse(root):
    srcs = load(root)
    decls, types, codable_like = build(srcs)
    decls_by_file = defaultdict(list)
    for d in decls:
        decls_by_file[d.src.rel].append(d)

    out_types = {}
    for q, t in types.items():
        ck = codable_kind(t, codable_like)
        if not ck or t.kind == "protocol":
            continue
        main = t.main
        bodies = t.decls + t.exts
        props, cases, coding_keys, custom_init, custom_encode = [], [], {}, False, False
        for d in bodies:
            ftxt, _ = flat_body(d.src, d)
            if re.search(r"\binit\s*\(\s*from\s+\w+\s*:|\binit\s*\(\s*from\s*:", ftxt):
                custom_init = True
            if re.search(r"\bfunc\s+encode\s*\(\s*to\s+\w+\s*:", ftxt):
                custom_encode = True
            props += parse_props(d.src, d)
            if d.kind == "enum":
                cases += parse_cases(d.src, d)
        for d2 in decls:
            if d2.kind == "enum" and d2.parent is not None and d2.parent in bodies and \
                    "CodingKey" in {c.split(".")[-1] for c in d2.conformances}:
                ck_cases = parse_cases(d2.src, d2)
                coding_keys[d2.name] = {
                    "line": d2.line, "file": d2.src.rel,
                    "raw_type": d2.conformances[0] if d2.conformances else None,
                    "cases": [{"case": c["name"],
                               "key": c["raw"]["string"] if c["raw"] and "string" in c["raw"] else c["name"],
                               "explicit": bool(c["raw"]), "line": c["line"]} for c in ck_cases]}
        stored, seen_names = [], set()
        for p in props:
            if not p["static"] and not p["computed"] and p["name"] not in seen_names:
                seen_names.add(p["name"])
                stored.append(p)
        modes = {}
        if custom_init:
            drx = re.compile(r"(try\??)\s*[\w.]+\.(decodeIfPresent|decode)\(\s*[^,]*?\.self\s*,\s*forKey:\s*\.(\w+)")
            for d in bodies:
                for mo in drx.finditer(d.src.masked, d.open, d.close):
                    m_ = "optional" if (mo.group(2) == "decodeIfPresent" or mo.group(1) == "try?") else "required"
                    k_ = mo.group(3)
                    if modes.get(k_) != "required":
                        modes[k_] = m_
        raw_type = None
        if t.kind == "enum" and main is not None and main.conformances:
            first = main.conformances[0].split(".")[-1]
            if first in RAW_TYPES:
                raw_type = first
        out_types[q] = {
            "type": q, "kind": t.kind, "codable": ck,
            "file": main.src.rel if main else (t.exts[0].src.rel if t.exts else ""),
            "line": main.line if main else (t.exts[0].line if t.exts else 0),
            "conformances": sorted(t.conformances),
            "extension_sites": sorted({d.src.rel + ":" + str(d.line) for d in t.exts}),
            "coding_keys": coding_keys, "explicit_coding_keys": "CodingKeys" in coding_keys,
            "custom_init_from": custom_init, "custom_encode_to": custom_encode,
            "stored_properties": [{k: p[k] for k in ("name", "kw", "type", "has_default", "line", "wrappers")}
                                  for p in stored],
            "raw_type": raw_type,
            "custom_decode_modes": modes,
            "cases": list({c["name"]: c for c in reversed(cases)}.values())[::-1] if t.kind == "enum" else [],
        }

    # the type graph: stored property types and associated values
    edges = defaultdict(set)
    for q, rec in out_types.items():
        texts = [p["type"] for p in rec["stored_properties"]] + [c["assoc"] or "" for c in rec["cases"]]
        for txt in texts:
            for ident in TYPE_IDENT_RE.findall(txt):
                r = resolve(ident, q, out_types)
                if r and r != q:
                    edges[q].add(r)
    ALIASES.update(typealiases(srcs))
    consts = collect_constants(srcs, decls_by_file)
    dsites = scan_defaults(srcs, decls_by_file, consts, types)
    roots = defaultdict(set)
    for d in dsites:
        for e in d["raw_value_enums"]:
            if e not in out_types and e in types and types[e].kind == "enum":
                # not Codable, but its raw values are kept in UserDefaults: a persisted name all the same
                t = types[e]
                cs = []
                for d_ in t.decls + t.exts:
                    if d_.kind == "enum":
                        cs += parse_cases(d_.src, d_)
                first = t.main.conformances[0].split(".")[-1] if t.main and t.main.conformances else None
                out_types[e] = {
                    "type": e, "kind": "enum", "codable": "no (RawRepresentable, kept in UserDefaults)",
                    "file": t.main.src.rel, "line": t.main.line, "conformances": sorted(t.conformances),
                    "extension_sites": [], "coding_keys": {}, "explicit_coding_keys": False,
                    "custom_init_from": False, "custom_encode_to": False, "stored_properties": [],
                    "raw_type": first if first in RAW_TYPES else None, "custom_decode_modes": {}, "cases": cs}
            if e in out_types:
                roots["UserDefaults raw values"].add(e)
    for f in FORMATS:
        for r in f["roots"]:
            if r.startswith("@file:"):
                for q, rec in out_types.items():
                    if rec["file"] == r[len("@file:"):]:
                        roots[f["id"]].add(q)
            elif r in out_types:
                roots[f["id"]].add(r)
    reach = defaultdict(set)
    via = {}
    for fid, rs in roots.items():
        stack = [(x, x) for x in rs]
        seen = set()
        while stack:
            x, path = stack.pop()
            if x in seen:
                continue
            seen.add(x)
            reach[x].add(fid)
            via.setdefault((x, fid), path)
            stack += [(y, path + " > " + y) for y in edges.get(x, ())]
    missing_roots = [{"format": f["id"], "root": r} for f in FORMATS for r in f["roots"]
                     if not r.startswith("@file:") and r not in out_types]
    for q, rec in out_types.items():
        rec["formats"] = sorted(reach.get(q, ()))
        rec["via"] = {f: via[(q, f)] for f in rec["formats"]}
        rec["refs"] = sorted(edges.get(q, ()))

    fmt_class = {f["id"]: f["class"] for f in FORMATS}
    names = []
    for q, rec in out_types.items():
        fmts = rec["formats"]
        if not fmts:
            continue
        base = max(CLASS_WEIGHT[fmt_class[f]] for f in fmts)
        crown = max([CROWN.get(f, 0) for f in fmts] + [0])
        custom = rec["custom_init_from"] or rec["custom_encode_to"]
        ck = rec["coding_keys"].get("CodingKeys")

        def row(**kw):
            names.append(dict({"type": q, "file": rec["file"], "formats": fmts}, **kw))

        def mode_of(prop_name, typ):
            if rec["custom_init_from"]:
                return rec["custom_decode_modes"].get(prop_name, "not decoded")
            if rec["codable"] == "Encodable":
                return "encoded only"
            t_ = (typ or "").strip()
            return "optional" if (t_.endswith("?") or t_.startswith("Optional<")) else "required"

        def score(mode, pinned):
            if pinned:
                return 0
            return base + crown + SEVERITY.get(mode, 0)

        if rec["kind"] == "enum":
            if rec["raw_type"] == "String":
                for c in rec["cases"]:
                    explicit = bool(c["raw"])
                    row(name=c["name"], key=c["raw"].get("string", c["name"]) if explicit else c["name"],
                        what="enum case, String raw value " + ("explicit" if explicit else "implicit (= case name)"),
                        mode="value", pinned=explicit, line=c["line"], score=score("value", explicit))
            elif rec["raw_type"]:
                for c in rec["cases"]:
                    row(name=c["name"], key=(c["raw"] or {}).get("literal", "<ordinal>"),
                        what="enum case, %s raw value %s (the number is stored; the case name is not, its order is)" %
                             (rec["raw_type"], "explicit" if c["raw"] else "implicit"),
                        mode="ordinal", pinned=True, line=c["line"], score=0)
            elif not custom:
                lit = {x["case"]: x for x in (ck or {}).get("cases", [])}
                for c in rec["cases"]:
                    k = lit.get(c["name"])
                    pinned = bool(k and k["explicit"])
                    row(name=c["name"], key=k["key"] if k else c["name"],
                        what="enum case name = " + ("CodingKeys literal" if pinned else "synthesized key") +
                             " (associated values" + (": " + c["assoc"] if c["assoc"] else ", none") + ")",
                        mode="value", pinned=pinned, line=c["line"],
                        score=score("value", pinned) + (0 if pinned else 2))
            else:
                for c in rec["cases"]:
                    row(name=c["name"], key="(custom coder)",
                        what="enum with a custom coder: the coder decides", mode="custom", pinned=True,
                        line=c["line"], score=0)
            continue
        if ck:
            in_ck = set()
            ptypes = {p["name"]: p["type"] for p in rec["stored_properties"]}
            for c in ck["cases"]:
                in_ck.add(c["case"])
                md = mode_of(c["case"], ptypes.get(c["case"], ""))
                row(name=c["case"], key=c["key"],
                    what="CodingKeys case, explicit literal" if c["explicit"] else
                         "CodingKeys case, implicit (key = case name)",
                    mode=md, pinned=c["explicit"], line=c["line"], file=ck["file"], score=score(md, c["explicit"]))
            for p in rec["stored_properties"]:
                if p["name"] not in in_ck:
                    row(name=p["name"], key=None, what="stored property not in CodingKeys: not persisted",
                        mode="-", pinned=True, line=p["line"], score=0)
        else:
            for p in rec["stored_properties"]:
                once = p["kw"] == "let" and p["has_default"]
                md = "encoded only" if once else mode_of(p["name"], p["type"])
                row(name=p["name"], key=p["name"],
                    what=("synthesized key = Swift property name" if not rec["custom_init_from"] else
                          "synthesized CodingKeys, custom init(from:): key = Swift property name") +
                         (" (let with a default: encoded, never decoded)" if once else ""),
                    mode=md, pinned=False, line=p["line"], score=score(md, False))
    for n in names:
        if n["score"] and n["type"].split(".")[0] in EDIT_CORE:
            n["score"] += 3

    decode_sites = []
    rx = re.compile(r"\.decode\(\s*([^,()]+?)\.self\s*,\s*from:")
    for s in srcs:
        for mo in rx.finditer(s.masked):
            texpr = s.text[mo.start(1):mo.end(1)].strip()
            owner = owner_of(decls_by_file[s.rel], mo.start())
            resolved = [r for r in (resolve(i, owner, out_types) for i in TYPE_IDENT_RE.findall(texpr)) if r]
            decode_sites.append({"file": s.rel, "line": s.line(mo.start()), "type_expr": texpr,
                                 "resolved": resolved, "in_a_format": any(reach.get(r) for r in resolved)})

    keys = defaultdict(list)
    for d in dsites:
        multi = d["key"] and "(each of)" in (d["resolved_by"] or "")
        for k in (d["key"].split(" | ") if multi else [d["key"]]):
            keys[k or ("<%s>" % d["expr"])].append("%s:%d" % (d["file"], d["line"]))
    used_multi = set(k for k in keys)
    used = {k for k in used_multi if not k.startswith("<")}
    prefixes = sorted({k.split(".")[0] + "." for k in used
                       if "." in k and re.fullmatch(r"[A-Za-z0-9_]+", k.split(".")[0])})
    candidates = []
    for (owner, name), c in sorted(consts.items(), key=lambda kv: (kv[1]["file"], kv[1]["line"])):
        v = c["value"] if c["value"] is not None else " | ".join(c.get("values", []))
        if v in used or re.search(r"\.(json|jsonl|heic|png|jpg|tif|tiff|cube|txt|log)$", v):
            continue
        if re.search(r"(?i)key$|defaults", name) or any(v.startswith(p) for p in prefixes):
            candidates.append({"owner": owner, "name": name, "value": v, "file": c["file"], "line": c["line"]})
    literal_hits = []
    for s in srcs:
        for st in s.strings:
            v = st["value"]
            near = s.text[max(0, st["start"] - 300):st["end"] + 300]
            if v not in used and any(v.startswith(p) for p in prefixes) and re.fullmatch(r"[\w.\-]+", v) \
                    and re.search(r"UserDefaults|forKey:|AppStorage|SceneStorage|defaults", near):
                literal_hits.append({"value": v, "file": s.rel, "line": s.line(st["start"])})

    # String enums with implicit raw values that the code turns into data (`X(rawValue:`, `X.y.rawValue`)
    # but that no format root reaches: their raw values travel as plain Strings (a sidecar's
    # `filmSide`, a wire value, a cache word), so renaming a case moves the data silently.
    raw_data = []
    for q, t in types.items():
        if t.kind != "enum" or not t.main or not t.main.conformances:
            continue
        if t.main.conformances[0].split(".")[-1] != "String":
            continue
        rec = out_types.get(q)
        if rec and rec["formats"]:
            continue
        cs = []
        for d_ in t.decls:
            cs += parse_cases(d_.src, d_)
        implicit = [c["name"] for c in cs if not c["raw"]]
        if not implicit:
            continue
        short = q.split(".")[-1]
        rx_use = re.compile(r"\b%s(?:\.init)?\(rawValue:|\b%s\.\w+\.rawValue\b" % (short, short))
        uses = []
        for s in srcs:
            for mo in rx_use.finditer(s.masked):
                uses.append("%s:%d" % (s.rel, s.line(mo.start())))
        if uses:
            raw_data.append({"type": q, "file": t.main.src.rel, "line": t.main.line,
                             "codable": bool(rec), "implicit_cases": implicit, "uses": uses})
    raw_data.sort(key=lambda x: (-len(x["uses"]), x["type"]))

    return {
        "tool": "persisted_names.py",
        "root": os.path.abspath(root),
        "swift_files": len(srcs),
        "formats": FORMATS,
        "missing_roots": missing_roots,
        "format_roots": {f: sorted(rs) for f, rs in roots.items()},
        "types": out_types,
        "names": sorted(names, key=lambda n: (-n["score"], n["type"], n["name"])),
        "decode_sites": decode_sites,
        "defaults_sites": dsites,
        "defaults_keys": dict(sorted(keys.items())),
        "defaults_key_prefixes": prefixes,
        "defaults_candidate_constants": candidates,
        "defaults_prefixed_literals": literal_hits,
        "engine_wire_literals": scan_wire_literals(srcs),
        "raw_values_as_data": raw_data,
        "limits": [
            "A Swift lexer, not the compiler: an extension of a nested type written with a short name, a "
            "typealias to Codable and generic wrappers are not resolved.",
            "The type graph follows stored-property and associated-value type names; a type encoded only "
            "through JSONSerialization or a hand-built dictionary is not reached.",
            "Format roots are a curated table (FORMATS); a decode site with in_a_format false is a root "
            "the table does not know. Encodable-only roots (a value passed to encode()) are curated only.",
            "UserDefaults receivers are recognised by name (defaults, UserDefaults, .standard, d, store); a "
            "key passed through a parameter is unresolved and its constant is listed under "
            "defaults_candidate_constants.",
        ],
    }


def summary(r):
    allt = r["types"]
    t = {q: x for q, x in allt.items() if x["codable"] in CODABLE}
    kinds = defaultdict(int)
    for x in t.values():
        kinds[x["kind"]] += 1
    s = {
        "swift_files": r["swift_files"],
        "codable_types": len(t),
        "codable_by_conformance": dict(sorted(defaultdict(int, {c: sum(1 for x in t.values() if x["codable"] == c)
                                                                for c in CODABLE}).items())),
        "non_codable_enums_kept_in_UserDefaults": len(allt) - len(t),
        "string_enums_whose_raw_values_are_data_but_reach_no_format": len(r["raw_values_as_data"]),
        "files_with_codable_types": len({x["file"] for x in t.values()}),
        "types_with_explicit_CodingKeys": sum(1 for x in t.values() if x["explicit_coding_keys"]),
        "types_with_custom_coder": sum(1 for x in t.values() if x["custom_init_from"] or x["custom_encode_to"]),
        "types_reaching_a_format": sum(1 for x in t.values() if x["formats"]),
        "types_reaching_no_format": sum(1 for x in t.values() if not x["formats"]),
        "persisted_names": sum(1 for n in r["names"] if n["key"] is not None),
        "pinned_names": sum(1 for n in r["names"] if n["key"] is not None and n["pinned"]),
        "unpinned_names": sum(1 for n in r["names"] if not n["pinned"]),
        "unpinned_names_in_user_files": sum(1 for n in r["names"] if not n["pinned"] and any(
            f in CROWN for f in n["formats"])),
        "defaults_sites": len(r["defaults_sites"]),
        "defaults_keys_resolved": sum(1 for k in r["defaults_keys"] if not k.startswith("<")),
        "defaults_keys_unresolved": sum(1 for k in r["defaults_keys"] if k.startswith("<")),
        "defaults_candidate_constants": len(r["defaults_candidate_constants"]),
        "engine_wire_literal_sites": len(r["engine_wire_literals"]),
        "engine_wire_fields_distinct": len({w["field"] for w in r["engine_wire_literals"] if w["channel"] == "engine-wire"}),
        "spklib_request_fields_distinct": len({w["field"] for w in r["engine_wire_literals"] if w["channel"] == "spklib-host"}),
        "codable_types_by_kind": dict(sorted(kinds.items())),
    }
    by_fmt = defaultdict(lambda: [0, 0])
    for n in r["names"]:
        if n["key"] is None:
            continue
        for f in n["formats"]:
            by_fmt[f][0] += 1
            by_fmt[f][1] += 0 if n["pinned"] else 1
    s["names_by_format"] = {f: {"names": a, "unpinned": b} for f, (a, b) in sorted(by_fmt.items())}
    return s


def key_paths(r, max_depth=14):
    """Every on-disk key path of every format, as the JSON spells it: `frames[].edit.params.filmStock`,
    an enum value as `...aspect=square`, an associated-value case as `...source.linkedFolder.disk`.
    Built from key strings only (never Swift type names), so it is stable across renames and
    precise where one key string occurs in many types (`luminance` in ColorZone and in HSLBand)."""
    types = r["types"]
    names_by_type = defaultdict(list)
    for n in r["names"]:
        names_by_type[n["type"]].append(n)

    def children(q, typ):
        out = []
        for ident in TYPE_IDENT_RE.findall(typ or ""):
            c = resolve(ident, q, types)
            if c:
                out.append((c, "[]" if ("[" in typ and ":" not in typ) else ("{}" if ("[" in typ and ":" in typ) else "")))
        return out

    paths = set()

    def walk(fmt, q, prefix, depth, onpath):
        rec = types[q]
        if depth > max_depth or q in onpath:
            paths.add((fmt, prefix + "…"))
            return
        onpath = onpath | {q}
        if rec["kind"] == "enum":
            for c in rec["cases"]:
                if rec["raw_type"] == "String":
                    raw = (c["raw"] or {}).get("string", c["name"]) if c["raw"] else c["name"]
                    paths.add((fmt, prefix + "=" + raw))
                elif rec["raw_type"]:
                    paths.add((fmt, prefix + "=" + (c["raw"] or {}).get("literal", "#%d" % rec["cases"].index(c))))
                elif not (rec["custom_init_from"] or rec["custom_encode_to"]):
                    # SE-0295: `CodingKeys` names the cases, `<Case>CodingKeys` the labels (`_0` unlabelled)
                    cks = rec.get("coding_keys", {})
                    case_key = {x["case"]: x["key"] for x in cks.get("CodingKeys", {}).get("cases", [])}
                    label_key = {x["case"]: x["key"] for x in
                                 cks.get(c["name"][:1].upper() + c["name"][1:] + "CodingKeys", {}).get("cases", [])}
                    base = prefix + "." + case_key.get(c["name"], c["name"])
                    paths.add((fmt, base))
                    for i, part in enumerate(split_top(c["assoc"] or "")):
                        lab = re.match(r"\s*(\w+)\s*:", part)
                        key = label_key.get(lab.group(1) if lab else "_%d" % i, lab.group(1) if lab else "_%d" % i)
                        typ = part[lab.end():] if lab else part
                        paths.add((fmt, base + "." + key))
                        for ch, suf in children(q, typ):
                            walk(fmt, ch, base + "." + key + suf, depth + 1, onpath)
            return
        ptypes = {p["name"]: p["type"] for p in rec["stored_properties"]}
        for n in names_by_type.get(q, []):
            if n["key"] is None or n["key"].startswith("("):
                continue
            p = prefix + "." + n["key"]
            paths.add((fmt, p))
            for ch, suf in children(q, ptypes.get(n["name"], "")):
                walk(fmt, ch, p + suf, depth + 1, onpath)

    for f in r["formats"]:
        for root in r.get("format_roots", {}).get(f["id"], []):
            if root in types:
                walk(f["id"], root, "$", 0, frozenset())
    return paths


def persisted_key_set(r):
    """What `--check` compares: (format, key string, kind) for every persisted name, every resolved
    UserDefaults key and every engine wire literal. Swift type names are left out on purpose: a rename
    moves them, and only the strings on disk must stay."""
    out = set()
    for f, p in key_paths(r):
        out.add((f, p, "path"))
    for k in r["defaults_keys"]:
        if not k.startswith("<"):
            out.add(("UserDefaults", k, "key"))
    for w in r["engine_wire_literals"]:
        out.add((w.get("channel", "engine-wire"), w["field"], "literal"))
    return out


MODE_WORDS = {"required": "throws: file unreadable", "value": "throws on that value",
              "optional": "silently resets it", "not decoded": "never reads it", "encoded only": "never reads it"}


def md_escape(s):
    return str(s).replace("|", "\\|")


def markdown(r, top):
    s = r["summary"]
    L = ["<!-- generated by tools/persisted_names.py from %s -->" % r["root"], "", "### Totals", ""]
    for k, v in s.items():
        if not isinstance(v, dict):
            L.append("- %s: **%s**" % (k.replace("_", " "), v))
    L.append("- codable types by kind: " + ", ".join("%s %d" % kv for kv in s["codable_types_by_kind"].items()))
    L += ["", "| format | persisted names | unpinned |", "|---|---:|---:|"]
    for f, v in s["names_by_format"].items():
        L.append("| `%s` | %d | %d |" % (f, v["names"], v["unpinned"]))
    L += ["", "### The riskiest %d unpinned names (by score)" % top, "",
          "| # | score | type.name | on-disk key | if renamed, a reader | what | formats | file:line |",
          "|---:|---:|---|---|---|---|---|---|"]
    for i, n in enumerate([n for n in r["names"] if not n["pinned"]][:top], 1):
        L.append("| %d | %d | `%s.%s` | `%s` | %s | %s | %s | `%s:%d` |" % (
            i, n["score"], n["type"], n["name"], md_escape(n["key"]), MODE_WORDS.get(n["mode"], n["mode"]),
            md_escape(n["what"]),
            ", ".join(n["formats"]), n["file"], n["line"]))
    L += ["", "### Every Codable type", "",
          "| type | kind | coder | CodingKeys | custom coder | unpinned names | reaches | file:line |",
          "|---|---|---|---|---|---:|---|---|"]
    unp = defaultdict(int)
    for n in r["names"]:
        if not n["pinned"]:
            unp[n["type"]] += 1
    for q, x in sorted(r["types"].items(), key=lambda kv: (kv[1]["file"], kv[1]["line"])):
        L.append("| `%s` | %s%s | %s | %s | %s | %s | %s | `%s:%d` |" % (
            q, x["kind"], (": " + x["raw_type"]) if x["raw_type"] else "", x["codable"],
            "yes" if x["explicit_coding_keys"] else "no",
            "yes" if (x["custom_init_from"] or x["custom_encode_to"]) else "",
            unp.get(q, 0) if x["formats"] else "-",
            ", ".join(x["formats"]) or "(none found)", x["file"], x["line"]))
    L += ["", "### Unpinned names per type (the keys a rename would move)", ""]
    per = defaultdict(list)
    for n in r["names"]:
        if not n["pinned"]:
            per[n["type"]].append(n["key"])
    for q in sorted(per, key=lambda q: (r["types"][q]["file"], q)):
        x = r["types"][q]
        L.append("- `%s` (%s; %s): %s" % (q, x["file"], ", ".join(x["formats"]),
                                          ", ".join("`%s`" % k for k in per[q])))
    L += ["", "### UserDefaults / @AppStorage / @SceneStorage keys", "", "| key | sites |", "|---|---|"]
    for k, v in r["defaults_keys"].items():
        L.append("| `%s` | %s |" % (md_escape(k), ", ".join("`%s`" % x for x in v)))
    if r["defaults_candidate_constants"]:
        L += ["", "Key-like string constants no call site resolved to (reached through a parameter or a "
                  "loop, or dead):", "", "| constant | value | file:line |", "|---|---|---|"]
        for c in r["defaults_candidate_constants"]:
            L.append("| `%s.%s` | `%s` | `%s:%d` |" % (c["owner"] or "(global)", c["name"], md_escape(c["value"]),
                                                     c["file"], c["line"]))
    if r["defaults_prefixed_literals"]:
        L += ["", "Literal strings with a known key prefix (%s) outside any defaults call:" %
              ", ".join("`%s`" % p for p in r["defaults_key_prefixes"]), ""]
        seen = defaultdict(list)
        for h in r["defaults_prefixed_literals"]:
            seen[h["value"]].append("%s:%d" % (h["file"], h["line"]))
        for v, w in sorted(seen.items()):
            L.append("- `%s`: %s" % (v, ", ".join("`%s`" % x for x in w[:4]) + (" …" if len(w) > 4 else "")))
    for ch, title in (("engine-wire", "Engine wire literals (`params_delta` and friends)"),
                      ("spklib-host", "spklib-host request field literals")):
        fields = defaultdict(set)
        for w in r["engine_wire_literals"]:
            if w.get("channel", "engine-wire") == ch:
                fields[w["field"]].add(w["file"])
        L += ["", "### %s: %d distinct" % (title, len(fields)), ""]
        L.append(", ".join("`%s`" % f for f in sorted(fields)))
    L += ["", "### String enums whose implicit raw values are used as data (no format root reaches them)", "",
          "Their raw values travel as plain Strings (a sidecar String field, a wire value, a cache word). "
          "Renaming a case moves the stored value unless the case carries an explicit literal.",
          "", "| enum | Codable | implicit cases | rawValue uses | file:line |", "|---|---|---|---:|---|"]
    for x in r["raw_values_as_data"]:
        L.append("| `%s` | %s | %s | %d (%s) | `%s:%d` |" % (
            x["type"], "yes" if x["codable"] else "no", ", ".join("`%s`" % c for c in x["implicit_cases"][:12]) +
            (" …" if len(x["implicit_cases"]) > 12 else ""), len(x["uses"]),
            ", ".join("`%s`" % u for u in x["uses"][:3]) + (" …" if len(x["uses"]) > 3 else ""), x["file"], x["line"]))
    L += ["", "### `decode(X.self, from:)` sites outside every format root", ""]
    for d in r["decode_sites"]:
        if not d["in_a_format"]:
            L.append("- `%s:%d` `%s`" % (d["file"], d["line"], d["type_expr"]))
    if r["missing_roots"]:
        L += ["", "Format roots not found in this tree: " +
              ", ".join("`%s` (%s)" % (m["root"], m["format"]) for m in r["missing_roots"])]
    return "\n".join(L) + "\n"


def apply_rename_map(path):
    """Rewrite FORMATS' roots through a rename map (type and file rows); returns the changes."""
    types, files = {}, {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 3:
                continue
            kind, old, new = cols[0].strip(), cols[1].strip(), cols[2].strip()
            if kind == "type":
                types[old] = new
            elif kind == "file":
                files[old] = new
    changed = []
    for f in FORMATS:
        roots = []
        for r in f["roots"]:
            n = r
            if r.startswith("@file:"):
                n = "@file:" + files.get(r[len("@file:"):], r[len("@file:"):])
            else:
                seg = r.split(".")
                out = list(seg)
                for i in range(len(seg)):              # a qualified row first, then a simple-name row
                    q = ".".join(seg[:i + 1])
                    if q in types:
                        out[i] = types[q].split(".")[-1]
                    elif seg[i] in types:
                        out[i] = types[seg[i]].split(".")[-1]
                seg = out
                n = ".".join(seg)
            if n != r:
                changed.append((f["id"], r, n))
            roots.append(n)
        f["roots"] = roots
    return changed


# What the baseline holds: the person's own files, the engine's and spklib-host's messages, the defaults.
BASELINE_FORMATS = {
    "library.json", "MacLibrary/sources.json", "MacLibrary/pairs.json", "MacLibrary/moved.json", ".spektrapair",
    "look-presets.json", "export-recipes.json", "lighttable.json", "defaults:scheduler.costCorrections.v1",
    "UserDefaults", "UserDefaults raw values", "engine-wire", "spklib-host",
}


def read_baseline(path):
    """(rows, retired): rows as (format, key, kind); retired maps a row to why it may be gone."""
    rows, retired = set(), {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            k = (cols[0], cols[1], cols[2])
            rows.add(k)
            if len(cols) > 3 and cols[3].startswith("retired:"):
                retired[k] = cols[3]
    return rows, retired


def write_baseline(path, rows, retired):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# persisted_names_baseline.tsv -- every key, value, defaults key and wire field the app keeps.\n"
                 "# format<TAB>key<TAB>kind[<TAB>retired: why]. Written by tools/persisted_names.py --write-baseline;\n"
                 "# a row is removed or marked retired by hand, with the reason, never to make the check pass.\n")
        for k in sorted(rows):
            fh.write("\t".join(k) + ("\t" + retired[k] if k in retired else "") + "\n")


def main():
    ap = argparse.ArgumentParser(description="the persisted names a rename must not move")
    ap.add_argument("sources", help="the app's Sources/ directory")
    ap.add_argument("--json")
    ap.add_argument("--markdown")
    ap.add_argument("--top", type=int, default=20)
    ap.add_argument("--check", help="a baseline JSON from this tool: exit 1 if a persisted key disappeared")
    ap.add_argument("--rename-map", help="an old->new map (type/file rows): the format roots follow it")
    ap.add_argument("--write-baseline", help="with --check: the tree's keys as a baseline, retired rows kept")
    a = ap.parse_args()
    if not os.path.isdir(a.sources):
        sys.exit("not a directory: " + a.sources)
    if a.rename_map:
        for fid, old, new in apply_rename_map(a.rename_map):
            print("root  %-38s %s -> %s" % (fid, old, new))
    r = analyse(a.sources)
    r["key_paths"] = sorted("%s  %s" % fp for fp in key_paths(r))
    r["summary"] = summary(r)
    r["summary"]["on_disk_key_paths"] = len(r["key_paths"])
    if a.json:
        with open(a.json, "w", encoding="utf-8") as fh:
            json.dump(r, fh, indent=1, ensure_ascii=False)
    if a.markdown:
        with open(a.markdown, "w", encoding="utf-8") as fh:
            fh.write(markdown(r, a.top))
    if a.check:
        if a.check.endswith(".tsv"):
            before, retired = read_baseline(a.check)
        else:                                   # a --json dump of the tool, every format
            with open(a.check, encoding="utf-8") as fh:
                before, retired = persisted_key_set(json.load(fh)), {}
        now = persisted_key_set(r)
        after = {k for k in now if k[0] in BASELINE_FORMATS} if a.check.endswith(".tsv") else now
        gone = sorted(k for k in before - after if k not in retired)
        new = sorted(after - before - set(retired))
        back = sorted(k for k in retired if k in after)
        for g in gone:
            print("GONE  %-38s %-44s %s" % g)
        for g in new:
            print("new   %-38s %-44s %s" % g)
        for g in back:
            print("back  %-38s %-44s %s  (a retired word is produced again)" % g)
        for m in r.get("missing_roots", []):
            print("MISSING ROOT  %-30s %s  (renamed? pass --rename-map; deleted? its keys show as GONE)"
                  % (m["format"], m["root"]))
        if a.write_baseline:
            write_baseline(a.write_baseline, after | set(retired), retired)
            print("baseline written: %s" % a.write_baseline)
        print("persisted names: %d in the baseline (%d retired), %d in the tree; %d gone, %d new"
              % (len(before), len(retired), len(after), len(gone), len(new)))
        sys.exit(1 if gone else 0)
    if not a.json and not a.markdown:
        print(json.dumps(r["summary"], indent=1))


if __name__ == "__main__":
    main()
