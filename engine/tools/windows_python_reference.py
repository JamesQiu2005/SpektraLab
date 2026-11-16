"""Render a Windows fixture with the public Python film-model reference.

The public ``spektrafilm`` package is useful for the deterministic core
pipeline. It is not the private fork that produced the macOS Metal oracle:
public history has no ``spektrafilm.model.colour_baked`` or
``spektrafilm.service.schema``. The generated metadata states this origin.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.machinery
from importlib.metadata import PackageNotFoundError, version as package_version
import json
from pathlib import Path
import subprocess
import sys
import types

import numpy as np


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def install_import_shims() -> None:
    exiv2 = types.ModuleType("exiv2")
    exiv2.__spec__ = importlib.machinery.ModuleSpec("exiv2", loader=None)
    sys.modules["exiv2"] = exiv2

    raw = types.ModuleType("spektrafilm.utils.raw_file_processor")
    raw.__spec__ = importlib.machinery.ModuleSpec("spektrafilm.utils.raw_file_processor", loader=None)
    raw.load_and_process_raw_file = lambda *_args, **_kwargs: None
    sys.modules["spektrafilm.utils.raw_file_processor"] = raw

    oiio = types.ModuleType("OpenImageIO")
    oiio.__spec__ = importlib.machinery.ModuleSpec("OpenImageIO", loader=None)
    oiio.ImageSpec = object
    for name, value in {"UINT8": 1, "UINT16": 2, "UINT": 3,
                        "HALF": 4, "FLOAT": 5, "DOUBLE": 6}.items():
        setattr(oiio, name, value)
    sys.modules["OpenImageIO"] = oiio


def load_engine_profile(path: Path):
    from spektrafilm.profiles.io import profile_from_dict

    payload = json.loads(path.read_text(encoding="utf-8"))
    # Engine paper profiles include its EDR table; the public runtime has no
    # such field and the fixture does not enable EDR.
    payload.get("data", {}).pop("edr_tone_map", None)
    return profile_from_dict(payload)


def reference_version(reference_dir: Path) -> str:
    commit = subprocess.check_output(
        ["git", "-C", str(reference_dir), "rev-parse", "HEAD"], text=True
    ).strip()
    try:
        package = package_version("spektrafilm")
    except PackageNotFoundError:
        package = "source"
    return f"spektrafilm {package} {commit}"


def apply_effect_switches(params, fixture: dict) -> None:
    params.film_render.halation.active = bool(fixture.get("halation_active", True))
    params.film_render.dir_couplers.active = bool(fixture.get("dir_couplers_active", True))
    params.camera.diffusion_filter.active = bool(fixture.get("diffusion_filter_active", False))
    params.enlarger.diffusion_filter.active = bool(fixture.get("diffusion_filter_active", False))
    if "lens_aberrations_active" in fixture:
        if fixture["lens_aberrations_active"]:
            raise RuntimeError("public spektrafilm has no lens-aberration model; disable it for this reference")
        params.camera.lens_blur_um = 0.0
        params.enlarger.lens_blur = 0.0
        params.scanner.lens_blur = 0.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-dir", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--reference-dir", type=Path, required=True,
                        help="checkout of public https://github.com/andreavolpato/spektrafilm")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    args = parser.parse_args()

    for path in (args.output, args.metadata):
        if path.exists():
            raise SystemExit(f"output already exists: {path}")

    sys.path.insert(0, str(args.reference_dir / "src"))
    install_import_shims()
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.runtime.pipeline import SimulationPipeline

    manifest = json.loads((args.fixture_dir / "manifest.json").read_text(encoding="utf-8"))
    fixture = json.loads((args.fixture_dir / "params.json").read_text(encoding="utf-8"))
    inp = manifest["input"]
    width, height = inp["width"], inp["height"]
    frame = np.fromfile(args.fixture_dir / "input.f32", dtype="<f4").reshape(height, width, 3)

    params = init_params()
    params.film = load_engine_profile(args.resources / "profiles" / (fixture["film_stock"] + ".json"))
    params.print = load_engine_profile(args.resources / "profiles" / (fixture["print_stock"] + ".json"))
    params.film_render.grain.active = bool(fixture["grain_active"])
    params.print_render.glare.active = bool(fixture["glare_active"])
    params.camera.auto_exposure = bool(fixture["auto_exposure"])
    params.io.input_color_space = fixture["input_color_space"]
    params.io.input_cctf_decoding = bool(fixture["input_cctf_decoding"])
    params.io.output_color_space = fixture["output_color_space"]
    params.io.output_cctf_encoding = bool(fixture["output_cctf_encoding"])
    params.io.scan_film = bool(fixture.get("scan_film", False))
    params.settings.neutral_print_filters_from_database = bool(
        fixture.get("neutral_print_filters_from_database", True)
    )
    if "print_exposure" in fixture:
        params.enlarger.print_exposure = float(fixture["print_exposure"])
    apply_effect_switches(params, fixture)
    params = digest_params(params)
    # Stock-specific digesting may set defaults; the fixture switch wins.
    apply_effect_switches(params, fixture)

    output = np.asarray(SimulationPipeline(params).process(frame), dtype=np.float64)
    if output.shape != (height, width, 3):
        raise RuntimeError(f"reference returned {output.shape}, expected {(height, width, 3)}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    np.save(args.output, output, allow_pickle=False)

    metadata = {
        "format_version": 1,
        "input_sha256": sha256(args.fixture_dir / "input.f32"),
        "params_sha256": sha256(args.fixture_dir / "params.json"),
        "resources_sha256": manifest["resource_contract"]["baked_sha256"],
        "width": width,
        "height": height,
        "row_order": "top_down",
        "output_color_space": params.io.output_color_space,
        "output_transfer": "encoded" if params.io.output_cctf_encoding else "linear",
        "reference_sha256": sha256(args.output),
        "producer": "spektrafilm_public_python",
        "reference_version": reference_version(args.reference_dir),
        "reference_backend": "python-numba",
    }
    args.metadata.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"reference {output.shape}; {metadata['reference_version']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
