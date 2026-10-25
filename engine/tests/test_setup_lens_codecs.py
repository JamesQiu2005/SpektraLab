"""Keep staged target GLib discoverable without consulting host dependencies."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ENGINE = Path(__file__).resolve().parents[1]
TOOLCHAIN = ENGINE / 'cmake/toolchain-mingw-w64.cmake'
spec = importlib.util.spec_from_file_location('lens_setup', ENGINE / 'setup-lens-codecs.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class StopAtConfigure(Exception):
    pass


class LensDependencyTests(unittest.TestCase):
    def configure(self, cross):
        with tempfile.TemporaryDirectory(prefix='spk lens setup ') as temporary:
            root = Path(temporary)
            prefix = root / 'target'
            argv = ['setup-lens-codecs.py', '--sources', str(root / 'sources'),
                    '--build', str(root / 'build'), '--install', str(prefix)]
            if cross:
                argv += ['--toolchain', str(TOOLCHAIN)]
            captured = {}

            def run(command, **kwargs):
                if str(command[0]) == 'cmake':
                    captured.update(command=command, env=dict(kwargs['env']))
                    raise StopAtConfigure

            with mock.patch.object(sys, 'argv', argv), \
                 mock.patch.dict(os.environ, {'PKG_CONFIG_PATH': '/host/developer',
                                               'PKG_CONFIG_LIBDIR': '/host/system'}), \
                 mock.patch.object(setup.json, 'loads', return_value={
                     'sources': [{}, {}], 'wraps': [], 'git': []}), \
                 mock.patch.object(setup, 'sources', side_effect=[root / 'lens', root / 'glib']), \
                 mock.patch.object(setup, 'run', side_effect=run):
                with self.assertRaises(StopAtConfigure):
                    setup.main()
                self.assertEqual(os.environ['PKG_CONFIG_PATH'], '/host/developer')
            return captured, prefix

    def test_cross_build_searches_staged_target_and_isolates_pkg_config(self):
        captured, prefix = self.configure(cross=True)
        self.assertIn('-DCMAKE_FIND_ROOT_PATH=' + prefix.as_posix(), captured['command'])
        self.assertEqual(captured['env']['PKG_CONFIG_LIBDIR'], (prefix / 'lib/pkgconfig').as_posix())
        self.assertEqual(captured['env']['PKG_CONFIG_PATH'], '')

    def test_native_build_preserves_pkg_config_environment(self):
        captured, _ = self.configure(cross=False)
        self.assertFalse(any(str(arg).startswith('-DCMAKE_FIND_ROOT_PATH=') for arg in captured['command']))
        self.assertEqual(captured['env']['PKG_CONFIG_LIBDIR'], '/host/system')
        self.assertEqual(captured['env']['PKG_CONFIG_PATH'], '/host/developer')

    def test_toolchain_finds_headers_in_caller_target_prefix(self):
        cmake = os.environ.get('SPEKTRALAB_CMAKE') or shutil.which('cmake')
        if not cmake:
            self.skipTest('CMake is required for the toolchain lookup regression')
        with tempfile.TemporaryDirectory(prefix='spk target lookup ') as temporary:
            root = Path(temporary)
            prefix = root / 'target'
            headers = prefix / 'include/glib-2.0'
            headers.mkdir(parents=True)
            (headers / 'glib.h').touch()
            script = root / 'lookup.cmake'
            script.write_text(f'''
set(CMAKE_C_COMPILER unused)
set(CMAKE_CXX_COMPILER unused)
set(CMAKE_RC_COMPILER unused)
set(CMAKE_FIND_ROOT_PATH "{prefix.as_posix()}")
include("{TOOLCHAIN.as_posix()}")
include("{TOOLCHAIN.as_posix()}")
find_path(GLIB_HEADER glib.h PATHS "{prefix.as_posix()}/include" PATH_SUFFIXES glib-2.0)
if(NOT GLIB_HEADER STREQUAL "{headers.as_posix()}")
  message(FATAL_ERROR "Staged target GLib was hidden: ${{GLIB_HEADER}}")
endif()
list(LENGTH CMAKE_FIND_ROOT_PATH root_count)
if(NOT root_count EQUAL 2)
  message(FATAL_ERROR "Toolchain repeated or replaced dependency roots: ${{CMAKE_FIND_ROOT_PATH}}")
endif()
''', encoding='utf-8')
            result = subprocess.run([cmake, '-P', str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
