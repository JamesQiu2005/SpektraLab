#!/usr/bin/env python3
"""End-to-end smoke test of spektralab-host (desktop/HOST-PROTOCOL.md).

Standard library only. Spawns the host, speaks the framed protocol, and walks
every method a frontend needs: hello -> params_schema -> probe -> thumbnail ->
open -> render (rgba8 sRGB, rgba16 working space, reprint) -> set_params ->
export_image (tiff16/tiff8/png/jpeg) -> write_image -> export_cube -> close ->
shutdown. Inputs are a synthetic PNG and TIFF the test writes itself, plus
any RAW files given on the command line (camera files are never committed).

    engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
        [--resources build/host-linux-x64/engine] [--wrapper wine] [RAW ...]

Exit status 0 only if every check passed; each check prints one line.
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

FAILURES = []


def check(cond, label, detail=""):
    print(("ok   " if cond else "FAIL ") + label + (f"  ({detail})" if detail else ""), flush=True)
    if not cond:
        FAILURES.append(label)
    return cond


class Host:
    def __init__(self, cmd):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.next_id = 1
        self.events = []
        self.stderr = []
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        for line in self.p.stderr:
            self.stderr.append(line.decode("utf-8", "replace").rstrip())

    def send(self, method, params=None, payload=b""):
        rid = self.next_id
        self.next_id += 1
        head = json.dumps({"id": rid, "method": method, "params": params or {}}).encode()
        self.p.stdin.write(struct.pack("<II", len(head), len(payload)) + head + payload)
        self.p.stdin.flush()
        return rid

    def read_frame(self):
        pre = self.p.stdout.read(8)
        if len(pre) < 8:
            raise EOFError("host closed stdout; stderr tail:\n" + "\n".join(self.stderr[-20:]))
        h, n = struct.unpack("<II", pre)
        header = json.loads(self.p.stdout.read(h))
        payload = self.p.stdout.read(n) if n else b""
        return header, payload

    def wait(self, rid):
        while True:
            header, payload = self.read_frame()
            if "event" in header:
                self.events.append(header)
                continue
            if header.get("id") == rid:
                return header, payload

    def call(self, method, params=None, payload=b""):
        return self.wait(self.send(method, params, payload))


def write_png(path, w, h):
    rows = b""
    for y in range(h):
        rows += b"\x00" + bytes(
            v for x in range(w) for v in (int(255 * x / (w - 1)), int(255 * y / (h - 1)), 128))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    open(path, "wb").write(data)


def write_tiff16(path, w, h):
    """Uncompressed 16-bit RGB, untagged -> the host must read it as linear ProPhoto."""
    pix = b"".join(struct.pack("<HHH", int(65535 * x / (w - 1)) // 4, int(65535 * y / (h - 1)) // 4, 8000)
                   for y in range(h) for x in range(w))
    entries = [(256, 4, 1, w), (257, 4, 1, h), (258, 3, 3, None), (259, 3, 1, 1), (262, 3, 1, 2),
               (273, 4, 1, None), (277, 3, 1, 3), (278, 4, 1, h), (279, 4, 1, len(pix))]
    ifd_at = 8
    extra_at = ifd_at + 2 + 12 * len(entries) + 4
    bps_at = extra_at
    pix_at = bps_at + 6
    out = b"II*\x00" + struct.pack("<I", ifd_at) + struct.pack("<H", len(entries))
    for tag, typ, cnt, val in entries:
        if tag == 258:
            out += struct.pack("<HHII", tag, typ, cnt, bps_at)
        elif tag == 273:
            out += struct.pack("<HHII", tag, typ, cnt, pix_at)
        elif typ == 3:
            out += struct.pack("<HHIHH", tag, typ, cnt, val, 0)
        else:
            out += struct.pack("<HHII", tag, typ, cnt, val)
    out += struct.pack("<I", 0) + struct.pack("<HHH", 16, 16, 16) + pix
    open(path, "wb").write(out)


def tiff_info(path):
    d = open(path, "rb").read()
    if d[:4] != b"II*\x00":
        return None
    at = struct.unpack_from("<I", d, 4)[0]
    n = struct.unpack_from("<H", d, at)[0]
    tags = {}
    for i in range(n):
        tag, typ, cnt, val = struct.unpack_from("<HHII", d, at + 2 + 12 * i)
        if typ == 3 and cnt == 1:
            val &= 0xFFFF
        tags[tag] = (typ, cnt, val)
    return tags


def exercise(host, path, tmp, label, raw):
    _, _ = None, None
    h, _ = host.call("probe", {"path": path})
    if not check(h["ok"], f"{label}: probe", h.get("error")):
        return
    r = h["result"]
    check(r["width"] > 0 and r["height"] > 0, f"{label}: probe size", f'{r["kind"]} {r["width"]}x{r["height"]}')

    h, px = host.call("thumbnail", {"path": path, "long_edge": 320})
    if check(h["ok"], f"{label}: thumbnail", h.get("error")):
        im = h["result"]["image"]
        check(max(im["width"], im["height"]) <= 320 and len(px) == im["width"] * im["height"] * 4,
              f"{label}: thumbnail payload", f'{im["width"]}x{im["height"]} {h["result"].get("source")}')
        # orientation agrees with probe's displayed aspect
        check((im["width"] >= im["height"]) == (r["width"] >= r["height"]),
              f"{label}: thumbnail orientation matches probe")

    t0 = time.time()
    h, _ = host.call("open", {"path": path})
    if not check(h["ok"], f"{label}: open", h.get("error")):
        return
    o = h["result"]
    sid = o["session"]
    check(o["width"] == r["width"] and o["height"] == r["height"], f"{label}: open size matches probe",
          f'{o["width"]}x{o["height"]}, {time.time() - t0:.1f} s, timings {o["timings_ms"]}')

    h, px = host.call("render", {"session": sid, "tier": "preview", "format": "rgba8", "display": "srgb",
                                 "progress_id": "smoke-1"})
    if check(h["ok"], f"{label}: render preview rgba8 srgb", h.get("error")):
        im = h["result"]["image"]
        ok = len(px) == im["width"] * im["height"] * 4 and im["color_space"] == "sRGB"
        mean = sum(px[0::4][:200000]) / max(1, len(px[0::4][:200000]))
        alpha = set(px[3::4][:10000])
        check(ok and alpha == {255} and 2 < mean < 253, f"{label}: preview pixels",
              f'{im["width"]}x{im["height"]} mean R {mean:.1f} timings {h["result"]["timings_ms"]}')
        check(any(e.get("progress_id") == "smoke-1" for e in host.events), f"{label}: progress events")

    h, px = host.call("render", {"session": sid, "tier": "live", "format": "rgba16"})
    if check(h["ok"], f"{label}: render live rgba16", h.get("error")):
        im = h["result"]["image"]
        check(len(px) == im["width"] * im["height"] * 8 and im["color_space"] == "ProPhoto RGB",
              f"{label}: rgba16 payload names the working space", im["color_space"])

    h, _ = host.call("set_params", {"session": sid, "delta": {"print_exposure": 1.2}})
    if not h["ok"]:
        h, _ = host.call("get_params", {"session": sid})
        check(h["ok"], f"{label}: get_params", h.get("error"))
    else:
        check(True, f"{label}: set_params")
        h, _ = host.call("render", {"session": sid, "tier": "preview", "reprint": True, "format": "rgba8",
                                    "display": "display-p3"})
        check(h["ok"], f"{label}: reprint preview display-p3",
              h.get("error") or f'reprinted={h["result"]["reprinted"]} {h["result"]["image"]["color_space"]}')

    for fmt, cs, ext in (("tiff16", "sRGB", "tif"), ("tiff8", "display-p3", "tif"), ("png", "sRGB", "png"),
                         ("jpeg", "prophoto", "jpg")):
        out = os.path.join(tmp, f"{label}-{fmt}.{ext}")
        h, _ = host.call("export_image", {"session": sid, "path": out, "format": fmt, "color_space": cs,
                                          "long_edge": 1200 if raw else 0})
        if check(h["ok"] and os.path.getsize(out) == h["result"]["bytes"], f"{label}: export {fmt} {cs}",
                 h.get("error") or f'{h["result"]["width"]}x{h["result"]["height"]} {h["result"]["bytes"]} B'):
            if fmt.startswith("tiff"):
                tags = tiff_info(out)
                check(tags is not None and 34675 in tags and tags[256][2] == h["result"]["width"],
                      f"{label}: {fmt} has an ICC profile and its size")
        h2, _ = host.call("export_image", {"session": sid, "path": out, "format": fmt, "color_space": cs})
        check(not h2["ok"] and h2["error"]["code"] == "io_error", f"{label}: export refuses to overwrite")

    host.call("close", {"session": sid})
    h, _ = host.call("render", {"session": sid, "tier": "live"})
    check(not h["ok"] and h["error"]["code"] == "not_found", f"{label}: closed session is gone")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--resources")
    ap.add_argument("--wrapper", help="e.g. wine")
    ap.add_argument("raws", nargs="*")
    a = ap.parse_args()
    cmd = ([a.wrapper] if a.wrapper else []) + [a.host]
    if a.resources:
        cmd += ["--resources", a.resources]
    host = Host(cmd)
    tmp = tempfile.mkdtemp(prefix="spk-host-smoke-")

    h, _ = host.call("hello")
    if not check(h["ok"] and h["result"]["protocol"] == 1, "hello", h.get("error")):
        return 1
    b = h["result"]["backend"]
    print(f'     backend: {b}', flush=True)
    if not check(b.get("available"), "engine available", b.get("error", "")):
        return 1
    h, _ = host.call("ping")
    check(h["ok"], "ping")
    h, _ = host.call("params_schema")
    check(h["ok"] and len(json.dumps(h["result"])) > 1000, "params_schema")
    h, _ = host.call("print_lut_catalog")
    stocks = list(h["result"].keys()) if h["ok"] else []
    check(h["ok"] and stocks, "print_lut_catalog", f"{len(stocks)} stocks")
    h, _ = host.call("memory_report")
    check(h["ok"], "memory_report")
    h, _ = host.call("nonsense_method")
    check(not h["ok"] and h["error"]["code"] == "unsupported", "unknown method -> unsupported")
    h, _ = host.call("probe", {"path": os.path.join(tmp, "missing.nef")})
    check(not h["ok"] and h["error"]["code"] == "not_found", "missing file -> not_found")
    if stocks:
        out = os.path.join(tmp, "print.cube")
        h, _ = host.call("export_cube", {"print_stock": stocks[0], "path": out})
        check(h["ok"] and open(out).read().count("\n") > h["result"]["size"] ** 3, "export_cube", h.get("error"))

    # write_image: the app's own finished pixels (R1)
    w, hh = 64, 48
    px = b"".join(struct.pack("<HHHH", 65535 * x // (w - 1), 65535 * y // (hh - 1), 30000, 65535)
                  for y in range(hh) for x in range(w))
    out = os.path.join(tmp, "written.tif")
    h, _ = host.call("write_image", {"path": out, "format": "tiff16", "color_space": "display-p3",
                                     "width": w, "height": hh}, px)
    check(h["ok"] and tiff_info(out)[256][2] == w, "write_image tiff16", h.get("error"))

    png = os.path.join(tmp, "ramp.png")
    write_png(png, 96, 64)
    exercise(host, png, tmp, "png", False)
    tif = os.path.join(tmp, "ramp16.tif")
    write_tiff16(tif, 80, 120)
    exercise(host, tif, tmp, "tiff16", False)
    for i, raw in enumerate(a.raws):
        exercise(host, raw, tmp, f"raw{i}-{os.path.basename(raw)}", True)

    rid = host.send("shutdown")
    h, _ = host.wait(rid)
    check(h["ok"], "shutdown")
    try:
        code = host.p.wait(timeout=20)
    except subprocess.TimeoutExpired:
        host.p.kill()
        code = None
    check(code == 0, "host exited 0", str(code))
    print(f"{'PASS' if not FAILURES else 'FAIL'}: {len(FAILURES)} failure(s); outputs in {tmp}")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
