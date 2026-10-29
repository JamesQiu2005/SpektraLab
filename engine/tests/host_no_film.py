#!/usr/bin/env python3
"""Actual Vulkan host no-film view/export/proof contract, owned fixtures only."""
import argparse
import json
from pathlib import Path
import shutil
import struct
import tempfile

from host_smoke import Host, write_png
from host_proof import good, tiff_pixels


def exercise(host, root):
    hello, _ = good(host, "hello")
    assert "no_film" in hello.get("view_options", []), "host does not advertise no_film"
    source = root / "source.png"
    write_png(str(source), 96, 64)
    params = {"grain_active": True, "halation_active": False, "glare_active": False, "auto_exposure": False}
    opened, _ = good(host, "open", {"path": str(source), "params": params})
    sid = opened["session"]
    view = {"session": sid, "tier": "full", "display": "srgb", "generation": 1}
    _, film = good(host, "render_view", view)
    no_film = dict(view, no_film=True)
    shown, original = good(host, "render_view", no_film)
    assert original != film and not shown["print_cached"]
    assert (shown["image"]["width"], shown["image"]["height"]) == (96, 64)
    _, decoded = good(host, "render_source", {"session": sid, "display": "srgb", "long_edge": 0})
    assert max(abs(a - b) for a, b in zip(original, decoded)) <= 2, "bypass differs from decoded source"
    restored, pixels = good(host, "render_view", view)
    assert restored["print_cached"] and pixels == film, "bypass overwrote the random film print cache"
    for value in (1, "true", None, [], {}):
        error, payload = host.call("render_view", dict(view, no_film=value))
        assert not error["ok"] and error["error"]["code"] == "bad_request" and not payload

    # An existing film/date geometry stays dormant. The request's source cut is
    # ignored; ordinary output geometry still executes once after Layer 2.
    edge_params = dict(params, overscan_active=True, overscan_format="135", overscan_frame_seed=7,
                       geometry_crop_x=.1, geometry_crop_y=.1, geometry_crop_w=.8, geometry_crop_h=.8,
                       date_imprint_active=True, date_imprint_text="26 10 28")
    good(host, "set_params", {"session": sid, "delta": edge_params})
    saved, _ = good(host, "get_params", {"session": sid})
    _, edge_film = good(host, "render_view", view)
    geometry = {"crop": {"x": .125, "y": .125, "width": .75, "height": .75}, "quarterTurns": 1, "flipH": True}
    current = dict(no_film, geometry=geometry, source_geometry={"crop": {"width": .2, "height": .2}},
                   adjustments={"exposure": -.75, "saturation": 20})
    output, graded = good(host, "render_view", current)
    assert (output["image"]["width"], output["image"]["height"]) == (48, 72)
    assert (output["image"]["source_width"], output["image"]["source_height"]) == (96, 64)
    still_saved, _ = good(host, "get_params", {"session": sid})
    assert still_saved == saved, "bypass mutated dormant source geometry"
    restored, pixels = good(host, "render_view", view)
    assert restored["print_cached"] and pixels == edge_film
    # Source-side film exposure, edge, date and negative scan selection cannot
    # leak into the source view. The real source and Post-Dev remain its inputs.
    good(host, "set_params", {"session": sid, "delta": {"exposure_compensation_ev": 3, "digital_intermediate": True}})
    _, changed = good(host, "render_view", current)
    assert changed == graded, "film or DI settings leaked into no_film"

    base = dict(current, source_path=str(source), proof_long_edge=128, long_edge=0, generation=42)
    for space in ("sRGB", "display-p3", "prophoto", "adobe-rgb", "rec2020"):
        for fmt in ("tiff8", "tiff16"):
            request = dict(base, format=fmt, color_space=space)
            proof, rgba = good(host, "render_proof", request)
            assert (proof["file_width"], proof["file_height"]) == (48, 72)
            assert not proof["print_cached"] and len(rgba) == 48 * 72 * 4
            assert proof["stats"]["pixels"] == 48 * 72
            path = root / f"{space}-{fmt}.tif"
            written, payload = good(host, "export_frame", dict(request, path=str(path)))
            assert not payload and (written["width"], written["height"]) == (48, 72)
            if space == "sRGB":
                raw = tiff_pixels(path)
                codes = raw if fmt == "tiff8" else bytes((v * 255 + 32767) // 65535 for (v,) in struct.iter_unpack("<H", raw))
                assert codes == bytes(v for i, v in enumerate(rgba) if i % 4 != 3), "no-film proof differs from actual file"
            small, _ = good(host, "render_proof", dict(request, proof_long_edge=17))
            assert max(small["image"]["width"], small["image"]["height"]) == 17
            assert small["stats"] == proof["stats"]

    # Private/background exports are the same frozen source/grade/geometry.
    active = root / "active.tif"
    request = dict(base, params=edge_params, format="tiff16", color_space="prophoto", path=str(active))
    good(host, "export_frame", request)
    private = dict(request, path=str(root / "private.tif")); del private["session"]
    good(host, "export_frame", private)
    assert tiff_pixels(active) == tiff_pixels(root / "private.tif")
    report, _ = good(host, "memory_report")
    assert len(report["persistent"]["sessions"]) == 1, "private bypass leaked a session"

    # Upstream R4 rejects bypass on the dedicated negative export and proof.
    cineon = dict(request, source_geometry={}, geometry={}, no_film=False, path=str(root / "di-before.tif"))
    good(host, "export_cineon", cineon)
    for method, extra in (("export_cineon", {}), ("render_proof", {"format": "di", "proof_long_edge": 64})):
        h, data = host.call(method, dict(cineon, no_film=True, **extra))
        assert not h["ok"] and h["error"]["code"] == "bad_request" and not data

    hole = {"path": str(source), "decode": {}, "geometry": {}, "placement": {}, "autoExposure": False}
    pair = {"schemaVersion": 1, "folder": str(root), "spacingMM": 1, "turned": False, "left": hole, "right": hole}
    pair_path = root / "pair.spektrapair"; pair_path.write_text(json.dumps(pair))
    opened, _ = good(host, "open_pair", {"path": str(pair_path), "pair": pair, "params": params})
    pair_id = opened["session"]
    paired = dict(base, session=pair_id, source_path=str(pair_path), pair=pair, params=params,
                  path=str(root / "must-not-exist.tif"), format="tiff8", color_space="sRGB")
    for method in ("render_view", "export_frame", "render_proof"):
        request = dict(paired, format="rgba8") if method == "render_view" else paired
        error, payload = host.call(method, request)
        assert not error["ok"] and error["error"]["code"] == "bad_request" and "pair" in error["error"]["message"], (method, error)
        assert not payload and not (root / "must-not-exist.tif").exists()
    good(host, "close", {"session": pair_id})
    good(host, "close", {"session": sid})
    print("no-film host: source isolation, dormant edge/date crop, grading, five-space exports/proofs, private frames, cache restoration, Cineon and pair/type rejection passed", flush=True)


def exercise_raw(host, root, raw):
    """Optional owned camera input: the bypass must use the frozen decode."""
    owned = root / ("owned-no-film" + raw.suffix)
    shutil.copyfile(raw, owned)
    params = {"grain_active": False, "halation_active": False, "glare_active": False, "auto_exposure": False}
    for mode in ("compatible16", "headroom"):
        decode = {"raw_mode": mode}
        opened, _ = good(host, "open", {"path": str(owned), "decode": decode, "params": params})
        sid = opened["session"]
        request = {"session": sid, "tier": "full", "display": "srgb", "no_film": True, "long_edge": 256,
                   "adjustments": {"exposure": -1}, "geometry": {"quarterTurns": 1}}
        shown, original = good(host, "render_view", request)
        assert max(shown["image"]["width"], shown["image"]["height"]) == 256 and not shown["print_cached"]
        custom = dict(decode, white_balance={"mode": "custom", "temperature_k": 4500., "tint": 5.})
        good(host, "redecode", {"session": sid, "decode": custom})
        _, changed = good(host, "render_view", request)
        assert changed != original, f"{raw.name} {mode}: bypass ignored the custom RAW white balance"
        path = root / f"{raw.name}-{mode}-active.tif"
        frozen = dict(request, params=params, decode=custom, source_path=str(owned), path=str(path),
                      source_geometry={"crop": {"width": .25, "height": .25}}, format="tiff8", color_space="sRGB")
        good(host, "export_frame", frozen)
        good(host, "redecode", {"session": sid, "decode": decode})
        _, restored = good(host, "render_view", request)
        assert restored == original, f"{raw.name} {mode}: exact as-shot restoration failed"
        private_path = root / f"{raw.name}-{mode}-frozen.tif"
        good(host, "export_frame", dict(frozen, path=str(private_path)))
        assert tiff_pixels(path) == tiff_pixels(private_path), "pending RAW decode snapshot exported older editor pixels"
        proof, rgba = good(host, "render_proof", dict(frozen, proof_long_edge=256))
        assert tiff_pixels(path) == bytes(v for i, v in enumerate(rgba) if i % 4 != 3)
        assert proof["stats"]["pixels"] == proof["file_width"] * proof["file_height"]
        _, after_private = good(host, "render_view", request)
        assert after_private == original, "private RAW bypass changed the editor decode"
        report, _ = good(host, "memory_report")
        assert len(report["persistent"]["sessions"]) == 1, "private RAW bypass leaked a session"
        good(host, "close", {"session": sid})
    print(f"no-film RAW {raw.name}: both decode modes, custom WB, exact restore, frozen private export/proof and editor isolation passed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--raw", type=Path, action="append", default=[])
    args = parser.parse_args()
    host = Host([args.host, "--resources", args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix="spektralab-no-film-") as tmp:
            exercise(host, Path(tmp))
            for raw in args.raw:
                exercise_raw(host, Path(tmp), raw)
    finally:
        if host.p.poll() is None:
            good(host, "shutdown"); host.p.wait(timeout=20)


if __name__ == "__main__":
    main()
