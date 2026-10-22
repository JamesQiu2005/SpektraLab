#!/usr/bin/env python3
"""Current decoded original and source-neutral wire regression; owned copies."""
import argparse
from pathlib import Path
import shutil
import tempfile

from host_smoke import Host, write_png
from host_proof import good


def source(host, sid, display="srgb", edge=512):
    reply, pixels = good(host, "render_source", {"session": sid, "display": display,
                                               "long_edge": edge, "generation": 19})
    image = reply["image"]
    assert reply["generation"] == 19 and reply["source"] == "decoded"
    assert len(pixels) == image["width"] * image["height"] * 4
    assert max(image["width"], image["height"]) <= edge
    assert image["color_space"] == ("sRGB" if display == "srgb" else "Display P3")
    return pixels


def exercise(host, folder, raw):
    hello, _ = good(host, "hello")
    assert {"render_source", "pick_neutral"} <= set(hello["methods"])
    png = folder / "普通图像.png"
    write_png(str(png), 96, 64)
    opened, _ = good(host, "open", {"path": str(png)})
    sid = opened["session"]
    before = source(host, sid)
    assert source(host, sid, "display-p3") != before
    good(host, "set_params", {"session": sid, "delta": {"exposure_compensation_ev": 2}})
    assert source(host, sid) == before, "film edits contaminated the original"
    h, p = host.call("pick_neutral", {"session": sid, "x": .5, "y": .5})
    assert not h["ok"] and not p and h["error"]["code"] == "unsupported"
    good(host, "close", {"session": sid})
    if not raw:
        print("decoded source: PNG, display conversion and source/film isolation passed; real RAW not requested")
        return
    owned = folder / ("中性点原图" + raw.suffix)
    shutil.copyfile(raw, owned)
    for mode in ("compatible16", "headroom"):
        opened, _ = good(host, "open", {"path": str(owned), "decode": {"raw_mode": mode}})
        sid = opened["session"]
        original = source(host, sid)
        assert len(original) <= 512 * 512 * 4
        for point in ((-.1,.5), (1.1,.5), (.5,-.1), (.5,1.1)):
            h,p = host.call("pick_neutral", {"session": sid, "x": point[0], "y": point[1]})
            assert not h["ok"] and not p
        found = None
        for y in (.3,.5,.7):
            for x in (.3,.5,.7):
                h,p = host.call("pick_neutral", {"session": sid, "x": x, "y": y})
                if h["ok"]:
                    assert not p
                    found = (x,y,h["result"])
                    break
            if found:
                break
        assert found, f"{mode}: no valid calibrated patch in fixture"
        x,y,wb = found
        # The target illuminant is independent of the current decode WB.
        good(host, "redecode", {"session": sid, "decode": {"raw_mode": mode, "white_balance": {"mode": "custom", "temperature_k": 4500., "tint": 5.}}})
        changed = source(host, sid)
        assert changed != original, "decoded original did not reflect custom WB"
        picked, _ = good(host, "pick_neutral", {"session": sid, "x": x, "y": y})
        assert abs(picked["temperature_k"] - wb["temperature_k"]) / wb["temperature_k"] < .025
        assert abs(picked["tint"] - wb["tint"]) < 2
        good(host, "redecode", {"session": sid, "decode": {"raw_mode": mode}})
        assert source(host, sid) == original, "as-shot restore changed original pixels"
        good(host, "close", {"session": sid})
    print("decoded source and neutral picker: PNG, both full RAW decode modes, custom WB, calibration invariance, bounds, source isolation and exact as-shot restoration passed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--raw", type=Path)
    args = parser.parse_args()
    host = Host([args.host,"--resources",args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix="spektralab-source-") as tmp:
            exercise(host,Path(tmp),args.raw)
    finally:
        if host.p.poll() is None:
            good(host,"shutdown")
            host.p.wait(timeout=20)


if __name__ == "__main__":
    main()
