"""Verify that an identified Nikon HE/HE* RAW is rejected honestly and cleanly.

This test reads only container metadata before executing the native host. It
does not decode RAW pixels or extract a preview as a substitute. The source
file is kept read-only and every requested native output must remain absent.
Python is the test runner only, never part of the native RAW runtime.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess


def require(value, message):
    if not value:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def nikon_metadata(path):
    """Read TIFF and Nikon MakerNote fields independently of LibRaw.

    Nikon's HE/HE* files use compression tag 34713, which is also used for
    supported NEF compression. That TIFF tag alone must never classify HE.
    Require the Nikon compression field and JPEG-XS payload signature too.
    """
    data = path.read_bytes()
    require(data[:4] == b"II\x2a\0", "test requires little-endian classic TIFF NEF")

    def chunk(offset, length):
        require(0 <= offset <= len(data) and 0 <= length <= len(data) - offset,
                "metadata field points outside the source file")
        return data[offset:offset + length]

    def read_ifd(offset, base=0):
        count, = struct.unpack("<H", chunk(offset, 2))
        entries = chunk(offset + 2, count * 12)
        tags = {}
        for index in range(count):
            tag, kind, length, pointer = struct.unpack_from("<HHII", entries, index * 12)
            size = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8}.get(kind)
            if size is None:
                continue
            require(tag not in tags, "duplicate TIFF tag")
            start = offset + 2 + index * 12 + 8 if size * length <= 4 else base + pointer
            tags[tag] = (kind, length, start, chunk(start, size * length))
        return tags

    def numbers(entry):
        kind, length, _, value = entry
        require(kind in (1, 3, 4), "expected unsigned numeric metadata field")
        return struct.unpack("<" + {1: "B", 3: "H", 4: "I"}[kind] * length, value)

    def scalar(entry):
        value = numbers(entry)
        require(len(value) == 1, "expected scalar metadata field")
        return value[0]

    root = read_ifd(struct.unpack("<I", chunk(4, 4))[0])
    exif = read_ifd(scalar(root[34665]))
    _, _, maker_offset, maker = exif[37500]
    require(maker[:6] == b"Nikon\0" and maker[10:14] == b"II\x2a\0",
            "unsupported Nikon MakerNote container")
    maker_base = maker_offset + 10
    maker_ifd = read_ifd(maker_base + struct.unpack("<I", chunk(maker_base + 4, 4))[0], maker_base)
    if 0x51 in maker_ifd:
        require(len(maker_ifd[0x51][3]) >= 12, "truncated Nikon compression MakerNote")
        compression = struct.unpack_from("<H", maker_ifd[0x51][3], 10)[0]
        compression_field = "Nikon MakerNote 0x0051, byte offset 10"
    else:
        require(0x93 in maker_ifd, "Nikon compression MakerNote is missing")
        compression = scalar(maker_ifd[0x93])
        compression_field = "Nikon MakerNote 0x0093"
    require(compression in (13, 14), "sample is not an HE/HE* NEF; do not reject ordinary Nikon RAW")
    raw_ifds = [read_ifd(offset) for offset in numbers(root[330])]
    raw_ifds = [tags for tags in raw_ifds if 254 in tags and scalar(tags[254]) == 0]
    require(len(raw_ifds) == 1, "expected exactly one primary RAW IFD")
    raw = raw_ifds[0]
    offset, byte_count = scalar(raw[273]), scalar(raw[279])
    require(0 < byte_count <= len(data) - offset, "invalid RAW strip extent")
    signature = chunk(offset, 4).hex()
    require(signature == "ff10ff50" and scalar(raw[259]) == 34713,
            "Nikon compression metadata and RAW payload signature disagree")
    width, height = scalar(raw[256]), scalar(raw[257])
    require(width > 0 and height > 0, "RAW dimensions are invalid")
    return {
        "make": root[271][3].rstrip(b"\0").decode("ascii"),
        "model": root[272][3].rstrip(b"\0").decode("ascii"),
        "raw_width": width, "raw_height": height, "raw_megapixels": width * height / 1e6,
        "raw_bits_per_sample": scalar(raw[258]), "tiff_compression": scalar(raw[259]),
        "nikon_nef_compression": compression,
        "nikon_nef_compression_name": {13: "High Efficiency (HE)", 14: "High Efficiency* (HE*)"}[compression],
        "compression_field": compression_field, "raw_strip_offset": offset,
        "raw_strip_bytes": byte_count, "raw_strip_signature": signature,
        "orientation": scalar(root[274]), "metadata_only": True,
        "decoded_pixels_produced": False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-source-sha256")
    parser.add_argument("--modes", nargs="+", choices=("default", "compatible16", "headroom"),
                        default=["default", "compatible16", "headroom"])
    args = parser.parse_args()
    for key in ("input", "driver", "resources", "output"):
        setattr(args, key, getattr(args, key).resolve())
    require(args.input.is_file() and args.driver.is_file(), "RAW or native executable is missing")
    require(args.resources.is_dir(), "native resources are missing")
    require(not args.output.exists(), "test output must be fresh")
    source_hash = sha256(args.input)
    require(args.expected_source_sha256 is None or source_hash == args.expected_source_sha256.lower(),
            "RAW source differs from the expected sample")
    args.output.mkdir(parents=True)
    report = {"success": False, "raw_decode_supported": False, "rendered": False,
              "benchmark_available": False, "external_engine_parity": "not tested",
              "input": {"path": str(args.input), "bytes": args.input.stat().st_size, "sha256": source_hash},
              "driver_sha256": sha256(args.driver), "harness_sha256": sha256(Path(__file__)),
              "decode_modes": args.modes, "cases": []}
    try:
        report["metadata"] = nikon_metadata(args.input)
        unicode_source = args.output / "尼康 原图 🧪.NEF"
        shutil.copy2(args.input, unicode_source)
        environment = {key: value for key, value in os.environ.items()
                       if not key.upper().startswith(("PYTHON", "SPEKTRAFILM_"))}
        windows = Path(environment.get("SystemRoot", r"C:\Windows"))
        environment["PATH"] = str(windows / "System32") + os.pathsep + str(windows)
        for mode in args.modes:
            for name, source in (("original_path", args.input), ("unicode_path", unicode_source)):
                directory = args.output / f"{mode}-{name}"
                directory.mkdir()
                tiff, native_report, decoded = (directory / filename for filename in ("result.tif", "report.json", "decoded.f32"))
                command = [str(args.driver), "--input", str(source), "--output", str(tiff),
                           "--report", str(native_report), "--resources", str(args.resources),
                           "--decoded-output", str(decoded)]
                if mode != "default":
                    command += ["--decode-mode", mode]
                run = subprocess.run(command, env=environment, capture_output=True, timeout=60)
                case = {"path_case": name, "decode_mode": mode, "command": command,
                        "returncode": run.returncode, "stdout": run.stdout.decode("utf-8", "replace"),
                        "stderr": run.stderr.decode("utf-8", "replace")}
                report["cases"].append(case)
                require(run.returncode != 0, "unsupported Nikon compression was silently accepted")
                require("Nikon HE/HE* compression" in case["stderr"],
                        "native rejection did not identify the unsupported Nikon compression")
                require("lossless" in case["stderr"].lower(),
                        "native rejection omitted the supported NEF recording alternative")
                require(not list(directory.iterdir()), "unsupported RAW left output or temporary artifacts")
                case["no_output_or_temporary_files"] = True
                case["source_sha256_unchanged"] = sha256(source) == source_hash
                require(case["source_sha256_unchanged"], "native rejection modified the source RAW")
        require(sha256(args.input) == source_hash, "original RAW changed during validation")
        require(sha256(args.driver) == report["driver_sha256"], "native executable changed during validation")
        report["success"] = True
        report["scope"] = "Nikon HE/HE* identification and rejection only; no decoded fixture, no TIFF render, no render timing"
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        (args.output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"success": True, "metadata": report["metadata"],
                      "cases_passed": len(report["cases"])}, ensure_ascii=True))


if __name__ == "__main__":
    main()
