cmake_minimum_required(VERSION 3.20)
project(SpektraLab LANGUAGES C CXX)

include(CTest)

# The Qt Quick editor (windows_UI) links the engine's spk_desktop_host, which
# needs the native RAW decoder and the desktop host enabled before the engine
# is configured. Qt itself is found through CMAKE_PREFIX_PATH.
if(WIN32)
    option(SPEKTRALAB_BUILD_QT "Build the Qt Quick editor in windows_UI" OFF)
    if(SPEKTRALAB_BUILD_QT)
        set(SPEKTRALAB_BUILD_NATIVE_RAW ON CACHE BOOL "" FORCE)
        set(SPEKTRALAB_BUILD_DESKTOP ON CACHE BOOL "" FORCE)
    endif()
endif()

add_subdirectory(engine)

if(WIN32 AND SPEKTRALAB_BUILD_QT)
    add_subdirectory(windows_UI)
endif()
