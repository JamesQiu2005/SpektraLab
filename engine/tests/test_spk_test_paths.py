"""The harness must grade the selected binary and its matching resources."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from spk_ctypes import Engine
from spk_test_paths import (ENGINE, LIBRARY_ENV, RESOURCES_ENV, add_engine_arguments,
                            default_binary, default_library, engine_options,
                            resolve_library, resolve_resources)


class EngineSelectionTests(unittest.TestCase):
    def setUp(self):
        self.env_patch = mock.patch.dict(os.environ, {}, clear=True)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def make_checkout(self, name):
        checkout = self.root / name
        (checkout / "build").mkdir(parents=True)
        (checkout / "resources").mkdir()
        library = checkout / "build" / "spektrafilm_engine.dll"
        library.touch()
        return library, checkout / "resources"

    def test_platform_defaults_preserve_macos_and_name_windows_outputs(self):
        with mock.patch("sys.platform", "darwin"):
            self.assertEqual(default_library(), ENGINE / "build" / "libspektrafilm_engine.dylib")
            self.assertEqual(default_binary("dump_setup"), ENGINE / "build" / "dump_setup")
        with mock.patch("sys.platform", "win32"):
            self.assertEqual(default_library(), ENGINE / "build" / "spektrafilm_engine.dll")
            self.assertEqual(default_binary("dump_setup"), ENGINE / "build" / "dump_setup.exe")

    def test_environment_selects_a_library_and_its_worktree_resources(self):
        library, resources = self.make_checkout("environment worktree")
        os.environ[LIBRARY_ENV] = str(library)
        self.assertEqual(resolve_library(), library.resolve())
        self.assertEqual(resolve_resources(), resources.resolve())

    def test_explicit_arguments_override_environment_and_keep_binary_pair(self):
        library, resources = self.make_checkout("explicit worktree")
        other, _ = self.make_checkout("environment worktree")
        os.environ[LIBRARY_ENV] = str(other)
        self.assertEqual(resolve_library(library), library.resolve())
        self.assertEqual(resolve_resources(library=library), resources.resolve())
        os.environ[RESOURCES_ENV] = str(self.root / "bundle resources")
        self.assertEqual(resolve_resources(library=library),
                         (self.root / "bundle resources").resolve())
        self.assertEqual(resolve_resources(resources, library), resources.resolve())

    def test_external_build_without_resources_uses_checkout_data(self):
        library = self.root / "external build" / "spektrafilm_engine.dll"
        self.assertEqual(resolve_resources(library=library), (ENGINE / "resources").resolve())

    def test_windows_cmake_resources_beside_dll_take_precedence(self):
        build = self.root / "CMake build"
        engine = build / "engine"
        (engine / "resources").mkdir(parents=True)
        (build / "resources").mkdir()
        library = engine / "spektrafilm_engine.dll"
        library.touch()
        os.environ[LIBRARY_ENV] = str(library)
        self.assertEqual(resolve_resources(), (engine / "resources").resolve())
        self.assertEqual(resolve_resources(library=library), (engine / "resources").resolve())

    def test_macos_keeps_build_sh_resource_layout_even_with_neighbor_directory(self):
        library, resources = self.make_checkout("macOS worktree")
        library = library.with_name("libspektrafilm_engine.dylib")
        library.touch()
        (library.parent / "resources").mkdir()
        self.assertEqual(resolve_resources(library=library), resources.resolve())

    def test_ctypes_loads_the_selected_paths_and_accepts_legacy_dylib(self):
        library, resources = self.make_checkout("selected worktree")
        lib = mock.Mock()
        lib.spk_engine_create.return_value = 1
        os.environ[LIBRARY_ENV] = str(library)
        with mock.patch("spk_ctypes.ctypes.CDLL", return_value=lib) as loader, \
                mock.patch.object(Engine, "_declare"):
            with Engine() as engine:
                self.assertEqual(engine.library_path, library.resolve())
                self.assertEqual(engine.resources_path, resources.resolve())
            loader.assert_called_once_with(str(library.resolve()))
            lib.spk_engine_create.assert_called_once_with(str(resources.resolve()).encode(), None)
            lib.spk_engine_destroy.assert_called_once_with(1)
            with Engine(dylib=str(library), resources=str(resources)):
                pass

    def test_conflicting_names_and_missing_library_fail_before_loading(self):
        with self.assertRaisesRegex(ValueError, "not both"):
            Engine(dylib="legacy.dylib", library="new.dll")
        with mock.patch("spk_ctypes.ctypes.CDLL") as loader:
            with self.assertRaisesRegex(FileNotFoundError, LIBRARY_ENV):
                Engine(library=self.root / "missing.dll")
            loader.assert_not_called()

    def test_cli_library_and_legacy_alias_reach_constructor_options(self):
        library, resources = self.make_checkout("CLI paths with spaces")
        for option in ("--library", "--dylib"):
            parser = argparse.ArgumentParser()
            add_engine_arguments(parser)
            args = parser.parse_args([option, str(library), "--resources", str(resources)])
            self.assertEqual(engine_options(args), {"library": library, "resources": resources})


if __name__ == "__main__":
    unittest.main()
