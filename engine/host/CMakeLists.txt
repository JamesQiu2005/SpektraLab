# spektralab-host: the engine as a child process (desktop/HOST-PROTOCOL.md).
add_executable(spektralab-host
    main.cpp
    image_io.cpp
    lens_correct.cpp
    output.cpp
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
target_link_libraries(spektralab-host PRIVATE spk_image_io spk_libraw spektralab_engine spektralab_core)
# Lens correction at decode (lens_correct.cpp), with lensfun (Linux). Off by default: lensfun is a shared
# library (and glib), and the staged host otherwise needs only glibc and a Vulkan loader. Without it the
# host refuses decode.lens_correction as before.
option(SPEKTRALAB_LENSFUN "Link lensfun for lens correction at decode (Linux)" OFF)
if(SPEKTRALAB_LENSFUN AND NOT WIN32 AND NOT APPLE)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(LENSFUN REQUIRED IMPORTED_TARGET lensfun)
    endif()
    if(LENSFUN_FOUND)
        target_link_libraries(spektralab-host PRIVATE PkgConfig::LENSFUN)
        target_compile_definitions(spektralab-host PRIVATE SPK_HAVE_LENSFUN=1)
        message(STATUS "spektralab-host: lens correction with lensfun ${LENSFUN_VERSION}")
    endif()
endif()
if(DEFINED SPEKTRALAB_HOST_VERSION)
    target_compile_definitions(spektralab-host PRIVATE SPEKTRALAB_HOST_VERSION="${SPEKTRALAB_HOST_VERSION}")
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
