#!/usr/bin/env python3
"""R4: `no_film` on export_frame / render_proof (1.3.4 "Don't Apply Film Simulation").

The Mac's Exporter.filePixels: with Sidecar.noFilm on, the file is the decode at
its own pixels, in the working space, through the same Layer 2 grade, geometry
and output conversion as a print. Each assertion here fails on a host that
ignores the field (it would write the film print) -- the pixel checks run before
the capability check so that a host that does not advertise `no-film` still
shows *which* property it breaks.

    python3 engine/tests/host_no_film.py --host <spektralab-host> --resources <engine dir>
"""
import argparse
from pathlib import Path
import struct
import tempfile
import zlib

from host_smoke import Host
from host_proof import good, tiff_pixels


def png_rgb(w, h):
    """A low-chroma ramp: a tone wedge along x, a +-12-code tint along y. Low
    chroma on purpose -- the file boundary's chroma knee (the same one a print
    passes) moves saturated colours, and this test is about which pixels go
    in, not about the knee."""
    out = bytearray()
    for y in range(h):
        t = int(24 * y / (h - 1)) - 12
        for x in range(w):
            v = 20 + int(215 * x / (w - 1))
            out += bytes((min(255, max(0, v + t)), v, min(255, max(0, v - t))))
    return bytes(out)


def write_png(path, w, h):
    raw = png_rgb(w, h)
    rows = b"".join(b"\x00" + raw[3 * w * y: 3 * w * (y + 1)] for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def u16_to_u8(raw):
    return bytes((v * 255 + 32767) // 65535 for (v,) in struct.iter_unpack("<H", raw))


def diff(a, b):
    d = [abs(x - y) for x, y in zip(a, b)]
    return max(d), sum(d) / len(d)


def exercise(host, folder):
    W, H = 96, 64
    source = folder / "源图.png"
    write_png(str(source), W, H)
    want = png_rgb(W, H)
    params = {"auto_exposure": False, "grain_active": False, "halation_active": False, "glare_active": False}
    opened, _ = good(host, "open", {"path": str(source), "params": params})
    sid = opened["session"]
    view = {"session": sid, "tier": "full", "display": "srgb", "generation": 1}
    _, editor_before = good(host, "render_view", view)
    base = {"session": sid, "params": params, "adjustments": {}, "geometry": {}, "long_edge": 0,
            "color_space": "sRGB", "format": "tiff16", "generation": 7}

    def export(name, **extra):
        path = folder / name
        written, payload = good(host, "export_frame", {**base, "path": str(path), **extra})
        assert not payload
        raw = tiff_pixels(path)
        return written, raw if extra.get("format", base["format"]) == "tiff8" else u16_to_u8(raw)

    # 1. The decode, not the print: a no-film sRGB file is the PNG's own codes
    #    (sRGB -> linear ProPhoto -> encoded ProPhoto -> sRGB, at 16 bits).
    w0, film = export("film.tif")
    w1, plain = export("no-film.tif", no_film=True)
    assert (w1["width"], w1["height"]) == (W, H), w1
    mx, mean = diff(plain, want)
    assert mx <= 2 and mean <= 0.25, f"no_film is not the decode: max {mx}, mean {mean:.3f} codes"
    fmx, fmean = diff(film, want)
    assert fmean > 5, f"control: the film print should not be the decode (mean {fmean:.2f})"

    # 2. The film settings are not applied: another stock, the same file.
    _, other = export("no-film-other-stock.tif", no_film=True,
                      params={**params, "film_stock": "kodak_gold_200", "print_exposure": 0.4})
    assert other == plain, "no_film pixels depend on the film params"

    # 3. Layer 2 and geometry still apply, as on a print.
    _, brighter = export("no-film-exposure.tif", no_film=True, adjustments={"exposure": 1.0})
    assert sum(brighter) > sum(plain) * 1.05, "Layer 2 exposure did not reach the no-film file"
    w2, turned = export("no-film-turned.tif", no_film=True, geometry={"quarterTurns": 1})
    assert (w2["width"], w2["height"]) == (H, W), w2
    # a quarter turn clockwise: out(x', y') = in(x = y', y = H - 1 - x')
    rotated = bytes(plain[3 * ((H - 1 - xp) * W + yp) + c]
                    for yp in range(W) for xp in range(H) for c in range(3))
    tmx, _ = diff(turned, rotated)
    assert tmx <= 1, f"quarter-turned no-film file is not the decode turned (max {tmx})"

    # 4. The proof is the file, here too.
    proof, rgba = good(host, "render_proof", {**base, "format": "tiff8", "no_film": True,
                                              "proof_long_edge": 4096, "display": "srgb"})
    _, file8 = export("no-film-8.tif", no_film=True, format="tiff8")
    assert (proof["file_width"], proof["file_height"]) == (W, H)
    shown = bytes(v for i, v in enumerate(rgba) if i % 4 != 3)
    assert shown == file8, f"no-film proof differs from its file {diff(shown, file8)} {len(shown)} {len(file8)}"

    # 5. Refusals: the DI is the film's negative; the field is a boolean.
    for method, extra in (("export_cineon", {"path": str(folder / "di.dpx")}),
                          ("render_proof", {"format": "di", "proof_long_edge": 64}),
                          ("export_frame", {"path": str(folder / "x.tif"), "no_film": 1})):
        request = {**base, "no_film": True, **extra}
        header, payload = host.call(method, request)
        assert not header.get("ok") and header["error"]["code"] == "bad_request" and not payload, (method, header)

    # 6. The editor's film session is untouched.
    _, editor_after = good(host, "render_view", view)
    assert editor_after == editor_before, "a no-film export changed the editor's print"
    good(host, "close", {"session": sid})

    hello, _ = good(host, "hello")
    assert "no-film" in hello.get("frame_options", []), "hello does not advertise frame_options no-film"
    print(f"no_film: decode codes (max {mx}, mean {mean:.3f} against the PNG; film print mean {fmean:.1f}), "
          "film params ignored, Layer 2 and geometry applied, proof = file, DI/type refusals, editor intact, "
          "advertised", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--resources", required=True)
    args = parser.parse_args()
    host = Host([args.host, "--resources", args.resources])
    try:
        with tempfile.TemporaryDirectory(prefix="spektralab-no-film-") as directory:
            exercise(host, Path(directory))
    finally:
        if host.p.poll() is None:
            try:
                good(host, "shutdown")
            finally:
                host.p.wait(timeout=20)


if __name__ == "__main__":
    main()
