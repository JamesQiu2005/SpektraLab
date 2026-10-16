cmake_minimum_required(VERSION 3.22)

# Also usable as add_subdirectory(windows_UI) after the engine defines
# spk_desktop_host. The standalone mode never modifies the engine checkout.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(SpektraLabWindowsUI LANGUAGES CXX)
    include(CTest)
    set(SPEKTRALAB_SOURCE_ROOT "" CACHE PATH "Source tree supplying engine/")
    if(NOT EXISTS "${SPEKTRALAB_SOURCE_ROOT}/engine/CMakeLists.txt")
        message(FATAL_ERROR "Set SPEKTRALAB_SOURCE_ROOT to the SpektraLab source tree")
    endif()
    set(SPEKTRALAB_BUILD_NATIVE_RAW ON CACHE BOOL "" FORCE)
    set(SPEKTRALAB_BUILD_DESKTOP ON CACHE BOOL "" FORCE)
    add_subdirectory("${SPEKTRALAB_SOURCE_ROOT}/engine" engine)
endif()

if(NOT TARGET spk_desktop_host)
    message(FATAL_ERROR "Build the engine's spk_desktop_host before windows_UI")
endif()
if(MSVC)
    # UTF-8 sources; see engine/CMakeLists.txt.
    add_compile_options(/utf-8 /Zc:__cplusplus)
    add_compile_definitions(NOMINMAX)
endif()
find_package(Qt6 6.8 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 ShaderTools)
# rhi/qrhi.h: the canvas's frame and display-LUT textures (ColorCanvasNode.cpp).
find_package(Qt6 6.8 REQUIRED COMPONENTS GuiPrivate)
qt_standard_project_setup(REQUIRES 6.8)

# The canvas material's shaders. The fragment shader is one source built per
# variant (no lookup, 3D texture, 2D atlas, bare copy, and both tables with
# the 1-D curves; see its header); GLSL 300 es/330 because it uses integer
# arithmetic and sampler3D.
function(spk_qt_add_canvas_shaders target)
    qt_add_shaders(${target} "${target}_canvas_vertex" BATCHABLE PREFIX "/" GLSL "300es,330"
        FILES shaders/colorcanvas.vert)
    foreach(variant IN ITEMS "plain;0;0" "lut3d;1;0" "lut2d;2;0" "copy;3;0" "lut3d_curves;1;1" "lut2d_curves;2;1")
        list(GET variant 0 name)
        list(GET variant 1 mode)
        list(GET variant 2 curves)
        qt_add_shaders(${target} "${target}_canvas_${name}" PREFIX "/" GLSL "300es,330"
            DEFINES "LUT_MODE=${mode};CURVES=${curves}" FILES shaders/colorcanvas.frag
            OUTPUTS shaders/colorcanvas_${name}.frag.qsb)
    endforeach()
endfunction()

qt_add_executable(SpektraLabQt WIN32
    src/main.cpp src/Messages.hpp src/PreviewController.hpp src/PreviewController.cpp
    src/FrameOutput.hpp src/FrameOutput.cpp src/FrameImage.hpp src/FrameImage.cpp
    src/EditStore.hpp src/EditStore.cpp
    src/FrameCanvas.hpp src/FrameCanvas.cpp
    src/ColorCanvasNode.hpp src/ColorCanvasNode.cpp
    src/ColorPipeline.hpp src/ColorPipeline.cpp
    src/Localizer.hpp src/Localizer.cpp)
target_compile_features(SpektraLabQt PRIVATE cxx_std_20)
target_link_libraries(SpektraLabQt PRIVATE
    spk_desktop_host Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Qml Qt6::Quick Qt6::QuickControls2)
spk_qt_add_canvas_shaders(SpektraLabQt)
# The colour core behind ColorPipeline: display-profile discovery and the LUT.
target_sources(SpektraLabQt PRIVATE
    src/DisplayColor.hpp src/DisplayColor.cpp src/ColorLut.hpp src/ColorLut.cpp)
