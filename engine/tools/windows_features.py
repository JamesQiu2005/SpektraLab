"""Exercise geometry, stock-LUT preview and DI through the built Windows C ABI.

Local kernel oracles run in CTest. This integration gate checks dimensions,
cache invalidation, baked table transport, metadata and result ownership; it is
not an external Metal/Python whole-image parity claim.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import struct
import time

import numpy as np

from windows_render_matrix import BASE, COMMON, Engine, EngineError, SpkResult, SPK_OK, load_input, render
from windows_lifecycle import frame, check_ledger
from windows_fixture import require, resource_snapshot, sha256_file, write_json


class LutResult:
    """Keep the actual DLL allocation alive, including across engine destruction."""
    def __init__(self, session, kind, stock, shape):
        self.lib = session._engine._lib
        self.result, reply = SpkResult(), ctypes.c_char_p()
        self.closed = False
        start = time.perf_counter()
        if kind == "preview":
            status = self.lib.spk_preview_stock_lut(session._handle, stock.encode(), b"full",
                                                   ctypes.byref(self.result), ctypes.byref(reply))
        else:
            status = self.lib.spk_export_di(session._handle, stock.encode() if stock else None,
                                           ctypes.byref(self.result), ctypes.byref(reply))
        self.wall_ms = (time.perf_counter() - start) * 1000
        try:
            self.meta = session._engine._take_json(reply)
            require(status == SPK_OK, session._engine._last_error())
            r = self.result
            require((r.height, r.width, 4) == shape and r.row_stride_px >= r.width,
                    "LUT/DI result dimensions or stride differ")
            require(bool(r.rgba16) and bool(r.texture), "LUT/DI result has no owned pixels")
            require(r.reprint == 1 and r.negative_was_cached == 1, "LUT/DI flags differ")
            require(bool((self.pixels()[..., 3] == 65535).all()), "LUT/DI alpha differs")
        except Exception:
            self.close()
            raise

    def pixels(self):
        require(not self.closed, "test attempted to read a freed result")
        r = self.result
        return np.ctypeslib.as_array(r.rgba16, shape=(r.height * r.row_stride_px * 4,)).reshape(
            r.height, r.row_stride_px, 4)[:, :r.width]

    def digest(self):
        return hashlib.sha256(self.pixels().tobytes()).hexdigest()

    def close(self):
        if not self.closed:
            self.lib.spk_result_free(ctypes.byref(self.result))
            self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def baked_tables(resources):
    # Read the documented blob layout independently of the engine's reader.
    data = (resources / "spektrafilm_constants.bin").read_bytes()
    magic, version, count, _ = struct.unpack_from("<4sIII", data)
    require(magic == b"SPKR" and version == 1, "unsupported baked blob")
    rows = {}
    for i in range(count):
        entry = struct.unpack_from("<64s6I2Q", data, 16 + i * 104)
        name = entry[0].split(b"\0", 1)[0].decode()
        if not name.startswith("print_lut/"):
            continue
        dtype, ndim = entry[1:3]
        dims, offset, size = entry[3:7], entry[7], entry[8]
        require(dtype == 1 and ndim == 4 and offset + size <= len(data), "invalid baked LUT")
        rows[name.split("/", 1)[1]] = np.frombuffer(data, dtype="<f4", count=size // 4,
                                                     offset=offset).reshape(dims).copy()
    return rows


def geometry_cases(engine, image, output, report, small):
    h, w = image.shape[:2]
    cases = [("turn90", {"geometry_quarter_turns": 1}, np.rot90(image, -1)),
             ("flip_h", {"geometry_flip_h": True}, image[:, ::-1])]
    if small:
        cases += [("turn180", {"geometry_quarter_turns": 2}, np.rot90(image, 2)),
                  ("turn270", {"geometry_quarter_turns": 3}, np.rot90(image, 1)),
                  ("flip_v", {"geometry_flip_v": True}, image[::-1]),
                  ("turn_and_flip", {"geometry_quarter_turns": 1, "geometry_flip_h": True},
                   np.rot90(image, -1)[:, ::-1])]
    cases += [("crop_rotate", {"geometry_crop_x": 0.1, "geometry_crop_y": 0.15,
               "geometry_crop_w": 0.73, "geometry_crop_h": 0.625,
               "geometry_rotation_deg": 17.5, "geometry_quarter_turns": 1}, None)]
    for name, delta, transformed in cases:
        shape = (max(1, int(h * delta.get("geometry_crop_h", 1) + 0.5)),
                 max(1, int(w * delta.get("geometry_crop_w", 1) + 0.5)))
        if delta.get("geometry_quarter_turns", 0) % 2:
            shape = shape[::-1]
        shape += (4,)
        with engine.open(image, {**COMMON, **BASE}) as session:
            old, _ = render(session, (h, w, 4))
            old_digest = hashlib.sha256(old.tobytes()).hexdigest()
            changed = session.set_params(delta)
            require(changed["invalidated"] == "shoot", "geometry failed to invalidate negative")
            actual, info = render(session, shape, reprint=True)
            require(not info["negative_was_cached"], "geometry reused the old negative")
            repeated, rep = render(session, shape, reprint=True)
            require(rep["negative_was_cached"] and np.array_equal(actual, repeated),
                    "geometry cached reprint differs")
            require(hashlib.sha256(old.tobytes()).hexdigest() == old_digest, "prior copied result changed")
        row = {"success": True, "delta": delta, "width": shape[1], "height": shape[0],
               "render": info, "sha256": hashlib.sha256(actual.tobytes()).hexdigest(),
               "cached_reprint_bit_exact": True}
        if transformed is not None:
            with engine.open(np.ascontiguousarray(transformed), {**COMMON, **BASE}) as reference:
                expected, _ = render(reference, shape)
            require(np.array_equal(actual, expected), f"geometry {name} differs from transformed input")
            row["explicit_input_transform_bit_exact"] = True
        else:
            row["numerical_oracle"] = "independent direct-kernel geometry CTest; integration dimensions/cache here"
        report["geometry"][name] = row
        if not small and name == "crop_rotate":
            path = output / "crop-rotate.rgba16"
            actual.tofile(path)
            row["output"] = {"file": path.name, "bytes": path.stat().st_size,
                             "color_space": "sRGB", "transfer": "encoded", "format": "RGBA16_LE"}
        check_ledger(engine.memory_report())
        print(f"geometry {name}: passed", flush=True)


def lut_cases(engine, image, output, report, small, held):
    catalog = engine.print_lut_catalog()
    tables = baked_tables(engine.resources_path)
    require(set(catalog) == set(tables), "LUT catalog differs from blob")
    for stock, table in tables.items():
        got = engine.print_lut_table(stock)
        require(got.dtype == table.dtype and got.shape == table.shape and got.tobytes() == table.tobytes(),
                f"baked LUT changed: {stock}")
    report["baked_tables_bit_exact"] = sorted(tables)
    stocks = sorted(catalog) if small else ["kodak_portra_endura"]
    shape = image.shape[:2] + (4,)
    for stock in stocks:
        entry = catalog[stock]
        with engine.open(image, {**COMMON, **BASE, "film_stock": entry["paired_film"],
                                "print_stock": stock}) as session:
            params_before = session.get_params()
            with LutResult(session, "preview", stock, shape) as preview, LutResult(session, "di", stock, shape) as di:
                preview_hash, di_hash = preview.digest(), di.digest()
                require(preview.meta["print_stock"] == stock and di.meta["print_stock"] == stock,
                        "LUT metadata has wrong stock")
                require("warning" not in preview.meta and "warning" not in di.meta, "paired LUT warns")
                require(preview.meta["paired_film"] == entry["paired_film"] and
                        di.meta["lut_size"] == entry["lut_size"], "LUT pairing/size differs")
                require(session.get_params() == params_before, "LUT call changed session parameters")
                require(bool(np.ptp(preview.pixels()[..., :3])) and bool(np.ptp(di.pixels()[..., :3])),
                        "LUT/DI output unexpectedly constant")
                with LutResult(session, "preview", stock, shape) as again, LutResult(session, "di", None, shape) as di_again:
                    require(again.digest() == preview_hash and di_again.digest() == di_hash,
                            "LUT/DI repeat or default stock differs")
                session.set_params({"print_exposure": 1.2})
                with LutResult(session, "preview", stock, shape) as again, LutResult(session, "di", stock, shape) as di_again:
                    require(again.digest() == preview_hash and di_again.digest() == di_hash,
                            "print exposure edit changed LUT/DI negative path")
                row = {"success": True, "preview": preview.meta, "di": di.meta,
                       "preview_sha256": preview_hash, "di_sha256": di_hash,
                       "preview_wall_ms": preview.wall_ms, "di_wall_ms": di.wall_ms,
                       "repeat_and_print_edit_bit_exact": True, "width": shape[1], "height": shape[0]}
                if not small:
                    for name, value, space in (("stock-preview", preview, {
                            "color_space": entry["output_color_space"],
                            "output_cctf_encoding": entry["output_cctf_encoding"]}),
                            ("di", di, "normalised negative density; not display RGB")):
                        path = output / f"{name}.rgba16"
                        value.pixels().tofile(path)
                        row[name + "_file"] = {"file": path.name, "bytes": path.stat().st_size,
                                                "format": "RGBA16_LE", "interpretation": space}
                report["lut_di"][stock] = row
            retained = LutResult(session, "preview", stock, shape)
            held.append((retained, retained.digest()))
            retained_di = LutResult(session, "di", stock, shape)
            held.append((retained_di, retained_di.digest()))
        check_ledger(engine.memory_report())
        print(f"LUT/DI {stock}: passed", flush=True)
    if small:
        with engine.open(image, {**COMMON, **BASE}) as session:
            with LutResult(session, "preview", "fujifilm_crystal_archive_typeii", shape) as mismatch:
                require("warning" in mismatch.meta and "kodak_portra_400" in mismatch.meta["warning"],
                        "mismatched film did not produce a useful warning")
            try:
                with LutResult(session, "preview", "missing_stock", shape):
                    pass
            except (EngineError, ValueError) as error:
                require("no shipped print-preview LUT" in str(error), "unexpected missing LUT error")
                report["missing_lut_rejected"] = str(error)
            else:
                raise AssertionError("missing LUT accepted")
            # A failed request must not poison the session or invalidate the result.
            with LutResult(session, "preview", "kodak_portra_endura", shape):
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--input-metadata", type=Path)
    parser.add_argument("--width", type=int, default=193)
    parser.add_argument("--height", type=int, default=129)
    args = parser.parse_args()
    require(not args.output.exists(), "output directory exists; choose a new path")
    args.output.mkdir(parents=True)
    report = {"success": False, "external_parity": "unverified", "geometry": {}, "lut_di": {},
              "harness_sha256": sha256_file(Path(__file__))}
    held = []
    try:
        if args.input:
            image, report["input"] = load_input(args.input, args.width, args.height, args.input_metadata)
        else:
            image = frame(args.height, args.width)
            report["input"] = {"kind": "synthetic", "shape": list(image.shape),
                               "sha256": hashlib.sha256(image.tobytes()).hexdigest()}
        with Engine(library=args.library, resources=args.resources) as engine:
            report["library_sha256"] = sha256_file(engine.library_path)
            report["build_info"] = engine.build_info
            report["resources"] = resource_snapshot(engine.resources_path)
            geometry_cases(engine, image, args.output, report, args.input is None)
            lut_cases(engine, image, args.output, report, args.input is None, held)
        for result, digest in held:
            require(result.digest() == digest, "LUT/DI result changed across later renders or engine destroy")
        report["retained_results_after_engine_destroy"] = len(held)
        report["success"] = True
    finally:
        for result, _ in held:
            result.close()
        write_json(args.output / "report.json", report)


if __name__ == "__main__":
    main()
