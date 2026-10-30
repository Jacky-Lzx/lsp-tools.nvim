#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export LSP_TOOLS_ROOT="$root"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
export LSP_TOOLS_TEST_TMP="$test_tmp"
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
export NVIM_LOG_FILE="$test_tmp/nvim.log"
for name in linked_editing diagnostics hover links workflows; do
  nvim --headless -u NONE -i NONE -l "$root/tests/${name}_integration.lua"
done
python3 "$root/tests/terminal.py" hover_integration.lua
python3 "$root/tests/terminal.py" workflows_integration.lua
