#!/usr/bin/env python3
"""Real host proof/export contract; owned fixtures, standard library only."""
import argparse
from pathlib import Path
import struct
import tempfile

from host_smoke import Host, write_png


def good(host, method, params=None):
    header, pixels = host.call(method, params)
    assert header.get("ok"), (method, header)
    return header["result"], pixels


def tiff_pixels(path):
    data = path.read_bytes()
    assert data[:4] == b"II*\x00"
    at = struct.unpack_from("<I", data, 4)[0]
    fields = {}
    for i in range(struct.unpack_from("<H", data, at)[0]):
        tag, typ, count, value = struct.unpack_from("<HHII", data, at + 2 + i * 12)
        fields[tag] = (typ, count, value)
    offset, count = fields[273][2], fields[279][2]
    assert fields[259][2] == 1
    return data[offset:offset + count]


def exercise(host, directory):
    source = directory / "source.png"
    write_png(str(source), 96, 64)
    hello, _ = good(host, "hello")
    assert "render_proof" in hello["methods"]
    spaces = ["sRGB", "display-p3", "prophoto", "adobe-rgb", "rec2020"]
    assert hello["export_spaces"] == spaces
    params = {"auto_exposure": False, "grain_active": False, "halation_active": False, "glare_active": False}
    opened, _ = good(host, "open", {"path": str(source), "params": params})
    sid = opened["session"]
    view = {"session": sid, "tier": "full", "display": "srgb", "generation": 1}
    _, before = good(host, "render_view", view)
    base = {"session": sid, "params": params, "source_path": str(source),
            "adjustments": {"saturation": 24, "exposure": 0.4},
            "geometry": {"quarterTurns": 1, "crop": {"x": 0.1, "y": 0.1, "width": 0.8, "height": 0.8}},
            "long_edge": 53, "proof_long_edge": 128, "display": "srgb", "generation": 42}
    for space in spaces:
        for fmt in ("tiff8", "tiff16"):
            request = {**base, "color_space": space, "format": fmt}
            files_before = set(directory.iterdir())
            proof, rgba = good(host, "render_proof", request)
            assert files_before == set(directory.iterdir()), "proof wrote a file"
            w, h = proof["file_width"], proof["file_height"]
            assert max(w, h) == 53 and proof["generation"] == 42
            assert proof["image"]["width"] == w and proof["image"]["height"] == h
            assert proof["image"]["color_space"] == "sRGB" and len(rgba) == w * h * 4
            assert proof["print_cached"] and proof["stats"]["pixels"] == w * h
            assert not proof["compression_simulated"]
            assert proof["bit_depth"] == (16 if fmt == "tiff16" else 8)
            for key in ("moved_fraction", "outside_fraction", "clipped_fraction"):
                assert 0 <= proof["stats"][key] <= 1
            path = directory / f"{space}-{fmt}.tif"
            written, payload = good(host, "export_frame", {**request, "path": str(path)})
            assert not payload and written["width"] == w and written["height"] == h
            if space == "sRGB":
                raw = tiff_pixels(path)
                codes = raw if fmt == "tiff8" else bytes((v * 255 + 32767) // 65535 for (v,) in struct.iter_unpack("<H", raw))
                assert codes == bytes(v for i, v in enumerate(rgba) if i % 4 != 3), "proof differs from saved file codes"
            small, thumb = good(host, "render_proof", {**request, "proof_long_edge": 17, "generation": 43})
            assert max(small["image"]["width"], small["image"]["height"]) == 17
            assert small["stats"] == proof["stats"], "statistics used preview-sized pixels"
            assert len(thumb) <= 17 * 17 * 4
    _, after = good(host, "render_view", view)
    assert before == after, "proof/export changed editor film result"
    for bad in ({"proof_long_edge": 0}, {"proof_long_edge": 1.5}, {"proof_long_edge": 4097},
                {"display": "prophoto"}, {"color_space": "unknown"}):
        header, payload = host.call("render_proof", {**base, "format": "png", "color_space": "sRGB", **bad})
        assert not header.get("ok") and not payload
    good(host, "cancel", {"session": sid, "progress_id": "proof-cancelled-before-start"})
    header, payload = host.call("render_proof", {**base, "progress_id": "proof-cancelled-before-start"})
    assert header.get("error", {}).get("code") == "cancelled" and not payload
    private = {**base, "format": "png", "color_space": "sRGB", "proof_long_edge": 13}
    del private["session"]
    small, pixels = good(host, "render_proof", private)
    assert pixels and max(small["image"]["width"], small["image"]["height"]) == 13
    report, _ = good(host, "memory_report")
    assert len(report["persistent"]["sessions"]) == 1, "private proof leaked a session"
    _, restored = good(host, "render_view", view)
    assert restored == before, "private proof lost the suspended editor cache"
    assert hello["tiff_options"] == ["lzw", "preview-page"]
    for compression in ("none", "lzw"):
        path = directory / f"preview-{compression}.tif"
        result, payload = good(host, "export_frame", {**base, "format": "tiff16", "path": str(path),
            "tiff_compression": compression, "embed_preview": True})
        assert not payload
        data = path.read_bytes()
        offset = struct.unpack_from("<I", data, 4)[0]
        for page in range(2):
            assert offset and offset % 2 == 0
            count = struct.unpack_from("<H", data, offset)[0]
            tags = {struct.unpack_from("<HHII", data, offset + 2 + i * 12)[0]:
                    struct.unpack_from("<HHII", data, offset + 2 + i * 12)[3] for i in range(count)}
            assert tags[259] == (5 if compression == "lzw" else 1)
            assert tags[256] == result["width"] and tags[257] == result["height"]
            assert 34675 in tags
            if page == 1: assert tags[254] == 1
            offset = struct.unpack_from("<I", data, offset + 2 + count * 12)[0]
        assert not offset
    for bad in ({"tiff_compression": "zip"}, {"embed_preview": 1}, {"format": "jpeg", "embed_preview": True}):
        result, payload = host.call("export_frame", {**base, "format": "tiff16", "path": str(directory / "invalid.tif"), **bad})
        assert not result.get("ok") and result["error"]["code"] == "bad_request" and not payload
    good(host, "close", {"session": sid})
    print("proof host: five output spaces, 8/16-bit saved-file equality, full-file stats, bounded display payload, cancellation, validation and private-session cleanup passed", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--resources", required=True)
    args = parser.parse_args()
    host = Host([args.host, "--resources", args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix="spektralab-proof-") as directory:
            exercise(host, Path(directory))
    finally:
        if host.p.poll() is None:
            try:
                good(host, "shutdown")
            finally:
                host.p.wait(timeout=20)


if __name__ == "__main__":
    main()
