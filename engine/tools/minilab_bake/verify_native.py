#!/usr/bin/env python3
"""Runtime execution gate: the promoted engine and the research engine must
consume the same table and produce the same RGBA16.

    python verify_native.py --work <copy> --oracle <engine> --ids <id>,<id>

For each staged pair the *research* arm renders through
`SPK_RESEARCH_MINILAB_LOGPOS` with the staged table; the *promoted* arm renders
through the bundle resources built by `stage.py` (base + product overlay +
`minilab/index.json`). Both use the same photograph, the same pair, the same
output space, grain and glare off. A difference is a real port difference, not
an interpolation difference: both arms read the identical 65^3 file.
"""
import argparse
import json
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ledger as ledger_mod  # noqa: E402
import mctx  # noqa: E402
import stage as stage_mod  # noqa: E402


def render_pair(after_root, before_root, before_resources, after_resources, image,
                film, paper, space, table, outdir):
    import numpy as np
    import performance_compare as pc

    params = dict(input_cctf_decoding=False, input_color_space="ProPhoto RGB",
                  output_color_space=space, auto_exposure=True,
                  grain_active=False, glare_active=False,
                  film_stock=film, print_stock=paper,
                  digital_intermediate=False, scan_film=False)
    before = dict(root=str(before_root), resources=str(before_resources),
                  input=str(image), params=params,
                  env={"SPK_RESEARCH_MINILAB_LOGPOS": str(table)},
                  steps=[dict(save=str(outdir / "before.npy"))])
    after = dict(root=str(after_root), resources=str(after_resources),
                 input=str(image), params=params,
                 env={}, steps=[dict(save=str(outdir / "after.npy"))])
    rb = pc.run(before)
    ra = pc.run(after)
    a = np.load(outdir / "before.npy")
    b = np.load(outdir / "after.npy")
    diff = np.abs(a.astype(np.int64) - b.astype(np.int64))
    return dict(exact=bool(np.array_equal(a, b)),
                max_diff=int(diff.max()) if diff.size else 0,
                frac_px_diff=float((diff.max(-1) > 0).mean()) if diff.size else 0.0,
                before_peak_mib=rb.get("peak_mib"), after_peak_mib=ra.get("peak_mib"))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--oracle", type=Path, required=True)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--repo", type=Path)
    ap.add_argument("--ids", required=True)
    a = ap.parse_args(argv)
    ctx = mctx.Ctx(a.work, a.oracle, a.out or (a.work / "run"), a.repo)
    led = ledger_mod.Ledger(ctx.ledger_path)
    bundle = stage_mod.make_bundle_resources(ctx)
    before_resources = ctx.engine_resources
    image = ctx.work / "inputs" / "apple_2048.npy"
    results = []
    index = mctx.read_json(ctx.repo / "engine" / "resources" / "minilab" / "index.json")
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        for jid in [x for x in a.ids.split(",") if x]:
            film, paper, space = mctx.parse_job_id(jid)
            # The catalog, not the id, names the file: an inherited-calibration
            # alias points at its base film's table (FINDINGS 9).
            entry = index["pairs"].get(film + "|" + paper, {}).get(space)
            if not entry:
                raise SystemExit("%s: no catalog entry" % jid)
            name = entry["file"]
            table = ctx.repo / "engine" / "resources" / "minilab" / name
            if not table.is_file():
                raise SystemExit("%s: %s is not staged" % (jid, name))
            # performance_compare is a test module of the production checkout
            sys.path.insert(0, str(ctx.repo / "engine" / "tests"))
            r = render_pair(ctx.repo / "engine", ctx.oracle, before_resources, bundle,
                            image, film, paper, space, table, td)
            r.update(id=jid, table=name, table_sha256=mctx.sha256_file(table))
            results.append(r)
            led.update(film, paper, space,
                       "integrated_verified" if r["exact"] else "gate_failed",
                       runtime=r, runtime_at=time.time())
            print(jid, "exact" if r["exact"] else "DIFF %d" % r["max_diff"], flush=True)
    mctx.write_json(ctx.out / "reports" / "runtime.json", dict(results=results))
    return 0 if all(r["exact"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
