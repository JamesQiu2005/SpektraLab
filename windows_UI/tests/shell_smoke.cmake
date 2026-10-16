# spk_qt_shell_smoke: run the real executable's --capture-shell into a fresh
# directory inside the build tree (the option refuses an existing one, like
# --self-test) with its edits and preferences inside it, then show the report.
# ShellCapture.hpp says what passes; the exit code is the app's.
if(NOT APP OR NOT OUTPUT)
    message(FATAL_ERROR "usage: cmake -DAPP=<SpektraLabQt.exe> -DOUTPUT=<directory> -P shell_smoke.cmake")
endif()
file(REMOVE_RECURSE "${OUTPUT}")
file(MAKE_DIRECTORY "${OUTPUT}")
execute_process(
    COMMAND "${APP}" --capture-shell "${OUTPUT}/captures" --edit-store "${OUTPUT}/edits"
    RESULT_VARIABLE result
    OUTPUT_VARIABLE out ERROR_VARIABLE err
    TIMEOUT 150)
if(EXISTS "${OUTPUT}/captures/report.json")
    file(READ "${OUTPUT}/captures/report.json" report)
    message("${report}")
endif()
if(NOT result EQUAL 0)
    message("${out}")
    message("${err}")
    message(FATAL_ERROR "SpektraLabQt --capture-shell exited with ${result}")
endif()
