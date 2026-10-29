#!/usr/bin/env python3
"""The process gate for the Windows_Linux branch (RFC-W001).

Three checks, each of which a person can run before pushing and CI runs on
every push and pull request:

  docs   PRD / RFC / ADR documents under docs/: file names, front matter,
         status vocabulary, required sections, index rows, cross references,
         relative links, and that every spec-sync rule is documented.
  audit  docs/reference-audit.md: the reference pin (repository, branches,
         40-hex SHAs, date), and the compliance matrix -- six columns, a fixed
         applicability vocabulary, a written reason for every rule that is not
         adopted as is, and code/test paths that exist.
  sync   Over a git range: an interface change edits its specification in the
         same range (tools/process/sync_rules.json), unless a commit carries
         `Spec-Sync-Waiver: <rule>: <reason>`. Code commits without a recorded
         gate (a `Gate:` / `Test:` line) are reported as warnings.

Standard library only; Python >= 3.10; Windows and Linux.

    python tools/process/check_process.py all [--base REF] [--head REF]
    python tools/process/check_process.py docs
    python tools/process/check_process.py audit
    python tools/process/check_process.py sync --base origin/Windows_Linux [--worktree]

Exit status: 0 no errors, 1 errors found, 2 the check could not run (no git
for `sync`, an unknown ref, a malformed rules file). A check that cannot run
never reports success.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RULES_FILE = Path("tools/process/sync_rules.json")
PROCESS_DOC = Path("docs/process/DEVELOPMENT-PROCESS.md")
AUDIT_DOC = Path("docs/reference-audit.md")

# --------------------------------------------------------------------------
# Findings


@dataclass(frozen=True)
class Finding:
    code: str
    path: str
    line: int
    message: str
    severity: str = "error"  # "error" | "warning"

    def render(self) -> str:
        where = f"{self.path}:{self.line}" if self.line else self.path
        return f"{where}: {self.severity} {self.code} {self.message}"


class CheckUnavailable(Exception):
    """The check could not run. Exit 2, never 0."""


@dataclass
class Report:
    findings: list[Finding] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def add(self, code: str, path: Path | str, line: int, message: str, severity: str = "error") -> None:
        self.findings.append(Finding(code, str(path).replace("\\", "/"), line, message, severity))

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "error"]

    def codes(self) -> set[str]:
        return {f.code for f in self.findings}


# --------------------------------------------------------------------------
# Markdown helpers

FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
LINK = re.compile(r"\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SHA40 = re.compile(r"\b[0-9a-f]{40}\b")
SHA_ANY = re.compile(r"^[0-9a-f]{7,40}$")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_code(lines: list[str]) -> list[str]:
    """Blank out fenced blocks and inline code so prose checks do not see them."""
    out, fenced = [], False
    for line in lines:
        if FENCE.match(line):
            fenced = not fenced
            out.append("")
            continue
        out.append("" if fenced else INLINE_CODE.sub("``", line))
    return out


def parse_front_matter(text: str) -> tuple[dict[str, object] | None, int]:
    """A deliberately small YAML subset: `key: value`, `key: [a, b]`, and
    `key:` followed by `  - item` lines. Returns (mapping, body start line)."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, 0
    data: dict[str, object] = {}
    current_list: list[str] | None = None
    for i, raw in enumerate(lines[1:], start=1):
        if raw.strip() == "---":
            return data, i + 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        item = re.match(r"^\s+-\s+(.*)$", raw)
        if item and current_list is not None:
            current_list.append(_unquote(item.group(1)))
            continue
        kv = re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$", raw)
        if not kv:
            return None, 0
        key, value = kv.group(1), kv.group(2).strip()
        if value == "":
            current_list = []
            data[key] = current_list
        elif value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            data[key] = [_unquote(v) for v in inner.split(",")] if inner else []
            current_list = None
        else:
            data[key] = _unquote(value)
            current_list = None
    return None, 0


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def h2_sections(lines: list[str], start: int) -> list[tuple[int, str, list[str]]]:
    """(1-based line, heading text, body lines) for each `## ` heading after `start`."""
    sections: list[tuple[int, str, list[str]]] = []
    fenced = False
    for i in range(start, len(lines)):
        line = lines[i]
        if FENCE.match(line):
            fenced = not fenced
        if not fenced and line.startswith("## "):
            sections.append((i + 1, line[3:].strip(), []))
        elif sections:
            sections[-1][2].append(line)
    return sections


