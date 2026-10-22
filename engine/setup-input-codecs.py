#!/usr/bin/env python3
"""Fetch pinned input codecs, then build static libraries. Python 3.12+."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import urllib.request


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--sources", type=Path, required=True)
    p.add_argument("--build", type=Path, required=True)
    p.add_argument("--install", type=Path, required=True)
    p.add_argument("--cmake", default="cmake")
    p.add_argument("--generator")
    p.add_argument("--cc")
    p.add_argument("--cxx")
    p.add_argument("--make")
    p.add_argument("--toolchain", type=Path)
    p.add_argument("--jobs", type=int, default=4)
    a = p.parse_args()
    here = Path(__file__).resolve().parent
    root = a.sources.resolve()
    root.mkdir(parents=True, exist_ok=True)
    pins = json.loads((here / "cmake/input-codecs-pins.json").read_text(encoding="utf-8"))
    for pin in pins:
        archive = root / (pin["name"] + ".tar.gz")
        if not archive.exists():
            with urllib.request.urlopen(pin["url"], timeout=120) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
            raise RuntimeError(f"Input codec checksum mismatch: {archive}")
        source = root / pin["name"]
        if not source.exists():
            with tarfile.open(archive) as tar:
                for member in tar.getmembers():
                    if not (root / member.name).resolve().is_relative_to(root):
                        raise RuntimeError("Unsafe codec archive path")
                tar.extractall(root, filter="data")
        if not source.is_dir():
            raise RuntimeError(f"Missing codec source: {source}")
        # Reusing a directory must not silently reuse edited source under a
        # verified archive's name. Extra build outputs are permitted, edits to
        # pinned files are not. Never overwrite the developer's local edits.
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                if not member.isfile():
                    continue
                target = (root / member.name).resolve()
                if not target.is_relative_to(source.resolve()):
                    raise RuntimeError(f"Unexpected codec archive member: {member.name}")
                if not target.is_file():
                    raise RuntimeError(f"Pinned codec source was modified: {target}")
                with target.open("rb") as actual, tar.extractfile(member) as expected:
                    if hashlib.file_digest(actual, "sha256").digest() != hashlib.file_digest(expected, "sha256").digest():
                        raise RuntimeError(f"Pinned codec source was modified: {target}")
        print(f"{pin['name']}: verified archive", flush=True)
    configure = [a.cmake, "-S", (here / "cmake/input-dependencies").as_posix(), "-B", a.build.resolve().as_posix(),
                 "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=" + a.install.resolve().as_posix(),
                 "-DSPEKTRALAB_INPUT_SOURCES=" + root.as_posix()]
    if a.generator:
        configure += ["-G", a.generator]
    if a.toolchain:
        configure.append("-DCMAKE_TOOLCHAIN_FILE=" + a.toolchain.resolve().as_posix())
    for key, value in (("CMAKE_C_COMPILER", a.cc), ("CMAKE_CXX_COMPILER", a.cxx), ("CMAKE_MAKE_PROGRAM", a.make)):
        if value:
            configure.append(f"-D{key}={value.replace(chr(92), '/')}")
    subprocess.run(configure, check=True)
    subprocess.run([a.cmake, "--build", str(a.build.resolve()), "--target", "install", "--parallel", str(max(1,a.jobs))], check=True)


if __name__ == "__main__":
    main()