# The compiled-in language tables, read from :/i18n (i18n/README.md).
qt_add_resources(SpektraLabQt "spektralab_i18n" PREFIX "/i18n" BASE i18n FILES i18n/en.json)
set_source_files_properties(qml/Theme.qml qml/L10n.qml qml/Icons.qml qml/SectionStates.qml qml/Catalog.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
# One module; the subdirectories are ownership, not namespaces -- every type is
# visible to every file by its bare name. Main.qml is the window, EditorState
# the state the panes share, L10n the text lookup; Theme, Icons and the
# controls in qml/controls are the design system ported from the macOS app.
qt_add_qml_module(SpektraLabQt URI SpektraLab VERSION 1.0
    QML_FILES
        qml/Main.qml qml/EditorState.qml qml/L10n.qml
        qml/Theme.qml qml/Icons.qml qml/SectionStates.qml qml/Catalog.qml
        qml/Section.qml qml/ActionButton.qml
        qml/controls/MacSection.qml qml/controls/ParamRow.qml qml/controls/ScrubSlider.qml
        qml/controls/ValueBox.qml qml/controls/CheckRow.qml qml/controls/SquareCheck.qml
        qml/controls/AsShotLine.qml qml/controls/PillDropdown.qml qml/controls/PillSwitch.qml
        qml/controls/PillButton.qml qml/controls/IconButton.qml qml/controls/Triangle.qml
        qml/controls/RailMenu.qml qml/controls/RailMenuItem.qml qml/controls/RailScrollBar.qml
        qml/controls/RailResizeHandle.qml qml/controls/StockList.qml qml/controls/CinePill.qml
        qml/controls/PlotPlaceholder.qml qml/controls/Note.qml
        qml/controls/Adjustment.qml qml/controls/Effect.qml
        qml/left/LeftRail.qml qml/left/NavigatorSection.qml qml/left/ClipboardSection.qml
        qml/left/FilmSection.qml qml/left/PrintSection.qml qml/left/CropSection.qml
        qml/left/EnlargerSection.qml
        qml/centre/CentrePane.qml qml/centre/TopBar.qml qml/centre/CanvasView.qml
        qml/centre/CropOverlay.qml qml/centre/Filmstrip.qml
        qml/right/RightRail.qml qml/right/LatitudeSection.qml qml/right/CameraSection.qml
        qml/right/FilmFormatSection.qml qml/right/ScenePlacementSection.qml
        qml/right/ToneMaskSection.qml qml/right/DecodeSection.qml qml/right/InfoSection.qml
        qml/right/StatusSection.qml
        qml/export/ExportPopup.qml
    NO_CACHEGEN)
set_target_properties(SpektraLabQt PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/app")

# The one resource directory is explicitly adjacent to the executable. No
# lookup through another checkout and no Python in the application.
add_custom_target(spektralab_qt_resources ALL
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "$<TARGET_FILE_DIR:spk_raw_render>/resources" "$<TARGET_FILE_DIR:SpektraLabQt>/resources"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "$<TARGET_FILE_DIR:spk_raw_render>/licenses" "$<TARGET_FILE_DIR:SpektraLabQt>/licenses"
    VERBATIM)
add_dependencies(spektralab_qt_resources spektralab_vulkan_resources)
add_dependencies(SpektraLabQt spektralab_qt_resources)

if(BUILD_TESTING)
    qt_add_executable(spk_qt_frame_output_test tests/frame_output.cpp src/FrameOutput.cpp src/FrameImage.cpp)
    target_include_directories(spk_qt_frame_output_test PRIVATE src)
    target_compile_features(spk_qt_frame_output_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_frame_output_test PRIVATE spk_desktop_host Qt6::Core Qt6::Gui)
    add_test(NAME spk_qt_frame_output COMMAND spk_qt_frame_output_test "$<TARGET_FILE_DIR:SpektraLabQt>/resources")

    # The canvas images: every engine output space against the engine's own
    # baked primaries and transfer functions, the half-float conversion of
    # all 65536 codes, and the navigator/thumbnail reduction. No RAW or GPU.
    qt_add_executable(spk_qt_frame_image_test tests/frame_image.cpp tests/display_checks.hpp
        src/FrameImage.cpp src/FrameOutput.cpp)
    target_include_directories(spk_qt_frame_image_test PRIVATE src)
    target_compile_features(spk_qt_frame_image_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_frame_image_test PRIVATE spk_desktop_host Qt6::Core Qt6::Gui)
    add_test(NAME spk_qt_frame_image COMMAND spk_qt_frame_image_test "$<TARGET_FILE_DIR:SpektraLabQt>/resources")

    qt_add_executable(spk_qt_library_workflow_test tests/library_workflow.cpp tests/display_checks.hpp
        src/PreviewController.hpp src/PreviewController.cpp src/FrameOutput.cpp src/FrameImage.cpp src/EditStore.cpp)
    target_include_directories(spk_qt_library_workflow_test PRIVATE src)
    target_compile_features(spk_qt_library_workflow_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_library_workflow_test PRIVATE spk_desktop_host Qt6::Core Qt6::Gui)
    qt_add_executable(spk_qt_edit_store_test tests/edit_store.cpp src/EditStore.cpp)
    target_include_directories(spk_qt_edit_store_test PRIVATE src)
    target_compile_features(spk_qt_edit_store_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_edit_store_test PRIVATE spk_desktop_host Qt6::Core Qt6::Gui)
    # Scratch roots inside the build tree, never the system temporary folder.
    add_test(NAME spk_qt_edit_store COMMAND spk_qt_edit_store_test "${CMAKE_CURRENT_BINARY_DIR}/edit-store-test")
    # The controller's settings API (generic parameters, legacy names,
    # defaults, locks) needs the engine's catalogue but no photograph.
    qt_add_executable(spk_qt_controller_settings_test tests/controller_settings.cpp
        src/PreviewController.hpp src/PreviewController.cpp src/FrameOutput.cpp src/FrameImage.cpp src/EditStore.cpp)
    target_include_directories(spk_qt_controller_settings_test PRIVATE src)
    target_compile_features(spk_qt_controller_settings_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_controller_settings_test PRIVATE spk_desktop_host Qt6::Core Qt6::Gui)
    add_test(NAME spk_qt_controller_settings COMMAND spk_qt_controller_settings_test
        "$<TARGET_FILE_DIR:SpektraLabQt>/resources" "${CMAKE_CURRENT_BINARY_DIR}/controller-settings-test")
    # The settings table through the real engine on a synthetic frame: the
    # macOS defaults are accepted, deltas stay minimal across stock changes,
    # and the filter scale is inert at zero shifts. No RAW fixture.
    if(TARGET spk_desktop_preview_test)
        add_test(NAME spk_desktop_settings_engine COMMAND spk_desktop_preview_test --settings-engine
            "$<TARGET_FILE_DIR:SpektraLabQt>/resources")
    endif()
    # The canvas through forced display LUTs, against a CPU reference: on the
    # GPU (D3D11 WARP through QQuickRenderControl; exit 77 = no WARP, skipped
    # loudly) and through the software backend's CPU path.
    qt_add_executable(spk_qt_color_canvas_test tests/color_canvas.cpp
        src/FrameCanvas.hpp src/FrameCanvas.cpp src/ColorCanvasNode.hpp src/ColorCanvasNode.cpp
        src/ColorPipeline.hpp src/ColorPipeline.cpp src/DisplayColor.hpp src/DisplayColor.cpp
        src/ColorLut.hpp src/ColorLut.cpp)
    target_include_directories(spk_qt_color_canvas_test PRIVATE src)
    target_compile_features(spk_qt_color_canvas_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_color_canvas_test PRIVATE Qt6::Core Qt6::Gui Qt6::GuiPrivate Qt6::Quick)
    spk_qt_add_canvas_shaders(spk_qt_color_canvas_test)
    add_test(NAME spk_qt_color_canvas COMMAND spk_qt_color_canvas_test)
    add_test(NAME spk_qt_color_canvas_software COMMAND spk_qt_color_canvas_test --software)
    set_tests_properties(spk_qt_color_canvas PROPERTIES SKIP_RETURN_CODE 77)
    # The shipped tables and the QML keys, plus a scratch directory inside the
    # build tree for the test's own language files.
    qt_add_executable(spk_qt_localizer_test tests/localizer.cpp src/Localizer.hpp src/Localizer.cpp)
    target_include_directories(spk_qt_localizer_test PRIVATE src)
    target_compile_features(spk_qt_localizer_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_localizer_test PRIVATE Qt6::Core)
    add_test(NAME spk_qt_localizer COMMAND spk_qt_localizer_test
        "${CMAKE_CURRENT_SOURCE_DIR}/i18n" "${CMAKE_CURRENT_SOURCE_DIR}/qml" "${CMAKE_CURRENT_BINARY_DIR}/localizer_test")
    if(WIN32)
        # Specify each test's DLL search path: CTest on this Windows host can
        # restore the pre-launch PATH between tests. Ambient PATH alone makes
        # the second Qt test fail to load even when it passes in isolation.
        set(qt_test_runtime_path "PATH=path_list_prepend:$<TARGET_FILE_DIR:Qt6::Core>")
        if(MINGW)
            get_filename_component(qt_test_compiler_directory "${CMAKE_CXX_COMPILER}" DIRECTORY)
            list(APPEND qt_test_runtime_path "PATH=path_list_prepend:${qt_test_compiler_directory}")
        endif()
        set_tests_properties(spk_qt_frame_output spk_qt_frame_image spk_qt_edit_store spk_qt_controller_settings
            spk_qt_localizer spk_qt_color_canvas spk_qt_color_canvas_software PROPERTIES
            ENVIRONMENT_MODIFICATION "${qt_test_runtime_path}")
    endif()
    qt_add_executable(spk_qt_editing_workflow_test tests/editing_workflow.cpp tests/display_checks.hpp
        src/PreviewController.hpp src/PreviewController.cpp src/FrameOutput.cpp src/FrameImage.cpp src/EditStore.cpp)
    target_include_directories(spk_qt_editing_workflow_test PRIVATE src)
    target_compile_features(spk_qt_editing_workflow_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_editing_workflow_test PRIVATE spk_desktop_host Qt6::Core Qt6::Gui)
    # Full-RAW fixtures and a fresh output directory are explicit test arguments;
    # no absent-fixture skip can masquerade as a green CTest run.

    # Display colour management on the CPU: synthetic ICC profiles, the LUT
    # against Qt's transform through a model of the shader's lookup, and
    # simulated monitors driving ColorPipeline. No GPU, no shown window, no
    # installed profile. `--probe-display` prints this machine's displays.
    qt_add_executable(spk_qt_color_core_test tests/color_core.cpp
        src/ColorPipeline.hpp src/ColorPipeline.cpp src/DisplayColor.hpp src/DisplayColor.cpp
        src/ColorLut.hpp src/ColorLut.cpp)
    target_include_directories(spk_qt_color_core_test PRIVATE src)
    target_compile_features(spk_qt_color_core_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_color_core_test PRIVATE Qt6::Core Qt6::Gui Qt6::Quick)
    add_test(NAME spk_qt_color_core COMMAND spk_qt_color_core_test "${CMAKE_CURRENT_BINARY_DIR}/color-core-test")
    if(WIN32)
        set_tests_properties(spk_qt_color_core PROPERTIES ENVIRONMENT_MODIFICATION "${qt_test_runtime_path}")
    endif()
endif()

# --- The application shell (lane ui-app-shell) ---
# The Settings and About windows, the application menu and the preferences
# file (src/AppSettings.*, src/AppShell.*, qml/shell/). The version is the
# macOS app's MARKETING_VERSION (modern_UI/Spektrafilm/Spektrafilm.xcodeproj/
# project.pbxproj:1334), so both builds of one release say the same number.
set(SPEKTRALAB_VERSION "1.3.3")
target_sources(SpektraLabQt PRIVATE src/AppSettings.hpp src/AppSettings.cpp src/AppShell.hpp src/AppShell.cpp
    src/ShellCapture.hpp src/ShellCapture.cpp)
target_compile_definitions(SpektraLabQt PRIVATE SPEKTRALAB_VERSION="${SPEKTRALAB_VERSION}")
qt_target_qml_sources(SpektraLabQt
    QML_FILES
        qml/shell/ShellWindow.qml qml/shell/SettingsWindow.qml qml/shell/SettingsGroup.qml
        qml/shell/SettingsReadout.qml qml/shell/AboutWindow.qml qml/shell/LicenceWindow.qml
        qml/shell/AppMenu.qml qml/shell/MenuCommand.qml qml/shell/LinkText.qml
    NO_CACHEGEN)
# volk (engine/third_party/volk, MIT) is compiled into the engine on Windows;
# its notice travels with the others in licenses/, where the About window
# lists it.
set(spk_volk_license "${CMAKE_CURRENT_SOURCE_DIR}/../engine/third_party/volk/LICENSE.md")
if(EXISTS "${spk_volk_license}")
    add_custom_command(TARGET spektralab_qt_resources POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E make_directory "$<TARGET_FILE_DIR:SpektraLabQt>/licenses"
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${spk_volk_license}" "$<TARGET_FILE_DIR:SpektraLabQt>/licenses/volk-LICENSE.md"
        VERBATIM)
endif()
if(BUILD_TESTING)
    # The preferences file: paths, round trip, atomic writes, unknown keys.
    qt_add_executable(spk_qt_app_settings_test tests/app_settings.cpp src/AppSettings.hpp src/AppSettings.cpp)
    target_include_directories(spk_qt_app_settings_test PRIVATE src)
    target_compile_features(spk_qt_app_settings_test PRIVATE cxx_std_20)
    target_link_libraries(spk_qt_app_settings_test PRIVATE Qt6::Core Qt6::Qml)
    add_test(NAME spk_qt_app_settings COMMAND spk_qt_app_settings_test "${CMAKE_CURRENT_BINARY_DIR}/app-settings-test")
    # The Settings and About windows load, every page and a licence text are
    # captured, and no QML warning is logged (ShellCapture.hpp): the real
    # executable, offscreen, with its preferences inside the build tree.
    add_test(NAME spk_qt_shell_smoke COMMAND "${CMAKE_COMMAND}" "-DAPP=$<TARGET_FILE:SpektraLabQt>"
        "-DOUTPUT=${CMAKE_CURRENT_BINARY_DIR}/shell-smoke" -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/shell_smoke.cmake")
    set_tests_properties(spk_qt_shell_smoke PROPERTIES TIMEOUT 180
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QT_QUICK_BACKEND=software;QML_DISABLE_DISK_CACHE=1;QSG_RHI_DISABLE_DISK_CACHE=1")
    if(WIN32)
        set_tests_properties(spk_qt_app_settings spk_qt_shell_smoke PROPERTIES ENVIRONMENT_MODIFICATION "${qt_test_runtime_path}")
    endif()
endif()