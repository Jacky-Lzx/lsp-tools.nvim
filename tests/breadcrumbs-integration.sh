#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export LSP_TOOLS_ROOT="$root"
export LUALINE_DIR="${LUALINE_DIR:-$HOME/.local/share/nvim/lazy/lualine.nvim}"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
export LSP_TOOLS_TEST_TMP="$test_tmp"
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
export NVIM_LOG_FILE="$test_tmp/nvim.log"
if [ "${1:-}" = tui ]; then
  export LSP_TOOLS_TUI=1
  nvim -u NONE -i NONE -c 'lua dofile(vim.env.LSP_TOOLS_ROOT .. "/tests/breadcrumbs_integration.lua")'
else
  nvim --headless -u NONE -i NONE -l "$root/tests/breadcrumbs_integration.lua"
fi
