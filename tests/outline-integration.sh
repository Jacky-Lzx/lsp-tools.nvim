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
export LSP_TOOLS_OUTLINE_SERVER="${2:-lua}"
test_file=outline_integration.lua
if [ "$LSP_TOOLS_OUTLINE_SERVER" = beamer ]; then
  test_file=outline_beamer.lua
fi
export LSP_TOOLS_OUTLINE_TEST="$root/tests/$test_file"
if [ "${1:-}" = tui ]; then
  export LSP_TOOLS_TUI=1
  nvim -u NONE -i NONE -c 'lua dofile(vim.env.LSP_TOOLS_OUTLINE_TEST)'
else
  nvim --headless -u NONE -i NONE -l "$LSP_TOOLS_OUTLINE_TEST"
fi
