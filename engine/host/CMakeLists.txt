# spektralab-host: the engine as a child process (desktop/HOST-PROTOCOL.md).
include("${CMAKE_CURRENT_SOURCE_DIR}/../cmake/Codecs.cmake")
add_executable(spektralab-host
    main.cpp
    image_io.cpp
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
target_link_libraries(spektralab-host PRIVATE spk_image_io spk_libraw spektralab_engine spektralab_core spk_codec_jpeg spk_codec_png)
if(DEFINED SPEKTRALAB_HOST_VERSION)
    target_compile_definitions(spektralab-host PRIVATE SPEKTRALAB_HOST_VERSION="${SPEKTRALAB_HOST_VERSION}")
endif()

if(BUILD_TESTING)
    add_executable(spk_host_codecs ../tests/host_codecs.cpp output.cpp output_codecs.cpp platform.cpp stb_impl.cpp
        image_io.cpp tiff_ifd.cpp white_balance.cpp)
    target_compile_features(spk_host_codecs PRIVATE cxx_std_20)
    target_include_directories(spk_host_codecs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/../include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/stb")
    target_link_libraries(spk_host_codecs PRIVATE spk_image_io spk_libraw spektralab_engine spektralab_core spk_codec_jpeg spk_codec_png)
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
