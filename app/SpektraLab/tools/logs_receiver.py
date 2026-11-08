#!/usr/bin/env python3
"""logs_receiver.py -- a stand-in for the log's server, on this Mac, for a debug build launched with `--logs-endpoint`.

    logs_receiver.py --port 8765 --key KEY --out DIR

It answers as `server/logs` does for the two things the app asks of it
(`tools/logs_receiver.py` is the contract; this is not the server and proves
nothing about it):

    PUT /v1/logs/<install>/<session>   Authorization: Bearer KEY, a body of 1 byte to 4 MiB
        -> 204, the body kept as DIR/<install>/<session>.jsonl (the latest wins)
        -> 401 without the key, 400 for a name that is not an install's or a session's or an
           empty body, 413 past 4 MiB
    GET /v1/health                     -> 200 {"ok":true}

and writes one line a request to DIR/requests.jsonl: when, the path, the status, the bytes, the
content type and the build header -- what the check compares with what the app says it sent.
"""
import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

INSTALL = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SESSION = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
MOST = 4 << 20


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--key", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):  # quiet: requests.jsonl is the record
            pass

        def answer(self, status: int, body: bytes = b"", bytes_in: int = 0) -> None:
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            if body:
                self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            with (out / "requests.jsonl").open("a") as f:
                f.write(json.dumps({"at": time.time(), "method": self.command, "path": self.path, "status": status,
                                    "bytes": bytes_in, "type": self.headers.get("Content-Type"),
                                    "build": self.headers.get("X-SpektraLab-Build")}) + "\n")

        def do_GET(self) -> None:
            if self.path == "/v1/health":
                return self.answer(200, b'{"ok":true}')
            self.answer(404)

        def do_PUT(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if 0 < length <= MOST + 1 else b""
            parts = self.path.strip("/").split("/")
            if parts[:2] != ["v1", "logs"]:
                return self.answer(404, bytes_in=length)
            if self.headers.get("Authorization") != "Bearer " + args.key:
                return self.answer(401, bytes_in=length)
            if len(parts) != 4 or not INSTALL.match(parts[2]) or not SESSION.match(parts[3]) or length == 0:
                return self.answer(400, bytes_in=length)
            if length > MOST:
                return self.answer(413, bytes_in=length)
            folder = out / parts[2]
            folder.mkdir(exist_ok=True)
            (folder / (parts[3] + ".jsonl")).write_bytes(body)
            self.answer(204, bytes_in=length)

    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