def is_empty_body(body: list[str]) -> bool:
    text = HTML_COMMENT.sub("", "\n".join(body))
    return not any(l.strip() and not l.strip().startswith("#") for l in text.splitlines())


def table_rows(lines: list[str], start: int) -> list[tuple[int, list[str]]]:
    """Rows of the markdown table starting at `start` (its header), excluding the
    separator. Cells are stripped; `\\|` is kept as a literal pipe."""
    rows = []
    i = start
    while i < len(lines) and lines[i].lstrip().startswith("|"):
        cells = split_row(lines[i])
        if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c) or not any(cells):
            rows.append((i + 1, cells))
        i += 1
    return rows


def split_row(line: str) -> list[str]:
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|"):
        s = s[:-1]
    parts = re.split(r"(?<!\\)\|", s)
    return [p.replace("\\|", "|").strip() for p in parts]


# --------------------------------------------------------------------------
# docs

KINDS = {
    "prd": {
        "dir": Path("docs/prd"),
        "prefix": "PRD",
        "keys": ["id", "title", "status", "owner", "created", "updated", "baseline"],
        "statuses": ["Draft", "Review", "Approved", "Building", "Shipped", "Withdrawn"],
        "draft": {"Draft"},
        "sections": ["Background", "Goals", "Requirements", "Windows conventions", "Constraints",
                     "Acceptance", "Measurements", "Decisions", "Open questions", "Out of scope"],
    },
    "rfc": {
        "dir": Path("docs/rfc"),
        "prefix": "RFC",
        "keys": ["id", "title", "status", "owner", "created", "updated", "baseline", "prd"],
        "statuses": ["Draft", "Review", "Accepted", "Implemented", "Superseded", "Rejected", "Withdrawn"],
        "draft": {"Draft"},
        "sections": ["Summary", "Context", "Design", "Contracts", "Impact", "Test plan",
                     "Alternatives", "Rollout", "Decision log", "Open questions"],
    },
    "adr": {
        "dir": Path("docs/adr"),
        "prefix": "ADR",
        "keys": ["id", "title", "status", "date", "deciders"],
        "statuses": ["Proposed", "Accepted", "Superseded", "Rejected"],
        "draft": {"Proposed"},
        "sections": ["Context", "Decision", "Consequences", "Alternatives"],
    },
}
DOC_NAME = re.compile(r"^(PRD|RFC|ADR)-W(\d{3})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
DOC_ID = re.compile(r"\b(PRD|RFC|ADR)-W\d{3}\b")
NON_DOCS = {"README.md", "TEMPLATE.md"}


def check_docs(root: Path, report: Report) -> None:
    docs: dict[str, dict] = {}  # id -> {path, kind, fm}
    for kind, spec in KINDS.items():
        directory = root / spec["dir"]
        if not directory.is_dir():
            report.add("DOC000", spec["dir"], 0, "directory is missing")
            continue
        index = directory / "README.md"
        if not index.is_file():
            report.add("DOC000", spec["dir"] / "README.md", 0, "index is missing")
        if not (directory / "TEMPLATE.md").is_file():
            report.add("DOC000", spec["dir"] / "TEMPLATE.md", 0, "template is missing")
        for path in sorted(directory.iterdir()):
            if path.is_dir() or path.name in NON_DOCS:
                continue
            rel = path.relative_to(root)
            m = DOC_NAME.match(path.name)
            if not m or m.group(1) != spec["prefix"]:
                report.add("DOC001", rel, 0,
                           f"file name must be {spec['prefix']}-Wnnn-lower-case-slug.md")
                continue
            doc_id = f"{m.group(1)}-W{m.group(2)}"
            if doc_id in docs:
                report.add("DOC016", rel, 0, f"{doc_id} is also {docs[doc_id]['path']}")
                continue
            fm = _check_one_doc(root, rel, kind, spec, doc_id, report)
            docs[doc_id] = {"path": rel, "kind": kind, "fm": fm or {}}
        if index.is_file():
            _check_index(root, index.relative_to(root), spec, docs, report)
    _check_cross_refs(root, docs, report)
    check_links(root, report)
    _check_rules_documented(root, report)


def _check_one_doc(root: Path, rel: Path, kind: str, spec: dict, doc_id: str, report: Report):
    text = read_text(root / rel)
    lines = text.splitlines()
    fm, body_start = parse_front_matter(text)
    if fm is None:
        report.add("DOC002", rel, 1, "front matter (--- key: value ---) is missing or malformed")
        return None
    for key in spec["keys"]:
        if key not in fm or fm[key] in ("", []):
            report.add("DOC003", rel, 1, f"front matter key `{key}` is missing or empty")
    if fm.get("id") and fm["id"] != doc_id:
        report.add("DOC004", rel, 1, f"id `{fm['id']}` does not match the file name ({doc_id})")
    status = fm.get("status")
    if isinstance(status, str) and status not in spec["statuses"]:
        report.add("DOC005", rel, 1, f"status `{status}` is not one of {', '.join(spec['statuses'])}")
    for key in ("created", "updated", "date"):
        value = fm.get(key)
        if isinstance(value, str) and value and not DATE.match(value):
            report.add("DOC006", rel, 1, f"`{key}` must be YYYY-MM-DD")
    if isinstance(fm.get("created"), str) and isinstance(fm.get("updated"), str):
        if DATE.match(fm["created"]) and DATE.match(fm["updated"]) and fm["updated"] < fm["created"]:
            report.add("DOC006", rel, 1, "`updated` is earlier than `created`")
    baseline = fm.get("baseline")
    if isinstance(baseline, str) and baseline and not SHA_ANY.match(baseline):
        report.add("DOC006", rel, 1, "`baseline` must be the commit SHA the document was written against")
    is_draft = status in spec["draft"]
    sections = h2_sections(lines, body_start)
    for keyword in spec["sections"]:
        hit = [s for s in sections if keyword.lower() in s[1].lower()]
        if not hit:
            report.add("DOC007", rel, 0, f"required section `{keyword}` is missing")
        elif is_empty_body(hit[0][2]):
            report.add("DOC008", rel, hit[0][0], f"section `{keyword}` is empty",
                       "warning" if is_draft else "error")
    if not is_draft:
        # Guidance comments may quote the placeholder syntax; keep line numbers.
        uncommented = HTML_COMMENT.sub(lambda m: "\n" * m.group(0).count("\n"), text)
        prose = strip_code(uncommented.splitlines())
        for n, line in enumerate(prose, start=1):
            if "{{" in line:
                report.add("DOC009", rel, n, "template placeholder left in a document past Draft")
                break
    return fm


def _check_index(root: Path, index_rel: Path, spec: dict, docs: dict, report: Report) -> None:
    lines = read_text(root / index_rel).splitlines()
    rows: dict[str, tuple[int, str]] = {}
    for n, line in enumerate(lines, start=1):
        if not line.lstrip().startswith("|"):
            continue
        for m in re.finditer(rf"\[({spec['prefix']}-W\d{{3}})\]\(([^)]+)\)", line):
            rows[m.group(1)] = (n, line)
            target = (root / index_rel.parent / m.group(2)).resolve()
            if not target.is_file():
                report.add("DOC012", index_rel, n, f"index row {m.group(1)} links to a missing file")
    for doc_id, info in docs.items():
        if not doc_id.startswith(spec["prefix"]):
            continue
        if doc_id not in rows:
            report.add("DOC010", index_rel, 0, f"{doc_id} ({info['path']}) has no row in the index")
            continue
        status = info["fm"].get("status") if info["fm"] else None
        n, line = rows[doc_id]
        if isinstance(status, str) and status not in [c.strip("* ") for c in split_row(line)]:
            report.add("DOC011", index_rel, n, f"{doc_id}: the index does not say `{status}`")


def _check_cross_refs(root: Path, docs: dict, report: Report) -> None:
    for doc_id, info in docs.items():
        fm, rel = info["fm"], info["path"]
        if not fm:
            continue
        if info["kind"] == "rfc":
            prd = fm.get("prd")
            values = prd if isinstance(prd, list) else [prd] if prd else []
            for value in values:
                if re.fullmatch(r"PRD-W\d{3}", value or ""):
                    if value not in docs:
                        report.add("DOC014", rel, 1, f"prd `{value}` does not exist")
                elif not re.match(r"^none\s*[:—-]\s*\S.{7,}", value or ""):
                    report.add("DOC014", rel, 1,
                               "prd must name PRD-Wnnn, or say `none: <why this module needs no PRD>`")
            if fm.get("status") == "Implemented":
                tests = fm.get("tests")
                tests = tests if isinstance(tests, list) else [tests] if tests else []
                if not tests:
                    report.add("DOC015", rel, 1, "an Implemented RFC lists the tests that hold it (`tests:`)")
                for t in tests:
                    if not path_exists(root, t):
                        report.add("DOC015", rel, 1, f"test path `{t}` does not exist")
        for key in ("rfcs", "rfc", "superseded_by", "supersedes"):
            value = fm.get(key)
            for ref in (value if isinstance(value, list) else [value] if value else []):
                if DOC_ID.fullmatch(ref or "") and ref not in docs:
                    report.add("DOC014", rel, 1, f"{key} `{ref}` does not exist")
        if fm.get("status") == "Superseded" and not fm.get("superseded_by"):
            report.add("DOC014", rel, 1, "a Superseded document names its successor (`superseded_by:`)")


def iter_markdown(root: Path):
    base = root / "docs"
    if base.is_dir():
        yield from sorted(base.rglob("*.md"))
    template = root / ".github" / "pull_request_template.md"
    if template.is_file():
        yield template


def check_links(root: Path, report: Report) -> None:
    for path in iter_markdown(root):
        rel = path.relative_to(root)
        lines = strip_code(read_text(path).splitlines())
        for n, line in enumerate(lines, start=1):
            for m in LINK.finditer(line):
                target = m.group(1)
                if re.match(r"^[a-z][a-z0-9+.-]*:", target, re.I) or target.startswith("#"):
                    continue
                target = target.split("#", 1)[0]
                if not target:
                    continue
                resolved = (path.parent / target).resolve()
                if not resolved.exists():
                    report.add("DOC013", rel, n, f"link target `{m.group(1)}` does not exist")


def _check_rules_documented(root: Path, report: Report) -> None:
    rules_path = root / RULES_FILE
    doc = root / PROCESS_DOC
    if not rules_path.is_file():
        return
    rule_ids = {r["id"] for r in load_rules(root)}
    if not doc.is_file():
        report.add("DOC017", PROCESS_DOC, 0, "the process document is missing")
        return
    documented = set(re.findall(r"`sync:([a-z0-9-]+)`", read_text(doc)))
    for missing in sorted(rule_ids - documented):
        report.add("DOC017", PROCESS_DOC, 0, f"spec-sync rule `sync:{missing}` is not documented")
    for extra in sorted(documented - rule_ids):
        report.add("DOC017", PROCESS_DOC, 0, f"`sync:{extra}` is documented but is not in {RULES_FILE.as_posix()}")


# --------------------------------------------------------------------------
# audit

APPLICABILITY = ("完全适用", "调整后适用", "经评估后不适用")
AUDIT_HEADER = ["ID", "SpektraLab规范", "本项目如何采用", "是否完全适用", "调整理由", "对应代码/测试"]
AUDIT_ID = re.compile(r"^[A-Z]{1,3}-\d{2,3}$")
EMPTY_REASON = {"", "—", "-", "–", "n/a", "N/A", "无"}
PATH_EXT = re.compile(r"\.(md|py|ts|tsx|rs|cpp|hpp|h|c|json|yml|yaml|ps1|sh|mjs|toml|cmake|txt|swift|qml|comp|glsl|svg|png)$")
COUNTS = re.compile(r"<!--\s*audit-counts:\s*total=(\d+)\s+full=(\d+)\s+adjusted=(\d+)\s+na=(\d+)\s*-->")
PIN_ROW = re.compile(r"`([A-Za-z0-9_./-]+)`\s*@\s*`([0-9a-f]{40})`")


def check_audit(root: Path, report: Report) -> None:
    path = root / AUDIT_DOC
    if not path.is_file():
        report.add("AUD000", AUDIT_DOC, 0, "the reference audit is missing")
        return
    text = read_text(path)
    lines = text.splitlines()
    _check_pin(root, lines, report)
    ids: dict[str, int] = {}
    counts = {"full": 0, "adjusted": 0, "na": 0}
    tables = 0
    for n, line in enumerate(lines):
        cells = split_row(line) if line.lstrip().startswith("|") else []
        if not cells or "SpektraLab规范" not in cells:
            continue
        tables += 1
        if cells != AUDIT_HEADER:
            report.add("AUD003", AUDIT_DOC, n + 1, "matrix header must be: " + " | ".join(AUDIT_HEADER))
            continue
        for row_line, row in table_rows(lines, n)[1:]:
            _check_row(root, row_line, row, ids, counts, report)
    if tables == 0:
        report.add("AUD003", AUDIT_DOC, 0, "no compliance matrix table found")
    m = COUNTS.search(text)
    total = sum(counts.values())
    if not m:
        report.add("AUD010", AUDIT_DOC, 0,
                   f"counts marker missing; expected <!-- audit-counts: total={total} full={counts['full']} "
                   f"adjusted={counts['adjusted']} na={counts['na']} -->")
    else:
        stated = tuple(int(x) for x in m.groups())
        actual = (total, counts["full"], counts["adjusted"], counts["na"])
        if stated != actual:
            line_no = text[: m.start()].count("\n") + 1
            report.add("AUD010", AUDIT_DOC, line_no,
                       f"counts marker says total/full/adjusted/na = {stated}, the matrix has {actual}")
    report.notes.append(f"audit: {total} rules -- {counts['full']} adopted as is, "
                        f"{counts['adjusted']} adjusted, {counts['na']} evaluated as not applicable")


def _check_pin(root: Path, lines: list[str], report: Report) -> None:
    text = "\n".join(lines)
    if "https://github.com/JamesQiu2005/SpektraLab" not in text:
        report.add("AUD001", AUDIT_DOC, 0, "the reference repository URL is missing")
    if not re.search(r"检查日期[^\n|]*\|\s*\d{4}-\d{2}-\d{2}", text):
        report.add("AUD001", AUDIT_DOC, 0, "the check date (检查日期 | YYYY-MM-DD) is missing")
    pins = [(i + 1, m.group(1), m.group(2)) for i, l in enumerate(lines) for m in PIN_ROW.finditer(l)]
    branches = {b for _, b, _ in pins}
    for needed in ("main", "Windows_Linux"):
        if needed not in branches:
            report.add("AUD001", AUDIT_DOC, 0, f"no pin of the form `{needed}` @ `<40-hex SHA>`")
    if git_available(root):
        for line_no, branch, sha in pins:
            if run_git(root, ["cat-file", "-e", f"{sha}^{{commit}}"], check=False).returncode != 0:
                report.add("AUD002", AUDIT_DOC, line_no,
                           f"`{branch}` @ {sha[:12]} is not a commit in this repository's history",
                           "warning")


def _check_row(root: Path, line_no: int, row: list[str], ids: dict, counts: dict, report: Report) -> None:
    if len(row) != len(AUDIT_HEADER):
        report.add("AUD004", AUDIT_DOC, line_no, f"row has {len(row)} cells, the matrix has {len(AUDIT_HEADER)}")
        return
    rid, rule, adoption, applies, reason, evidence = row
    if not AUDIT_ID.match(rid):
        report.add("AUD011", AUDIT_DOC, line_no, f"row id `{rid}` must look like P-01")
    elif rid in ids:
        report.add("AUD009", AUDIT_DOC, line_no, f"row id {rid} is also on line {ids[rid]}")
    else:
        ids[rid] = line_no
    for name, cell in (("SpektraLab规范", rule), ("本项目如何采用", adoption), ("对应代码/测试", evidence)):
        if cell.strip() in EMPTY_REASON:
            report.add("AUD005", AUDIT_DOC, line_no, f"{rid}: `{name}` is empty")
    verdict = applies.replace("*", "").strip()
    match = next((v for v in APPLICABILITY if verdict.startswith(v)), None)
    if match is None:
        report.add("AUD006", AUDIT_DOC, line_no, f"{rid}: `是否完全适用` must start with one of {', '.join(APPLICABILITY)}")
    else:
        counts[{"完全适用": "full", "调整后适用": "adjusted", "经评估后不适用": "na"}[match]] += 1
        if match != "完全适用" and (reason.strip() in EMPTY_REASON or len(reason.strip()) < 8):
            report.add("AUD007", AUDIT_DOC, line_no, f"{rid}: a rule that is {match} needs a written reason")
    for token in re.findall(r"`([^`]+)`", evidence):
        candidate = token.strip()
        if " " in candidate or "=" in candidate:
            continue
        candidate = re.split(r"::|#|:(?=\d)|:(?=[A-Za-z_][A-Za-z0-9_]*$)", candidate)[0]
        looks_like_path = "/" in candidate or PATH_EXT.search(candidate)
        if looks_like_path and not path_exists(root, candidate):
            report.add("AUD008", AUDIT_DOC, line_no, f"{rid}: `{token}` does not exist in this tree")


def path_exists(root: Path, candidate: str) -> bool:
    candidate = candidate.strip().rstrip("/")
    if any(ch in candidate for ch in "*?["):
        return any(root.glob(candidate))
    return (root / candidate).exists()


# --------------------------------------------------------------------------
# sync

WAIVER = re.compile(r"^Spec-Sync-Waiver:\s*([a-z0-9-]+)\s*[:：—-]\s*(\S.{7,})$", re.M)
GATE_LINE = re.compile(r"^\s*(Gate|Gates|Test|Tests|Verified|Measured)\b", re.M | re.I)


def git_available(root: Path) -> bool:
    if shutil.which("git") is None:
        return False
    return run_git(root, ["rev-parse", "--git-dir"], check=False).returncode == 0


def run_git(root: Path, args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(["git", "-c", "core.quotepath=off", *args], cwd=root, capture_output=True,
                          text=True, encoding="utf-8", errors="replace")
    if check and proc.returncode != 0:
        raise CheckUnavailable(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc


def names(output: str) -> list[str]:
    """File names from a `-z` git listing (names may contain spaces)."""
    return [n.strip("\n") for n in output.split("\0") if n.strip("\n")]


def load_rules(root: Path) -> list[dict]:
    try:
        data = json.loads(read_text(root / RULES_FILE))
        rules = data["rules"]
        for r in rules:
            assert re.fullmatch(r"[a-z0-9-]+", r["id"]), r["id"]
            assert r["require_all"] and r["triggers"]
            for t in r["triggers"]:
                assert t["mode"] in ("file", "keys", "entries"), t["mode"]
                if t["mode"] != "file":
                    re.compile(t["regex"])
        return rules
    except (OSError, ValueError, KeyError, AssertionError, re.error) as exc:
        raise CheckUnavailable(f"{RULES_FILE.as_posix()} is unreadable or malformed: {exc!r}") from exc


def glob_match(path: str, pattern: str) -> bool:
    if "**" in pattern:
        prefix = pattern.split("**", 1)[0]
        return path.startswith(prefix)
    return fnmatch.fnmatchcase(path, pattern)


def diff_entries(diff: str, regex: str) -> tuple[dict[str, str], dict[str, str]]:
    """Map each regex key to its whitespace-normalised line, on the removed and
    the added side of a unified diff."""
    pattern = re.compile(regex)
    removed: dict[str, str] = {}
    added: dict[str, str] = {}
    for line in diff.splitlines():
        if line.startswith(("---", "+++")) or not line[:1] in ("+", "-"):
            continue
        body = line[1:]
        for m in pattern.finditer(body):
            key = next((g for g in m.groups() if g), m.group(0))
            norm = " ".join(body.split())
            (added if line[0] == "+" else removed).setdefault(key, norm)
    return removed, added


def trigger_fired(trigger: dict, changed: list[str], diff_for) -> str | None:
    hits = [p for p in changed if glob_match(p, trigger["path"])]
    if not hits:
        return None
    if trigger["mode"] == "file":
        return f"{hits[0]} changed"
    for path in hits:
        removed, added = diff_entries(diff_for(path), trigger["regex"])
        if trigger["mode"] == "keys":
            gone, new = sorted(set(removed) - set(added)), sorted(set(added) - set(removed))
            if gone or new:
                return f"{path}: " + ", ".join([f"+{k}" for k in new] + [f"-{k}" for k in gone])
        else:
            keys = sorted(set(removed) | set(added))
            moved = [k for k in keys if removed.get(k) != added.get(k)]
            if moved:
                return f"{path}: {', '.join(moved[:6])}{' …' if len(moved) > 6 else ''}"
    return None


def check_sync(root: Path, report: Report, base: str, head: str = "HEAD", worktree: bool = False,
               waivers: list[str] | None = None, strict_trailers: bool = False) -> None:
    if not git_available(root):
        raise CheckUnavailable("sync needs git and a git checkout (a source ZIP cannot be checked)")
    rules = load_rules(root)
    merge_base = run_git(root, ["merge-base", base, head]).stdout.strip()
    changed = names(run_git(root, ["diff", "--name-only", "-z", merge_base, head]).stdout)
    if worktree:
        changed += names(run_git(root, ["diff", "--name-only", "-z", "HEAD"]).stdout)
        changed += names(run_git(root, ["ls-files", "-z", "--others", "--exclude-standard"]).stdout)
    changed = sorted(set(changed))
    log = run_git(root, ["log", "--format=%H%x00%P%x00%B%x1e", f"{merge_base}..{head}"]).stdout
    commits = [c.strip("\n").split("\x00") for c in log.split("\x1e") if c.strip()]
    waived: dict[str, str] = {}
    for _, _, body in commits:
        for m in WAIVER.finditer(body):
            waived[m.group(1)] = m.group(2).strip()
    for w in waivers or []:
        m = re.match(r"^([a-z0-9-]+)\s*[:：]\s*(\S.{7,})$", w)
        if not m:
            raise CheckUnavailable(f"--waive must be `<rule>: <reason of 8+ characters>`, got {w!r}")
        waived[m.group(1)] = m.group(2)

    def diff_for(path: str) -> str:
        text = run_git(root, ["diff", "-U0", merge_base, head, "--", path]).stdout
        if worktree:
            text += run_git(root, ["diff", "-U0", "HEAD", "--", path]).stdout
            if run_git(root, ["ls-files", "--error-unmatch", path], check=False).returncode != 0:
                full = root / path
                if full.is_file():
                    text += "".join("+" + l + "\n" for l in read_text(full).splitlines())
        return text

    known = {r["id"] for r in rules}
    for rule_id in sorted(set(waived) - known):
        report.add("SYN003", RULES_FILE, 0, f"waiver names an unknown rule `{rule_id}`", "warning")
    fired = 0
    for rule in rules:
        reason = next((r for t in rule["triggers"] if (r := trigger_fired(t, changed, diff_for))), None)
        if reason is None:
            continue
        fired += 1
        missing = [req for req in rule["require_all"] if not any(glob_match(p, req) for p in changed)]
        if not missing:
            continue
        if rule["id"] in waived:
            report.notes.append(f"sync:{rule['id']} waived -- {waived[rule['id']]}")
            continue
        report.add("SYN001", rule["triggers"][0]["path"], 0,
                   f"sync:{rule['id']} fired ({reason}) but {', '.join(missing)} did not change in "
                   f"{merge_base[:12]}..{head}. {rule['description']} Waive with a commit trailer "
                   f"`Spec-Sync-Waiver: {rule['id']}: <reason>` if the change is not an interface change.")
    for sha, parents, body in commits:
        if len(parents.split()) > 1:
            continue
        files = names(run_git(root, ["show", "--name-only", "-z", "--format=", sha]).stdout)
        code = [f for f in files if not f.endswith(".md") and not f.startswith("docs/")]
        if code and not GATE_LINE.search(body):
            report.add("SYN010", sha[:12], 0, "commit changes code but records no gate "
                       "(a `Gate:` / `Test:` line naming what ran)", "error" if strict_trailers else "warning")
    report.notes.append(f"sync: {len(changed)} files changed since {merge_base[:12]}, "
                        f"{len(commits)} commits, {fired} rule(s) fired")


# --------------------------------------------------------------------------
# CLI


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # Windows consoles
    except (AttributeError, ValueError):
        pass
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checks", nargs="+", choices=["all", "docs", "audit", "sync"])
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: this checkout)")
    parser.add_argument("--base", help="sync: the branch or commit the range starts from (merge base is used)")
    parser.add_argument("--head", default="HEAD", help="sync: the end of the range (default HEAD)")
    parser.add_argument("--worktree", action="store_true", help="sync: include uncommitted and untracked files")
    parser.add_argument("--waive", action="append", default=[], metavar="RULE: REASON",
                        help="sync: waive a rule for this local run (CI reads commit trailers instead)")
    parser.add_argument("--strict-trailers", action="store_true", help="sync: a code commit without a gate line is an error")
    parser.add_argument("--strict", action="store_true", help="warnings fail the run")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    checks = {"docs", "audit", "sync"} if "all" in args.checks else set(args.checks)
    report = Report()
    try:
        if "docs" in checks:
            check_docs(root, report)
        if "audit" in checks:
            check_audit(root, report)
        if "sync" in checks:
            if not args.base:
                if "all" in args.checks:
                    report.notes.append("sync: skipped (no --base)")
                else:
                    raise CheckUnavailable("sync needs --base")
            else:
                check_sync(root, report, args.base, args.head, args.worktree, args.waive, args.strict_trailers)
    except CheckUnavailable as exc:
        print(f"process check could not run: {exc}", file=sys.stderr)
        return 2
    for f in sorted(report.findings, key=lambda f: (f.severity != "error", f.path, f.line, f.code)):
        print(f.render())
    for note in report.notes:
        print(note)
    errors = len(report.errors)
    warnings = len(report.findings) - errors
    failed = errors > 0 or (args.strict and warnings > 0)
    print(f"process check: {', '.join(sorted(checks))} -- {errors} error(s), {warnings} warning(s) -> "
          f"{'FAIL' if failed else 'PASS'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
