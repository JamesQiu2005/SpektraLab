"""Tests for tools/process/check_process.py (RFC-W001 §6).

Every check has a passing fixture and, for each failure it claims to catch, a
fixture that must turn it red with that finding's code. A test that only ever
sees the passing fixture would pass with the check deleted; the negative
fixtures are what make these tests able to fail.

Run:  python -m unittest discover -s tools/process/tests -v
The sync tests need git. Under CI (`SPK_REQUIRE_GIT=1`) a missing git is a
failure, not a skip, so a runner without git cannot report green.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
spec = importlib.util.spec_from_file_location("check_process", HERE.parent / "check_process.py")
cp = importlib.util.module_from_spec(spec)
sys.modules["check_process"] = cp
spec.loader.exec_module(cp)

HAVE_GIT = shutil.which("git") is not None
REQUIRE_GIT = os.environ.get("SPK_REQUIRE_GIT") == "1"

PRD = """\
---
id: PRD-W001
title: Example feature
status: Approved
owner: someone
created: 2026-10-28
updated: 2026-10-28
baseline: 1e727cd6cbd25e0292013e3b4dbb6ac237c0231f
rfcs: [RFC-W001]
---

# PRD-W001: Example feature

<!-- guidance that mentions {{placeholders}} is fine inside a comment -->

## 1. Background
Users need it; see [the RFC](../rfc/RFC-W001-example.md).

## 2. Goals
A goal.

## 3. Requirements
R1.

## 4. Windows conventions
F11 for full screen.

## 5. Constraints
P-01.

## 6. Acceptance
A test.

## 7. Measurements
不涉及：no performance claim.

## 8. Decisions
2026-10-28 · decided.

## 9. Open questions
None.

## 10. Out of scope
Nothing.
"""

RFC = """\
---
id: RFC-W001
title: Example module
status: Implemented
owner: someone
created: 2026-10-28
updated: 2026-10-28
baseline: 1e727cd
prd: PRD-W001
tests:
  - tools/example_test.py
---

# RFC-W001

## 1. Summary
S.
## 2. Context
C.
## 3. Design
D.
## 4. Contracts
None changed.
## 5. Impact
None.
## 6. Test plan
T.
## 7. Alternatives
A.
## 8. Rollout
R.
## 9. Decision log
L.
## 10. Open questions
Q.
"""

ADR = """\
---
id: ADR-W001
title: Example decision
status: Accepted
date: 2026-10-28
deciders: [someone]
rfc: RFC-W001
---

## 1. Context
C.
## 2. Decision
D.
## 3. Consequences
C.
## 4. Alternatives
A.
"""

AUDIT = """\
# Reference audit

| 字段 | 值 |
|---|---|
| 仓库 URL | https://github.com/JamesQiu2005/SpektraLab |
| UI 与规范参考 | `main` @ `fd891c6bc5eb350387602deb5c1ef9b6dcdab948` |
| 本项目基线 | `Windows_Linux` @ `1e727cd6cbd25e0292013e3b4dbb6ac237c0231f` |
| 检查日期 | 2026-10-28 |

| ID | SpektraLab规范 | 本项目如何采用 | 是否完全适用 | 调整理由 | 对应代码/测试 |
|---|---|---|---|---|---|
| P-01 | PRD before code | PRDs live in docs/prd | 完全适用 | — | `docs/prd/README.md` |
| P-02 | gate in commit | trailer | 调整后适用 | upstream writes prose; we accept both | `tools/process/check_process.py:12` |
| P-03 | Xcode only | none | 经评估后不适用 | the Windows port has no Xcode target at all | —（不适用） |

