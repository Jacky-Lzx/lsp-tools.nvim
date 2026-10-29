# lsp-tools.nvim roadmap

Independent, practical LSP tools for reading, changing, and fixing code.
Features should preserve the user's editing context, support cancellation, and
integrate with existing Neovim UI providers. Modules are independently enabled;
key mappings belong to the user's configuration.

## First milestone: code actions

- [x] Integrate the existing code-actions.nvim functionality into this plugin.
- [x] Provide `require("lsp-tools").setup()` and a public code action entry point.
- [x] Preserve native LSP requests, Visual ranges, diagnostics, filters, and auto-apply.
- [x] Provide a Snacks picker with asynchronous resolution and workspace-edit previews.
- [x] Preserve native diff rendering and optional asynchronous delta rendering.
- [x] Preserve Unicode positions, unsaved buffers, multi-file edits, and resource-operation summaries.
- [x] Preserve resolve caching, cancellation, timeout/failure fallback, and stale-buffer checks.
- [x] Document installation and migration without a code-actions.nvim dependency.
- [x] Verify unit coverage, real Neovim LSP/Snacks integration, and terminal key/focus behavior.

## Rename preview

- [x] Preview the language server's actual rename edits, grouped by file.
- [x] Show affected-file and edit counts, with diff navigation.
- [x] Apply the complete edit after confirmation; cancellation leaves files unchanged.
- [x] Handle prepareRename, unsupported servers, stale results, and failed requests.
- [x] Guard all affected buffers, document versions, and disk snapshots before applying.
- [x] Show change annotations and resource operations; select a single rename provider.
- [x] Verify cross-file edits and real LuaLS semantics through headless and terminal UI tests.

## Symbol outline

- [x] Render a right-hand sidebar from one LSP document-symbol provider.
- [x] Preserve server hierarchy; handle flat SymbolInformation without invented nesting.
- [x] Fold subtrees, jump to selections, follow source files, and highlight the current scope.
- [x] Filter LaTeX sections, with an all-symbol mode for macros, labels, and other symbols.
- [x] Preserve per-document folds and mode across debounced updates and source switches.
- [x] Cancel obsolete requests and reject stale replies and stale jump positions.
- [x] Verify real LuaLS/TeXquill symbols and terminal navigation without Snacks.
- [ ] Add optional Tree-sitter providers for documents without an LSP, if needed.

## Current-location breadcrumbs

- [x] Render the enclosing LSP symbol path as a lualine component or optional native winbar.
- [x] Follow each window's cursor using a shared per-buffer cache without cursor-triggered requests.
- [x] Preserve hierarchy, Unicode positions, semantic icons/colors, and optional LaTeX section filtering.
- [x] Cancel obsolete requests and preserve other winbar providers on setup and disable.
- [x] Verify real LuaLS, installed lualine, terminal rendering, split cursors, and live edits.

## Diagnostic workflow

- [ ] Show full messages, sources, codes, and related locations.
- [ ] Navigate related locations without losing the original diagnostic.
- [ ] Request code actions for the selected diagnostic.
- [ ] Continue to the next matching diagnostic after a fix.

## Persistent documentation

- [ ] Pin hover documentation in a searchable side window.
- [ ] Support copying signatures and opening documentation links.
- [ ] Offer manual refresh and an optional follow-cursor mode.

## Semantic reference navigation

- [x] Highlight and navigate the current symbol's document highlights, independently of Snacks.words.
- [x] Support signed counts, optional wrapping, jump origins, and opening target folds.
- [x] Preserve server-provided read/write highlight kinds and position encodings.
- [x] Sort/deduplicate multiple clients' locations and reject stale asynchronous results.
- [x] Recommend Normal-mode `]r` / `[r`, leaving native section/terminal navigation available.
- [ ] Filter navigation by read/write kind when the server supplies that information.
- [ ] Filter references by the current function or document where supported.
- [ ] Explain capability limits; do not infer workspace-wide read/write classification from ordinary references.

## Call and type hierarchies

- [ ] Lazily expand incoming/outgoing calls and super/subtypes.
- [ ] Preserve expansion state and preview concrete source locations.
- [ ] Gate operations on the attached server's capabilities.

## LSP inspection

- [ ] Inspect attached clients, project roots, and supported methods for the current buffer.
- [ ] Explain client selection when multiple servers provide the same feature.
- [ ] Expose recent request failures, timeouts, and empty results on demand.

## Shared behavior

- [ ] Keep modules independently configurable and avoid assigning default user key mappings.
- [ ] Cancel obsolete requests and discard responses after buffer/cursor context changes.
- [ ] Keep focus restoration, return locations, and cancellation predictable.
- [ ] Reuse existing picker/UI integrations where practical.
