cmake_minimum_required(VERSION 3.20)
project(re7mp LANGUAGES CXX)
if(WIN32)
  enable_language(RC)  # for the embedded Lua script (src/app.rc)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Engine + transport + game locator, shared by the GUI, the CLI and the tests.
add_library(re7mp_core STATIC
  src/engine.cpp
  src/tcp_transport.cpp
  src/game_locator.cpp
  src/save_sync.cpp
  src/save_resign.cpp
  src/zip_extract.cpp
  src/updater.cpp)
target_include_directories(re7mp_core PUBLIC src)
find_package(Threads REQUIRED)
target_link_libraries(re7mp_core PUBLIC Threads::Threads)
if(WIN32)
  target_link_libraries(re7mp_core PUBLIC ws2_32)
endif()

# Headless front end and tests (cross-platform).
add_executable(re7mp_cli src/cli_main.cpp)
target_link_libraries(re7mp_cli PRIVATE re7mp_core)
add_executable(re7mp_tests tests/core_tests.cpp)
target_link_libraries(re7mp_tests PRIVATE re7mp_core)
# The tests read the Lua script to check its release number matches src/version.hpp.
target_compile_definitions(re7mp_tests PRIVATE RE7MP_LUA_PATH="${CMAKE_CURRENT_SOURCE_DIR}/lua/re7mp.lua"
                           RE7MP_TEST_DATA="${CMAKE_CURRENT_SOURCE_DIR}/tests/data")

# The GUI: the exe you actually use. Lua script is embedded via src/app.rc.
if(WIN32)
  add_executable(re7mp WIN32 src/gui_win.cpp src/http_win.cpp src/app.rc)
  target_link_libraries(re7mp PRIVATE re7mp_core winhttp)
  set_source_files_properties(src/app.rc PROPERTIES OBJECT_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/lua/re7mp.lua;${CMAKE_CURRENT_SOURCE_DIR}/data/re7mp/defaults.json")
endif()

foreach(t re7mp_core re7mp_cli re7mp_tests re7mp)
  if(TARGET ${t})
    if(MSVC)
      target_compile_options(${t} PRIVATE /W4 /permissive- /utf-8)
      # Static CRT so the exe runs on a friend's PC without the VC++ redistributable.
      set_property(TARGET ${t} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    else()
      target_compile_options(${t} PRIVATE -Wall -Wextra)
    endif()
  endif()
endforeach()
