# lsp-tools.nvim

Practical LSP tools for Neovim: symbol breadcrumbs, a symbol outline, rename previews, semantic reference navigation,
and code actions with asynchronous resolution and optional delta rendering.
Includes the code-actions.nvim implementation.

Install this plugin in place of code-actions.nvim. It contains the implementation
and does not load or depend on that plugin. See [TODO.md](TODO.md) for the roadmap.

## Requirements

- Neovim 0.12 (tested with 0.12.6)
- [snacks.nvim](https://github.com/folke/snacks.nvim), with picker enabled, for code actions and rename previews
- An attached language server supporting the enabled tool's LSP methods

No plenary or external diff executable is required. Delta is optional.
Reference navigation, breadcrumbs, and the outline require no Snacks: use `setup({ code_actions = false, rename = false })`.

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
      "<leader>go",
      function() require("lsp-tools").toggle_outline() end,
      desc = "[LSP] Toggle outline",
    },
    {
      "<leader>rn",
      function() require("lsp-tools").rename() end,
      mode = "n",
      desc = "[LSP] Rename with preview",
    },
    {
      "]r",
      function() require("lsp-tools").jump_reference(vim.v.count1) end,
      mode = "n",
      desc = "[LSP] Next reference",
    },
    {
      "[r",
      function() require("lsp-tools").jump_reference(-vim.v.count1) end,
      mode = "n",
      desc = "[LSP] Previous reference",
    },
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

