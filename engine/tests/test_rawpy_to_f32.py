"""RAW bridge contract tests using synthetic decoder mocks only.

These tests do not open/demosaic a real RAW, validate native RAW support, or
establish image colour parity. They pin the bridge's data and provenance wire.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import rawpy_to_f32 as bridge


class FakeRaw:
    def __init__(self, pixels):
        self.pixels = pixels
        self.sizes = SimpleNamespace(raw_width=10, raw_height=8, width=7, height=5,
                                     top_margin=1, left_margin=1, iwidth=7, iheight=5, flip=5)
        self.black_level_per_channel = [512, 512, 512, 512]
        self.white_level = 16383
        self.camera_white_level_per_channel = None
        self.camera_whitebalance = [2.0, 1.0, 1.5, 0.0]
        self.postprocess = mock.Mock(return_value=pixels)
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.closed = True


class RawBridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "mock source.ARW"
        self.source.write_bytes(b"synthetic RAW placeholder, never really decoded")
        self.output = self.root / "result folder" / "input.f32"
        self.sidecar = self.output.with_suffix(".f32.json")
        self.pixels = np.arange(7 * 5 * 3, dtype=np.uint16).reshape(7, 5, 3)
        self.raw = FakeRaw(self.pixels)
        self.decoder = SimpleNamespace(
            imread=mock.Mock(return_value=self.raw), __version__="mock-decoder",
            libraw_version=(0, 0, 0), flags={"mock": True},
            DemosaicAlgorithm=SimpleNamespace(AHD="mock-AHD"),
            ColorSpace=SimpleNamespace(ProPhoto="mock-ProPhoto"),
            HighlightMode=SimpleNamespace(Clip="mock-Clip"),
        )

    def decode(self, factor=2):
        return bridge.decode_raw(self.source, self.output, downsample=factor,
                                 rawpy_module=self.decoder)

    def assert_no_outputs(self):
        self.assertFalse(self.output.exists())
        self.assertFalse(self.sidecar.exists())

    def test_factor_one_preserves_order_and_normalises_endpoints(self):
        pixels = np.array([[[0, 1, 65535], [32768, 1234, 42000]],
                           [[65535, 0, 12345], [12, 24, 36]]], dtype=np.uint16)
        actual = bridge.average_rgb16(pixels, 1)
        np.testing.assert_array_equal(actual, (pixels.astype(np.float64) / 65535).astype("<f4"))
        self.assertEqual(actual.dtype.str, "<f4")
        self.assertTrue(actual.flags.c_contiguous)
        self.assertEqual(actual[0, 0, 0], 0)
        self.assertEqual(actual[0, 0, 2], 1)

    def test_linear_block_mean_and_incomplete_edges(self):
        # Distinct edge samples reveal accidental inclusion or interpolation.
        pixels = np.arange(5 * 7 * 3, dtype=np.uint16).reshape(5, 7, 3)
        pixels[-1] = 65535
        pixels[:, -1] = 65535
        expected = np.empty((2, 3, 3), dtype="<f4")
        for y in range(2):
            for x in range(3):
                expected[y, x] = pixels[2*y:2*y+2, 2*x:2*x+2].mean(axis=(0, 1)) / 65535
        np.testing.assert_array_equal(bridge.average_rgb16(pixels, 2), expected)

    def test_chunking_is_numerically_identical_for_strided_rows(self):
        pixels = np.arange(37 * 43 * 3, dtype=np.uint16).reshape(37, 43, 3)
        for factor in (1, 2, 3, 7):
            with self.subTest(factor=factor):
                np.testing.assert_array_equal(
                    bridge.average_rgb16(pixels, factor, chunk_rows=1),
                    bridge.average_rgb16(pixels, factor, chunk_rows=128))

    def test_invalid_factors_and_empty_images_are_rejected(self):
        for factor in (0, -1, 1.5, True, 99):
            with self.subTest(factor=factor), self.assertRaises(ValueError):
                bridge.average_rgb16(self.pixels, factor)
        with self.assertRaises(ValueError):
            bridge.average_rgb16(np.zeros((0, 3, 3), dtype=np.uint16), 1)

    def test_incorrect_channels_dtypes_and_nonfinite_samples_are_rejected(self):
        for pixels in (np.zeros((3, 3), dtype=np.uint16),
                       np.zeros((3, 3, 4), dtype=np.uint16),
                       np.zeros((3, 3, 3), dtype=np.uint8),
                       np.full((3, 3, 3), np.nan, dtype=np.float32)):
            with self.subTest(shape=pixels.shape, dtype=pixels.dtype), self.assertRaises(ValueError):
                bridge.average_rgb16(pixels, 1)

    def test_decoder_request_pins_linear_rgb_wb_levels_and_orientation(self):
        self.decode()
        requested = self.raw.postprocess.call_args.kwargs
        self.assertEqual(requested["demosaic_algorithm"], "mock-AHD")
        self.assertEqual(requested["output_color"], "mock-ProPhoto")
        self.assertEqual(requested["output_bps"], 16)
        self.assertEqual(requested["gamma"], (1, 1))
        self.assertTrue(requested["use_camera_wb"])
        self.assertFalse(requested["use_auto_wb"])
        self.assertTrue(requested["no_auto_bright"])
        self.assertFalse(requested["no_auto_scale"])
        self.assertEqual(requested["adjust_maximum_thr"], 0)
        self.assertEqual(requested["bright"], 1)
        self.assertEqual(requested["highlight_mode"], "mock-Clip")
        for key in ("user_wb", "user_black", "user_cblack", "user_sat", "user_flip", "exp_shift"):
            self.assertIsNone(requested[key])
        self.assertTrue(self.raw.closed)

    def test_manifest_hashes_payload_shape_and_trimmed_orientation(self):
        metadata = self.decode()
        self.assertEqual(metadata, json.loads(self.sidecar.read_text(encoding="utf-8")))
        self.assertEqual(metadata["output_sha256"], bridge.sha256_file(self.output))
        self.assertEqual(metadata["source_sha256"], bridge.sha256_file(self.source))
        self.assertEqual(metadata["bridge_sha256"], bridge.sha256_file(Path(bridge.__file__)))
        self.assertEqual((metadata["width"], metadata["height"]), (2, 3))
        self.assertEqual(metadata["output_byte_count"], 2 * 3 * 3 * 4)
        self.assertEqual(metadata["row_order"], "top_down")
        self.assertEqual(metadata["orientation"]["raw_flip"], 5)
        self.assertEqual(metadata["sampling"]["trimmed_right_px"], 1)
        self.assertEqual(metadata["sampling"]["trimmed_bottom_px"], 1)
        self.assertEqual(metadata["source_metadata"]["black_level_per_channel"], [512] * 4)
        self.assertEqual(metadata["source_metadata"]["white_level"], 16383)
        actual = np.fromfile(self.output, dtype="<f4").reshape(3, 2, 3)
        np.testing.assert_array_equal(actual, bridge.average_rgb16(self.pixels, 2))

    def test_manifest_explicitly_limits_integer_decode_to_zero_one(self):
        self.raw.postprocess.return_value = np.array([[[0, 65535, 1234]]], dtype=np.uint16)
        metadata = self.decode(factor=1)
        self.assertEqual(metadata["decoded_zero_fraction_per_channel"], [1, 0, 0])
        self.assertEqual(metadata["decoded_max_fraction_per_channel"], [0, 1, 0])
        self.assertEqual(metadata["normalization"]["range"], [0, 1])
        self.assertFalse(metadata["normalization"]["retains_highlights_above_one"])
        self.assertFalse(metadata["normalization"]["retains_negative_rgb"])
        self.assertFalse(metadata["output_cctf_encoding"])
        self.assertIn("unverified", metadata["verification"])

    def test_existing_payload_is_preserved_without_decoding(self):
        self.output.parent.mkdir()
        self.output.write_bytes(b"old payload")
        with self.assertRaises(FileExistsError):
            self.decode()
        self.assertEqual(self.output.read_bytes(), b"old payload")
        self.decoder.imread.assert_not_called()

    def test_existing_sidecar_is_preserved_without_decoding(self):
        self.sidecar.parent.mkdir()
        self.sidecar.write_text("old sidecar")
        with self.assertRaises(FileExistsError):
            self.decode()
        self.assertEqual(self.sidecar.read_text(), "old sidecar")
        self.assertFalse(self.output.exists())
        self.decoder.imread.assert_not_called()

    def test_source_alias_missing_source_and_invalid_factor_do_not_decode(self):
        cases = ((self.source, self.source, 1), (self.root / "absent.ARW", self.output, 1),
                 (self.source, self.output, 0))
        for source, output, factor in cases:
            with self.subTest(source=source, output=output, factor=factor), self.assertRaises(ValueError):
                bridge.decode_raw(source, output, downsample=factor, rawpy_module=self.decoder)
        self.decoder.imread.assert_not_called()

    def test_missing_or_nonfinite_as_shot_wb_refuses_decoder_fallback(self):
        for wb in ([0, 0, 0, 0], [2, 1, np.nan, 0], [2, 1, 1]):
            self.raw.camera_whitebalance = wb
            with self.subTest(wb=wb), self.assertRaisesRegex(ValueError, "white balance"):
                self.decode()
        self.raw.postprocess.assert_not_called()
        self.assert_no_outputs()

    def test_changed_source_is_rejected_after_decoding(self):
        def mutate(**kwargs):
            self.source.write_bytes(b"changed RAW content")
            return self.pixels
        self.raw.postprocess.side_effect = mutate
        with self.assertRaisesRegex(ValueError, "changed"):
            self.decode()
        self.assert_no_outputs()

    def test_wrong_decoder_dtype_does_not_leave_outputs(self):
        self.raw.postprocess.return_value = self.pixels.astype(np.float32)
        with self.assertRaisesRegex(ValueError, "uint16"):
            self.decode()
        self.assert_no_outputs()

    def test_failed_sidecar_serialisation_removes_only_created_files(self):
        with mock.patch.object(bridge.json, "dumps", side_effect=ValueError("mock write failure")):
            with self.assertRaisesRegex(ValueError, "mock write failure"):
                self.decode()
        self.assert_no_outputs()


if __name__ == "__main__":
    unittest.main()
