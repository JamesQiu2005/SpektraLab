# The decoder alone, against a chosen LibRaw tree and a chosen copy of
# engine/src/io -- so the previous pin and the current one can be built with
# the same compiler and flags and their linear frames compared (T-A2).
# raw_pin_compare.sh configures this twice; it is not part of the product
# build and does not run the pin guard (the setup scripts verified each tree).
#
#   cmake -S engine/tests/raw_pin_compare -B <dir> -DSPK_ENGINE_SRC=<engine/src> \
#         -DSPK_LIBRAW_SOURCE=<LibRaw tree>
cmake_minimum_required(VERSION 3.20)
project(spk_raw_pin_compare LANGUAGES C CXX)
# The same language settings engine/CMakeLists.txt gives LibRaw and spk_image_io.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS ON)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
foreach(var SPK_ENGINE_SRC SPK_LIBRAW_SOURCE)
    if(NOT EXISTS "${${var}}")
        message(FATAL_ERROR "${var} is required")
    endif()
endforeach()
file(GLOB_RECURSE libraw_sources "${SPK_LIBRAW_SOURCE}/src/*.cpp")
list(FILTER libraw_sources EXCLUDE REGEX "/[^/]*_ph\\.cpp$")
add_library(cmp_libraw STATIC ${libraw_sources})
target_include_directories(cmp_libraw PUBLIC "${SPK_LIBRAW_SOURCE}")
target_compile_definitions(cmp_libraw PUBLIC LIBRAW_NODLL SPEKTRALAB_RAW_OPENMP=0)
target_compile_options(cmp_libraw PRIVATE -w)
add_executable(raw_decode_dump raw_decode_dump.cpp
    "${SPK_ENGINE_SRC}/io/raw_decoder.cpp" "${SPK_ENGINE_SRC}/io/raw_headroom.cpp")
target_include_directories(raw_decode_dump PRIVATE "${SPK_ENGINE_SRC}")
target_compile_features(raw_decode_dump PRIVATE cxx_std_20)
target_link_libraries(raw_decode_dump PRIVATE cmp_libraw m)
add_executable(raw_frame_compare raw_frame_compare.cpp)
