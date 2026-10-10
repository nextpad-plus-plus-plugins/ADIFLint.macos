cmake_minimum_required(VERSION 3.20)

# -DADIF_SANITIZE=ON builds the core, CLI and tests with ASan+UBSan for the
# host architecture only, and skips the plugin (it runs inside Nextpad++).
# Architectures must be chosen before project().
option(ADIF_SANITIZE "Build core and tests with AddressSanitizer and UBSan" OFF)
if(NOT ADIF_SANITIZE)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "")

project(ADIFLint VERSION 0.9.0 LANGUAGES CXX OBJCXX)

# Plugin build follows the Nextpad++ porting playbook: universal, macOS 11+,
# ARC, a .dylib named after its plugins/ folder.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

if(ADIF_SANITIZE)
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
    add_link_options(-fsanitize=address,undefined)
endif()

set(WARNINGS -Wall -Wextra -Wno-unused-parameter)

# ── Core: ADIF tables, validator, length fixer (no platform dependencies) ────
add_library(adif_core STATIC
    src/core/adif_spec.cpp
    src/core/adif_spec_317.cpp
    src/core/adif_lint.cpp
    src/core/adif_edit.cpp
    src/core/adif_enrich.cpp
    src/core/adif_tools.cpp
    src/core/adif_upload.cpp
    src/core/adif_import.cpp
    src/core/adif_geo.cpp
    src/core/adif_country.cpp
    src/core/adif_programs.cpp
    src/core/adif_formats.cpp
    src/core/adif_profiles.cpp
    src/core/adif_capture.cpp
    src/core/adif_compare.cpp
    src/core/adif_qsl.cpp)
