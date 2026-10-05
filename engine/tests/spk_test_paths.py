"""Resolve binaries and resources for the native engine's test harnesses.

Explicit paths take precedence over environment overrides. A selected library
uses its checkout's sibling ``resources`` directory when one exists, keeping
the macOS dylib/metallib pair together across worktree comparisons.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

ENGINE = Path(__file__).resolve().parents[1]
LIBRARY_ENV = "SPEKTRAFILM_ENGINE_LIBRARY"
RESOURCES_ENV = "SPEKTRAFILM_ENGINE_RESOURCES"


def default_library() -> Path:
    if sys.platform == "win32":
        name = "spektrafilm_engine.dll"
    elif sys.platform == "darwin":
        name = "libspektrafilm_engine.dylib"
    else:
        name = "libspektrafilm_engine.so"
    return ENGINE / "build" / name


def resolve_library(library: Path | str | None = None) -> Path:
    return Path(library or os.environ.get(LIBRARY_ENV) or default_library()).expanduser().resolve()


def resolve_resources(resources: Path | str | None = None,
                      library: Path | str | None = None) -> Path:
    chosen = resources or os.environ.get(RESOURCES_ENV)
    if chosen:
        return Path(chosen).expanduser().resolve()
    # Honour an environment-selected library exactly like an explicit one.
    selected = library or os.environ.get(LIBRARY_ENV)
    if selected:
        binary = resolve_library(selected)
        # CMake's Windows output is <build>/engine/*.dll with resources in
        # <build>/engine/resources. build.sh's macOS layout remains
        # <checkout>/engine/build/*.dylib with ../resources beside build/.
        candidates = ([binary.parent / "resources", binary.parent.parent / "resources"]
                      if binary.suffix.lower() == ".dll"
                      else [binary.parent.parent / "resources"])
        for beside in candidates:
            if beside.is_dir():
                return beside.resolve()
    return (ENGINE / "resources").resolve()


def default_binary(name: str) -> Path:
    return ENGINE / "build" / (f"{name}.exe" if sys.platform == "win32" else name)


def add_resource_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--resources", type=Path,
                        help=f"engine resources directory (or {RESOURCES_ENV})")


def add_engine_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--library", "--dylib", dest="library", type=Path,
                        help=f"engine shared library/DLL (or {LIBRARY_ENV})")
    add_resource_argument(parser)


def engine_options(args: argparse.Namespace) -> dict:
    return {"library": args.library, "resources": args.resources}
