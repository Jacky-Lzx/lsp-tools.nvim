#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export LSP_TOOLS_ROOT="$root"
export LSP_TOOLS_TUI=1
export SNACKS_DIR="${SNACKS_DIR:-$HOME/.local/share/nvim/lazy/snacks.nvim}"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
export NVIM_LOG_FILE="$test_tmp/nvim.log"
nvim -u NONE -i NONE -c 'lua dofile(vim.env.LSP_TOOLS_ROOT .. "/tests/integration.lua")'