target_include_directories(adif_core PUBLIC src/core)
target_compile_options(adif_core PRIVATE ${WARNINGS})
set_target_properties(adif_core PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Regenerate the tables after replacing spec/adif-3.1.7/all.json.
find_package(Python3 COMPONENTS Interpreter)
if(Python3_FOUND)
    add_custom_target(regen-spec
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/gen_spec_tables.py
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Generating src/core/adif_spec_317.cpp from the ADIF JSON export")
endif()

# ── Command-line checker ─────────────────────────────────────────────────────
# Target name differs from ADIFLint (the plugin) by more than case: macOS
# volumes are usually case-insensitive and CMake's per-target dirs would collide.
add_executable(adiflint_cli src/cli/adiflint_main.cpp)
set_target_properties(adiflint_cli PROPERTIES OUTPUT_NAME adiflint)
target_link_libraries(adiflint_cli PRIVATE adif_core)
target_compile_options(adiflint_cli PRIVATE ${WARNINGS})

# ── Tests ────────────────────────────────────────────────────────────────────
enable_testing()
set(OFFICIAL_ADI ${CMAKE_SOURCE_DIR}/tests/fixtures/ADIF_317_test_QSOs_2026_03_22.adi)
add_executable(adif_tests tests/adif_tests.cpp)
target_link_libraries(adif_tests PRIVATE adif_core)
target_compile_options(adif_tests PRIVATE ${WARNINGS})
add_test(NAME adif_tests COMMAND adif_tests ${OFFICIAL_ADI} ${CMAKE_SOURCE_DIR}/data/cty.csv)

add_executable(fuzz_smoke tests/fuzz_smoke.cpp)
target_link_libraries(fuzz_smoke PRIVATE adif_core)
target_compile_options(fuzz_smoke PRIVATE ${WARNINGS})
add_test(NAME fuzz_smoke COMMAND fuzz_smoke ${OFFICIAL_ADI} 1000)

add_test(NAME adiflint_official COMMAND adiflint_cli --quiet ${OFFICIAL_ADI})
add_test(NAME adiflint_tools COMMAND sh ${CMAKE_SOURCE_DIR}/tests/cli_tools.sh $<TARGET_FILE:adiflint_cli> ${OFFICIAL_ADI}
         ${CMAKE_BINARY_DIR}/cli_tools)

# ── Nextpad++ plugin ─────────────────────────────────────────────────────────
if(NOT ADIF_SANITIZE)
    add_library(ADIFLint SHARED src/plugin/ADIFLint.mm src/plugin/RecordPanel.mm src/plugin/NewQsoPanel.mm
        src/plugin/EnrichPanel.mm src/plugin/Lookup.mm src/plugin/SettingsPanel.mm src/plugin/QsoFieldsPanel.mm
        src/plugin/ToolWindow.mm src/plugin/LogTools.mm src/plugin/CheckLog.mm src/plugin/Families.mm src/plugin/Station.mm src/plugin/Monitor.mm
        src/plugin/Uploads.mm src/plugin/Imports.mm src/plugin/Country.mm)
    target_include_directories(ADIFLint PRIVATE
        third_party/nextpad
        third_party/scintilla/include)
    target_link_libraries(ADIFLint PRIVATE adif_core "-framework Cocoa" "-framework Security"
        "-framework UniformTypeIdentifiers")
    target_compile_definitions(ADIFLint PRIVATE ADIFLINT_VERSION="${PROJECT_VERSION}")
    target_compile_options(ADIFLint PRIVATE ${WARNINGS} $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    # The host loads plugins/<Folder>/<Folder>.dylib, so the name must stay ADIFLint.
    set_target_properties(ADIFLint PROPERTIES PREFIX "" SUFFIX ".dylib" OUTPUT_NAME "ADIFLint")
    target_link_options(ADIFLint PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")
    # The country file sits next to the dylib, installed or built (the harness loads the built one).
    add_custom_command(TARGET ADIFLint POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/data/cty.csv $<TARGET_FILE_DIR:ADIFLint>/cty.csv)

    set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/ADIFLint"
        CACHE PATH "Where 'cmake --install' puts the plugin")
    # Copy to a new file, sign it, then rename it over the old one. Overwriting
    # the installed dylib in place could crash a running Nextpad++ that has it
    # mapped; a rename leaves the running copy's file intact until restart.
    # (Nextpad++ disables library validation, so an ad-hoc signature is enough.)
    install(CODE "
        set(dir \"${PLUGIN_INSTALL_DIR}\")
        file(MAKE_DIRECTORY \"\${dir}\")
        execute_process(COMMAND \"${CMAKE_COMMAND}\" -E copy \"$<TARGET_FILE:ADIFLint>\" \"\${dir}/ADIFLint.dylib.new\"
                        RESULT_VARIABLE rc)
        if(NOT rc EQUAL 0)
            message(FATAL_ERROR \"copy failed\")
        endif()
        execute_process(COMMAND codesign --force --sign - \"\${dir}/ADIFLint.dylib.new\")
        file(RENAME \"\${dir}/ADIFLint.dylib.new\" \"\${dir}/ADIFLint.dylib\")
        file(COPY \"${CMAKE_SOURCE_DIR}/data/cty.csv\" \"${CMAKE_SOURCE_DIR}/data/cty-copyright.txt\" DESTINATION \"\${dir}\")
        file(GLOB icons \"${CMAKE_SOURCE_DIR}/data/toolbar/*.png\")
        file(COPY \${icons} DESTINATION \"\${dir}\")
        message(STATUS \"Installed \${dir}/ADIFLint.dylib; restart Nextpad++ to load it\")
    ")

    # Drives the built dylib through a simulated host and Scintilla.
    add_executable(host_harness tests/host_harness.mm)
    target_include_directories(host_harness PRIVATE third_party/nextpad third_party/scintilla/include)
    target_link_libraries(host_harness PRIVATE "-framework Cocoa")
    target_compile_options(host_harness PRIVATE ${WARNINGS} -fobjc-arc)
    add_dependencies(host_harness ADIFLint)
    add_test(NAME host_harness COMMAND host_harness $<TARGET_FILE:ADIFLint> ${CMAKE_SOURCE_DIR}/tests/fixtures/lookup)
endif()
