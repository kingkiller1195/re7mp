#!/usr/bin/env bash
# Usage: run_e2e.sh <path-to-lua_harness>   (run from the repo root)
set -u
H="${1:-/tmp/lua_harness}"
PORT=$((20000 + RANDOM % 20000))
"$H" plugin/tests/lua/test_e2e.lua host $PORT > /tmp/e2e_host.log 2>&1 &
HP=$!
sleep 0.4
"$H" plugin/tests/lua/test_e2e.lua client $PORT > /tmp/e2e_client.log 2>&1
CR=$?
wait $HP
HR=$?
echo "=== host (exit $HR) ==="; cat /tmp/e2e_host.log
echo "=== client (exit $CR) ==="; cat /tmp/e2e_client.log
[ $HR -eq 0 ] && [ $CR -eq 0 ] && echo "E2E PASSED" || { echo "E2E FAILED"; exit 1; }
