#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export LSP_TOOLS_ROOT="$root"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT HUP INT TERM
export XDG_STATE_HOME="$test_tmp/state"
export XDG_CACHE_HOME="$test_tmp/cache"
export NVIM_LOG_FILE="$test_tmp/nvim.log"
nvim --headless -u NONE -i NONE -l "$root/tests/unit.lua"
nvim --headless -u NONE -i NONE -l "$root/tests/render.lua"
nvim --headless -u NONE -i NONE -l "$root/tests/paths.lua"
nvim --headless -u NONE -i NONE -l "$root/tests/public.lua"
nvim --headless -u NONE -i NONE -l "$root/tests/references.lua"
nvim --headless -u NONE -i NONE -l "$root/tests/workspace_edit.lua"
nvim --headless -u NONE -i NONE -l "$root/tests/rename.lua"