`setup()` enables all tools by default. Set `code_actions = false` (or
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

## Reference navigation

`require("lsp-tools").jump_reference(count, opts)` moves forward for a positive
count and backward for a negative count, within the current file. It uses
`textDocument/documentHighlight`, so it follows the language server's understanding
of the symbol. It does not perform text search or query workspace references.
Read/write classification is displayed when the server supplies highlight kinds.

```lua
require("lsp-tools").setup({
  references = {
    debounce = 200, -- automatic highlighting after cursor movement, milliseconds
    request_timeout = 1500,
    wrap = false, -- stop at the ends by default
    jumplist = true, -- Ctrl-O returns to the jump origin
    foldopen = true,
    notify_end = true,
  },
})
-- Override wrapping for one operation:
require("lsp-tools").jump_reference(1, { wrap = true })
```

Recommended mappings are Normal-mode `]r` / `[r` (reference), with counts such as
`3]r`. They leave native `]]` / `[[` section navigation available, including shell
prompt navigation in terminal buffers. No mappings are installed automatically.
Terminal input mode has no reference mapping. The feature only operates in normal
file buffers, with automatic highlights in Normal, Insert, and command-line modes.

An explicit jump requests highlights immediately, including before the automatic
debounce expires. Repeated keys during a request accumulate their counts. Results
are sorted and deduplicated across clients using each client's position encoding.
The source window, cursor, and buffer version must still match before a pending
jump is applied. Moving outside the current symbol, editing, switching windows,
detaching a client, or disabling the tool cancels obsolete work. Slow clients time
out; completed clients' results remain usable. Highlights use an owned namespace
and native `LspReferenceText`, `LspReferenceRead`, and `LspReferenceWrite` groups.

Set `references = false` (or `{ enabled = false }`) to disable the tool and clear
its highlights. When migrating from Snacks.words, disable it with
`words = { enabled = false }` in Snacks, and remove its old jump mappings so only
one component owns highlighting and navigation. Workspace-wide reference pickers
such as Snacks' LSP references picker can continue to be used separately.

## Rename preview

`require("lsp-tools").rename()` prepares the symbol at the current cursor position,
prefills its name through your existing `vim.ui.input` provider, and requests one
rename after you enter the new name. A Snacks picker then lists affected files,
their edit counts, and their diffs. Select a file to inspect it. The title reports
totals and states that Enter applies **all** listed changes; Escape cancels.
Reviewing a different file does not restrict the edit to that file. Text edits
remain unsaved buffers, as with native LSP rename.

```lua
require("lsp-tools").setup({
  rename = {
    request_timeout = 3000, -- per prepare/rename request, milliseconds
    backend = "vim", -- or "delta", using the same renderer as code actions
    delta = {
      command = "delta",
      args = { "--file-style=omit", "--hunk-header-style=file line-number syntax" },
      timeout = 2000,
    },
    picker = { layout = { preset = "default" } },
  },
})

require("lsp-tools").rename("new_name") -- still previews before applying
require("lsp-tools").rename(nil, { name = "lua_ls" }) -- optional client name
require("lsp-tools").rename(nil, { filter = function(client) return client.name ~= "other" end })
require("lsp-tools").cancel_rename()
```

Servers must support `textDocument/rename`; `prepareRename` is used when supported.
A null preparation result or server error stops the operation. Servers without
preparation use the cursor word as the input default. When multiple matching
servers are attached, choose one through `vim.ui.select`; edits from different
servers are never combined. Native `vim.lsp.buf.rename()` remains available.
The optional `bufnr` must identify the current file buffer.

The source position is captured before requests. Late replies after moving the
source cursor, changing its text, cancelling, starting another rename, or
disconnecting are discarded. Affected loaded buffers are checked against the
request baseline. Before application, every affected buffer and disk snapshot is
checked again, including versioned entries after the first `documentChanges`
item. Stale previews stay open for inspection but refuse to apply; request rename
again to refresh them. Loading a previously unopened file is allowed if its text
still matches the snapshot. Preview scratch buffers never modify real files.

Change annotation labels/descriptions appear in the corresponding file preview;
Enter approves all of them together. Annotated text edits are then applied without
repeated native per-file prompts. Ordered create/rename/delete operations are
shown as summaries and are only executed after confirmation. As with code actions,
resource previews do not simulate filesystem permissions or all operation options.
Application uses Neovim's workspace edit implementation and is not a filesystem
transaction: a failure during application can leave earlier operations applied.
Unversioned unopened files are first snapshotted when the response arrives; changes
before that snapshot cannot be detected reliably.

Set `rename = false` (or `{ enabled = false }`) to disable the tool. Disabling or
calling `cancel_rename()` cancels pending requests, closes the rename preview,
and invalidates input callbacks. An already open name input remains owned by your
UI provider. No key mappings are installed by the plugin; `<leader>rn` is the
recommended example and can be configured buffer-locally on LSP attachment.

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
./tests/references-integration.sh # requires lua-language-server (or LUA_LS=/path/to/server)
./tests/references-integration.sh tui # real terminal keys and Ctrl-O
./tests/rename-integration.sh # deterministic real LSP client/server and Snacks
LSP_TOOLS_BACKEND=delta ./tests/rename-integration.sh tui # actual input, Enter/Escape
LSP_TOOLS_REAL_LSP=1 ./tests/rename-integration.sh # real LuaLS semantic rename
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

Reference unit tests cover immediate requests, counted jumps, boundaries/wrapping,
Unicode encodings, multi-client deduplication, kinds, cancellation, timeout, stale
responses, and owned-highlight cleanup. Reference integration tests use real LuaLS
to verify that an inner variable with the same name is excluded from the outer
symbol's locations. They also cover preceding emoji, counts, backward navigation,
and jump origins without loading Snacks.

Rename tests cover preparation shapes, input cancellation, timeouts, multiple
clients, stale results, entire-edit application, and disabling. Workspace snapshot
tests cover Unicode, unsaved files, file aliases, loading new buffers, external
disk writes, document versions, annotations, and ordered resource operations.
Integration checks include two-file rename review/apply/cancel, annotation previews,
stale second-file refusal, and real LuaLS renaming that preserves a shadowed local.

## Current-location breadcrumbs

Display the enclosing LSP symbol path at the top of the editor, for example
`impl Circuit for State › next`. The component uses the server's full symbol
ranges to find the scope under each window's cursor. It does not require Trouble,
nvim-navic, Snacks, Tree-sitter, or an open outline.

For lualine, keep its existing filename and LSP-status components and replace the
Trouble symbols function in `winbar.lualine_b` with:

```lua
table.insert(opts.winbar.lualine_b, 1, {
  function()
    return require("lsp-tools").breadcrumbs()
  end,
})
```

Call `require("lsp-tools").setup()` from the plugin's configuration as usual.
The function returns `""` before setup, when disabled, outside symbol scopes,
in special/floating windows, or when no eligible symbol provider is attached.
It can safely be used when lualine loads before this plugin. Remove the previous
`require("trouble").statusline({ mode = "lsp_document_symbols", ... })` component
to avoid showing the same location twice. Lualine continues to own the winbar;
the default breadcrumbs configuration never changes the window's `winbar` option.

Without lualine, enable the native winbar:

```lua
require("lsp-tools").setup({
  breadcrumbs = {
    winbar = true,       -- default false; install only in windows with an empty winbar
    separator = " › ",
    debounce = 200,      -- milliseconds after document edits
    request_timeout = 3000,
    mode = "all",       -- "all" (default), "auto", or "sections"
    -- client_name = "rust_analyzer",
    -- client_filter = function(client, bufnr) return true end,
    icons = {
      Method = { icon = "󰆧", hl = "Function" },
    },
  },
})
```

The native winbar displays only the symbol path. Existing winbars are preserved.
Disabling or repeating setup restores windows still owned by this module and
leaves newer winbar providers untouched. For a custom native winbar expression,
use `%{%v:lua.require'lsp-tools'.breadcrumbs()%}`.

`breadcrumbs({ winid = win, color = false, icons = false })` optionally selects
a window or omits colors/icons. The result is escaped **statusline text** (literal
`%` becomes `%%`), suitable for lualine or a native expression that re-evaluates
statusline formatting. `require("lsp-tools.breadcrumbs").get(winid)` returns a
fresh outer-to-inner array of `{ name, kind }` entries for custom rendering.
The evaluated statusline's `g:statusline_winid` is honored when no window is given.

Breadcrumbs share the outline's built-in icons, semantic highlights, position
conversion, and hierarchy rules. Each module's icon overrides are independent.
The default `all` mode includes every enclosing symbol; `auto` shows only heading
scopes in TeX buffers, and `sections` applies that filter explicitly. Flat
`SymbolInformation` results do not gain invented parents from `containerName`.

One document cache is shared by all windows showing the same buffer. Cursor
movement reads that cache without making requests; edits clear the old path and
refresh after a debounce. Hidden documents drop their cache and cancel pending
requests. Provider selection retains the previous eligible client, falling back
to the lowest client ID. Edits, URI changes, detach, timeout, and disable reject
obsolete replies. Errors and unsupported providers leave the component empty.
The outline and breadcrumbs request their own symbol snapshots independently.
Set `breadcrumbs = false` (or `{ enabled = false }`) to disable this module.

Run `tests/run.sh` for cache, range, cancellation, escaping, and window-ownership
coverage. `tests/breadcrumbs-integration.sh [headless|tui]` verifies real LuaLS,
the native winbar, the installed lualine implementation, split cursors, and edits.
LuaLS must be on `PATH`; set `LUALINE_DIR` if lualine is installed outside
`~/.local/share/nvim/lazy/lualine.nvim`.

## Symbol outline

The outline uses one attached LSP provider's `textDocument/documentSymbol` results
and renders a normal right-hand split. It requires neither Snacks nor Tree-sitter.
The server supplies symbol names, kinds, scopes, hierarchy, and jump positions.
Hierarchical `DocumentSymbol` results retain their tree; `SymbolInformation`
results remain flat because `containerName` does not define reliable nesting.
Servers without this method show an explanatory status; there is no Tree-sitter
fallback in this version.

```lua
require("lsp-tools").setup({
  outline = {
    width = 0.25,         -- fraction of screen columns; >= 1 means columns
    min_width = 20,
    max_width = 60,
    focus_on_open = false,
    follow_cursor = true,
    debounce = 200,       -- milliseconds after source edits
    request_timeout = 3000,
    mode = "auto",       -- "auto", "all", or "sections"
    -- client_name = "texquill", -- optional provider preference/filter
    -- client_filter = function(client, bufnr) return true end,
    icons = {            -- optional overrides of the built-in symbol icons
      Key = { icon = "󰌆", hl = "Type" },
      Event = { icon = "󱐋", hl = "Type" },
    },
  },
})
```

`auto` initially shows sections for `tex` buffers and all symbols for other file
types. Section filtering recognizes LaTeX heading commands in the server's
`detail` field, with Namespace symbols as a fallback when detail is absent.
TeXquill supplies the heading hierarchy directly. Press `m` to include labels,
macros, environments, and other symbols returned by the server. Filtered-out
parents do not hide matching descendants.

All standard LSP symbol kinds have built-in icons. Icons and symbol names use the
kind's semantic highlight group from the active colorscheme; fold markers and
details use `Comment`. A configured `hl` override applies to both icon and name.
Use a Nerd Font in your terminal to display the icons. For example, LaTeX headings
reported as Namespace use `󰅪`. `icons` merges with the defaults: override individual
kinds with `{ icon = "…", hl = "Type" }` or a plain icon string without replacing
the remaining defaults. Unknown symbol kinds retain a letter fallback.

Public API: `toggle_outline()`, `open_outline({ focus = true })`, and
`close_outline()`. Calling `open_outline()` on an existing sidebar focuses it;
pass `{ focus = false }` to keep the current focus. Setup registers
`:LspToolsOutline`, `:LspToolsOutlineOpen`, and `:LspToolsOutlineClose`.
For lazy.nvim, add these names to `cmd`, or use the key callback above.
Set `outline = false` to disable the module. No global key mappings are installed.

Inside the sidebar:

| Key | Action |
| --- | --- |
| `Enter` | Jump to the symbol's selection range in the source window |
| `Tab`, `za` | Toggle the selected subtree |
| `h`, `zc` | Collapse, or move to the visible parent |
| `l`, `zo` | Expand, or move to the first child |
| `zM`, `zR` | Collapse / expand all |
| `m` | Toggle sections / all symbols |
| `r` | Refresh from the language server |
| `q`, `Esc` | Close and return to the source |

Each tab owns a sidebar that follows its last active source window. Source edits
refresh symbols after a debounce; cursor movement only updates the enclosing
symbol highlight (`LspToolsOutlineCurrent`, default link `Visual`). Navigation
opens source folds and records the jump origin. Folding and display mode survive
refreshes and source switches while the sidebar is open. Duplicate sibling names
use occurrence-based identities; inserting another identical sibling can move a
saved fold to that occurrence. Refreshes preserve the sidebar selection while it
has focus. A folded ancestor represents a hidden current symbol.

When several clients provide symbols, the previous provider is retained if still
available; otherwise the lowest eligible client ID is selected. Trees from
different providers are not merged. Requests are canceled on edits, source
switches, close, and timeout; late results are checked against buffer identity,
URI, changedtick, and the attached client. Stale positions cannot be used to jump.

Run `tests/run.sh` for model/UI race coverage and
`tests/outline-integration.sh [headless|tui] [lua|texquill]` for real LuaLS or
TeXquill hierarchy, filtering, editing, key, and focus checks. The chosen server
must be installed on `PATH`.
