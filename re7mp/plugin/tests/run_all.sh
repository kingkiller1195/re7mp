#!/usr/bin/env bash
# Builds and runs every test that can run off-Windows. Run from the repo root:  plugin/tests/run_all.sh
# Needs: g++ (C++20), pthreads, and liblua5.4.so (Debian/Ubuntu: apt install liblua5.4-0).
# The Lua harness compiles the REAL plugin/src/plugin.cpp against minimal test-only Lua headers
# (plugin/tests/stubs) and links the system Lua 5.4 runtime.
set -euo pipefail
cd "$(dirname "$0")/../.."
LUA_SO="${LUA_SO:-$( (ls /usr/lib/*/liblua5.4.so.0 /usr/lib/liblua5.4.so.0 2>/dev/null || true) | head -1)}"
OUT="${TMPDIR:-/tmp}/re7mp_tests"; mkdir -p "$OUT"
CXX="${CXX:-g++}"; FLAGS="-std=c++20 -Wall -Wextra -g -fsanitize=address,undefined -pthread"

echo "### 1/4 transport: loopback (handshake, relay, reliability under 30% loss, leave, full)"
$CXX $FLAGS plugin/src/net.cpp plugin/tests/loopback_test.cpp -o "$OUT/loopback"
"$OUT/loopback" | tail -1

echo "### 2/4 transport: ThreadSanitizer"
$CXX -std=c++20 -g -fsanitize=thread -pthread plugin/src/net.cpp plugin/tests/loopback_test.cpp -o "$OUT/loopback_tsan"
"$OUT/loopback_tsan" | tail -1

echo "### 3/4 Lua modules (real Lua 5.4 + real plugin bridge)"
$CXX $FLAGS -D'__declspec(x)=' -Iplugin/tests/stubs -Iplugin/src plugin/src/net.cpp plugin/tests/lua_harness.cpp -o "$OUT/lua_harness" "$LUA_SO"
"$OUT/lua_harness" plugin/tests/lua/test_unit.lua | tail -1

echo "### 4/4 two-process end-to-end (real entry script, real UDP)"
plugin/tests/run_e2e.sh "$OUT/lua_harness" | tail -1
