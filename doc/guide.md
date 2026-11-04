# Configuration and workflow guide

[Back to the README](../README.md)

Detailed options, behavior, mappings and validation for lsp-tools.nvim.
Shell commands below run from the repository root. For installation and a working
starter configuration, see [Quick start](../README.md#quick-start).

## Migrating from code-actions.nvim

Remove the old code-actions.nvim specification, replace `require("code_actions")`
with `require("lsp-tools")`, and move its setup options under `code_actions`.
lsp-tools includes that implementation; it does not load or depend on the old
plugin. Install selection-tools.nvim and the local git-tools.nvim checkout for code-action
and rename previews.

After setup, native `vim.lsp.buf.code_action()` and the default `gra` mapping use
the preview picker. Confirm with Enter, cancel with Escape. These bindings apply
to the picker input and list; lsp-tools installs no global editor mappings.
Ordinary `vim.ui.select` requests keep using your existing provider.

## Health checks

Run `:checkhealth lsp-tools` from a source buffer to inspect the Neovim version,
enabled/deferred tools, selected server configs and missing server commands,
selection-tools, git-tools, optional delta, preview parsers and syntax
fallbacks, attached LSP providers, and lualine winbar ownership. This does not open
tools or modify source buffers. Missing capabilities depend on the attached server.
Other winbar providers must preserve the `lsp-tools-results` filetype.

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
    picker = { layout = { width = 0.85, height = 0.8, preview_height = 0.7 } },
  },
})
```

`setup()` enables code actions, references, rename, outline and breadcrumbs by default.
The newer optional tools below are enabled explicitly. Set `code_actions = false` (or
`{ enabled = false }`) to disable the tool, close its open pickers, and cancel
pending requests. Disabling restores the previous select provider when the
adapter still owns it, and preserves providers installed by other plugins.
Repeated setup is supported; supplied code action options merge with previous
options. Requiring the plugin alone registers no behavior and loads no picker UI.

Interactive tools (rename, outline, diagnostic details, pinned documentation,
links, inspection and hierarchies) retain their settings at setup and initialize
on first use. Their public entries and outline commands respect explicit disable.
The native code-action selection adapter and inspection recorder stay lightweight;
picker/preview code loads only when needed, and inspection retains request events
recorded before its first opening. Deferred options are validated during setup.
Rename/link cancellation listeners exist only while an operation is pending.
Outline listeners are installed for the first sidebar and removed when the last
sidebar closes, including sidebars in other tabs.
Automatic reference highlights, breadcrumbs, lightbulb and linked editing load
when a visible buffer has a provider for their method. A lightweight capability
check also handles capabilities registered after attachment. Unsupported buffers
do not allocate lightbulb/breadcrumb update timers; hidden buffers are initialized
when displayed. Automatic bootstrap listeners are released once every enabled
engine has initialized. None of these checks opens a UI.

`require("lsp-tools").code_action(opts)` forwards native code action options such
as `context`, `filter`, `range`, and `apply` to `vim.lsp.buf.code_action()`.

`picker` accepts selection-tools picker options, such as `layout.width`,
`layout.height`, `layout.preview_height`, `layout.input_position` and
`layout.reverse`. Previous Snacks `preset`, `win` and nested layout trees must be
replaced with selection-tools options. Item collection, LSP resolution, validation
and application stay with lsp-tools; selection-tools owns windows and preview
frames. git-tools owns unified diff generation and native/delta rendering, using
a host view contract rather than importing selection-tools. The optional
`git_tools.integrations.selection.diff(opts)` provider can be registered by callers.
The previous `selection_tools.providers.diff` module has moved to git-tools.
Rename and code-action pickers use `resume = false` and cannot resume stale edits.

Set `backend = "delta"` to format diffs with the optional
[delta](https://dandavison.github.io/delta/) executable. Its ANSI colors are rendered
in an owned selection-tools preview buffer. Delta runs asynchronously with the preview window's
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

## Server configuration and lifecycle

The optional `servers` map selects native Neovim LSP configurations. Install
`neovim/nvim-lspconfig` and load it before lsp-tools setup to use its maintained
`lsp/*.lua` configs. lsp-tools does not copy those configs or call the deprecated
`require("lspconfig").SERVER.setup()` framework. Native configs from your own
runtimepath work as well; no nvim-lspconfig dependency is required for custom configs.
Language server executables must be installed separately (for example with your
package manager or Mason).

```lua
require("lsp-tools").setup({
  servers = {
    lua_ls = {
      settings = {
        Lua = {
          runtime = { version = "LuaJIT" },
          diagnostics = { globals = { "vim" } },
          workspace = { library = { vim.env.VIMRUNTIME } },
        },
      },
    },
    clangd = true,
    custom_server = {
      cmd = { "/path/to/server", "--stdio" },
      filetypes = { "custom" },
      root_markers = { { ".custom-root", "custom.json" }, ".git" },
      workspace_required = true,
    },
  },
})
```

- `true` enables an existing native config. A table applies native overrides and
  enables the config. Unknown names require a custom `cmd` or an existing native config;
  missing configs fail setup with an actionable error.
- `false` stops that server only if lsp-tools enabled it, and releases its management.
  `servers = false` does this for every selected server. Native config overrides remain
  registered, so enabling again retains them. A server already enabled elsewhere is
  recorded as external and stays enabled when lsp-tools management is disabled.
- Omitted server names and an omitted `servers` option leave server state unchanged.
  An empty map is a no-op. Servers are never enabled just because their configs exist.

Load the plugin before LSP startup (`lazy = false` in lazy.nvim). `LspAttach` cannot
bootstrap server management because an LSP must already be running to emit that event.
Interactive tools still load on demand. If lsp-tools manages servers, remove other
startup paths for the same names, including legacy lspconfig setup and Mason automatic
enablement. Native activation has no ownership reference count: lsp-tools tracks which
names it enabled, but cannot detect another plugin taking ownership later.

Overrides use `vim.lsp.config(name, opts)`; activation uses `vim.lsp.enable(name)`.
Neovim keeps the merge order: global `'*'` defaults, runtimepath `lsp/*.lua`,
`after/lsp/*.lua`, then explicit per-server overrides. Dictionary fields merge; lists
and functions replace earlier values. In particular, overriding `on_init` or
`on_attach` can replace upstream hooks. Prefer `LspAttach` autocommands for common
buffer behavior. Configure shared capabilities explicitly with
`vim.lsp.config("*", { capabilities = ... })`; lsp-tools never changes global defaults.

Repeated setup merges native overrides and does not restart or re-enable an already
enabled config. Changes apply to future clients; use `:lsp restart <name>` to apply
them to running clients. `:lsp enable <name>` and `:lsp disable <name>` also remain
available. Root selection, single-file support (`workspace_required`), dynamic
`root_dir(bufnr, on_dir)`, workspace isolation and client reuse follow Neovim's rules.
Server names, entry types and core config fields are validated alongside UI options
before lsp-tools changes tool state or registers overrides. Server-specific extension
fields pass through to Neovim. Config resolution evaluates selected runtimepath config
files using Neovim's loader.

Inspect selected servers without opening a view:

```lua
local servers = require("lsp-tools").server_status() -- optional source buffer number
vim.print(servers)
```

The sorted snapshots include `name`, `requested`, native `enabled`, `managed`,
`configured`, `cmd`, `executable` (only for command lists), `filetypes`,
`matches_filetype`, `root`, `root_markers`, `dynamic_root`, `workspace_required`,
and `clients` (IDs, initialization, attachment to this buffer, and roots).
`configuration().servers` returns an isolated copy of supplied entries; use
`server_status()` for effective native configuration and current runtime state.
Health checks and the optional `inspect = true` view also show selected configs
that have no attached client. Status checks do not run command functions or dynamic
root callbacks. An enabled but unattached config is reported without guessing why
a server declined the buffer; check its root policy and native LSP log.

## Panel action mappings

All owned side panels share action-based mappings. Configure the common prefix
under `ui`, and override individual actions globally or per tool:

```lua
require("lsp-tools").setup({
  ui = { key_prefix = "<LocalLeader>", keymaps = { help = "<prefix>?" } },
  results = { keymaps = { preview = "<prefix>v", sort = false } },
  hover = { keymaps = { follow = false, copy = { "<prefix>y", "<F6>" } } },
})
```

`false` disables an action; a string or list replaces all its default keys.
Settings apply when a panel is opened again. Common actions include `close`,
`help`, `refresh`, `return_source`, `copy`, `preview`, and `jump`. Results also
provide `jump_keep`, `auto_preview`, `filter`, `errors`, `sort`, `group`, `pin`,
`export`, `next`, `previous`, `details`, `fix`, `fix_next`, and `scope`. Hover adds
`follow`/`open_link`; hierarchies add `expand`/`collapse`/`direction`/`callsite`;
inspection adds `log`; outline adds `toggle_fold`, `collapse_all`, `expand_all`,
and `mode`. Letter actions use the prefix; native Vim motions remain available.
Panel help lists only its effective owned bindings. Literal result `actions` and
`keys` callbacks remain supported; named definitions accept `{ keys, action, desc }`.

## Optional code action indicator

Enable `lightbulb = true` to show `` at the end of the current line when a server
offers an enabled code action. This replaces nvim-lightbulb; disable/remove that
plugin so only one indicator queries the servers. New optional tools are opt-in.

```lua
require("lsp-tools").setup({
  lightbulb = { debounce = 200, request_timeout = 1500, text = "", sign = false },
})
```

The indicator uses asynchronous automatic-trigger requests with the requesting
client's diagnostics. It never resolves or applies actions. Cursor movement,
edits, window changes, Insert mode, detach, timeout and disable discard obsolete
results and clear only this tool's decoration. Set `sign = true` for a sign-column
indicator instead of virtual text. `hl` defaults to `DiagnosticHint`.

## Optional call and type hierarchies

Enable `hierarchy = true`, then use `require("lsp-tools").call_hierarchy()` or
`type_hierarchy()`. Call directions are `incoming` (default) and `outgoing`;
type directions are `supertypes` (default) and `subtypes`. Pass e.g.
`call_hierarchy({ direction = "outgoing", name = "clangd", focus = false })`.
Unsupported servers report the missing capability. Multiple providers prompt for
one client; opaque item data is preserved in subsequent requests.

The root expands once; further branches load only on Tab / `<LocalLeader>l`. `<LocalLeader>h` collapses,
`<LocalLeader>d` switches direction while preserving each tree's expansion cache, Enter jumps
to the symbol, `g` jumps to a concrete call site (choosing if several exist), `<LocalLeader>p`
previews source around that call site or type, `<LocalLeader>r` rebuilds from the source
window's current cursor, `<LocalLeader>b` returns to the origin, and `<LocalLeader>q` / Escape closes.
Recursive cycles are marked `↻` and cannot expand. Code buffers stay unchanged.

Setup options: `width = 0.35`, `request_timeout = 3000`, `max_nodes = 500`,
`max_depth = 20`. Limits bound expansion; timeout/errors remain visible and can be
retried. Source edits, changed captured target buffers/files, detach and close
reject obsolete work. This is a persistent lazy tree; ordinary Snacks pickers
remain usable separately. The integration suite verifies real clangd call trees,
previews and invocation jumps, and type hierarchies when advertised by clangd.

## Optional LSP inspection

Enable `inspect = true`, then call `require("lsp-tools").inspect()` for the current
buffer's actual clients, roots, workspace folders, position encodings, supported
methods and pending requests. It describes each tool's provider-selection policy.
Use `<LocalLeader>r` to refresh, `<LocalLeader>y` to copy the report, `<LocalLeader>l` to open the native LSP log, `<LocalLeader>b` to
return to the source, and `<LocalLeader>q` / Escape to close. `width` defaults to 0.5;
`inspect({ focus = false })` keeps source focus. The structured read API is
`require("lsp-tools.inspect").snapshot(bufnr)`.

Request metadata is bounded to 80 entries per recorder. Recent optional-tool
outcomes include response errors, timeout messages, empty results and durations;
native `LspRequest` events show lifecycle status since this module was enabled.
Native lifecycle completion does **not** prove a successful response: those events
do not expose response contents. Existing tools' response errors remain in the
native LSP log. No client handler is wrapped and no document text is recorded.

## Optional semantic links

Enable `links = true` and map `require("lsp-tools").open_link()` to query the
server's `documentLink` at the cursor. Unresolved links use `documentLink/resolve`
when supported. Different targets from multiple clients prompt through your
existing `vim.ui.select`; cancelling never opens a fallback. Duplicate targets
are shown once. Positions use each client's encoding and exclusive range ends.

```lua
require("lsp-tools").setup({
  links = {
    request_timeout = 3000,
    open = function(uri) vim.ui.open(uri) end,
    fallback = function() require("my-path-opener").open_at_cursor() end,
  },
})
```

`open` defaults to `vim.ui.open`. With no supported/resolved link (including
request failure/timeout), `fallback` runs once; the default opens `<cfile>` through
`vim.ui.open`. Override either callback per invocation with `open_link(opts)`.
No fallback runs for a stale source, cancelled selection or failed target opener.
Movement, edits, source/window changes, detach and disable discard obsolete work.
The plugin installs no `go` or Visual-mode mappings.

## Optional pinned documentation

Enable `hover = true`, then call `require("lsp-tools").hover()` to pin the source
position's hover documentation in a searchable, read-only Markdown side buffer.
Native `K` gets a bounded, padded documentation float with theme-aware colors.
Code fences stay hidden even after `KK` focuses the float; Markdown and injected
code highlighting start independently of legacy `:syntax` settings. `q` closes
the focused float, and moving the source cursor dismisses it as usual. Signature
help and other floating previews keep their existing rendering. Results from capable
clients are labeled and sorted by client ID; Unicode positions use each client's
encoding. No Snacks dependency is needed.

Inside the float, `j`/`k`, arrow keys, `Ctrl-N`/`Ctrl-P` and `gj`/`gk` skip hidden
fence rows. Counts and Visual selection count visible steps; screen-line motions
also retain their behavior on wrapped text. These mappings are local to the
hover buffer, and the original Markdown remains available for copying.

Configure the native float separately from the pinned panel:

```lua
require("lsp-tools").setup({
  hover = {
    float = { max_width = 80, max_height = 20, border = "rounded" },
  },
})
```

Use `hover = { float = false }` to keep the native float's original appearance
while retaining pinned documentation. Options supplied directly to
`vim.lsp.buf.hover(opts)` take precedence. No `K` mapping is installed.
Markdown/code highlighting uses available Tree-sitter parsers; fence hiding also
works without them. Other UI plugins that replace native hover rendering own
their presentation.

Keys inside the side window: `<LocalLeader>r` refreshes from the source window's current
position, `<LocalLeader>f` toggles debounced following, `<LocalLeader>y` copies the document (including
signatures) to the unnamed register, `gx` opens the URL at the cursor, `<LocalLeader>b` returns
to the captured source position, and `<LocalLeader>q` / Escape closes. Ordinary `/` searches
the Markdown buffer. The default is pinned: moving the source cursor keeps the
document unchanged. Use `hover({ focus = false, follow_cursor = true })` for a
following window. Setup options: `width = 0.4`, `debounce = 200`,
`request_timeout = 3000`, `follow_cursor = false`. Closing, hiding the requesting
source or detaching cancels pending requests; existing pinned content remains
readable when the source changes. Stale results cannot replace it.

## Searchable LSP and diagnostic pickers

Enable `pickers = true` to use selection-tools for navigation and search. This is
independent of `results` and `diagnostics`: their existing persistent panels stay
available through `locations()`, `diagnostics()` and `diagnostic()`.

```lua
local tools = require("lsp-tools")
tools.setup({
  pickers = {
    request_timeout = 3000,
    debounce = 100, -- workspace-symbol queries, in milliseconds
    jump_single = true,
    picker = {}, -- optional selection-tools layout/keys; inherits its global setup
  },
})
tools.lsp_definitions()
tools.lsp_declarations()
tools.lsp_references({ include_declaration = false })
tools.lsp_implementations()
tools.lsp_type_definitions()
tools.lsp_symbols()
tools.lsp_workspace_symbols({ query = "" })
tools.pick_diagnostics() -- all diagnostics already received, including linters
tools.pick_diagnostics({ scope = "buffer" })
tools.pick_diagnostics({ scope = "project", root = vim.fn.getcwd() })
```

Location queries use every attached provider that supports the method. Results
are deduplicated after converting each provider's UTF position encoding to byte
columns. LocationLinks use their target selection range. Current-cursor locations
are excluded unless `include_current = true`; a single remaining location jumps
directly unless `jump_single = false`. With this default, location requests keep
the source visible while waiting; only multiple results open a populated picker.
Empty results and request errors produce a notification. Moving away from the
query position cancels pending navigation. The returned pending handle supports
`:close()` and `closed`; its `picker` field is set if multiple results open a picker.
Native LSP jumps retain the jumplist and
tagstack. Unsupported methods, timeouts and failed providers are reported; valid
results from another provider remain available.

Picker rows put highlighted content on the left and muted, right-aligned
file locations and file icons on the right, matching selection-tools grep.
Symbols use their kind colors; diagnostics use their severity colors; location
results use full-source Tree-sitter highlights when available. Query matches
remain highlighted over these colors. Narrow layouts prioritize the content.

Document symbols include all kinds and preserve nesting as indentation;
SymbolInformation remains flat. Workspace symbols query the server as you type,
with debounce and cancellation of superseded queries. URI-only WorkspaceSymbols
resolve on confirmation when the provider supports `workspaceSymbol/resolve`.

Diagnostic pickers refresh on `DiagnosticChanged`. Optional `namespace`, `severity`
(native `vim.diagnostic.get` severity/range), and `filter` (result-model filters)
restrict the received diagnostics. Source previews include unsaved buffer text;
F2 shows the full diagnostic message or symbol details.

Enter jumps; the configured selection-tools split/vsplit/tab keys open the chosen
result in another destination. Quickfix and location-list export use selection-tools
keys and validate snapshots first; URI-only unresolved symbols support navigation
through confirmation, and cannot be exported before their location is resolved.
Changed sources/targets, removed diagnostics and detached providers cannot silently
jump to old coordinates. Escape, picker replacement and `setup({ pickers = false })`
cancel pending requests and remove picker listeners. These context-bound pickers
use `resume = false`. Requiring/configuring lsp-tools loads no picker UI, and no
Snacks dependency is needed for this workflow. lsp-tools installs no global mappings.

## Optional diagnostic workflow

Enable `diagnostics = true`, then call `require("lsp-tools").diagnostic()` to open
persistent details for the current buffer. `diagnostic({ filter = { severity =
vim.diagnostic.severity.ERROR }, focus = false })` limits the native diagnostic
query and optionally leaves focus in the source. Existing diagnostic signs,
virtual text, native floats, Trouble and Snacks lists remain independently usable.

The side window shows complete messages, sources, codes, documentation URLs and
related locations. Its buffer-local keys are `]d` / `[d` (counts supported), `<LocalLeader>a`
(preview a fix), `<LocalLeader>A` (preview a fix then continue), Enter (open a related location),
`<LocalLeader>b` (return to the diagnostic), `<LocalLeader>r` (refresh) and `<LocalLeader>q` / Escape (close).

Fixes request the selected diagnostic's range and client-specific diagnostic
context, then reuse the code-action resolve/diff/confirmation UI. Enable
`code_actions` for this workflow. Edits stay in unsaved buffers. `<LocalLeader>A` advances only
after a diagnostic update confirms fewer matching messages; moved diagnostics
alone do not count as fixed. It preserves the query filter and does not move the
cursor if the source window, cursor or text changed while waiting. A bounded wait
(`advance_timeout`, default 5000 ms) leaves manual navigation available when the
server has not confirmed a fix. `request_timeout` defaults to 3000 ms; `width`
defaults to 0.35. Closing or disabling cancels outstanding requests.

## Optional linked editing

Enable `linked_editing = true` to synchronize server-provided linked ranges (for
example HTML tags or LaTeX environment names). This replaces configuration-side
linked-editing adapters. It uses one capable client per buffer, ordered by client
ID, and disables native linked editing for that client/buffer to prevent duplicate
edits. To return to native behavior after disabling this tool, explicitly call
`vim.lsp.linked_editing_range.enable(true)`.

```lua
require("lsp-tools").setup({ linked_editing = { request_timeout = 1500 } })
```

Only non-overlapping, single-line ranges with identical text are synchronized.
Changes join the original undo block. Empty names remain editable during `ciw`.
Common repeated-character-class `wordPattern` expressions are supported, including
TeXquill's Unicode/star-friendly pattern. Unsupported ECMAScript expressions stop
the session with a warning; supply `validate = function(text, server_pattern)` for
a custom validator returning a boolean. A server without a pattern uses ASCII
letters, digits, underscores and hyphens. No local tag/environment parser is used.
Requests time out and stale cursor/buffer/window replies are discarded; leaving,
detaching or disabling clears owned ranges and cancels pending work.

## Optional persistent result lists

Enable `results = true`, then call `require("lsp-tools").results(items, opts)`.
An item accepts `id`, `bufnr`, `filename` or `uri`, `pos = { row, byte_column }`
(one-based row, zero-based UTF-8 byte column), `text`, `source`, `severity`, `code`
and optional source-specific `data`. Explicit IDs preserve selection across updates.

Options include `id`, `title`, `position = "bottom" | "right"`, `height`, `width`,
`focus = false`, `group_by = { "directory", "file" }`, `sort = "position" |
"severity" | "none"`, `filter`, `follow`, `auto_preview`, `max_items` (5000), and
`toggle`. Filters accept literal `text`, `bufnr`, `severity`, `source`, `code`,
`root`, or an item `predicate`. Open lists outlive their source buffers. Closing
releases preview windows, timers and source listeners; reopening restores filters,
folds, selection and snapshots. The module remains unloaded until first use.

Grouped results use Neovim's native expression folds for directory, file and LSP
sections. `za`, `zc`/`zo`, `zC`/`zO`, `zM`/`zR`, `zm`/`zr`, `zj`/`zk`, and
`zn`/`zN` are ordinary Vim commands, with no plugin mappings. All result lines stay
in the buffer. Native searches can open matching folds, and result navigation opens
only the target's ancestors. Live refreshes, filtering and reopening preserve
foldlevel and nested closed/open states by group identity, including children of
a closed parent. Fold captions retain the group's icons, colors and result count.

The Trouble-inspired layout puts the title, count and active filters in the
winbar. The body uses file icons, tree guides and multiline messages, with muted
source/code/position metadata and severity-colored icons. Paths are relative to
the source window's cwd; file groups retain directory context for duplicate names.
`icons = false`, `indent_guides = false`, or `multiline = false` disable individual
decorations under `results`. File icons reuse an already loaded nvim-web-devicons
provider and otherwise use a generic icon; no extra plugin is required.
The `LspToolsResults*` highlight groups follow the active colorscheme and can be
overridden. Lists use a cursor line and hide empty-buffer markers.
If a statusline plugin manages winbars, exclude the `lsp-tools-results` filetype
from its winbar handling so it preserves the list's own title and count.

Keys: Enter jumps or folds a group; `<LocalLeader>o` jumps while keeping list
focus; `<LocalLeader>p` previews; `<LocalLeader>P` toggles auto-preview; `za`, `zM`,
`zR` fold; `<LocalLeader>f` filters; `<LocalLeader>e` toggles errors;
`<LocalLeader>s` cycles sorting; `<LocalLeader>g` toggles grouping;
`<LocalLeader>F` pins; `<LocalLeader>r` refreshes; `]q`/`[q` move between results;
`<LocalLeader>Q` exports filtered locations to quickfix; `<LocalLeader>?` shows
keys in an owned help popup; `<LocalLeader>q`/Escape closes.

`<LocalLeader>-`, `<LocalLeader>|`, and `<LocalLeader>t` jump in a horizontal
split, vertical split, or new tab. The actions are `jump_split`, `jump_vsplit`,
and `jump_tab`; Enter remains `jump` in the source window. The list stays open
in its original tab. Stale results are rejected before creating a destination.
Native quickfix/location-list jumps preserve visual columns, search patterns and
the original list's current index, including location-list window ownership.

`gg`, `G`, word motions, character searches, yank and macro commands retain their
Vim behavior. `/` and `?` search forward and backward. The default `<LocalLeader>`
is `\`; it follows your `maplocalleader` setting (often Space). Help shows that
actual prefix and only this plugin's bindings, excluding other plugins' internal
triggers. User-supplied `actions` / `keys` remain literal mappings. Preview reads
loaded buffer contents first and limits disk previews to 1 MiB. Results are never
applied as edits.

Preview code uses the source language's Tree-sitter highlight queries, falling
back to Vim syntax files when a parser or query is unavailable. Only the code
excerpt is parsed; paths and diagnostic messages have separate colors. The target
line and UTF-8 range are highlighted. Source buffers stay unchanged and unopened
files are read without loading their buffers or starting language/filetype hooks.
Preview buffers retain the widget filetype so statusline integrations keep working.
The preview separates the file path, producer/code, diagnostic message and source
excerpt. Floating borders show the severity and excerpt language/line range;
`LspToolsResultsPreview*` highlight groups follow the active colorscheme.
Use the `focus_preview` action (default `<LocalLeader>w`) to enter the preview and
use native scrolling/search/yank commands. Escape returns to the original list.
Source line numbers exclude the metadata header. In the preview,
`<LocalLeader>+` expands context and `<LocalLeader>s` toggles float/side layout;
these are configurable actions `more_context` and `preview_layout`.
Configure `results.preview = { before = 3, after = 6, layout = "float", width = 0.6,
height = 0.5 }`. Layout also accepts `"right"` or `"bottom"`. Width/height are
fractions of the editor. Previews stay read-only and leave source buffers intact.

The `history` action (default `<LocalLeader>H`) or
`require("lsp-tools").results_history({ focus = true })` opens recent session
queries. It restores the source, results, filters, selection, grouping and native
fold state as a pinned snapshot without sending a request. Source edits, target
buffer/disk changes, detached providers and replaced native lists block stale
jumps. Refresh explicitly reruns the saved LSP origin, or reloads current
diagnostics/quickfix/loclist data. An imported picker snapshot without a refresh
provider must be searched again. `results.history = 20` bounds retained queries;
`0` disables recording. History is in memory only and disappears on Neovim exit.

## Diagnostic overview

The `filters` action (default `<LocalLeader>/`) opens an interactive field menu:
literal text, severity (including Error+Warning), source, diagnostic code and
namespace. Filters combine and affect only this view. Reset clears the view filter.
Configure durable named combinations with e.g.
`results = { presets = { Build = { severity = { 1, 2 }, source = "compiler" } } }`.
Save/load from the menu also supports project-scoped presets for this Neovim session.
Namespace IDs and buffer IDs are session-local; prefer source/code filters in
configuration presets. Cancelled or closed dialogs do not change a view.

With `results = true` and `diagnostics = true`, `require("lsp-tools").diagnostics()`
opens a live overview grouped by directory/file. `scope = "all"` (default) shows all
diagnostics received by Neovim, including non-LSP producers. `scope = "buffer"` binds to
the original buffer; `scope = "project"` uses an explicit `root`, Git root, or source
directory. This does not claim to discover diagnostics in unopened files that the server
has never reported. `<LocalLeader>S` cycles the three scopes, including when the current
scope is empty. The standard result filters and sorting remain usable.

`<LocalLeader>d` opens the exact selected diagnostic's existing detail view, even when
several diagnostics overlap. `<LocalLeader>a` previews a fix; `<LocalLeader>A` previews
a fix and continues across files after a diagnostic refresh confirms fewer matching
messages. User cursor, window and text changes prevent automatic navigation.
`<LocalLeader>F` pins the snapshot; `<LocalLeader>r` refreshes it manually. `namespace`
restricts a producer; native source/code/severity metadata is preserved. Closed
overviews have no diagnostic listeners or timers.

## Quickfix and Location List

With `results = true`, `quickfix(opts)` and `loclist(opts)` open native lists
through the common result UI. They preserve native order (default `sort = "none"`,
no grouping), list ID, title, context, original row indices and invalid log rows.
Initial selection follows the native current index; explicit jumps use native
`:cc` / `:ll`, preserving visual-column and pattern semantics. Opening a view does
not replace the canonical list or change its contents.

Location lists bind to the original source window, or explicit `winid`, rather than the
panel's current window. Closing that window stops polling and leaves a labeled snapshot
whose jumps are disabled. Open lists observe native events and poll `changedtick`/list
ID/current index for API-only updates (`poll_interval`, default 150 ms). Polling stops
on close. `<LocalLeader>F` pins; `<LocalLeader>r` refreshes; unpinning refreshes
immediately. Stale snapshots refuse native jumps until refreshed. `<LocalLeader>Q`
explicitly exports the filtered view as a new quickfix list. `toggle = true` toggles the
view.

## Persistent LSP locations

With `results = true`, `locations(opts)` queries definitions, references,
implementations, type definitions and declarations into labeled sections. Set
`method = "references"` (or another plural name / protocol method) to query one
section; `include_declaration = false` omits reference declarations. Multiple
providers are deduplicated by converted location while retaining provider IDs.
`Location` and `LocationLink` use each client's encoding and selection range.

Results remain available while moving between source files. `<LocalLeader>r` queries the
source window's current position; `follow_symbol = true` enables debounced queries while
that window's cursor moves. `<LocalLeader>F` pins automatic following. Edits/detach mark
snapshots stale; changed source/target text or files refuse jumps until refreshed. Late
replies after source cursor changes and closed views are discarded. Slow clients time
out (`request_timeout`, default 3000 ms); errors and unsupported sections remain
visible. Large/unavailable files show an unknown column until native navigation loads
them; jumps and quickfix export retain protocol encoding. Location queries require no
Snacks picker or Trouble dependency.

## Import picker results

With `results = true`, call `require("lsp-tools").from_picker(picker, opts)` from
a Snacks action. `type = "smart"` (default) imports selected items, or all filtered
items when nothing is selected. Explicit `"selected"` and `"all"` are supported.
The picker closes before the persistent list opens, retaining the original source
window. Relative files resolve against the item's cwd or the picker cwd. Byte
positions, text and original item metadata are retained. Rows without locations
remain visible but cannot jump. Import takes a snapshot, not a live search.

Use `append = true` (`add = true` is an alias) to add to an open or closed snapshot;
`id` defaults to `"picker"`. Other common result options apply. The returned token
can cancel a scheduled import with `token.cancel()`. Disabling results cancels it.
Other pickers, including selection-tools adapters, can pass normalized items to
the public `results(items, opts)` API without depending on Snacks.

```lua
-- Inside Snacks picker options:
actions = {
  results_open = function(picker)
    require("lsp-tools").from_picker(picker, { type = "smart" })
  end,
},
win = { input = { keys = { ["<c-t>"] = { "results_open", mode = { "n", "i" } } } } },
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
prefills its name through the general `input-tools.input()` API when available
(or your existing `vim.ui.input` provider otherwise), and requests one
rename after you enter the new name. A selection-tools picker then lists affected files,
their edit counts, and their diffs. Select a file to inspect it. The title reports
totals and states that Enter applies **all** listed changes; Escape cancels.
Reviewing a different file does not restrict the edit to that file. Text edits
remain unsaved buffers, as with native LSP rename.

```lua
require("lsp-tools").setup({
  rename = {
    request_timeout = 3000, -- per prepare/rename request, milliseconds
    input = false, -- Automatic input-tools API, with vim.ui.input fallback.
    backend = "vim", -- or "delta", using the same renderer as code actions
    delta = {
      command = "delta",
      args = { "--file-style=omit", "--hunk-header-style=file line-number syntax" },
      timeout = 2000,
    },
    picker = { layout = { width = 0.85, height = 0.8, preview_height = 0.7 } },
  },
})

require("lsp-tools").rename("new_name") -- still previews before applying
require("lsp-tools").rename(nil, { name = "lua_ls" }) -- optional client name
require("lsp-tools").rename(nil, { filter = function(client) return client.name ~= "other" end })
require("lsp-tools").cancel_rename()
```

Rename calls the general `require("input-tools").input(opts, on_confirm)` API
automatically when available; no per-rename configuration callback is required.
It passes `vim_mode=true`, `position="cursor"`, `width=32`, `title="Rename"`,
`title_pos="left"`,
and the prepared/default name;
the input opens beside the source cursor, the label is left-aligned in the upper
border, and only the name is editable.
Rename starts in Insert mode; Escape enters Normal for native motions, `ciw`
and undo/redo. Enter accepts the name, then the existing workspace-edit preview
opens. Ctrl-C or Normal-mode Escape cancels the input. Pending inputs are also
closed when `cancel_rename()` or a stale source invalidates the rename.
Fallback providers receive the title as a conventional inline prompt.
Input-tools is optional and is resolved only when asking for input, so lsp-tools
setup does not load it or enable its renderer. Missing installations and older
versions without the API fall back to the current `vim.ui.input`. The global
provider is never replaced. Vim-mode inputs can open independently of the global
command-line renderer; native inputs use their documented native-display fallback
when that renderer is disabled.

`rename.input` still accepts an explicit `function(opts, on_confirm)` override
with the `vim.ui.input` callback contract (`nil` cancels); `false` restores
automatic selection. Providers may return an optional `{ cancel = function() ... end }`
handle; lsp-tools uses it to close pending input when the rename is cancelled.
Programmatic names skip the input provider. Input errors
cancel the rename and are reported without applying edits.

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
sh tests/servers-integration.sh # native startup, config merging, reuse and project isolation
LSPCONFIG_DIR="$HOME/.local/share/nvim/lazy/nvim-lspconfig" sh tests/servers-integration.sh # also real LuaLS with upstream configs
SELECTION_TOOLS_DIR=../selection-tools.nvim GIT_TOOLS_DIR=../git-tools.nvim ./tests/integration.sh
./tests/tui.sh # run from a terminal; exercises actual mapped keys and focus
sh tests/pickers-integration.sh # real LuaLS, typed search and diagnostic scopes in a PTY
LSP_TOOLS_NVIM_CONFIG="$HOME/.config/nvim" sh tests/pickers-integration.sh # current config and keys
./tests/references-integration.sh # requires lua-language-server (or LUA_LS=/path/to/server)
./tests/references-integration.sh tui # real terminal keys and Ctrl-O
./tests/rename-integration.sh # deterministic real LSP client/server and selection-tools
LSP_TOOLS_BACKEND=delta ./tests/rename-integration.sh tui # actual input, Enter/Escape
LSP_TOOLS_REAL_LSP=1 ./tests/rename-integration.sh # real LuaLS semantic rename
```

Unit tests cover preview isolation, Unicode edits, unsaved/multiple files,
resource-operation order, late responses, resolve caching, failure/timeout,
confirmation, cancellation, fallback selection, and setup lifecycle.
Integration tests start a real Neovim LSP client against a local fixture server
and open an actual selection-tools picker. No network or language server installation is
required. The fixture is a protocol test, not a compatibility claim for every
language server.

Public API tests verify lazy loading, option forwarding, repeated setup, disabling,
and select-provider ownership without loading code-actions.nvim. The TUI test
opens real terminal Neovim, triggers Normal/Visual mappings through key input,
confirms with Enter, cancels with Escape, and checks source-buffer focus recovery.

Server tests use runtimepath/after config fixtures and a real local LSP process,
covering preflight validation, hook preservation, ownership, missing executables,
existing/new buffers, client reuse, multiple project roots and single-file mode.
The optional `LSPCONFIG_DIR` run requires a local nvim-lspconfig checkout and
`lua-language-server` on PATH (or `LUA_LS=/path/to/server`) and verifies actual
LuaLS attachment and rename using an upstream config.

Renderer and generation tests live in git-tools (`tests/render.lua` and
`tests/unified.lua`); selection-tools keeps generic transaction/frame lifecycle
tests. These cover native output, literal delta arguments, ANSI output, cancellation,
resize and fallback. Integration tests additionally exercise a missing
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
movement reads that cache without making requests. Edits refresh after a debounce;
the previous symbols remain visible while waiting, with ranges tracked through
edits to avoid flickering during typing. Symbol names update when the new response
arrives. Hidden documents drop their cache and cancel pending requests.
Provider selection retains the previous eligible client, falling back
to the lowest client ID. Edits, URI changes, detach, timeout, and disable reject
obsolete replies. Errors and unsupported providers leave the component empty.
The outline and breadcrumbs request their own symbol snapshots independently.
Set `breadcrumbs = false` (or `{ enabled = false }`) to disable this module.

Run `tests/run.sh` for cache, range, cancellation, escaping, and window-ownership
coverage. `tests/breadcrumbs-integration.sh [headless|tui]` verifies real LuaLS,
the native winbar, the installed lualine implementation, split cursors, and edits.
The TUI run also types in Insert mode and samples both winbars throughout refreshes.
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
    indent = 1,           -- spaces per hierarchy level; 0 disables indentation
    focus_on_open = false,
    follow_cursor = true,
    debounce = 200,       -- milliseconds after source edits
    request_timeout = 3000,
    mode = "auto",       -- "auto", "structure", "all", or "sections"
    -- client_name = "texquill", -- optional provider preference/filter
    -- client_filter = function(client, bufnr) return true end,
    icons = {            -- optional overrides of the built-in symbol icons
      Key = { icon = "󰌆", hl = "Type" },
      Event = { icon = "󱐋", hl = "Type" },
    },
  },
})
```

`auto` initially shows document structure for `tex` buffers and all symbols for
other file types. `structure` includes headings, Beamer frames and blocks, lists,
individual list items, columns, figures, tables, and theorem/proof environments
when supplied by the server. TeXquill reports frame titles from either
`\begin{frame}{Title}` or `\frametitle{Title}` and nests list-item previews under
their environments. For example, a Beamer outline can show
`Progress → Comparison with the Existing Methods → itemize → Our method`.
Selection jumps to the frame title or the item's `\item` command.

Set `mode = "sections"` to keep a headings-only view. This recognizes LaTeX
heading commands in the server's `detail` field, with Namespace symbols as a
fallback when detail is absent. Structural scopes use Object symbols whose
detail names the environment, Array symbols for `itemize`/`enumerate`/`description`,
and EnumMember symbols with detail `item`. These symbols require a TeXquill build
with document-structure support; changing outline modes cannot add symbols absent
from an older server's response.

Press `<LocalLeader>m` to include labels, citations, macros, and other server symbols, then
press it again to return to structure (`sections` when explicitly configured).
Filtered-out parents do not hide matching descendants. The client preserves the
server's hierarchy and never parses LaTeX source itself.

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
| `<LocalLeader>h`, `zc` | Collapse, or move to the visible parent |
| `<LocalLeader>l`, `zo` | Expand, or move to the first child |
| `zM`, `zR` | Collapse / expand all |
| `<LocalLeader>m` | Toggle structure / all symbols (sections when explicitly configured) |
| `<LocalLeader>r` | Refresh from the language server |
| `<LocalLeader>q`, `Esc` | Close and return to the source |

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
`tests/outline-integration.sh [headless|tui] [lua|texquill|beamer]` for real LuaLS or
TeXquill hierarchy, filtering, editing, key, and focus checks. The chosen server
must be installed on `PATH`. The `beamer` case covers frames, nested lists/items,
source jumps, breadcrumbs and structure/all mode switching. Set `TEXQUILL_BIN`
to test a specific server build, or `LSP_TOOLS_BEAMER_FILE` to inspect an existing
presentation containing the fixture's frame/item names without modifying it.

Run `sh tests/tools-integration.sh` for the optional tools: real TeXquill linked
editing and document links, LuaLS hover documentation, clangd call/type hierarchies,
LSP/selection-tools diagnostic fixes, persistent LuaLS locations, picker imports, and terminal
rendering/key/focus checks. It requires
`texquill` (or `NVIM_TEXQUILL`), `lua-language-server`, `clangd`, Python 3, and an
installed Snacks checkout. `python3 tests/terminal.py workflows_integration.lua`
runs just the code-action indicator, diagnostic-fix and inspection terminal flow.

For a compatible profile-based Neovim configuration using this development
checkout, run `LSP_TOOLS_NVIM_CONFIG=/path/to/nvim python3 tests/terminal.py
config_lazy_integration.lua`. This opt-in check exercises real first-key loading,
the no-LSP path fallback, code-action preview/cancellation, and outline listener
cleanup through the configuration's mappings. The regular suite also verifies
real LSP dynamic capability registration and removal with a stdio fixture.
Run the same opt-in command with `config_results_integration.lua` for the actual
Snacks `<C-t>` first-use path before LSP attachment and the configured diagnostic,
LSP, quickfix and loclist toggles after replacing Trouble.
Set `LSP_TOOLS_TEST_DEBUGGING=1` for the same check with the configuration's debugging
feature enabled. This verifies that DAP and result-window winbar exclusions merge
correctly and that focus changes, live diagnostics and lualine refreshes do not
replace the result title with a filename.
