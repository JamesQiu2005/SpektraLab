# Develop Camera's native library: Develop's engine, built from this repository's engine/ (GPL-3.0-or-later), the
# RAW path (raw_develop.cpp) and the JNI bridge (native-lib.cpp). The source list mirrors engine/CMakeLists.txt:
# spektralab_core, spektralab_pipeline and the Vulkan backend; volk loads libvulkan.so at run time.
cmake_minimum_required(VERSION 3.22)
project(developcamera LANGUAGES C CXX)

set(D ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../engine)
set(CORE blob cam16 colour curves diffusion_psf digital_intermediate hanatos hdr_curves json latitude_fit minilab
         negative_hue numeric params print_lut printing profile scan_hdr setup_cache spectral)
set(PIPE blur disk_checkpoint engine pipeline scene_latitude contrast_mask lens overscan edge_raster scene_layers
         windows_unported)
list(TRANSFORM CORE PREPEND ${D}/src/core/)
list(TRANSFORM CORE APPEND .cpp)
list(TRANSFORM PIPE PREPEND ${D}/src/pipeline/)
list(TRANSFORM PIPE APPEND .cpp)

add_library(developcamera SHARED native-lib.cpp raw_develop.cpp ${CORE} ${PIPE} ${D}/src/gpu/vulkan_gpu.cpp ${D}/third_party/volk/volk.c)
# The engine's pinned Vulkan headers (1.4.341, C headers only, vulkan-headers/) before the NDK's own.
target_include_directories(developcamera BEFORE PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/vulkan-headers)
target_include_directories(developcamera PRIVATE
    ${D}/src/core ${D}/include ${D}/src ${D}/third_party/stb ${D}/third_party/volk)
target_compile_features(developcamera PRIVATE cxx_std_20)
target_compile_definitions(developcamera PRIVATE SPK_HARDENED=1)   # no test entry points in the app
target_compile_options(developcamera PRIVATE -O2 $<$<COMPILE_LANGUAGE:CXX>:-fexceptions -frtti>)
target_link_libraries(developcamera PRIVATE android log jnigraphics dl)
