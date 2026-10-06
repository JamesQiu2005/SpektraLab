# Cross-compiling the engine and spektralab-host for Windows x64 from Linux
# with MinGW-w64 (Debian/Ubuntu: g++-mingw-w64-x86-64-posix). The *posix*
# thread model is required: the host and the engine use std::thread and
# std::mutex, which the win32 model's libstdc++ does not provide.
#
#   cmake -DCMAKE_TOOLCHAIN_FILE=engine/cmake/toolchain-mingw-w64.cmake ...
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(SPEKTRALAB_MINGW_PREFIX x86_64-w64-mingw32 CACHE STRING "MinGW-w64 tool prefix")
find_program(CMAKE_C_COMPILER NAMES ${SPEKTRALAB_MINGW_PREFIX}-gcc-posix ${SPEKTRALAB_MINGW_PREFIX}-gcc REQUIRED)
find_program(CMAKE_CXX_COMPILER NAMES ${SPEKTRALAB_MINGW_PREFIX}-g++-posix ${SPEKTRALAB_MINGW_PREFIX}-g++ REQUIRED)
find_program(CMAKE_RC_COMPILER NAMES ${SPEKTRALAB_MINGW_PREFIX}-windres)
set(CMAKE_FIND_ROOT_PATH /usr/${SPEKTRALAB_MINGW_PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
# Tests are run under wine by the cross script, not by CTest's own launcher.
set(CMAKE_CROSSCOMPILING_EMULATOR wine CACHE STRING "")
