"""Exercise input codec package discovery with the real MinGW search policy."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[1]


class InputCodecDiscoveryTests(unittest.TestCase):
    def configure(self, cross, missing_target=False):
        cmake = os.environ.get('SPEKTRALAB_CMAKE') or shutil.which('cmake')
        if not cmake:
            self.skipTest('CMake is required for package discovery regression tests')
        with tempfile.TemporaryDirectory(prefix='spk input codec lookup ') as temporary:
            root = Path(temporary)
            prefix = root / 'target codecs'
            host = root / 'host codecs'

            def write(path, content):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding='utf-8')

            write(prefix / 'include/lcms2.h', '')
            write(prefix / 'share/spektralab-input-codecs/licenses/LICENSE', 'fixture')
            for name, version, target in [('OpenEXR', '3.5.2', 'OpenEXR::OpenEXR'),
                                           ('libheif', '1.23.6', 'heif'),
                                           ('Imath', '3.2.3', 'Imath::Imath')]:
                for install in (prefix, host):
                    if missing_target and install == prefix and name == 'OpenEXR':
                        continue
                    config = install / 'lib/cmake' / name
                    write(config / f'{name}ConfigVersion.cmake',
                          f'set(PACKAGE_VERSION {version})\n'
                          'set(PACKAGE_VERSION_COMPATIBLE TRUE)\n'
                          'set(PACKAGE_VERSION_EXACT TRUE)\n')
                    content = 'message(FATAL_ERROR "Selected a host codec")\n'
                    if install == prefix:
                        content = f'add_library({target} INTERFACE IMPORTED)\n'
                        if name == 'OpenEXR':
                            content += 'include(CMakeFindDependencyMacro)\nfind_dependency(Imath CONFIG)\n'
                    write(config / f'{name}Config.cmake', content)
            write(host / 'lib/cmake/HostOnly/HostOnlyConfig.cmake',
                  'message(FATAL_ERROR "Host package search leaked into cross-build")\n')
            cross_setup = ''
            if cross:
                cross_setup = f'''
set(CMAKE_C_COMPILER unused)
set(CMAKE_CXX_COMPILER unused)
set(CMAKE_RC_COMPILER unused)
set(CMAKE_TOOLCHAIN_FILE "{(ENGINE / 'cmake/toolchain-mingw-w64.cmake').as_posix()}")
'''
            write(root / 'CMakeLists.txt', f'''
cmake_minimum_required(VERSION 3.20)
{cross_setup}
project(InputCodecLookup NONE)
set(CMAKE_PREFIX_PATH "{host.as_posix()}")
set(SPEKTRALAB_INPUT_CODEC_PREFIX "{prefix.as_posix()}" CACHE PATH "")
include("{(ENGINE / 'cmake/InputCodecs.cmake').as_posix()}")
foreach(codec OpenEXR::OpenEXR Imath::Imath heif spk_input_lcms)
  if(NOT TARGET ${{codec}})
    message(FATAL_ERROR "Missing codec target: ${{codec}}")
  endif()
endforeach()
if(CMAKE_CROSSCOMPILING)
  find_package(HostOnly QUIET CONFIG)
endif()
''')
            # No languages or build commands: the test only needs CMake's
            # generator and package resolver, not a platform compiler/IDE.
            return subprocess.run([cmake, '-G', 'Unix Makefiles',
                                   '-DCMAKE_MAKE_PROGRAM=unused',
                                   '-S', str(root), '-B', str(root / 'build')],
                                  capture_output=True, text=True, encoding='utf-8', errors='replace')

    def test_cross_build_finds_target_packages_and_transitive_dependencies(self):
        result = self.configure(cross=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cross_build_does_not_fall_back_to_host_packages(self):
        result = self.configure(cross=True, missing_target=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('OpenEXR', result.stderr)
        self.assertNotIn('Selected a host codec', result.stderr)

    def test_native_build_still_finds_staged_packages(self):
        result = self.configure(cross=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
