"""Check the public-reference adapter's switch and limitation handling."""
from __future__ import annotations

from pathlib import Path
import sys
import unittest
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import windows_python_reference as wr


def params():
    effect = lambda active=True: SimpleNamespace(active=active)
    return SimpleNamespace(
        film_render=SimpleNamespace(halation=effect(), dir_couplers=effect()),
        camera=SimpleNamespace(diffusion_filter=effect(False), lens_blur_um=4.0),
        enlarger=SimpleNamespace(diffusion_filter=effect(False), lens_blur=4.0),
        scanner=SimpleNamespace(lens_blur=4.0),
    )


class PublicReferenceTests(unittest.TestCase):
    def test_core_switches_disable_spatial_effects(self):
        value = params()
        wr.apply_effect_switches(value, {
            "halation_active": False,
            "dir_couplers_active": False,
            "diffusion_filter_active": False,
            "lens_aberrations_active": False,
        })
        self.assertFalse(value.film_render.halation.active)
        self.assertFalse(value.film_render.dir_couplers.active)
        self.assertFalse(value.camera.diffusion_filter.active)
        self.assertFalse(value.enlarger.diffusion_filter.active)
        self.assertEqual(value.camera.lens_blur_um, 0.0)
        self.assertEqual(value.enlarger.lens_blur, 0.0)
        self.assertEqual(value.scanner.lens_blur, 0.0)

    def test_public_reference_refuses_unmodelled_lens_aberrations(self):
        with self.assertRaisesRegex(RuntimeError, "no lens-aberration model"):
            wr.apply_effect_switches(params(), {"lens_aberrations_active": True})


if __name__ == "__main__":
    unittest.main()
