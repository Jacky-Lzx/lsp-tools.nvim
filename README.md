# lsp-tools.nvim

Practical LSP tools for Neovim. The first implemented tool integrates all
code-actions.nvim functionality: a Snacks picker with asynchronous code action
resolution, workspace-edit previews, and optional delta rendering.

Install this plugin in place of code-actions.nvim. It contains the implementation
and does not load or depend on that plugin. See [TODO.md](TODO.md) for the roadmap.

## Requirements

- Neovim 0.12 (tested with 0.12.6)
- [snacks.nvim](https://github.com/folke/snacks.nvim), with picker enabled
- An attached language server supporting code actions

No plenary or external diff executable is required. Delta is optional.

## Installation

Local installation with lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/Documents/Github/nvim_plugins/lsp-tools.nvim"),
  name = "lsp-tools.nvim",
  dependencies = { "folke/snacks.nvim" },
  event = "LspAttach",
  opts = {
    code_actions = {
      backend = "delta", -- optional; defaults to the native diff renderer
      delta = {
        args = { "--file-style=omit", "--hunk-header-style=file line-number syntax" },
      },
    },
  },
  config = function(_, opts)
    require("lsp-tools").setup(opts)
  end,
  keys = {
    {
      "<leader>a",
      function() require("lsp-tools").code_action() end,
      mode = { "n", "x" },
      desc = "[LSP] Code action",
    },
    {
      "<A-a>",
      function() require("lsp-tools").code_action() end,
      mode = "i",
      desc = "[LSP] Code action",
    },
  },
}
```

For migration, remove the old code-actions.nvim plugin specification, replace
`require("code_actions")` calls with `require("lsp-tools")`, and move its previous
setup options under `opts.code_actions`. Keep Snacks installed. This repository
is usable as a local plugin; no remote publication is required.

After setup, native `vim.lsp.buf.code_action()` and the default `gra` mapping also
use the preview picker. Confirm with Enter, cancel with Escape. These keys are
configured on picker input and list windows. No editor key mappings are installed
by this plugin. Ordinary `vim.ui.select` requests use your existing provider.

## Configuration

```lua
require("lsp-tools").setup({
  code_actions = {
    enabled = true,
    resolve_timeout = 3000, -- milliseconds; no synchronous waits
    backend = "vim", -- "vim" (default) or "delta"
    delta = {
      command = "delta", -- executable name or absolute path
      args = {}, -- e.g. { "--line-numbers", "--side-by-side" }
      timeout = 2000, -- milliseconds
    },
    picker = { layout = { preset = "default" } },
  },
})
```

`setup()` enables code actions by default. Set `code_actions = false` (or
`{ enabled = false }`) to disable the tool, close its open pickers, and cancel
pending requests. Disabling restores the previous select provider when the
adapter still owns it, and preserves providers installed by other plugins.
Repeated setup is supported; supplied code action options merge with previous
options. Requiring the plugin alone registers no behavior and loads no Snacks UI.

`require("lsp-tools").code_action(opts)` forwards native code action options such
as `context`, `filter`, `range`, and `apply` to `vim.lsp.buf.code_action()`.

`picker` customizes Snacks appearance. Item collection, preview, confirmation,
and close callbacks are owned by this plugin.

Set `backend = "delta"` to format diffs with the optional
[delta](https://dandavison.github.io/delta/) executable. Its ANSI colors are rendered
in the Snacks preview buffer. Delta runs asynchronously with the preview window's
width, dark/light mode, true color, and paging disabled. Extra arguments are passed
directly as an argument list, never through a shell; delta can read your normal
Git configuration. Missing delta, startup errors, unsuccessful exits, empty output,
and timeouts fall back to the native diff. Command-only actions and resource-only
summaries use the native text preview. Changing selection or closing the picker
cancels any pending delta process and ignores late output.

To hide the repeated top file section while keeping a project-relative path and
line number in each hunk header:

```lua
require("lsp-tools").setup({
  code_actions = {
    backend = "delta",
    delta = {
      args = { "--file-style=omit", "--hunk-header-style=file line-number syntax" },
    },
  },
})
```

## Behavior and limits

- Previews use loaded buffer contents, including unsaved edits, before disk.
- File labels are relative to the source buffer's Git root, otherwise its LSP
  workspace/root directory, otherwise Neovim's cwd when the picker opens. Files
  outside that root keep absolute paths; non-file URIs remain unchanged. Only
  display labels change, not the URIs used for applying edits.
- UTF-8/UTF-16/UTF-32 edits use the server's position encoding via Neovim.
- `changes` and ordered `documentChanges` support multiple files. File resource
  operations appear as summaries; the preview never creates, renames or deletes
  real files. Operation options/annotations are applied by Neovim on confirmation,
  but preview summaries are not a simulation of filesystem permissions/options.
- Command-only actions remain executable but have no text diff. Commands attached
  to text edits may have extra effects that cannot be previewed.
- Resolve errors/timeouts keep the picker open when no executable edit/command
  was provided. Otherwise the original action remains executable, as in native
  code actions. Closing cancels pending requests;
  late responses cannot replace the currently selected item's preview.
- Confirmation refuses actions if the original buffer changed while the picker
  was open. Cross-file previews are snapshots, not a transactional edit guarantee.
- This adapter recognizes Neovim's internal `{ action, ctx }` selection items.
  If the shape changes, it delegates to the existing picker without a preview.
  Check compatibility after upgrading Neovim. LSP apply/command behavior uses
  public APIs; cached resolved actions deliberately avoid resolving twice.

## Tests

```sh
./tests/run.sh
SNACKS_DIR=~/.local/share/nvim/lazy/snacks.nvim ./tests/integration.sh
./tests/tui.sh # run from a terminal; exercises actual mapped keys and focus
```

Unit tests cover preview isolation, Unicode edits, unsaved/multiple files,
resource-operation order, late responses, resolve caching, failure/timeout,
confirmation, cancellation, fallback selection, and setup lifecycle.
Integration tests start a real Neovim LSP client against a local fixture server
and open an actual Snacks picker. No network or language server installation is
required. The fixture is a protocol test, not a compatibility claim for every
language server.

Public API tests verify lazy loading, option forwarding, repeated setup, disabling,
and select-provider ownership without loading code-actions.nvim. The TUI test
opens real terminal Neovim, triggers Normal/Visual mappings through key input,
confirms with Enter, cancels with Escape, and checks source-buffer focus recovery.

Renderer tests cover native output, literal delta arguments, ANSI output,
cancellation and fallback. Integration tests additionally exercise a missing
executable and a timed-out process. If delta is installed, they test its real ANSI
output, switching between delta and command-only previews, and failure fallback.
