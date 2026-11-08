#!/usr/bin/env python3
"""The atomic, resumable run ledger.

One JSON object keyed by `film|paper|space`, written through a temp file and
`os.replace` after every state transition. Regenerating the inventory never
touches it: the inventory says what *should* be done, the ledger says what *has*
been done, and they are reconciled by `report.py`.
"""
import json
import os
import time
from pathlib import Path

import mctx

# terminal states that should not be retried by a normal sweep
DONE = {"staged", "integrated_verified"}
# states that are complete for the baker but still owe a visual/runtime stage
OWES = {"numeric_pass", "needs_visual_review"}
FAILED = {"blocked_input", "fit_failed", "bake_failed", "gate_failed"}
ORDER = ["pending", "preflight_ok", "fitting", "fitted", "baking", "baked",
         "numeric_pass", "needs_visual_review", "gate_failed", "blocked_input",
         "fit_failed", "bake_failed", "visual_pass", "qualified", "staged",
         "integrated_verified"]


class Ledger:
    def __init__(self, path, recipe=None):
        self.path = Path(path)
        if self.path.exists():
            self.data = mctx.read_json(self.path)
        else:
            self.data = {"schema_version": 1, "created": time.time(),
                         "recipe": recipe or mctx.RECIPE, "entries": {}}
        self.data.setdefault("entries", {})

    @staticmethod
    def key(film, paper, space):
        return "%s|%s|%s" % (film, paper, space)

    def get(self, film, paper, space):
        return self.data["entries"].get(self.key(film, paper, space))

    def state(self, film, paper, space):
        entry = self.get(film, paper, space)
        return entry["state"] if entry else "pending"

    def update(self, film, paper, space, state, force=False, **fields):
        key = self.key(film, paper, space)
        entry = self.data["entries"].setdefault(
            key, dict(film=film, paper=paper, space=space, state="pending",
                      attempts=0, history=[]))
        # A late writer (a sweep finishing its child, a second command) must not
        # move a pair backwards from a later stage: `numeric_pass` arriving after
        # `staged` used to undo the staging in the ledger while the catalog kept
        # the table. Failure states may always overwrite; a deliberate re-run
        # passes force=True.
        rank = {name: i for i, name in enumerate(ORDER)}
        if (not force and entry["state"] in rank and state in rank
                and rank[state] < rank[entry["state"]] and entry["state"] not in FAILED):
            state = entry["state"]
        if state != entry.get("state"):
            entry.setdefault("history", []).append(
                dict(state=state, at=time.time()))
        entry["state"] = state
        entry["updated"] = time.time()
        entry.update(fields)
        self.save()
        return entry

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(self.data, indent=1, default=str) + "\n")
        os.replace(tmp, self.path)

    def counts(self):
        out = {}
        for entry in self.data["entries"].values():
            out[entry["state"]] = out.get(entry["state"], 0) + 1
        return dict(sorted(out.items()))
