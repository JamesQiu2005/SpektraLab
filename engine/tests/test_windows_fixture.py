"""Check fixture provenance and meaningful rejection paths without a GPU oracle.

Synthetic mock outputs here exercise the tooling only, never engine parity.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import windows_fixture as wf


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.fixture = self.root / "fixture with spaces"
        self.manifest = wf.generate_fixture(self.fixture, size=6)
        self.resources = self.root / "resources"
        for name in ("spektrafilm_constants.bin", "neutral_print_filters.json", "print_luts.json",
                     "profiles/kodak_portra_400.json", "profiles/kodak_portra_endura.json"):
            path = self.resources / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        self.driver = self.root / "build with spaces" / "spk_render_fixture.exe"
        self.driver.parent.mkdir()
        self.driver.write_bytes(b"test driver, never executed")
        (self.driver.parent / "spektrafilm_engine.dll").write_bytes(b"test DLL, never loaded")
        self.output_dir = self.root / "run with spaces"

    def pixels(self):
        inp = self.manifest["input"]
        pixels = np.full((inp["height"], inp["width"], 4), 10000, dtype="<u2")
        pixels[..., 3] = 65535
        return pixels

    def fake_driver(self, argv, **kwargs):
        self.assertEqual(kwargs["cwd"], self.driver.parent)
        self.assertIsInstance(argv, list)
        self.assertEqual(argv[:3], [str(self.driver.resolve()), str(self.resources.resolve()),
                                   str((self.fixture / "input.f32").resolve())])
        pixels = self.pixels()
        pixels.tofile(argv[6])
        report = {"format_version": 1, "success": True, "stage": "done", "error": "",
                  "input": self.manifest["input"], "params_delta": wf.PARAMS,
                  "open_reply": {"params": wf.PARAMS},
                  "capabilities": {"backend": {"render_core": "native-vulkan"}},
                  "output": {**self.manifest["output_contract"], "written": True,
                             "packed_row_stride_px": pixels.shape[1],
                             "row_stride_px": pixels.shape[1] + 64, "byte_count": pixels.nbytes}}
        wf.write_json(Path(argv[7]), report)
        return subprocess.CompletedProcess(argv, 0, "driver completed", "")

    def good_run(self):
        with mock.patch.object(wf.subprocess, "run", side_effect=self.fake_driver):
            result = wf.run_fixture(self.driver, self.resources, self.fixture, self.output_dir)
        self.assertEqual(result["status"], "rendered", result.get("error"))
        self.assertEqual(result["verification"], "unverified")
        return result

    def reference(self, pixels=None, extension=".npy"):
        path = self.root / ("separate_unit_test_reference" + extension)
        if pixels is None:
            pixels = self.pixels().astype(np.float64) / 65535.0
        if extension == ".npy":
            np.save(path, pixels)
        else:
            pixels.astype("<u2").tofile(path)
        metadata = wf.read_json(self.output_dir / "reference-metadata.template.json")
        metadata.update(producer="unit_test_external_producer", reference_version="unit-test-v1",
                        reference_backend="unit-test-cpu", reference_sha256=wf.sha256_file(path))
        meta_path = self.root / "external-metadata.json"
        wf.write_json(meta_path, metadata)
        return path, meta_path, metadata

    def compare(self, reference, metadata, name="comparison.json"):
        return wf.compare_fixture(self.fixture, self.output_dir / "output.rgba16", reference,
                                  metadata, self.root / name)

    def test_generation_is_deterministic_and_refuses_to_replace_fixture(self):
        another = self.root / "second fixture"
        second = wf.generate_fixture(another, 6)
        self.assertEqual(second, self.manifest)
        self.assertEqual((another / "input.f32").read_bytes(), (self.fixture / "input.f32").read_bytes())
        self.assertEqual(self.manifest["input"]["width"], 8)
        self.assertEqual(wf.read_json(self.fixture / "params.json"), wf.PARAMS)
        with self.assertRaisesRegex(wf.FixtureError, "already exist"):
            wf.generate_fixture(self.fixture, 6)

    def test_corrupt_input_and_nonfinite_input_are_rejected(self):
        pixel_path = self.fixture / "input.f32"
        pixels = np.fromfile(pixel_path, dtype="<f4")
        pixels[0] = np.nan
        pixels.tofile(pixel_path)
        with self.assertRaisesRegex(wf.FixtureError, "SHA-256"):
            wf.validate_fixture(self.fixture)
        self.manifest["input"]["sha256"] = wf.sha256_file(pixel_path)
        wf.write_json(self.fixture / "manifest.json", self.manifest)
        with self.assertRaisesRegex(wf.FixtureError, "NaN or infinity"):
            wf.validate_fixture(self.fixture)

    def test_resource_contract_excludes_backend_kernels_but_tracks_baked_changes(self):
        before = wf.resource_snapshot(self.resources)
        (self.resources / "vulkan").mkdir()
        (self.resources / "vulkan" / "test.spv").write_bytes(b"different backend kernel")
        after = wf.resource_snapshot(self.resources)
        self.assertNotEqual(before["tree_sha256"], after["tree_sha256"])
        self.assertEqual(before["baked_sha256"], after["baked_sha256"])
        (self.resources / "spektrafilm_constants.bin").write_bytes(b"changed model")
        self.assertNotEqual(after["baked_sha256"], wf.resource_snapshot(self.resources)["baked_sha256"])

    def test_run_records_success_provenance_and_rejects_existing_output(self):
        result = self.good_run()
        self.assertEqual(result["driver_returncode"], 0)
        self.assertEqual(result["output"]["sha256"], wf.sha256_file(self.output_dir / "output.rgba16"))
        self.assertIn(str(self.driver.resolve()), result["binaries_sha256"])
        with mock.patch.object(wf.subprocess, "run") as run:
            with self.assertRaisesRegex(wf.FixtureError, "output already exists"):
                wf.run_fixture(self.driver, self.resources, self.fixture, self.output_dir)
            run.assert_not_called()

    def test_run_records_driver_failure_without_claiming_parity(self):
        def fail(argv, **kwargs):
            wf.write_json(Path(argv[7]), {"format_version": 1, "success": False,
                                         "stage": "render_first", "error": "kernel not ported"})
            return subprocess.CompletedProcess(argv, 1, "", "kernel not ported")
        with mock.patch.object(wf.subprocess, "run", side_effect=fail):
            result = wf.run_fixture(self.driver, self.resources, self.fixture, self.output_dir)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["verification"], "unverified")
        self.assertEqual(result["driver_returncode"], 1)
        self.assertEqual(result["driver_stage"], "render_first")
        self.assertIn("kernel not ported", result["error"])
        self.assertNotIn("output", result)

    def test_success_exit_code_is_insufficient_when_engine_resolves_wrong_color(self):
        def wrong_color(argv, **kwargs):
            completed = self.fake_driver(argv, **kwargs)
            report = wf.read_json(Path(argv[7]))
            report["open_reply"]["params"]["output_color_space"] = "sRGB"
            wf.write_json(Path(argv[7]), report)
            return completed
        with mock.patch.object(wf.subprocess, "run", side_effect=wrong_color):
            result = wf.run_fixture(self.driver, self.resources, self.fixture, self.output_dir)
        self.assertEqual(result["status"], "failed")
        self.assertIn("output_color_space", result["error"])

    def test_compare_distinct_bit_exact_artifact_is_allowed(self):
        self.good_run()
        path, metadata, _ = self.reference()
        result = self.compare(path, metadata)
        self.assertEqual(result["status"], "passed", result.get("error"))
        self.assertEqual(result["metrics"]["max_abs_counts"], 0)
        self.assertEqual(result["verification"], "compared_to_declared_external_reference")
        path, metadata, _ = self.reference(self.pixels(), ".rgba16")
        self.assertEqual(self.compare(path, metadata)["status"], "passed")

    def test_self_reference_and_copy_with_windows_producer_are_rejected(self):
        self.good_run()
        path, metadata, meta = self.reference()
        result = self.compare(self.output_dir / "output.rgba16", metadata)
        self.assertEqual(result["status"], "invalid")
        self.assertIn("not got itself", result["error"])
        meta["producer"] = wf.PRODUCER
        wf.write_json(metadata, meta)
        result = self.compare(path, metadata)
        self.assertEqual(result["status"], "invalid")
        self.assertIn("own external reference", result["error"])

    def test_wrong_fixture_resource_transfer_artifact_or_empty_version_fail_closed(self):
        self.good_run()
        path, metadata, original = self.reference()
        for key in ("input_sha256", "params_sha256", "resources_sha256", "output_transfer",
                    "output_color_space", "reference_sha256", "producer", "reference_version"):
            with self.subTest(key=key):
                meta = {**original, key: ""}
                wf.write_json(metadata, meta)
                result = self.compare(path, metadata)
                self.assertEqual(result["status"], "invalid")
                self.assertIn(key, result["error"])

    def test_wrong_shape_nonfinite_and_integer_numpy_references_are_rejected(self):
        self.good_run()
        for pixels in (np.zeros((1, 1, 3)), np.full(self.pixels().shape, np.nan), self.pixels()):
            with self.subTest(dtype=str(pixels.dtype), shape=pixels.shape):
                path, metadata, _ = self.reference(pixels)
                result = self.compare(path, metadata)
                self.assertEqual(result["status"], "invalid")

    def test_rgb_count_gate_can_fail_below_float_gate(self):
        got = self.pixels()
        want = got.astype(np.float64) / 65535.0
        want[0, 0, 0] = (10000 + 1.5001) / 65535.0
        result = wf.compare_pixels(got, want)
        self.assertLess(result["max_abs_float"], wf.FLOAT_TOLERANCE)
        self.assertEqual(result["max_abs_counts"], 2)
        self.assertFalse(result["passed"])

    def test_float_gate_can_fail_with_permitted_outlier_fraction(self):
        got = np.full((200, 200, 4), 10000, dtype="<u2")
        got[..., 3] = 65535
        want = got.astype(np.float64) / 65535.0
        want[0, 0, 0] = 10002 / 65535.0
        result = wf.compare_pixels(got, want)
        self.assertLessEqual(result["count_outlier_fraction"], wf.COUNT_OUTLIER_FRACTION)
        self.assertGreater(result["max_abs_float"], wf.FLOAT_TOLERANCE)
        self.assertFalse(result["passed"])


if __name__ == "__main__":
    unittest.main()
