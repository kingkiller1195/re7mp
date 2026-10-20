cmake_minimum_required(VERSION 3.20)
project(re7_mp LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------------------
# Transport library + loopback test (builds and runs on Windows, Linux, macOS)
# ---------------------------------------------------------------------------
add_library(mp_net STATIC src/net.cpp)
target_include_directories(mp_net PUBLIC src)
find_package(Threads REQUIRED)
target_link_libraries(mp_net PUBLIC Threads::Threads)
if(WIN32)
  target_link_libraries(mp_net PUBLIC ws2_32)
endif()

enable_testing()
add_executable(loopback_test tests/loopback_test.cpp)
target_link_libraries(loopback_test PRIVATE mp_net)
add_test(NAME loopback COMMAND loopback_test)

# ---------------------------------------------------------------------------
# REFramework plugin (Windows only)
# ---------------------------------------------------------------------------
if(WIN32)
  # The plugin operates on the lua_State that REFramework owns, so it must be compiled against
  # the same Lua minor version. Check `print(_VERSION)` in REFramework's script console and
  # override this tag if needed:   cmake -DLUA_TAG=v5.4.6 ..
  set(LUA_TAG "v5.4.7" CACHE STRING "Lua git tag to build against")

  include(FetchContent)
  FetchContent_Declare(lua_src
    GIT_REPOSITORY https://github.com/lua/lua.git
    GIT_TAG        ${LUA_TAG}
    GIT_SHALLOW    TRUE)
  FetchContent_MakeAvailable(lua_src)

  file(GLOB LUA_SOURCES "${lua_src_SOURCE_DIR}/*.c")
  list(FILTER LUA_SOURCES EXCLUDE REGEX "[/\\\\](lua|luac|onelua|ltests)\\.c$")
  add_library(lua_static STATIC ${LUA_SOURCES})
  target_include_directories(lua_static PUBLIC "${lua_src_SOURCE_DIR}")
  set_target_properties(lua_static PROPERTIES LINKER_LANGUAGE C)

  # Copy REFramework's include/reframework/ folder (API.h, API.hpp) into
  # plugin/third_party/reframework/ - see README.
  if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/third_party/reframework/API.h")
    message(FATAL_ERROR
      "Missing plugin/third_party/reframework/API.h. Copy the 'include/reframework' folder from "
      "https://github.com/praydog/REFramework into plugin/third_party/ (see README).")
  endif()

  add_library(re7_mp SHARED src/plugin.cpp)
  target_include_directories(re7_mp PRIVATE third_party)
  target_link_libraries(re7_mp PRIVATE mp_net lua_static)
  set_target_properties(re7_mp PROPERTIES PREFIX "" OUTPUT_NAME "re7_mp")
endif()
