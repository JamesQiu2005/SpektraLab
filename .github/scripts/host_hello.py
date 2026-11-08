#!/usr/bin/env python3
"""Start spektralab-host, ask `hello` (and `params_schema` when a device exists), shut it down.

The cheapest end-to-end check that a staged host starts on a machine and
speaks desktop/HOST-PROTOCOL.md. It needs no Vulkan device: without one the
host still answers, with `backend.available: false`, and this script says so
rather than failing -- a GitHub-hosted Windows runner has no Vulkan driver.
Pass --require-vulkan to make a missing device a failure.

    python3 host_hello.py --host <spektralab-host[.exe]> --resources <engine dir>
"""
import argparse
import json
import struct
import subprocess
import sys


def send(proc, rid, method, params=None):
    header = json.dumps({"id": rid, "method": method, "params": params or {}}).encode()
    proc.stdin.write(struct.pack("<II", len(header), 0) + header)
    proc.stdin.flush()


def read_exact(stream, n):
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise EOFError("host closed stdout")
        buf += chunk
    return buf


def receive(proc, rid):
    while True:
        hlen, plen = struct.unpack("<II", read_exact(proc.stdout, 8))
        header = json.loads(read_exact(proc.stdout, hlen))
        read_exact(proc.stdout, plen)
        if header.get("id") == rid:  # skip unsolicited events
            return header


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--resources", required=True)
    ap.add_argument("--require-vulkan", action="store_true")
    ap.add_argument("--wrapper", help="e.g. wine, to run a Windows exe on Linux")
    args = ap.parse_args()

    cmd = ([args.wrapper] if args.wrapper else []) + [args.host, "--resources", args.resources]
    proc = subprocess.Popen(cmd,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        send(proc, 1, "hello")
        hello = receive(proc, 1)
        if not hello.get("ok"):
            sys.exit(f"hello failed: {hello}")
        result = hello["result"]
        backend = result.get("backend", {})
        print(f"protocol {result.get('protocol')}, host {result.get('host_version')}")
        print(f"backend: {json.dumps(backend)}")
        if result.get("protocol") != 1:
            sys.exit("unexpected protocol version")
        if not backend.get("available", False):
            msg = f"no Vulkan device: {backend.get('error')}"
            if args.require_vulkan:
                sys.exit(msg)
            print(f"note: {msg} (expected on a runner without a GPU driver)")

        if backend.get("available", False):  # the schema comes from the engine
            send(proc, 2, "params_schema")
            schema = receive(proc, 2)
            if not schema.get("ok"):
                sys.exit(f"params_schema failed: {schema}")
            print(f"params_schema: {len(json.dumps(schema['result']))} bytes")

        send(proc, 3, "shutdown")
        receive(proc, 3)
        code = proc.wait(timeout=30)
        if code != 0:
            sys.exit(f"host exited {code}")
        print("PASS")
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    main()
