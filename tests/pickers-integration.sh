#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export SELECTION_TOOLS_DIR="${SELECTION_TOOLS_DIR:-$root/../selection-tools.nvim}"
export GIT_TOOLS_DIR="${GIT_TOOLS_DIR:-$root/../git-tools.nvim}"
python3 "$root/tests/terminal.py" pickers_integration.lua
