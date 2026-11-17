# Pinned standalone LibRaw build; no download or Python at configure/runtime.
#
# The pin is an upstream master checkout (LibRaw's release tags stop at 0.22.3
# and none of them decodes the modern bodies the product needs). setup-libraw.sh
# and setup-libraw.ps1 fetch and verify it; this file refuses to build from any
# other tree: the version macros must say 0.23.0-Snapshot202611 and every file
# must match engine/third_party/libraw-pin/SHA256SUMS -- nothing added, removed
# or edited. A 0.22.x tree, a later snapshot or a locally patched copy all stop
# here, before a single LibRaw object is compiled.
set(SPEKTRALAB_LIBRAW_COMMIT 42f89c165763272a5482a254c446337f8048e0df)
set(SPEKTRALAB_LIBRAW_TREE 865b3ac461d5b734e5bc54683e914ff8dd82b7da)
set(SPEKTRALAB_LIBRAW_VERSION "0.23.0-Snapshot202611")
set(SPEKTRALAB_LIBRAW_SOURCE "${SPEKTRALAB_DEPS_DIR}/LibRaw-${SPEKTRALAB_LIBRAW_COMMIT}" CACHE PATH
    "Verified LibRaw master ${SPEKTRALAB_LIBRAW_COMMIT} source tree")
set(spk_libraw_setup_hint "run engine/setup-libraw.ps1 (Windows) or engine/setup-libraw.sh (POSIX) and set SPEKTRALAB_LIBRAW_SOURCE to the directory it prints")
if(NOT EXISTS "${SPEKTRALAB_LIBRAW_SOURCE}/libraw/libraw.h")
    message(FATAL_ERROR "Native RAW requires LibRaw master ${SPEKTRALAB_LIBRAW_COMMIT} (${SPEKTRALAB_LIBRAW_VERSION}); ${spk_libraw_setup_hint}")
endif()
file(STRINGS "${SPEKTRALAB_LIBRAW_SOURCE}/libraw/libraw_version.h" libraw_version
     REGEX "^#define LIBRAW_(MAJOR|MINOR|PATCH)_VERSION|^#define LIBRAW_VERSION_TAIL")
foreach(line IN ITEMS "#define LIBRAW_MAJOR_VERSION 0" "#define LIBRAW_MINOR_VERSION 23"
                      "#define LIBRAW_PATCH_VERSION 0" "#define LIBRAW_VERSION_TAIL Snapshot202611")
    list(FIND libraw_version "${line}" libraw_version_found)
    if(libraw_version_found EQUAL -1)
        message(FATAL_ERROR "This RAW integration is validated with LibRaw ${SPEKTRALAB_LIBRAW_VERSION} (master ${SPEKTRALAB_LIBRAW_COMMIT}) only; ${SPEKTRALAB_LIBRAW_SOURCE} is a different version. ${spk_libraw_setup_hint}")
    endif()
endforeach()
# The version macros do not move between snapshot commits, so the tree is
# checked file by file as well. A git checkout's own metadata is not part of it.
set(libraw_manifest "${CMAKE_CURRENT_LIST_DIR}/../third_party/libraw-pin/SHA256SUMS")
file(STRINGS "${libraw_manifest}" libraw_manifest_lines)
set(libraw_expected "")
foreach(line IN LISTS libraw_manifest_lines)
    if(NOT line MATCHES "^([0-9a-f]+)  (.+)$")
        message(FATAL_ERROR "Malformed line in ${libraw_manifest}: ${line}")
    endif()
    set(hash "${CMAKE_MATCH_1}")
    set(rel "${CMAKE_MATCH_2}")
    list(APPEND libraw_expected "${rel}")
    if(NOT EXISTS "${SPEKTRALAB_LIBRAW_SOURCE}/${rel}")
        message(FATAL_ERROR "LibRaw tree ${SPEKTRALAB_LIBRAW_SOURCE} is missing ${rel}; it is not the pinned ${SPEKTRALAB_LIBRAW_COMMIT}. ${spk_libraw_setup_hint}")
    endif()
    file(SHA256 "${SPEKTRALAB_LIBRAW_SOURCE}/${rel}" actual)
    if(NOT actual STREQUAL hash)
        message(FATAL_ERROR "LibRaw file ${rel} differs from the pinned ${SPEKTRALAB_LIBRAW_COMMIT} (tree ${SPEKTRALAB_LIBRAW_TREE}); refusing a modified tree. ${spk_libraw_setup_hint}")
    endif()
endforeach()
file(GLOB_RECURSE libraw_present LIST_DIRECTORIES false RELATIVE "${SPEKTRALAB_LIBRAW_SOURCE}" "${SPEKTRALAB_LIBRAW_SOURCE}/*")
list(FILTER libraw_present EXCLUDE REGEX "^\\.git/")
list(REMOVE_ITEM libraw_present ${libraw_expected})
if(libraw_present)
    list(GET libraw_present 0 libraw_extra)
    message(FATAL_ERROR "Unexpected file in the pinned LibRaw tree: ${libraw_extra}; refusing a modified tree. ${spk_libraw_setup_hint}")
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
    # LibRaw (0.22.2 and this snapshot alike) disables OpenMP for non-MSVC
    # Windows compilers unless explicitly opted in. PUBLIC keeps its inline
    # allocator definitions identical in the library and all consumers.
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
# Select the LGPL-2.1 option offered by the LibRaw dual license. stage-host.sh
# copies these three files into the staged licenses/.
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/third-party/LibRaw")
foreach(notice LICENSE.LGPL COPYRIGHT)
    configure_file("${SPEKTRALAB_LIBRAW_SOURCE}/${notice}" "third-party/LibRaw/${notice}" COPYONLY)
endforeach()
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/third-party/LibRaw/SOURCE.txt"
"LibRaw ${SPEKTRALAB_LIBRAW_VERSION}, statically linked under the LGPL-2.1 option
of its LGPL-2.1 / CDDL-1.0 dual licence (LICENSE.LGPL, COPYRIGHT).
Source: https://github.com/LibRaw/LibRaw, commit ${SPEKTRALAB_LIBRAW_COMMIT}
(git tree ${SPEKTRALAB_LIBRAW_TREE}), unmodified; engine/setup-libraw.sh in the
SpektraLab repository fetches and verifies exactly this tree.
")
