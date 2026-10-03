# Windows headless build: portable setup/pipeline sources plus the incremental
# Vulkan backend. The macOS application continues to use build.sh/Xcode.
add_library(spektralab_core STATIC
    src/core/blob.cpp
    src/core/cam16.cpp
    src/core/colour.cpp
    src/core/curves.cpp
    src/core/hanatos.cpp
    src/core/json.cpp
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

# These translation units are platform-neutral, but linking them into a
# runnable engine still requires an implementation of gpu::Gpu.
add_library(spektralab_pipeline OBJECT
    src/pipeline/blur.cpp
    src/pipeline/engine.cpp
    src/pipeline/pipeline.cpp
)
target_link_libraries(spektralab_pipeline PRIVATE spektralab_core)
target_include_directories(spektralab_pipeline PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
)

if(BUILD_TESTING)
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

if(WIN32)
    option(SPEKTRALAB_BUILD_NATIVE_RAW "Build the native RAW-to-TIFF host" OFF)
    option(SPEKTRALAB_BUILD_DESKTOP "Build the minimal native Windows RAW viewer" ON)
    option(SPEKTRALAB_REQUIRE_VULKAN "Fail configuration when the Vulkan toolchain is missing" OFF)
    option(SPEKTRALAB_BUILD_TEST_DLL "Build the C ABI DLL used by parity tests" ${BUILD_TESTING})
    # Accept an installed Vulkan SDK, or explicit paths for a local toolchain.
    # Nothing here changes the upstream macOS build.sh / Xcode path.
    find_path(SPEKTRALAB_VULKAN_INCLUDE_DIR vulkan/vulkan.h
        HINTS "$ENV{VULKAN_SDK}/Include")
    find_library(SPEKTRALAB_VULKAN_LIBRARY NAMES vulkan-1
        HINTS "$ENV{VULKAN_SDK}/Lib")
    if(MINGW AND NOT SPEKTRALAB_VULKAN_LIBRARY)
        find_file(SPEKTRALAB_VULKAN_LIBRARY NAMES vulkan-1.dll
            PATHS "$ENV{WINDIR}/System32" NO_DEFAULT_PATH)
    endif()
    find_program(SPEKTRALAB_GLSLANG NAMES glslangValidator glslang
        HINTS "$ENV{VULKAN_SDK}/Bin")

    if(SPEKTRALAB_VULKAN_INCLUDE_DIR AND SPEKTRALAB_VULKAN_LIBRARY AND SPEKTRALAB_GLSLANG)
        set(vulkan_resource_dir "${CMAKE_CURRENT_BINARY_DIR}/resources")
        set(vulkan_shader_dir "${vulkan_resource_dir}/vulkan")
        set(vulkan_spirv)
        foreach(kernel spk_math_probe spk_take_rgb spk_matmul3 spk_stride_sample
                       spk_affine3 spk_tc_b spk_lut2d_cubic spk_sep_fir_acc spk_iir_df_acc
                       spk_lincomb3 spk_log10_guarded spk_curves
                       spk_couplers_correction spk_spectral_epilogue
                       spk_print_exposure spk_cam16ucs_compress
                       spk_cctf_encode_matrix spk_to_rgba16
                       spk_grain_layers spk_grain_layer_one spk_grain_simple
                       spk_lognormal_field spk_rng_probe spk_mul spk_glare_add
                       spk_reduce_max spk_boost spk_bw_correct spk_edr spk_cctf_decode
                       spk_zoom_bilinear_mirror spk_geometry_resample_df
                       spk_lut3d_trilinear spk_di_normalise)
            set(shader "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/vulkan/${kernel}.comp")
            set(spirv "${vulkan_shader_dir}/${kernel}.spv")
            add_custom_command(OUTPUT "${spirv}"
                COMMAND "${CMAKE_COMMAND}" -E make_directory "${vulkan_shader_dir}"
                COMMAND "${SPEKTRALAB_GLSLANG}" -V --target-env vulkan1.0
                        "-I${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/vulkan"
                        -o "${spirv}" "${shader}"
                DEPENDS "${shader}" "${CMAKE_CURRENT_SOURCE_DIR}/src/shaders/vulkan/spk_rng.glsl"
                VERBATIM)
            list(APPEND vulkan_spirv "${spirv}")
        endforeach()
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
            "${SPEKTRALAB_VULKAN_INCLUDE_DIR}"
            "${CMAKE_CURRENT_SOURCE_DIR}/include"
            "${CMAKE_CURRENT_SOURCE_DIR}/src")
        target_link_libraries(spektralab_engine PUBLIC
            spektralab_core "${SPEKTRALAB_VULKAN_LIBRARY}")
        add_dependencies(spektralab_engine spektralab_vulkan_resources)

        if(SPEKTRALAB_BUILD_NATIVE_RAW)
            include(cmake/LibRaw.cmake)
            add_library(spk_image_io STATIC src/io/raw_decoder.cpp src/io/raw_headroom.cpp src/io/image_writer.cpp)
            target_compile_features(spk_image_io PUBLIC cxx_std_20)
            target_include_directories(spk_image_io PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src")
            target_link_libraries(spk_image_io PRIVATE spk_libraw)
            add_executable(spk_raw_render tools/raw_render.cpp)
            target_include_directories(spk_raw_render PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include")
            target_link_libraries(spk_raw_render PRIVATE spk_image_io spektralab_engine)
            if(MINGW)
                target_link_options(spk_raw_render PRIVATE -municode)
            endif()
            if(SPEKTRALAB_BUILD_DESKTOP)
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
                add_executable(spk_image_writer_test tests/image_writer_test.cpp)
                target_link_libraries(spk_image_writer_test PRIVATE spk_image_io)
                add_test(NAME spk_image_writer COMMAND spk_image_writer_test
                    "${CMAKE_CURRENT_SOURCE_DIR}/resources/io/sRGB.icc"
                    "${CMAKE_CURRENT_BINARY_DIR}/writer-test")
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
            add_library(spektralab_engine_shared SHARED
                $<TARGET_OBJECTS:spektralab_pipeline>
                src/gpu/vulkan_gpu.cpp
                windows_exports.def)
            set_target_properties(spektralab_engine_shared PROPERTIES
                OUTPUT_NAME spektrafilm_engine PREFIX "")
            target_compile_features(spektralab_engine_shared PUBLIC cxx_std_20)
            target_include_directories(spektralab_engine_shared PRIVATE
                "${SPEKTRALAB_VULKAN_INCLUDE_DIR}"
                "${CMAKE_CURRENT_SOURCE_DIR}/include"
                "${CMAKE_CURRENT_SOURCE_DIR}/src")
            target_link_libraries(spektralab_engine_shared PRIVATE
                spektralab_core "${SPEKTRALAB_VULKAN_LIBRARY}")
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
            message(FATAL_ERROR "Vulkan SDK headers, loader and glslang are required for this build")
        endif()
        message(STATUS "Vulkan SDK headers, loader, or glslang missing; building portable core only")
    endif()
endif()
