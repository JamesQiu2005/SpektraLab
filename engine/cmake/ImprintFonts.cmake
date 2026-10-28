# Trusted, pinned font blobs are embedded in the portable renderer. Runtime
# input never reaches stb_truetype; no system font or new shared library is
# required. Originals and their complete OFL are kept in resources_product.
set(imprint_font_dir "${CMAKE_CURRENT_SOURCE_DIR}/resources_product/fonts")
file(SHA256 "${imprint_font_dir}/LiberationSans-Regular.ttf" imprint_regular_hash)
file(SHA256 "${imprint_font_dir}/LiberationSans-Bold.ttf" imprint_bold_hash)
file(SHA256 "${imprint_font_dir}/DejaVuSansMono-Bold.ttf" imprint_mono_bold_hash)
if(NOT imprint_regular_hash STREQUAL "76d04c18ea243f426b7de1f3ad208e927008f961dc5945e5aad352d0dfde8ee8" OR
   NOT imprint_bold_hash STREQUAL "788abee4c806d660e8aee46689dd8540cd4bb98da03dcc9d171ce3efd99a9173")
    message(FATAL_ERROR "Bundled Liberation Sans blobs differ from pinned 2.1.5 sources")
endif()
if(NOT imprint_mono_bold_hash STREQUAL "bce60f1b4421acd9ea51ba6623d7024ecbe6817a953e3654df62a5e6bdf8f769")
    message(FATAL_ERROR "Bundled DejaVu Sans Mono Bold differs from the pinned 2.37 source")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${imprint_font_dir}/LiberationSans-Regular.ttf" "${imprint_font_dir}/LiberationSans-Bold.ttf"
    "${imprint_font_dir}/DejaVuSansMono-Bold.ttf")
file(READ "${imprint_font_dir}/LiberationSans-Regular.ttf" imprint_regular HEX)
file(READ "${imprint_font_dir}/LiberationSans-Bold.ttf" imprint_bold HEX)
file(READ "${imprint_font_dir}/DejaVuSansMono-Bold.ttf" imprint_mono_bold HEX)
string(REGEX REPLACE "(..)" "0x\\1," imprint_regular "${imprint_regular}")
string(REGEX REPLACE "(..)" "0x\\1," imprint_bold "${imprint_bold}")
string(REGEX REPLACE "(..)" "0x\\1," imprint_mono_bold "${imprint_mono_bold}")
file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/generated/spk_imprint_fonts.hpp"
    CONTENT "#pragma once\nnamespace spk::imprint::font_data {\nconst unsigned char regular[] = {${imprint_regular}};\nconst unsigned char bold[] = {${imprint_bold}};\nconst unsigned char mono_bold[] = {${imprint_mono_bold}};\n}\n")
unset(imprint_regular)
unset(imprint_bold)
unset(imprint_mono_bold)
target_include_directories(spektralab_pipeline PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