<!-- audit-counts: total=3 full=1 adjusted=1 na=1 -->
"""


def write(root: Path, rel: str, text: str) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def make_repo(root: Path) -> None:
    rules = json.loads((REPO / "tools/process/sync_rules.json").read_text(encoding="utf-8"))
    write(root, "tools/process/sync_rules.json", json.dumps(rules, indent=2))
    write(root, "tools/process/check_process.py", "# placeholder for the audit path check\n")
    write(root, "tools/example_test.py", "# test\n")
    ids = " ".join(f"`sync:{r['id']}`" for r in rules["rules"])
    write(root, "docs/process/DEVELOPMENT-PROCESS.md", f"# Process\n\nRules: {ids}\n")
    for kind, prefix, body, name, status in (
        ("prd", "PRD", PRD, "PRD-W001-example.md", "Approved"),
        ("rfc", "RFC", RFC, "RFC-W001-example.md", "Implemented"),
        ("adr", "ADR", ADR, "ADR-W001-example.md", "Accepted"),
    ):
        write(root, f"docs/{kind}/TEMPLATE.md", "---\nid: X\n---\n")
        write(root, f"docs/{kind}/{name}", body)
        write(root, f"docs/{kind}/README.md",
              f"# Index\n\n| ID | Title | Status |\n|---|---|---|\n| [{prefix}-W001]({name}) | Example | {status} |\n")
    write(root, "docs/reference-audit.md", AUDIT)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        make_repo(self.root)

    def run_docs(self) -> cp.Report:
        report = cp.Report()
        cp.check_docs(self.root, report)
        return report

    def run_audit(self) -> cp.Report:
        report = cp.Report()
        cp.check_audit(self.root, report)
        return report

    def edit(self, rel: str, old: str, new: str) -> None:
        path = self.root / rel
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text, f"fixture edit did not apply to {rel}")
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def assertOnly(self, report: cp.Report, code: str):
        codes = {f.code for f in report.errors}
        self.assertIn(code, codes, "\n".join(f.render() for f in report.findings))
        return codes


class DocsTests(Base):
    def test_the_fixture_passes(self):
        report = self.run_docs()
        self.assertEqual(report.errors, [], "\n".join(f.render() for f in report.findings))

    def test_missing_directory_index_or_template(self):
        (self.root / "docs/adr/TEMPLATE.md").unlink()
        self.assertOnly(self.run_docs(), "DOC000")
        shutil.rmtree(self.root / "docs/adr")
        self.assertOnly(self.run_docs(), "DOC000")

    def test_a_file_name_outside_the_scheme_is_refused(self):
        write(self.root, "docs/rfc/my-design.md", RFC)
        self.assertOnly(self.run_docs(), "DOC001")

    def test_missing_front_matter(self):
        self.edit("docs/prd/PRD-W001-example.md", "---\nid: PRD-W001", "id: PRD-W001")
        self.assertOnly(self.run_docs(), "DOC002")

    def test_missing_front_matter_key(self):
        self.edit("docs/prd/PRD-W001-example.md", "owner: someone\n", "")
        self.assertOnly(self.run_docs(), "DOC003")

    def test_id_must_match_file_name(self):
        self.edit("docs/prd/PRD-W001-example.md", "id: PRD-W001", "id: PRD-W002")
        self.assertOnly(self.run_docs(), "DOC004")

    def test_unknown_status(self):
        self.edit("docs/prd/PRD-W001-example.md", "status: Approved", "status: Done")
        self.assertOnly(self.run_docs(), "DOC005")

    def test_bad_dates_and_baseline(self):
        self.edit("docs/prd/PRD-W001-example.md", "updated: 2026-10-28", "updated: 2026-10-01")
        self.assertOnly(self.run_docs(), "DOC006")
        self.edit("docs/prd/PRD-W001-example.md", "updated: 2026-10-01", "updated: 2026-10-28")
        self.edit("docs/prd/PRD-W001-example.md", "baseline: 1e727cd6", "baseline: latest-1e727cd6")
        self.assertOnly(self.run_docs(), "DOC006")

    def test_missing_section(self):
        self.edit("docs/rfc/RFC-W001-example.md", "## 5. Impact\nNone.\n", "")
        self.assertOnly(self.run_docs(), "DOC007")

    def test_empty_section_is_an_error_past_draft_and_a_warning_in_draft(self):
        self.edit("docs/rfc/RFC-W001-example.md", "## 7. Alternatives\nA.\n", "## 7. Alternatives\n<!-- todo -->\n")
        self.assertOnly(self.run_docs(), "DOC008")
        self.edit("docs/rfc/RFC-W001-example.md", "status: Implemented", "status: Draft")
        self.edit("docs/rfc/README.md", "| Implemented |", "| Draft |")
        report = self.run_docs()
        self.assertNotIn("DOC008", {f.code for f in report.errors})
        self.assertIn("DOC008", {f.code for f in report.findings if f.severity == "warning"})

    def test_placeholder_left_in_an_approved_document(self):
        self.edit("docs/prd/PRD-W001-example.md", "A goal.", "A goal for {{who}}.")
        self.assertOnly(self.run_docs(), "DOC009")

    def test_document_missing_from_index(self):
        write(self.root, "docs/adr/README.md", "# Index\n")
        self.assertOnly(self.run_docs(), "DOC010")

    def test_index_status_disagrees(self):
        self.edit("docs/prd/README.md", "| Approved |", "| Draft |")
        self.assertOnly(self.run_docs(), "DOC011")

    def test_index_row_for_a_missing_file(self):
        self.edit("docs/prd/README.md", "| Approved |\n",
                  "| Approved |\n| [PRD-W009](PRD-W009-gone.md) | Gone | Draft |\n")
        self.assertOnly(self.run_docs(), "DOC012")

    def test_broken_relative_link(self):
        self.edit("docs/prd/PRD-W001-example.md", "../rfc/RFC-W001-example.md", "../rfc/RFC-W009-missing.md")
        self.assertOnly(self.run_docs(), "DOC013")

    def test_links_inside_code_are_not_checked(self):
        self.edit("docs/prd/PRD-W001-example.md", "R1.", "R1. `[x](nowhere.md)`\n\n```\n[y](nowhere.md)\n```")
        self.assertEqual(self.run_docs().errors, [])

    def test_rfc_must_name_its_prd_or_say_why_not(self):
        self.edit("docs/rfc/RFC-W001-example.md", "prd: PRD-W001", "prd: PRD-W007")
        self.assertOnly(self.run_docs(), "DOC014")
        self.edit("docs/rfc/RFC-W001-example.md", "prd: PRD-W007", "prd: none")
        self.assertOnly(self.run_docs(), "DOC014")
        self.edit("docs/rfc/RFC-W001-example.md", "prd: none", "prd: none: a build-only module with no user-facing feature")
        self.assertEqual(self.run_docs().errors, [])

    def test_implemented_rfc_names_tests_that_exist(self):
        self.edit("docs/rfc/RFC-W001-example.md", "tools/example_test.py", "tools/missing_test.py")
        self.assertOnly(self.run_docs(), "DOC015")

    def test_duplicate_number(self):
        write(self.root, "docs/rfc/RFC-W001-another.md", RFC)
        self.assertOnly(self.run_docs(), "DOC016")

    def test_every_sync_rule_is_documented_and_nothing_else(self):
        write(self.root, "docs/process/DEVELOPMENT-PROCESS.md", "# Process\n\n`sync:wire-schema` `sync:made-up`\n")
        report = self.run_docs()
        messages = [f.message for f in report.errors if f.code == "DOC017"]
        self.assertTrue(any("made-up" in m for m in messages), messages)
        self.assertTrue(any("host-protocol" in m for m in messages), messages)


class AuditTests(Base):
    def test_the_fixture_passes(self):
        report = self.run_audit()
        self.assertEqual(report.errors, [], "\n".join(f.render() for f in report.findings))

    def test_the_audit_must_exist(self):
        (self.root / "docs/reference-audit.md").unlink()
        self.assertOnly(self.run_audit(), "AUD000")

    def test_pin_is_required(self):
        self.edit("docs/reference-audit.md", "| 检查日期 | 2026-10-28 |", "| 检查日期 | soon |")
        self.assertOnly(self.run_audit(), "AUD001")

    def test_both_branches_are_pinned_to_full_shas(self):
        self.edit("docs/reference-audit.md", "`1e727cd6cbd25e0292013e3b4dbb6ac237c0231f`", "`1e727cd`")
        self.assertOnly(self.run_audit(), "AUD001")

    def test_header_must_be_exact(self):
        self.edit("docs/reference-audit.md", "| 调整理由 |", "| 理由 |")
        self.assertOnly(self.run_audit(), "AUD003")

    def test_row_cell_count(self):
        self.edit("docs/reference-audit.md", "| P-01 | PRD before code |", "| P-01 | PRD before code | extra |")
        self.assertOnly(self.run_audit(), "AUD004")

    def test_empty_cell(self):
        self.edit("docs/reference-audit.md", "| PRDs live in docs/prd |", "| — |")
        self.assertOnly(self.run_audit(), "AUD005")

    def test_applicability_vocabulary(self):
        self.edit("docs/reference-audit.md", "| 完全适用 |", "| 部分适用 |")
        self.assertOnly(self.run_audit(), "AUD006")

    def test_a_rule_not_adopted_as_is_needs_a_reason(self):
        self.edit("docs/reference-audit.md", "| the Windows port has no Xcode target at all |", "| — |")
        self.assertOnly(self.run_audit(), "AUD007")

    def test_evidence_paths_must_exist(self):
        self.edit("docs/reference-audit.md", "`docs/prd/README.md`", "`docs/prd/MISSING.md`")
        self.assertOnly(self.run_audit(), "AUD008")

    def test_evidence_tokens_that_are_not_paths_are_not_checked(self):
        self.edit("docs/reference-audit.md", "`docs/prd/README.md`",
                  "`docs/prd/README.md`, `npm run check`, `SPK_REQUIRE_GIT=1`, `docs/prd/*.md`")
        self.assertEqual(self.run_audit().errors, [])

    def test_duplicate_row_id(self):
        self.edit("docs/reference-audit.md", "| P-02 |", "| P-01 |")
        self.assertOnly(self.run_audit(), "AUD009")

    def test_counts_marker_must_match_the_matrix(self):
        self.edit("docs/reference-audit.md", "total=3 full=1", "total=4 full=2")
        self.assertOnly(self.run_audit(), "AUD010")

    def test_row_id_format(self):
        self.edit("docs/reference-audit.md", "| P-03 |", "| rule3 |")
        self.assertOnly(self.run_audit(), "AUD011")


@unittest.skipUnless(HAVE_GIT or REQUIRE_GIT, "git is not installed")
class SyncTests(unittest.TestCase):
    PARAMS = 'const SchemaField kFields[] = {\n    {"film_stock", "film.info.stock", S, SHOOT, false, 0, 0, false},\n};\n'

    def setUp(self):
        if not HAVE_GIT:
            self.fail("SPK_REQUIRE_GIT=1 but git is not installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        make_repo(self.root)
        write(self.root, "engine/src/core/params.cpp", self.PARAMS)
        write(self.root, "API-SPEC-callable-render-service.md", "# spec\n")
        write(self.root, "engine/tests/parity_schema.py", "NATIVE_ONLY = []\n")
        write(self.root, ".github/workflows/ci.yml", "name: ci\n")
        self.git("init", "-q", "-b", "base")
        self.git("add", "-A")
        self.commit("base\n\nGate: none (fixture)")
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args: str) -> str:
        env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
                   GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
        proc = subprocess.run(["git", "-c", "commit.gpgsign=false", *args], cwd=self.root, env=env,
                              capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def sync(self, **kw) -> cp.Report:
        report = cp.Report()
        cp.check_sync(self.root, report, self.base, **kw)
        return report

    def errors(self, report: cp.Report) -> list[str]:
        return [f.message for f in report.errors]

    def add_field(self, name: str = "print_stock") -> None:
        path = self.root / "engine/src/core/params.cpp"
        text = path.read_text(encoding="utf-8").replace(
            "};", f'    {{"{name}", "print.info.stock", S, PRINT, false, 0, 0, false}},\n}};')
        path.write_text(text, encoding="utf-8")

    def test_a_new_wire_field_without_its_spec_is_red(self):
        self.add_field()
        self.commit("feat: a field\n\nGate: unit")
        messages = self.errors(self.sync())
        self.assertTrue(any("sync:wire-schema " in m for m in messages), messages)
        self.assertTrue(any("sync:wire-schema-parity" in m for m in messages), messages)

    def test_the_same_change_with_spec_and_parity_is_green(self):
        self.add_field()
        write(self.root, "API-SPEC-callable-render-service.md", "# spec\n\nprint_stock\n")
        write(self.root, "engine/tests/parity_schema.py", "NATIVE_ONLY = ['print_stock']\n")
        self.commit("feat: a field\n\nGate: unit")
        self.assertEqual(self.errors(self.sync()), [])

    def test_a_range_change_is_a_wire_change_but_not_a_parity_change(self):
        path = self.root / "engine/src/core/params.cpp"
        path.write_text(path.read_text(encoding="utf-8").replace("0, 0, false}", "0, 1, false}"), encoding="utf-8")
        self.commit("fix: range\n\nGate: unit")
        messages = self.errors(self.sync())
        self.assertTrue(any("sync:wire-schema " in m for m in messages), messages)
        self.assertFalse(any("wire-schema-parity" in m for m in messages), messages)

    def test_moving_a_field_line_without_changing_it_does_not_fire(self):
        path = self.root / "engine/src/core/params.cpp"
        path.write_text("// moved\n" + path.read_text(encoding="utf-8").replace("    {", "        {"), encoding="utf-8")
        self.commit("style: indent\n\nGate: unit")
        self.assertEqual(self.errors(self.sync()), [])

    def test_a_waiver_trailer_names_the_rule_and_a_reason(self):
        path = self.root / "engine/src/core/params.cpp"
        path.write_text(path.read_text(encoding="utf-8").replace("0, 0, false}", "0, 1, false}"), encoding="utf-8")
        self.commit("fix: range\n\nGate: unit\nSpec-Sync-Waiver: wire-schema: tiny")
        self.assertTrue(self.errors(self.sync()), "a waiver needs a reason of 8+ characters")
        self.commit("chore: waive\n\nSpec-Sync-Waiver: wire-schema: internal clamp only, wire range unchanged in practice")
        self.assertEqual(self.errors(self.sync()), [])

    def test_a_waiver_for_another_rule_does_not_help(self):
        self.add_field()
        self.commit("feat\n\nGate: unit\nSpec-Sync-Waiver: host-protocol: not relevant to this field at all")
        self.assertTrue(any("wire-schema" in m for m in self.errors(self.sync())))

    def test_workflow_change_needs_the_process_document(self):
        write(self.root, ".github/workflows/ci.yml", "name: ci2\n")
        self.commit("ci: rename\n\nGate: actionlint")
        self.assertTrue(any("sync:ci-gates-doc" in m for m in self.errors(self.sync())))
        write(self.root, "docs/process/DEVELOPMENT-PROCESS.md",
              (self.root / "docs/process/DEVELOPMENT-PROCESS.md").read_text(encoding="utf-8") + "\nci2\n")
        self.commit("docs: gate table\n\nGate: docs check")
        self.assertEqual(self.errors(self.sync()), [])

    def test_file_names_with_spaces_and_non_ascii_are_seen(self):
        write(self.root, ".github/workflows/夜间 build.yml", "name: nightly\n")
        self.commit("ci: nightly\n\nGate: actionlint")
        self.assertTrue(any("夜间 build.yml" in m for m in self.errors(self.sync())))

    def test_worktree_mode_sees_uncommitted_and_untracked_changes(self):
        self.add_field()
        self.assertEqual(self.errors(self.sync()), [], "committed range is empty")
        self.assertTrue(self.errors(self.sync(worktree=True)))
        write(self.root, ".github/workflows/new.yml", "name: new\n")
        messages = self.errors(self.sync(worktree=True))
        self.assertTrue(any("ci-gates-doc" in m for m in messages), messages)

    def test_a_code_commit_without_a_gate_line_is_a_warning_or_an_error_when_strict(self):
        write(self.root, "src.py", "x = 1\n")
        self.commit("feat: no gate recorded")
        report = self.sync()
        self.assertEqual(self.errors(report), [])
        self.assertIn("SYN010", {f.code for f in report.findings})
        self.assertIn("SYN010", {f.code for f in self.sync(strict_trailers=True).errors})

    def test_a_docs_only_commit_needs_no_gate_line(self):
        write(self.root, "docs/notes.md", "notes\n")
        self.commit("docs: notes")
        self.assertNotIn("SYN010", {f.code for f in self.sync().findings})

    def test_a_pinned_sha_that_is_not_in_history_is_a_warning(self):
        report = cp.Report()
        cp.check_audit(self.root, report)
        self.assertEqual(report.errors, [])
        self.assertIn("AUD002", {f.code for f in report.findings if f.severity == "warning"})
        path = self.root / "docs/reference-audit.md"
        text = path.read_text(encoding="utf-8").replace("fd891c6bc5eb350387602deb5c1ef9b6dcdab948", self.base)
        text = text.replace("1e727cd6cbd25e0292013e3b4dbb6ac237c0231f", self.base)
        path.write_text(text, encoding="utf-8")
        report = cp.Report()
        cp.check_audit(self.root, report)
        self.assertNotIn("AUD002", {f.code for f in report.findings})

    def test_a_waiver_for_an_unknown_rule_is_a_warning(self):
        self.commit("chore\n\nGate: none\nSpec-Sync-Waiver: no-such-rule: a reason long enough")
        report = self.sync()
        self.assertEqual(self.errors(report), [])
        self.assertIn("SYN003", {f.code for f in report.findings if f.severity == "warning"})

    def test_no_git_checkout_cannot_pass(self):
        plain = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, plain, True)
        make_repo(plain)
        with self.assertRaises(cp.CheckUnavailable):
            cp.check_sync(plain, cp.Report(), "HEAD")

    def test_malformed_rules_cannot_pass(self):
        write(self.root, "tools/process/sync_rules.json", '{"rules": [{"id": "Bad Id"}]}')
        with self.assertRaises(cp.CheckUnavailable):
            cp.check_sync(self.root, cp.Report(), self.base)


class CommandLineTests(Base):
    def run_cli(self, *args: str) -> int:
        from contextlib import redirect_stdout, redirect_stderr
        import io
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return cp.main(["--root", str(self.root), *args])

    def test_exit_codes(self):
        self.assertEqual(self.run_cli("docs", "audit"), 0)
        self.edit("docs/reference-audit.md", "| 完全适用 |", "| 也许 |")
        self.assertEqual(self.run_cli("audit"), 1)
        self.assertEqual(self.run_cli("sync"), 2, "sync without --base cannot run, and must not pass")

    def test_strict_turns_warnings_into_failure(self):
        self.edit("docs/rfc/RFC-W001-example.md", "status: Implemented", "status: Draft")
        self.edit("docs/rfc/README.md", "| Implemented |", "| Draft |")
        self.edit("docs/rfc/RFC-W001-example.md", "## 7. Alternatives\nA.\n", "## 7. Alternatives\n")
        self.assertEqual(self.run_cli("docs"), 0)
        self.assertEqual(self.run_cli("docs", "--strict"), 1)


if __name__ == "__main__":
    unittest.main()
