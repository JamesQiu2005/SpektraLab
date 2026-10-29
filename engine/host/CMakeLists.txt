# spektralab-host: the engine as a child process (desktop/HOST-PROTOCOL.md).
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/Codecs.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/InputCodecs.cmake")
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/LensCorrection.cmake")
add_executable(spektralab-host
    main.cpp
    pair_source.cpp
    image_io.cpp
    input_formats.cpp
    lens_correction.cpp
    output.cpp
    output_codecs.cpp
    platform.cpp
    stb_impl.cpp
    tiff_ifd.cpp
    white_balance.cpp
)
target_compile_features(spektralab-host PRIVATE cxx_std_20)
target_include_directories(spektralab-host PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/../include"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src"
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stb")
target_link_libraries(spektralab-host PRIVATE spk_image_io spk_libraw spektralab_engine spektralab_core spk_codec_jpeg spk_codec_png spk_input_codecs spk_lens)
if(DEFINED SPEKTRALAB_HOST_VERSION)
    target_compile_definitions(spektralab-host PRIVATE SPEKTRALAB_HOST_VERSION="${SPEKTRALAB_HOST_VERSION}")
endif()

if(BUILD_TESTING)
    find_package(Python3 QUIET COMPONENTS Interpreter)
    if(Python3_Interpreter_FOUND)
        foreach(workflow source proof cineon film_edge pair no_film no_film_upstream)
            add_test(NAME spk_host_${workflow}_workflow COMMAND "${Python3_EXECUTABLE}"
                "${CMAKE_CURRENT_SOURCE_DIR}/../tests/host_${workflow}.py"
                --host "$<TARGET_FILE:spektralab-host>" --resources "${CMAKE_CURRENT_BINARY_DIR}/../resources")
            set_tests_properties(spk_host_${workflow}_workflow PROPERTIES TIMEOUT 180 RESOURCE_LOCK spektralab_gpu
                ENVIRONMENT "PYTHONIOENCODING=utf-8")
        endforeach()
    endif()
    add_executable(spk_host_lens ../tests/host_lens.cpp lens_correction.cpp platform.cpp)
    target_compile_features(spk_host_lens PRIVATE cxx_std_20)
    target_include_directories(spk_host_lens PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../src")
    target_link_libraries(spk_host_lens PRIVATE spk_lens)
    if(WIN32)
        target_link_libraries(spk_host_lens PRIVATE shell32)
    endif()
    if(MINGW AND SPEKTRALAB_STATIC_RUNTIME)
        target_link_options(spk_host_lens PRIVATE -static)
    endif()
    add_test(NAME spk_host_lens COMMAND spk_host_lens "${CMAKE_CURRENT_BINARY_DIR}/lens-tests")
    add_executable(spk_host_inputs ../tests/host_inputs.cpp image_io.cpp input_formats.cpp lens_correction.cpp platform.cpp
        stb_impl.cpp tiff_ifd.cpp white_balance.cpp)
    target_compile_features(spk_host_inputs PRIVATE cxx_std_20)
    target_include_directories(spk_host_inputs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../src"
        "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stb")
    target_link_libraries(spk_host_inputs PRIVATE spk_image_io spk_libraw spk_input_codecs spk_lens)
    if(WIN32)
        target_link_libraries(spk_host_inputs PRIVATE shell32)
    endif()
    if(MINGW AND SPEKTRALAB_STATIC_RUNTIME)
        target_link_options(spk_host_inputs PRIVATE -static)
    endif()
    add_test(NAME spk_host_inputs COMMAND spk_host_inputs "${CMAKE_CURRENT_BINARY_DIR}/input-tests"
        "${SPEKTRALAB_INPUT_CODEC_PREFIX}/share/spektralab-input-codecs/tests/with-alpha-512x512.heic")
    add_executable(spk_host_neutral ../tests/host_neutral.cpp white_balance.cpp)
    target_compile_features(spk_host_neutral PRIVATE cxx_std_20)
    target_include_directories(spk_host_neutral PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../src")
    target_link_libraries(spk_host_neutral PRIVATE spk_libraw)
    if(MINGW AND SPEKTRALAB_STATIC_RUNTIME)
        target_link_options(spk_host_neutral PRIVATE -static)
    endif()
    add_test(NAME spk_host_neutral COMMAND spk_host_neutral)
    add_executable(spk_host_pair_source ../tests/host_pair_source.cpp pair_source.cpp platform.cpp)
    target_compile_features(spk_host_pair_source PRIVATE cxx_std_20)
    target_include_directories(spk_host_pair_source PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../src")
    target_link_libraries(spk_host_pair_source PRIVATE spektralab_core)
    if(WIN32)
        target_link_libraries(spk_host_pair_source PRIVATE shell32)
    endif()
    if(SPEKTRALAB_STATIC_RUNTIME AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        target_link_options(spk_host_pair_source PRIVATE -static-libstdc++ -static-libgcc)
        if(MINGW)
            target_link_options(spk_host_pair_source PRIVATE -static)
        endif()
    endif()
    add_test(NAME spk_host_pair_source COMMAND spk_host_pair_source)
    add_executable(spk_host_codecs ../tests/host_codecs.cpp output.cpp output_codecs.cpp platform.cpp stb_impl.cpp
        image_io.cpp input_formats.cpp lens_correction.cpp tiff_ifd.cpp white_balance.cpp)
    target_compile_features(spk_host_codecs PRIVATE cxx_std_20)
    target_include_directories(spk_host_codecs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stb")
    target_link_libraries(spk_host_codecs PRIVATE spk_image_io spk_libraw spektralab_engine spektralab_core spk_codec_jpeg spk_codec_png spk_input_codecs spk_lens)
    if(WIN32)
        target_link_libraries(spk_host_codecs PRIVATE shell32)
    endif()
    if(SPEKTRALAB_STATIC_RUNTIME AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
        target_link_options(spk_host_codecs PRIVATE -static-libstdc++ -static-libgcc)
        if(MINGW)
            target_link_options(spk_host_codecs PRIVATE -static)
        endif()
    endif()
    add_test(NAME spk_host_codecs COMMAND spk_host_codecs "${CMAKE_CURRENT_SOURCE_DIR}/../resources"
        "${CMAKE_CURRENT_BINARY_DIR}/codec-test-output")
endif()
if(WIN32)
    target_link_libraries(spektralab-host PRIVATE ws2_32 shell32)
endif()
if(SPEKTRALAB_STATIC_RUNTIME AND CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    target_link_options(spektralab-host PRIVATE -static-libstdc++ -static-libgcc)
    if(MINGW)
        target_link_options(spektralab-host PRIVATE -static)
    endif()
endif()
