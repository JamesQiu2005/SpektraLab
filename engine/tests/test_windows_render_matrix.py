"""Reject fixture contract mistakes before passing pixels to the DLL."""
import json
import ctypes
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from windows_render_matrix import (FixtureError, load_input, save_image, sha256_file,
                                   validate_params, COMMON, render)


class MatrixInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.input = self.directory / "input.f32"
        self.meta = self.directory / "input.f32.json"
        np.linspace(0, 1, 18, dtype="<f4").tofile(self.input)
        self.metadata = {"format_version": 2, "width": 3, "height": 2, "channels": 3,
                         "output_sha256": sha256_file(self.input), "output_byte_count": 72,
                         "dtype": "little-endian float32", "layout": "packed HWC RGB",
                         "row_order": "top_down", "row_stride_px": 3,
                         "output_color_space": "ProPhoto RGB", "output_cctf_encoding": False,
                         "gamma": [1, 1]}
        self.write_metadata()

    def write_metadata(self):
        self.meta.write_text(json.dumps(self.metadata), encoding="utf-8")

    def test_valid_decoder_contract(self):
        image, info = load_input(self.input, 3, 2, self.meta)
        self.assertEqual(image.shape, (2, 3, 3))
        self.assertEqual(info["sha256"], self.metadata["output_sha256"])

    def test_synthetic_input_without_decoder_claim(self):
        _, info = load_input(self.input, 3, 2, None)
        self.assertEqual(info["decoder"], {})

    def test_dimension_mismatch(self):
        with self.assertRaises(FixtureError):
            load_input(self.input, 2, 2, self.meta)

    def test_nonfinite_samples(self):
        values = np.fromfile(self.input, dtype="<f4")
        values[5] = np.nan
        values.tofile(self.input)
        with self.assertRaises(FixtureError):
            load_input(self.input, 3, 2, None)

    def test_hash_mismatch(self):
        self.metadata["output_sha256"] = "0" * 64
        self.write_metadata()
        with self.assertRaises(FixtureError):
            load_input(self.input, 3, 2, self.meta)

    def test_double_gamma_rejected(self):
        self.metadata["output_cctf_encoding"] = True
        self.metadata["gamma"] = [2.2, 4.5]
        self.write_metadata()
        with self.assertRaises(FixtureError):
            load_input(self.input, 3, 2, self.meta)

    def test_wrong_colour_space_rejected(self):
        self.metadata["output_color_space"] = "sRGB"
        self.write_metadata()
        with self.assertRaises(FixtureError):
            load_input(self.input, 3, 2, self.meta)

    def test_preview_and_raw_output_endpoints(self):
        from PIL import Image
        rgba = np.array([[[0, 32768, 65535, 65535]]], dtype=np.uint16)
        info = save_image(self.directory, "endpoint", rgba, True)
        np.testing.assert_array_equal(np.fromfile(self.directory / info["file"], dtype="<u2"), rgba.ravel())
        with Image.open(self.directory / info["preview"]["file"]) as preview:
            self.assertEqual(preview.getpixel((0, 0)), (0, 128, 255))
            self.assertEqual(preview.info["srgb"], 0)

    def test_output_space_ignored_by_engine_is_rejected(self):
        resolved = {**COMMON, "grain_active": True, "glare_active": True, "auto_exposure": True}
        validate_params(resolved, "default")
        resolved["output_color_space"] = "ProPhoto RGB"
        with self.assertRaises(FixtureError):
            validate_params(resolved, "default")

    def test_disabled_default_feature_is_rejected(self):
        resolved = {**COMMON, "grain_active": False, "glare_active": True, "auto_exposure": True}
        with self.assertRaises(FixtureError):
            validate_params(resolved, "default")

    def test_wrong_returned_shape_rejected_before_read_and_freed(self):
        from spk_ctypes import SpkResult
        freed = []
        pointer = ctypes.pointer(ctypes.c_uint16(1))
        def fake_render(handle, tier, out):
            result = ctypes.cast(out, ctypes.POINTER(SpkResult)).contents
            result.width, result.height, result.row_stride_px = 3, 1, 3
            result.rgba16 = pointer
            return 0
        lib = SimpleNamespace(spk_render=fake_render, spk_result_free=lambda value: freed.append(True))
        session = SimpleNamespace(_handle=1, _engine=SimpleNamespace(_lib=lib))
        with patch("numpy.ctypeslib.as_array", side_effect=AssertionError("must not read mismatched buffer")):
            with self.assertRaises(FixtureError):
                render(session, (2, 3, 4))
        self.assertEqual(freed, [True])


if __name__ == "__main__":
    unittest.main()
