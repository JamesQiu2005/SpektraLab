"""RFC-030 §5: duplicated and truncated data in the shipped profiles.

Standard library only. Reads `engine/resources/profiles/*.json` and prints:
  1. every data field that is identical, value for value, across two or more
     profiles (a copy, unless the stocks are the same emulsion);
  2. where each profile's `base_density` is undefined (NaN).

    python3 rfc/probes/rfc030-profile-data.py
"""
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path

PROFILES = Path(__file__).resolve().parents[2] / "engine/resources/profiles"
FIELDS = ["base_density", "log_sensitivity", "channel_density", "density_curves"]


def digest(values):
    return hashlib.md5(json.dumps(values).encode()).hexdigest()[:8]


def undefined(v):
    return v is None or (isinstance(v, float) and math.isnan(v))


profiles = {p.stem: json.loads(p.read_text()) for p in sorted(PROFILES.glob("*.json"))}

print("1. Identical data fields")
for field in FIELDS:
    groups = defaultdict(list)
    for name, d in profiles.items():
        groups[digest(d["data"][field])].append(name)
    for key, names in groups.items():
        if len(names) > 1:
            print(f"   {field:16s} {key}  {', '.join(names)}")

print("\n2. Where base_density is undefined (NaN), and what reads each film")
for name, d in profiles.items():
    wl, base = d["data"]["wavelengths"], d["data"]["base_density"]
    missing = [w for w, v in zip(wl, base) if undefined(v)]
    if not missing:
        continue
    low = [w for w in missing if w < 550]
    high = [w for w in missing if w >= 550]
    parts = []
    if low:
        parts.append(f"{low[0]:.0f}-{low[-1]:.0f} nm")
    if high:
        parts.append(f"{high[0]:.0f}-{high[-1]:.0f} nm")
    target = d["info"].get("target_print") or "-"
    print(f"   {name:28s} {len(missing):2d}/{len(wl)} undefined: {', '.join(parts):22s} read through {target}")
