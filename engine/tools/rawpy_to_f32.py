"""Test-only LibRaw/rawpy bridge: RAW -> linear ProPhoto RGB float32.

This is a decoder fixture tool, not native Windows C++ RAW support or a
colour-parity oracle. LibRaw's 16-bit output is clipped/quantised; normalising
it cannot recover negative RGB or highlight values above one. Camera black
and white levels, scaling, and as-shot WB are handled by LibRaw. We disable
histogram brightening and data-dependent white-maximum adjustment, but retain
scale_colors() because it also applies WB.

Decoder and orientation contract:
https://letmaik.github.io/rawpy/api/rawpy.Params.html
https://www.libraw.org/docs/API-datastruct.html
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

import numpy as np

BRIDGE_VERSION = 2
ORIENTATION = {0: "none", 3: "180 degrees", 5: "90 degrees counterclockwise",
               6: "90 degrees clockwise"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def decoder_parameters(rawpy_module: Any) -> dict:
    """Keep the real decoder request and emitted policy in one place."""
    return {
        "demosaic_algorithm": rawpy_module.DemosaicAlgorithm.AHD,
        "half_size": False,
        "four_color_rgb": False,
        "output_color": rawpy_module.ColorSpace.ProPhoto,
        "output_bps": 16,
        "gamma": (1, 1),
        "no_auto_bright": True,
        "no_auto_scale": False,
        "adjust_maximum_thr": 0.0,
        "bright": 1.0,
        "use_camera_wb": True,
        "use_auto_wb": False,
        "user_wb": None,
        "user_black": None,
        "user_cblack": None,
        "user_sat": None,
        "user_flip": None,
        "highlight_mode": rawpy_module.HighlightMode.Clip,
        "exp_shift": None,
    }


def average_rgb16(rgb16: np.ndarray, factor: int, *, chunk_rows: int = 128) -> np.ndarray:
    """Top-left aligned block means; discard incomplete bottom/right blocks.

    Float64 reduction keeps the integer means accurate before the one float32
    conversion. Bands bound any reshape copy when trimming makes rows strided.
    They do not reduce LibRaw's full-resolution demosaic memory requirement.
    """
    if not isinstance(factor, int) or isinstance(factor, bool) or factor < 1:
        raise ValueError("downsample must be a positive integer")
    if chunk_rows < 1:
        raise ValueError("chunk_rows must be positive")
    if not isinstance(rgb16, np.ndarray) or rgb16.ndim != 3 or rgb16.shape[2] != 3:
        raise ValueError("LibRaw must produce an H x W x 3 RGB array")
    if rgb16.dtype.kind != "u" or rgb16.dtype.itemsize != 2:
        raise ValueError("LibRaw must produce uint16 when output_bps=16")
    height, width, _ = rgb16.shape
    out_height, out_width = height // factor, width // factor
    if not out_height or not out_width:
        raise ValueError("downsample exceeds the decoded image dimensions")
    linear = np.empty((out_height, out_width, 3), dtype="<f4", order="C")
    for start in range(0, out_height, chunk_rows):
        stop = min(start + chunk_rows, out_height)
        band = rgb16[start * factor:stop * factor, :out_width * factor]
        means = band.reshape(stop - start, factor, out_width, factor, 3).mean(
            axis=(1, 3), dtype=np.float64
        )
        linear[start:stop] = means / 65535.0
    if not np.isfinite(linear).all():
        raise ValueError("decoded RGB contains non-finite samples")
    if linear.min() < 0 or linear.max() > 1:
        raise ValueError("normalised uint16 RGB must be in [0, 1]")
    return linear


def _source_metadata(raw: Any) -> dict:
    wb = np.asarray(raw.camera_whitebalance, dtype=np.float64)
    # Do not label a decoder fallback as successful camera/as-shot WB.
    if wb.shape != (4,) or not np.isfinite(wb).all() or not (wb[:3] > 0).all():
        raise ValueError("valid camera/as-shot RGB white balance is required")
    sizes = raw.sizes
    fields = ("raw_height", "raw_width", "height", "width", "top_margin",
              "left_margin", "iheight", "iwidth", "flip")
    return {
        "sizes_before_postprocess": {name: int(getattr(sizes, name)) for name in fields},
        "black_level_per_channel": [int(v) for v in raw.black_level_per_channel],
        "white_level": int(raw.white_level),
        "camera_white_level_per_channel": (
            None if raw.camera_white_level_per_channel is None else
            [int(v) for v in raw.camera_white_level_per_channel]
        ),
        "camera_whitebalance": wb.tolist(),
    }


def decode_raw(source: Path, output: Path, *, downsample: int = 4,
               rawpy_module: Any = None) -> dict:
    """Decode once, write a fresh payload+manifest pair, and return the manifest.

    The rawpy_module injection exists for decoder-contract unit tests only.
    Those tests exercise synthetic pixels, never a real RAW decode or parity.
    """
    source, output = Path(source).resolve(), Path(output).resolve()
    sidecar = output.with_suffix(output.suffix + ".json")
    if not isinstance(downsample, int) or isinstance(downsample, bool) or downsample < 1:
        raise ValueError("downsample must be a positive integer")
    if not source.is_file():
        raise ValueError(f"RAW source does not exist: {source}")
    if source in (output, sidecar):
        raise ValueError("source and output paths must differ")
    for path in (output, sidecar):
        if path.exists():
            raise FileExistsError(f"refusing to overwrite: {path}")
    if rawpy_module is None:
        import rawpy as rawpy_module
    source_hash = sha256_file(source)
    source_size = source.stat().st_size
    params = decoder_parameters(rawpy_module)
    with rawpy_module.imread(str(source)) as raw:
        source_info = _source_metadata(raw)
        rgb16 = raw.postprocess(**params)
    linear = average_rgb16(rgb16, downsample)
    decoded_height, decoded_width, _ = rgb16.shape
    height, width, _ = linear.shape
    zero_fraction = [float(v) for v in (rgb16 == 0).mean(axis=(0, 1))]
    max_fraction = [float(v) for v in (rgb16 == 65535).mean(axis=(0, 1))]
    del rgb16
    if source.stat().st_size != source_size or sha256_file(source) != source_hash:
        raise ValueError("RAW source changed while decoding")
    flip = source_info["sizes_before_postprocess"]["flip"]
    metadata = {
        "format_version": BRIDGE_VERSION,
        "decoder": "rawpy/LibRaw test bridge, outside native engine",
        "verification": "decoded fixture only; engine parity unverified",
        "source_name": source.name,
        "source_byte_count": source_size,
        "source_sha256": source_hash,
        "bridge_sha256": sha256_file(Path(__file__).resolve()),
        "rawpy_version": rawpy_module.__version__,
        "libraw_version": ".".join(map(str, rawpy_module.libraw_version)),
        "numpy_version": np.__version__,
        "decoder_flags": dict(getattr(rawpy_module, "flags", {})),
        "source_metadata": source_info,
        "decode_parameters": {
            **{key: value for key, value in params.items()
               if key not in ("demosaic_algorithm", "output_color", "highlight_mode")},
            "demosaic_algorithm": "AHD", "output_color": "ProPhoto RGB",
            "highlight_mode": "Clip", "gamma": list(params["gamma"]),
        },
        "output_color_space": "ProPhoto RGB",
        "output_cctf_encoding": False,
        "white_balance": "camera/as shot",
        "auto_bright": False,
        "gamma": [1, 1],
        "output_bps_before_float": 16,
        "normalization": {"divisor": 65535, "range": [0.0, 1.0],
                          "retains_negative_rgb": False,
                          "retains_highlights_above_one": False},
        "orientation": {"policy": "LibRaw applies RAW metadata (user_flip=None)",
                        "raw_flip": flip, "operation": ORIENTATION.get(flip, "decoder defined")},
        "decoded_width": decoded_width,
        "decoded_height": decoded_height,
        "decoded_zero_fraction_per_channel": zero_fraction,
        "decoded_max_fraction_per_channel": max_fraction,
        "downsample": downsample,
        "sampling": {"method": "linear-light arithmetic block mean",
                     "alignment": "top-left after decoder orientation",
                     "accumulator_dtype": "float64",
                     "samples_per_output_pixel": downsample * downsample,
                     "edge_policy": "trim incomplete bottom/right blocks",
                     "trimmed_right_px": decoded_width - width * downsample,
                     "trimmed_bottom_px": decoded_height - height * downsample},
        "width": width, "height": height, "channels": 3,
        "dtype": "little-endian float32", "layout": "packed HWC RGB",
        "row_order": "top_down", "row_stride_px": width,
        "output_byte_count": int(linear.nbytes),
        "statistics": {"finite": True, "min": float(linear.min()),
                       "max": float(linear.max()),
                       "mean_per_channel": [float(v) for v in linear.mean(
                           axis=(0, 1), dtype=np.float64)]},
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    created = []
    try:
        with output.open("xb") as stream:
            created.append(output)
            linear.tofile(stream)
        metadata["output_sha256"] = sha256_file(output)
        with sidecar.open("x", encoding="utf-8", newline="\n") as stream:
            created.append(sidecar)
            stream.write(json.dumps(metadata, indent=2, allow_nan=False) + "\n")
    except Exception:
        for path in reversed(created):
            path.unlink(missing_ok=True)
        raise
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path, help="fresh tightly packed little-endian RGB float32")
    parser.add_argument("--downsample", type=int, default=4,
                        help="linear-light block average factor (default: 4)")
    args = parser.parse_args()
    try:
        metadata = decode_raw(args.source, args.output, downsample=args.downsample)
    except (ValueError, FileExistsError) as exc:
        parser.error(str(exc))
    print(json.dumps({"width": metadata["width"], "height": metadata["height"],
                      "output_sha256": metadata["output_sha256"],
                      **metadata["statistics"]}))


if __name__ == "__main__":
    main()
