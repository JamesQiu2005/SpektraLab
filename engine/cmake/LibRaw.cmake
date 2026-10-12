# Pinned standalone LibRaw build; no download or Python at configure/runtime.
set(SPEKTRALAB_LIBRAW_SOURCE "${SPEKTRALAB_DEPS_DIR}/LibRaw-0.22.2" CACHE PATH "Extracted official LibRaw 0.22.2 source")
if(NOT EXISTS "${SPEKTRALAB_LIBRAW_SOURCE}/libraw/libraw.h")
    message(FATAL_ERROR "Native RAW requires LibRaw 0.22.2; run engine/setup-libraw.ps1 (Windows) or engine/setup-libraw.sh (POSIX) and set SPEKTRALAB_LIBRAW_SOURCE")
endif()
file(STRINGS "${SPEKTRALAB_LIBRAW_SOURCE}/libraw/libraw_version.h" libraw_version REGEX "^#define LIBRAW_(MAJOR|MINOR|PATCH)_VERSION")
list(FIND libraw_version "#define LIBRAW_MAJOR_VERSION 0" libraw_major)
list(FIND libraw_version "#define LIBRAW_MINOR_VERSION 22" libraw_minor)
list(FIND libraw_version "#define LIBRAW_PATCH_VERSION 2" libraw_patch)
if(libraw_major EQUAL -1 OR libraw_minor EQUAL -1 OR libraw_patch EQUAL -1)
    message(FATAL_ERROR "This RAW integration is validated with LibRaw 0.22.2 only")
endif()
file(GLOB_RECURSE libraw_sources CONFIGURE_DEPENDS "${SPEKTRALAB_LIBRAW_SOURCE}/src/*.cpp")
# *_ph.cpp are replacement placeholders for LibRaw's no-postprocessing build,
# not extra implementations. Including them beside the real processing units
# makes small metadata-only consumers fail with duplicate symbols.
list(FILTER libraw_sources EXCLUDE REGEX "/[^/]*_ph\\.cpp$")
add_library(spk_libraw STATIC ${libraw_sources})
target_include_directories(spk_libraw PUBLIC "${SPEKTRALAB_LIBRAW_SOURCE}")
target_compile_definitions(spk_libraw PUBLIC LIBRAW_NODLL)
# Keep per-instance decoder state even in the serial comparison build. The
# LIBRAW_NOTHREADS variant uses shared static state in several decoders.
option(SPEKTRALAB_LIBRAW_OPENMP "Enable bounded parallel LibRaw processing" ON)
if(SPEKTRALAB_LIBRAW_OPENMP)
    if(MINGW AND SPEKTRALAB_STATIC_RUNTIME AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        # FindOpenMP otherwise prefers libgomp.dll.a; a final -static cannot
        # undo that explicit import archive and would add a missing DLL.
        execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=libgomp.a
            OUTPUT_VARIABLE spk_static_gomp OUTPUT_STRIP_TRAILING_WHITESPACE
            RESULT_VARIABLE spk_static_gomp_status)
        if(NOT spk_static_gomp_status EQUAL 0 OR NOT IS_ABSOLUTE "${spk_static_gomp}" OR NOT EXISTS "${spk_static_gomp}")
            message(FATAL_ERROR "Static RAW OpenMP requires this MinGW compiler's libgomp.a")
        endif()
        set(OpenMP_gomp_LIBRARY "${spk_static_gomp}" CACHE FILEPATH "Static MinGW OpenMP runtime" FORCE)
    endif()
    find_package(OpenMP REQUIRED COMPONENTS CXX)
    target_link_libraries(spk_libraw PUBLIC OpenMP::OpenMP_CXX)
    # LibRaw 0.22.2 intentionally disables OpenMP for non-MSVC Windows
    # compilers unless explicitly opted in. PUBLIC keeps its inline allocator
    # definitions identical in the library and all consumers of libraw.h.
    if(WIN32 AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        target_compile_definitions(spk_libraw PUBLIC LIBRAW_FORCE_OPENMP)
    endif()
    target_compile_definitions(spk_libraw PUBLIC SPEKTRALAB_RAW_OPENMP=1)
else()
    target_compile_definitions(spk_libraw PUBLIC SPEKTRALAB_RAW_OPENMP=0)
endif()
target_compile_features(spk_libraw PUBLIC cxx_std_11)
set_target_properties(spk_libraw PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(WIN32)
    target_link_libraries(spk_libraw PUBLIC ws2_32)
else()
    target_link_libraries(spk_libraw PUBLIC m)
endif()
# LibRaw's own sources are not ours to warn about.
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(spk_libraw PRIVATE -w)
endif()
# Select the LGPL-2.1 option offered by the LibRaw dual license.
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/third-party/LibRaw")
foreach(notice LICENSE.LGPL COPYRIGHT)
    configure_file("${SPEKTRALAB_LIBRAW_SOURCE}/${notice}" "third-party/LibRaw/${notice}" COPYONLY)
endforeach()
