# The engine outside macOS: the portable setup/pipeline sources plus the
# Vulkan backend, on Linux and Windows (native MinGW/MSVC or cross-compiled
# MinGW-w64). The macOS application continues to use build.sh/Xcode and
# nothing here is read by them.
#
# Dependencies (all pinned, all fetched into the gitignored build/deps by
# engine/setup-deps.sh, none downloaded by CMake itself):
#   SPEKTRALAB_VULKAN_HEADERS   Khronos Vulkan-Headers include dir (default:
#                               build/deps/Vulkan-Headers/include, else the
#                               system's / $VULKAN_SDK's)
#   SPEKTRALAB_LIBRAW_SOURCE    LibRaw 0.22.2 source tree (RAW decode)
# The Vulkan loader is never linked: engine/third_party/volk opens it at run
# time. glslangValidator compiles the kernels to SPIR-V at build time.
add_library(spektralab_core STATIC
    src/core/blob.cpp
    src/core/cam16.cpp
    src/core/colour.cpp
    src/core/curves.cpp
    src/core/digital_intermediate.cpp
    src/core/hanatos.cpp
    src/core/json.cpp
    src/core/latitude_fit.cpp
    src/core/numeric.cpp
    src/core/params.cpp
    src/core/print_lut.cpp
    src/core/printing.cpp
    src/core/profile.cpp
    src/core/setup_cache.cpp
    src/core/spectral.cpp
)
target_compile_features(spektralab_core PUBLIC cxx_std_20)
target_include_directories(spektralab_core PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/src/core>
)
set_target_properties(spektralab_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

set(SPEKTRALAB_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." CACHE INTERNAL "")
set(SPEKTRALAB_DEPS_DIR "${SPEKTRALAB_REPO_ROOT}/build/deps" CACHE PATH
    "Directory engine/setup-deps.sh fetched the pinned dependencies into")

# These translation units are platform-neutral, but linking them into a
# runnable engine still requires an implementation of gpu::Gpu.
add_library(spektralab_pipeline OBJECT
    src/pipeline/blur.cpp
    src/pipeline/engine.cpp
    src/pipeline/pipeline.cpp
    src/pipeline/scene_latitude.cpp
)
set_target_properties(spektralab_pipeline PROPERTIES POSITION_INDEPENDENT_CODE ON)
if(APPLE)
    target_sources(spektralab_pipeline PRIVATE
        src/pipeline/contrast_mask.cpp src/pipeline/overscan.cpp)
else()
    target_sources(spektralab_pipeline PRIVATE src/pipeline/windows_unported.cpp)
endif()
target_link_libraries(spektralab_pipeline PRIVATE spektralab_core)
target_include_directories(spektralab_pipeline PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

if(BUILD_TESTING)
    if(WIN32)
        # Exercise resource opens without a Vulkan device (also under Wine).
        add_executable(spk_resource_paths tests/resource_paths.cpp)
        target_link_libraries(spk_resource_paths PRIVATE spektralab_core)
        add_test(NAME spk_resource_paths COMMAND spk_resource_paths
            "${CMAKE_CURRENT_SOURCE_DIR}/resources"
            "${CMAKE_CURRENT_BINARY_DIR}/resource-path-tests")
    endif()

    add_executable(spk_dump_json tests/dump_json.cpp)
    target_link_libraries(spk_dump_json PRIVATE spektralab_core)
    add_test(NAME spk_core_schema
        COMMAND spk_dump_json "${CMAKE_CURRENT_SOURCE_DIR}/resources")

    add_executable(spk_dump_setup tests/dump_setup.cpp)
    target_link_libraries(spk_dump_setup PRIVATE spektralab_core)
    target_include_directories(spk_dump_setup PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/tests")
    add_test(NAME spk_core_setup
        COMMAND spk_dump_setup "${CMAKE_CURRENT_SOURCE_DIR}/resources"
                "${CMAKE_CURRENT_BINARY_DIR}/setup.dat"
                "${CMAKE_CURRENT_BINARY_DIR}/setup.idx")
endif()

if(NOT APPLE)
    option(SPEKTRALAB_BUILD_NATIVE_RAW "Build LibRaw decode, the image writer and the RAW tools" OFF)
    option(SPEKTRALAB_BUILD_HOST "Build engine/host: spektralab-host (needs SPEKTRALAB_BUILD_NATIVE_RAW)" OFF)
    option(SPEKTRALAB_BUILD_DESKTOP "Build the minimal native Windows RAW viewer (Windows only)" ON)
    option(SPEKTRALAB_REQUIRE_VULKAN "Fail configuration when the Vulkan toolchain is missing" OFF)
    option(SPEKTRALAB_BUILD_TEST_DLL "Build the C ABI shared library used by parity tests" ${BUILD_TESTING})
    option(SPEKTRALAB_STATIC_RUNTIME "Link libstdc++/libgcc (and winpthread) statically into executables" OFF)

    # Headers: the pinned Khronos tree when setup-deps.sh fetched it, else an
    # installed SDK or the system's. Only headers -- volk loads the loader.
    find_path(SPEKTRALAB_VULKAN_HEADERS vulkan/vulkan_core.h
        HINTS "${SPEKTRALAB_DEPS_DIR}/Vulkan-Headers/include" "$ENV{VULKAN_SDK}/Include"
              "$ENV{VULKAN_SDK}/include"
        NO_CMAKE_FIND_ROOT_PATH)
    find_program(SPEKTRALAB_GLSLANG NAMES glslangValidator glslang
        HINTS "$ENV{VULKAN_SDK}/Bin" "$ENV{VULKAN_SDK}/bin")

    if(SPEKTRALAB_VULKAN_HEADERS AND SPEKTRALAB_GLSLANG)
        # volk, compiled once as C, with the platform's loader name built in.
        add_library(spk_volk STATIC third_party/volk/volk.c)
        set_target_properties(spk_volk PROPERTIES POSITION_INDEPENDENT_CODE ON LINKER_LANGUAGE C)
        target_include_directories(spk_volk PUBLIC
            "${CMAKE_CURRENT_SOURCE_DIR}/third_party/volk" "${SPEKTRALAB_VULKAN_HEADERS}")
        if(NOT WIN32)
            target_link_libraries(spk_volk PUBLIC ${CMAKE_DL_LIBS})
        endif()

        set(vulkan_resource_dir "${CMAKE_CURRENT_BINARY_DIR}/resources")
        set(vulkan_shader_dir "${vulkan_resource_dir}/vulkan")
        set(SPEKTRALAB_VULKAN_KERNELS
            spk_math_probe spk_take_rgb spk_matmul3 spk_stride_sample
            spk_affine3 spk_tc_b spk_lut2d_cubic spk_sep_fir_acc spk_iir_df_acc
            spk_lincomb3 spk_log10_guarded spk_curves
            spk_couplers_correction spk_spectral_epilogue
            spk_print_exposure spk_cam16ucs_compress
            spk_cctf_encode_matrix spk_to_rgba16
            spk_grain_layers spk_grain_layer_one spk_grain_simple
            spk_lognormal_field spk_rng_probe spk_mul spk_glare_add
            spk_reduce_max spk_boost spk_bw_correct spk_edr spk_cctf_decode
            spk_zoom_bilinear_mirror spk_geometry_resample_df
            spk_lut3d_trilinear spk_di_normalise
            CACHE INTERNAL "")
        set(vulkan_spirv)
        file(GLOB vulkan_includes "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/vulkan/*.glsl")
        foreach(kernel ${SPEKTRALAB_VULKAN_KERNELS})
            set(shader "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/vulkan/${kernel}.comp")
            set(spirv "${vulkan_shader_dir}/${kernel}.spv")
            add_custom_command(OUTPUT "${spirv}"
                COMMAND "${CMAKE_COMMAND}" -E make_directory "${vulkan_shader_dir}"
                COMMAND "${SPEKTRALAB_GLSLANG}" -V --target-env vulkan1.0
                        "-I${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/vulkan"
                        -o "${spirv}" "${shader}"
                DEPENDS "${shader}" ${vulkan_includes}
                VERBATIM)
            list(APPEND vulkan_spirv "${spirv}")
        endforeach()
        set(SPEKTRALAB_VULKAN_SPIRV ${vulkan_spirv} CACHE INTERNAL "")
        add_custom_target(spektralab_vulkan_resources
            COMMAND "${CMAKE_COMMAND}" -E copy_directory
                    "${CMAKE_CURRENT_SOURCE_DIR}/resources" "${vulkan_resource_dir}"
            DEPENDS ${vulkan_spirv}
            VERBATIM)

        add_library(spektralab_engine STATIC
            $<TARGET_OBJECTS:spektralab_pipeline>
            src/gpu/vulkan_gpu.cpp)
        target_compile_features(spektralab_engine PUBLIC cxx_std_20)
        target_include_directories(spektralab_engine PRIVATE
            "${CMAKE_CURRENT_SOURCE_DIR}/include"
            "${CMAKE_CURRENT_SOURCE_DIR}/src")
        target_link_libraries(spektralab_engine PUBLIC spektralab_core spk_volk)
        if(NOT WIN32)
            find_package(Threads REQUIRED)
            target_link_libraries(spektralab_engine PUBLIC Threads::Threads)
        endif()
        add_dependencies(spektralab_engine spektralab_vulkan_resources)

        if(SPEKTRALAB_BUILD_NATIVE_RAW)
            include(cmake/LibRaw.cmake)
            add_library(spk_image_io STATIC src/io/raw_decoder.cpp src/io/raw_headroom.cpp src/io/image_writer.cpp)
            target_compile_features(spk_image_io PUBLIC cxx_std_20)
            target_include_directories(spk_image_io PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
            target_link_libraries(spk_image_io PRIVATE spk_libraw)
            if(WIN32)
                # Win32-only RAW-to-TIFF tool; engine/host is the portable host.
                add_executable(spk_raw_render tools/raw_render.cpp)
                target_include_directories(spk_raw_render PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
                target_link_libraries(spk_raw_render PRIVATE spk_image_io spektralab_engine)
                if(MINGW)
                    target_link_options(spk_raw_render PRIVATE -municode)
                endif()
            endif()
            if(SPEKTRALAB_BUILD_HOST)
                add_subdirectory(host)
            endif()
            if(WIN32 AND SPEKTRALAB_BUILD_DESKTOP)
                add_library(spk_desktop_host STATIC src/desktop/preview_host.cpp)
                target_compile_features(spk_desktop_host PUBLIC cxx_std_20)
                target_include_directories(spk_desktop_host PUBLIC
                    "${CMAKE_CURRENT_SOURCE_DIR}/src" "${CMAKE_CURRENT_SOURCE_DIR}/include")
                target_link_libraries(spk_desktop_host PUBLIC spk_image_io spektralab_engine)
                add_executable(SpektraLab WIN32 tools/windows_preview.cpp)
                target_link_libraries(SpektraLab PRIVATE spk_desktop_host comctl32 comdlg32 shell32 gdi32 user32)
                file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/licenses")
                foreach(notice LICENSE SPEKTRAFILM_LICENSE.txt)
                    configure_file("${CMAKE_CURRENT_SOURCE_DIR}/../license/${notice}" "licenses/${notice}" COPYONLY)
                endforeach()
                if(MINGW)
                    target_link_options(SpektraLab PRIVATE -municode)
                endif()
                if(BUILD_TESTING)
                    add_executable(spk_desktop_preview_test tests/desktop_preview.cpp)
                    target_link_libraries(spk_desktop_preview_test PRIVATE spk_desktop_host)
                    add_test(NAME spk_desktop_preview COMMAND spk_desktop_preview_test)
                endif()
            endif()
            if(BUILD_TESTING)
                if(WIN32)
                    # The transactional sRGB TIFF writer is a Win32-handle
                    # implementation; the host has its own portable writers.
                    add_executable(spk_image_writer_test tests/image_writer_test.cpp)
                    target_link_libraries(spk_image_writer_test PRIVATE spk_image_io)
                    add_test(NAME spk_image_writer COMMAND spk_image_writer_test
                        "${CMAKE_CURRENT_SOURCE_DIR}/resources/io/sRGB.icc"
                        "${CMAKE_CURRENT_BINARY_DIR}/writer-test")
                endif()
                add_executable(spk_raw_decoder_errors tests/raw_decoder_errors.cpp)
                target_link_libraries(spk_raw_decoder_errors PRIVATE spk_image_io)
                add_test(NAME spk_raw_decoder_errors COMMAND spk_raw_decoder_errors
                    "${CMAKE_CURRENT_BINARY_DIR}/raw-errors")
                add_executable(spk_raw_metadata_link tests/raw_metadata_link.cpp)
                target_link_libraries(spk_raw_metadata_link PRIVATE spk_libraw)
                add_test(NAME spk_raw_metadata_link COMMAND spk_raw_metadata_link)
                add_executable(spk_raw_headroom tests/raw_headroom.cpp)
                target_link_libraries(spk_raw_headroom PRIVATE spk_image_io)
                add_test(NAME spk_raw_headroom COMMAND spk_raw_headroom)
            endif()
        endif()

        if(SPEKTRALAB_BUILD_TEST_DLL)
            # Compile the same pipeline/core as the static engine. Export only
            # the public C boundary; callers never free DLL allocations themselves.
            set(shared_sources $<TARGET_OBJECTS:spektralab_pipeline> src/gpu/vulkan_gpu.cpp)
            if(WIN32)
                list(APPEND shared_sources windows_exports.def)
            endif()
            add_library(spektralab_engine_shared SHARED ${shared_sources})
            set_target_properties(spektralab_engine_shared PROPERTIES
                OUTPUT_NAME spektrafilm_engine PREFIX "")
            target_compile_features(spektralab_engine_shared PUBLIC cxx_std_20)
            target_include_directories(spektralab_engine_shared PRIVATE
                "${CMAKE_CURRENT_SOURCE_DIR}/include"
                "${CMAKE_CURRENT_SOURCE_DIR}/src")
            target_link_libraries(spektralab_engine_shared PRIVATE spektralab_core spk_volk)
            if(NOT WIN32)
                target_link_libraries(spektralab_engine_shared PRIVATE Threads::Threads)
            endif()
            add_dependencies(spektralab_engine_shared spektralab_vulkan_resources)
        endif()

        if(BUILD_TESTING)
            add_executable(spk_vulkan_smoke tests/gpu_vulkan_smoke.cpp)
            target_include_directories(spk_vulkan_smoke PRIVATE
                "${CMAKE_CURRENT_SOURCE_DIR}/include"
                "${CMAKE_CURRENT_SOURCE_DIR}/src")
            target_link_libraries(spk_vulkan_smoke PRIVATE spektralab_engine)
            add_dependencies(spk_vulkan_smoke spektralab_vulkan_resources)
            add_test(NAME spk_vulkan_smoke
                COMMAND spk_vulkan_smoke "${vulkan_resource_dir}")

            foreach(probe grain pointwise resample transfer geometry lut_di)
                add_executable(spk_vulkan_${probe} tests/gpu_vulkan_${probe}.cpp)
                target_include_directories(spk_vulkan_${probe} PRIVATE
                    "${CMAKE_CURRENT_SOURCE_DIR}/include"
                    "${CMAKE_CURRENT_SOURCE_DIR}/src")
                target_link_libraries(spk_vulkan_${probe} PRIVATE spektralab_engine)
                add_dependencies(spk_vulkan_${probe} spektralab_vulkan_resources)
                add_test(NAME spk_vulkan_${probe}
                    COMMAND spk_vulkan_${probe} "${vulkan_resource_dir}")
            endforeach()

            if(SPEKTRALAB_BUILD_TEST_DLL)
                add_executable(spk_windows_feature_boundaries tests/windows_feature_boundaries.cpp)
                target_compile_features(spk_windows_feature_boundaries PRIVATE cxx_std_20)
                target_include_directories(spk_windows_feature_boundaries PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
                target_link_libraries(spk_windows_feature_boundaries PRIVATE spektralab_engine_shared)
                add_test(NAME spk_windows_feature_boundaries
                    COMMAND spk_windows_feature_boundaries "${vulkan_resource_dir}")

                add_executable(spk_render_fixture tests/render_fixture.cpp)
                target_compile_features(spk_render_fixture PRIVATE cxx_std_20)
                target_include_directories(spk_render_fixture PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
                target_link_libraries(spk_render_fixture PRIVATE spektralab_engine_shared)
                file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/fixtures")
                configure_file(tests/fixtures/windows/abi_probe.f32 fixtures/abi_probe.f32 COPYONLY)
                configure_file(tests/fixtures/windows/abi_probe_params.json fixtures/abi_probe_params.json COPYONLY)
                add_test(NAME spk_windows_c_abi
                    COMMAND spk_render_fixture "${vulkan_resource_dir}"
                        "${CMAKE_CURRENT_BINARY_DIR}/fixtures/abi_probe.f32" 3 2
                        "${CMAKE_CURRENT_BINARY_DIR}/fixtures/abi_probe_params.json"
                        "${CMAKE_CURRENT_BINARY_DIR}/fixtures/abi_probe.rgba16"
                        "${CMAKE_CURRENT_BINARY_DIR}/fixtures/abi_probe_report.json")
            endif()
        endif()
    else()
        if(SPEKTRALAB_REQUIRE_VULKAN)
            message(FATAL_ERROR "Vulkan headers (engine/setup-deps.sh) and glslangValidator are required for this build")
        endif()
        message(STATUS "Vulkan headers or glslangValidator missing; building portable core only")
    endif()
endif()
