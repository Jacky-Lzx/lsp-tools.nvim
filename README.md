# lsp-tools.nvim

Selection-tools action/rename lists use the shared text component style. Location, symbol and diagnostic pickers retain their specialized grep layout and source highlighting; explicit picker components can replace that layout.

Native LSP workflows with previews, persistent results and inspection.

![Grouped diagnostics with a syntax-highlighted source preview, severity title, and precise target range](assets/screenshots/diagnostics.png)

## Features

- Preview code actions and renames before applying edits.
- Navigate references, symbols, diagnostics and persistent result lists.
- Inspect server configuration, capabilities and request lifecycle.

## Requirements

Neovim **0.12+**. Install your language servers separately. Preview workflows use selection-tools.nvim and git-tools.nvim. nvim-lspconfig optionally supplies server definitions.

## Installation

With lazy.nvim:

```lua
{
  "Jacky-Lzx/lsp-tools.nvim",
  main = "lsp-tools",
  dependencies = {
    "neovim/nvim-lspconfig",
    "Jacky-Lzx/selection-tools.nvim",
    "Jacky-Lzx/git-tools.nvim",
  },
  opts = {
    servers = { lua_ls = true },
    server_activation = "filetype",
    server_filetypes = { lua_ls = { "lua" } },
    inspect = true,
  },
}
```

Or put this repository and its required dependencies on `runtimepath`, then call:

```lua
require("lsp-tools").setup({
  servers = { lua_ls = true },
  server_activation = "filetype",
  server_filetypes = { lua_ls = { "lua" } },
  inspect = true,
})
```

The example selects `lua_ls` from nvim-lspconfig. Install `lua-language-server`
separately; choose server names and options for your own languages.

## Usage

```vim
:LspToolsInfo
:LspToolsOutline
```

## Documentation

- [Complete reference](doc/lsp-tools.txt) — `:help lsp-tools`.
- [Workflow and integration guide](doc/guide.md).
- [More screenshots](doc/gallery.md).
- Diagnose availability with `:checkhealth lsp-tools`.

## Development

Run from the repository root:

```sh
python3 tests/run.py unit --filter docs
python3 tests/run.py default
```

See [the test workflow](tests/README.md) for dependencies, optional suites and
retained failure evidence. Local development overrides belong in your package
manager configuration; public installation uses the repository above.
