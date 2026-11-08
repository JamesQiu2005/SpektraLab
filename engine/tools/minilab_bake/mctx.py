#!/usr/bin/env python3
"""Shared context for the offline all-pair minilab baker.

This module is the only place that knows *where* things are. The scientific
functions stay in the research tree (`research/Metamerism/v2` and `study`, which
this repository does not carry); this file bootstraps an isolated copy of that
tree, materialises the effective profile overlay the engine itself would see
(including `derived_from` aliases), and records provenance.

Nothing here is imported by the product build. Python is an offline prerequisite
for a *new* calibration, exactly like `engine/tools/bake_resources.py`: ordinary
`engine/build.sh bundle` copies the tracked tables and never runs Python.

The one process-per-job rule from `engine/minilab-coverage/SOP.md` §8 lives in
`sweep.py`; every function here is expected to be called from a child that owns
its own memory.

Paths
-----
`--work`  an isolated full copy of `research/Metamerism` (code + small outputs,
          with `inputs/` and `data/` symlinked read-only). Nothing is ever
          written through a symlink into the original research tree.
`--oracle` a disposable engine built from the recorded revision + the recorded
          patch order (`engine/performance/2026-10-24/provenance.json`) whose
          dylib carries the `SPK_RESEARCH_*` hooks. The promoted engine does
          *not* carry those hooks, so it cannot generate negatives or taps.
`--out`   the run root: ledger, job directories, published tables, evidence.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

SPACES = ("sRGB", "ProPhoto RGB")
SPACE_SUFFIX = {"sRGB": "", "ProPhoto RGB": "_pp"}
RECIPE = {
    "side": 65,
    "storage": "float32",
    "interpolation": "trilinear",
    "r_blend": 1.0,
    "ymode": "opt",
    "mode": "hybrid",
    "print_ev": 0.0,
    "dir_amount": 1.0,
    "spaces": list(SPACES),
    "suffix": "_f10",
}

# The research sources whose bytes decide a bake. Hashed into every manifest so
# that a resumed run cannot silently mix two harnesses.
SOURCE_FILES = [
    "v2/c3_build_f.py", "v2/c3_lib.py", "v2/c2_lib.py", "v2/cp_lib.py",
    "v2/cp_build.py", "v2/minilab_build.py", "v2/minilab_io.py", "v2/dilib.py",
    "v2/printlib.py", "v2/evalib.py", "v2/e1x.py", "v2/e1_fit.py",
    "v2/fitlib.py", "v2/negs.py", "v2/eng2.py", "v2/eng2_worker.py",
    "v2/chartlib.py", "v2/ramplib.py", "v2/c1_common.py",
    "study/filmlib.py", "study/e2lib.py", "study/common.py", "study/blob.py",
]


# --------------------------------------------------------------------------
# small utilities


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fnv1a64(data):
    """The engine's runtime identity: FNV-1a 64-bit, 16 lowercase hex digits.

    `engine/src/core/minilab.cpp` hashes raw file bytes with exactly this.
    """
    h = 14695981039346656037
    for byte in data:
        h = ((h ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def fnv1a64_file(path):
    with open(path, "rb") as f:
        return fnv1a64(f.read())


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, default=str) + "\n")
    os.replace(tmp, path)


def repo_root(start=None):
    """Walk up to the checkout that owns `engine/`."""
    p = Path(start or __file__).resolve()
    for parent in [p] + list(p.parents):
        if (parent / "engine" / "build.sh").is_file():
            return parent
    raise SystemExit("not inside a SpektraLab checkout (no engine/build.sh above %s)" % p)


# --------------------------------------------------------------------------
# the context


class Ctx:
    def __init__(self, work, oracle, out, repo=None):
        self.repo = Path(repo) if repo else repo_root()
        self.work = Path(work).resolve()
        self.oracle = Path(oracle).resolve()
        self.out = Path(out).resolve()
        self.engine_resources = self.work / "resources"
        self.host_resources = self.work / "host_resources"
        self._booted = False

    # -- derived paths -----------------------------------------------------
    @property
    def jobs(self):
        return self.out / "jobs"

    @property
    def tables(self):
        return self.out / "tables"

    @property
    def sheets(self):
        return self.out / "sheets"

    @property
    def reports(self):
        return self.out / "reports"

    @property
    def ledger_path(self):
        return self.out / "ledger.json"

    @property
    def python(self):
        return self.work / ".venv" / "bin" / "python"

    def job_dir(self, film, paper, space):
        return self.jobs / job_id(film, paper, space)

    def ensure_dirs(self):
        for d in (self.jobs, self.tables, self.sheets, self.reports,
                  (self.work / "study" / "out" / "e3"), self.engine_resources,
                  self.host_resources):
            d.mkdir(parents=True, exist_ok=True)

    # -- bootstrap ---------------------------------------------------------
    def bootstrap(self):
        """chdir into the work copy and point the research modules at the host
        overlay. Idempotent; must run before any research module is imported."""
        if self._booted:
            return
        if not (self.work / "v2" / "c3_lib.py").is_file():
            raise SystemExit("not a research work copy: %s" % self.work)
        os.chdir(self.work)
        ensure_engine_bridge(self)
        for p in (str(self.work / "study"), str(self.work / "v2")):
            if p not in sys.path:
                sys.path.insert(0, p)
        # printlib pins filmlib.RES at import; override afterwards, then clear
        # every cache that read the old directory.
        import printlib as pl  # noqa: F401
        import filmlib as fl
        fl.RES = self.host_resources
        fl.profile.cache_clear()
        fl.spectra_lut.cache_clear()
        if hasattr(pl, "_neutral_pack"):
            pl._neutral_pack.cache_clear()
        if hasattr(pl, "cached_lut"):
            pl.cached_lut.cache_clear()
        import numpy  # noqa: F401
        import eng2
        eng2.RESOURCES = str(self.engine_resources)  # the overlay, not the oracle's own dir
        self._booted = True


def job_id(film, paper, space):
    return "%s__%s__%s" % (film, paper, "pp" if space == "ProPhoto RGB" else "srgb")


def parse_job_id(text):
    film, paper, sp = text.split("__")
    return film, paper, {"pp": "ProPhoto RGB", "srgb": "sRGB"}[sp]


def ctx_from_args(argv=None, description=None):
    ap = argparse.ArgumentParser(description=description)
    ap.add_argument("--work", type=Path, required=True, help="isolated research copy")
    ap.add_argument("--oracle", type=Path, required=True, help="patched research engine root")
    ap.add_argument("--out", type=Path, help="run root (default: <work>/run)")
    ap.add_argument("--repo", type=Path, help="production checkout (default: inferred)")
    a = ap.parse_args(argv)
    return Ctx(a.work, a.oracle, a.out or (a.work / "run"), a.repo)


# --------------------------------------------------------------------------
# resource overlays
#
# The engine resolves a `derived_from` alias itself: the base's data whole, then
# the alias's `info` over it, and the *base's* neutral-filter row when the alias
# has none. The numpy replica in `study/filmlib.py` has no alias handling at
# all, so the host gets a materialised copy. Both overlays are built from the
# same base bytes, and `resources/` keeps the real alias file so the engine is
# tested against the shipped shape rather than against the materialisation.


def _alias_profiles(repo):
    """Alias profile JSONs from the product overlay, keyed by stock."""
    out = {}
    for folder in (repo / "engine" / "resources" / "profiles",
                   repo / "engine" / "resources_product" / "profiles"):
        for path in sorted(folder.glob("*.json")):
            data = read_json(path)
            if data.get("derived_from"):
                out[path.stem] = (path, data)
    return out


def _materialise_alias(stock, path, data, base):
    merged = {
        "metadata": {
            "materialised_from": {
                "alias": str(path.name),
                "alias_sha256": sha256_file(path),
                "base": data["derived_from"],
                "note": "effective profile: the base's data whole, the alias's info over it "
                        "(engine/src/core/profile.cpp:load_profile)",
            }
        },
        "info": dict(base["info"]),
        "data": base["data"],
    }
    merged["info"].update(data.get("info", {}))
    merged["info"]["stock"] = stock
    return merged


def ensure_overlays(ctx):
    """Build `resources/` (engine + host) from the oracle, adding product aliases.

    Idempotent: only missing files are written, and the result is recorded so a
    resumed run can detect drift.
    """
    ctx.ensure_dirs()
    oracle_res = ctx.oracle / "resources"
    if not (oracle_res / "spektralab_constants.bin").is_file():
        raise SystemExit("oracle resources missing under %s" % oracle_res)
    base_profiles = oracle_res / "profiles"
    aliases = _alias_profiles(ctx.repo)

    # `resources/`: the engine's view. Base files are hard-linked or copied;
    # the alias files are the product's own bytes.
    if not (ctx.engine_resources / "spektralab_constants.bin").is_file():
        shutil.copytree(oracle_res, ctx.engine_resources, dirs_exist_ok=True)
    for stock, (path, data) in aliases.items():
        target = ctx.engine_resources / "profiles" / (stock + ".json")
        if not target.exists():
            target.write_bytes(path.read_bytes())
        if data["derived_from"] not in {p.stem for p in base_profiles.glob("*.json")}:
            raise SystemExit("alias %s: base %s is not in the base overlay" % (stock, data["derived_from"]))

    # `host_resources/`: the replica's view. Same bytes plus materialised aliases
    # and the alias neutral-filter rows the engine falls back to.
    if not (ctx.host_resources / "spektralab_constants.bin").is_file():
        shutil.copytree(ctx.engine_resources, ctx.host_resources, dirs_exist_ok=True)
    for stock, (path, data) in aliases.items():
        base = read_json(base_profiles / (data["derived_from"] + ".json"))
        (ctx.host_resources / "profiles" / (stock + ".json")).write_text(
            json.dumps(_materialise_alias(stock, path, data, base), indent=1) + "\n")
    filters_path = ctx.host_resources / "neutral_print_filters.json"
    filters = read_json(filters_path)
    changed = False
    for stock, (_, data) in aliases.items():
        base = data["derived_from"]
        for paper, packs in filters.items():
            for pack, rows in packs.items():
                if stock not in rows and base in rows:
                    rows[stock] = list(rows[base])
                    changed = True
    if changed:
        filters_path.write_text(json.dumps(filters, indent=1) + "\n")

    record = {
        "engine_resources": str(ctx.engine_resources),
        "host_resources": str(ctx.host_resources),
        "constants_blob_sha256": sha256_file(ctx.engine_resources / "spektralab_constants.bin"),
        "profiles": {
            p.stem: sha256_file(p)
            for p in sorted((ctx.engine_resources / "profiles").glob("*.json"))
        },
        "aliases": {
            stock: {
                "file": str(path.relative_to(ctx.repo)),
                "derived_from": data["derived_from"],
                "alias_sha256": sha256_file(path),
                "base_sha256": sha256_file(base_profiles / (data["derived_from"] + ".json")),
            }
            for stock, (path, data) in aliases.items()
        },
    }
    write_json(ctx.reports / "overlay.json", record)
    return record


def ensure_engine_bridge(ctx):
    """Point `v2/eng2.py` at the effective overlay instead of the oracle's own dir.

    The oracle's dylib resolves its resources from `<engine>/resources`, which is
    the recorded base tree. The product overlay (the CineStill alias, the
    resources_product profiles) is not there, so a CineStill job must be able to
    say which directory the engine reads. The edit lives in the disposable copy
    and is applied here, not by hand, so a fresh work copy is reproducible.
    """
    worker = ctx.work / "v2" / "eng2_worker.py"
    s = worker.read_text()
    needle = "resources=str(ENG / 'resources')"
    if "job.get('resources')" not in s:
        if needle not in s:
            raise SystemExit("eng2_worker.py: unexpected resource line")
        worker.write_text(s.replace(needle, "resources=job.get('resources') or str(ENG / 'resources')"))
    b = ctx.work / "v2" / "eng2.py"
    s = b.read_text()
    if "RESOURCES = None" not in s:
        needle = "HERE = Path(__file__).resolve().parent"
        if needle not in s:
            raise SystemExit("eng2.py: unexpected HERE line")
        s = s.replace(needle, needle + "\nRESOURCES = None   # set by the minilab baker: the effective overlay")
        needle = "job = dict(params=params, dylib=str(dylib), engine_root=str(eroot), mode=mode, di=di, solve=solve)"
        if needle not in s:
            raise SystemExit("eng2.py: unexpected job line")
        b.write_text(s.replace(needle, needle[:-1] + ", resources=RESOURCES)"))
    return {"resources": str(ctx.engine_resources),
            "eng2_sha256": sha256_file(ctx.work / "v2" / "eng2.py"),
            "eng2_worker_sha256": sha256_file(ctx.work / "v2" / "eng2_worker.py")}


def ensure_anchors(ctx, films):
    """Generate the per-film exposure anchor the negative recipe needs.

    `negs.neg_for_spectra` scales a spectrum by `2 ** anchor_C0`, where
    `anchor_C0 = log2(Ehat/Etrue)` of the D55 white through the film's own C0
    table (`study/e2lib.py:anchor`). The four research films have this in
    `study/out/e3/tables_<film>.npz`; every other colour film does not, and a
    guessed constant would shift the negative. This recomputes it from the same
    spectral procedure and leaves existing files untouched.
    """
    import numpy as np
    import e2lib as L
    import filmlib as fl

    made = {}
    for film in films:
        path = ctx.work / "study" / "out" / "e3" / ("tables_%s.npz" % film)
        if path.exists():
            made[film] = {"reused": True, "sha256": sha256_file(path),
                          "anchor_C0": np.load(path)["anchor_C0"].tolist()}
            continue
        t0 = fl.build_tc_lut(film)
        anchor = L.anchor(film, t0)
        np.savez_compressed(path, anchor_C0=anchor)
        made[film] = {"reused": False, "sha256": sha256_file(path),
                      "anchor_C0": np.asarray(anchor).tolist()}
        print("anchor", film, np.round(anchor, 6).tolist(), flush=True)
    write_json(ctx.reports / "anchors.json", made)
    return made


# --------------------------------------------------------------------------
# provenance


def manifest(ctx, film, paper, space):
    """The complete input identity of one calibration."""
    import platform

    profiles = {}
    for stock in (film, paper):
        for folder in (ctx.repo / "engine" / "resources" / "profiles",
                       ctx.repo / "engine" / "resources_product" / "profiles"):
            path = folder / (stock + ".json")
            if path.exists():
                data = read_json(path)
                profiles[stock] = {
                    "path": str(path.relative_to(ctx.repo)),
                    "sha256": sha256_file(path),
                    "fnv1a64": fnv1a64_file(path),
                    "derived_from": data.get("derived_from"),
                }
                if data.get("derived_from"):
                    base = ctx.repo / "engine" / "resources" / "profiles" / (data["derived_from"] + ".json")
                    profiles[stock]["base"] = {
                        "path": str(base.relative_to(ctx.repo)),
                        "sha256": sha256_file(base),
                        "fnv1a64": fnv1a64_file(base),
                    }
                break
        else:
            raise SystemExit("missing profile for %s" % stock)

    sources = {}
    for rel in SOURCE_FILES:
        path = ctx.work / rel
        if path.is_file():
            sources[rel] = sha256_file(path)
    datasets = {}
    for rel in ("data/munsell_uef", "data/japan_natural"):
        folder = ctx.work / rel
        for path in sorted(folder.glob("*")):
            if path.is_file():
                datasets[str(path.relative_to(ctx.work))] = sha256_file(path)
    inputs = {}
    for name in ("apple_2048.npy",):
        path = ctx.work / "inputs" / name
        if path.is_file():
            inputs[name] = {"sha256": sha256_file(path), "bytes": path.stat().st_size}

    engine = {
        "dylib_sha256": sha256_file(ctx.oracle / "build" / "libspektralab_engine.dylib"),
        "metallib_sha256": sha256_file(ctx.oracle / "resources" / "spektralab.metallib"),
        "resources_sha256": sha256_file(ctx.oracle / "resources" / "spektralab_constants.bin"),
        "neutral_filters_sha256": sha256_file(ctx.oracle / "resources" / "neutral_print_filters.json"),
    }
    try:
        import subprocess
        commit = subprocess.check_output(
            ["git", "-C", str(ctx.repo), "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        commit = None
    import numpy
    import scipy
    import colour
    return {
        "film": film,
        "paper": paper,
        "space": space,
        "recipe": RECIPE,
        "profiles": profiles,
        "sources": sources,
        "datasets": datasets,
        "inputs": inputs,
        "engine": engine,
        "product_commit": commit,
        "python": platform.python_version(),
        "packages": {"numpy": numpy.__version__, "scipy": scipy.__version__,
                     "colour": colour.__version__},
        "threads": {k: os.environ.get(k) for k in
                    ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS",
                     "MKL_NUM_THREADS", "NUMEXPR_NUM_THREADS")},
    }


def manifest_digest(man):
    """Stable digest of the parts that decide the numbers (not the host paths)."""
    key = json.dumps({k: man[k] for k in ("film", "paper", "space", "recipe", "profiles",
                                          "sources", "datasets", "inputs", "engine",
                                          "packages")}, sort_keys=True)
    return hashlib.sha256(key.encode()).hexdigest()
