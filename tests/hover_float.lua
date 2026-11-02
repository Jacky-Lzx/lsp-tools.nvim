vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local api = vim.api
local original = vim.lsp.util.open_floating_preview
local source = api.nvim_get_current_win()
vim.o.columns, vim.o.lines = 100, 35
vim.wo.list = true
vim.g.syntax_on = nil
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
tools.setup({
  code_actions = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
  references = false,
  hover = true,
})
check(not package.loaded["lsp-tools.hover"], "styling native K keeps pinned UI deferred")
local lines = {
  "```rust",
  "sc_residual_mvp::stats::JointErrors",
  "```",
  "",
  "```rust",
  "pub total: Moments",
  "```",
  "",
  "**Accuracy** and `total`.",
  "[Documentation](https://example.com)",
}
local function open(content, syntax, opts)
  return vim.lsp.util.open_floating_preview(
    content or lines,
    syntax or "markdown",
    vim.tbl_extend("force", { focus_id = "textDocument/hover" }, opts or {})
  )
end
local buf, win = open()
check(vim.bo[buf].filetype == "markdown", "legacy syntax disabled still produces Markdown")
check(vim.treesitter.highlighter.active[buf], "Markdown Tree-sitter starts independently")
check(
  vim.wo[win].conceallevel == 2 and vim.wo[win].concealcursor == "nvic",
  "syntax remains concealed on focused cursor line"
)
check(not vim.wo[win].list and vim.wo[win].winblend == 0, "hover has clean, opaque local options")
check(vim.wo[source].list, "source window options are preserved")
check(
  api.nvim_win_get_width(win) <= 80 and api.nvim_win_get_height(win) < #lines + 2,
  "float is bounded and excludes hidden fence rows from height"
)
local raw = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(
  raw:find("```rust", 1, true) and raw:find("https://example.com", 1, true),
  "raw Markdown and URLs survive for copying and links"
)
local again, focused = open()
check(
  again == buf and focused == win and api.nvim_get_current_win() == win,
  "second native hover focuses the same float"
)
api.nvim_win_set_cursor(win, { 1, 0 })
vim.cmd.normal("j")
check(api.nvim_win_get_cursor(win)[1] == 3, "j skips the hidden opening fence")
vim.cmd.normal("2j")
check(
  api.nvim_win_get_cursor(win)[1] == 7,
  "counted j counts visible rows across consecutive fences"
)
vim.cmd.normal("2k")
check(api.nvim_win_get_cursor(win)[1] == 3, "counted k skips fences in reverse")
vim.cmd.normal(vim.keycode("<Down>"))
check(api.nvim_win_get_cursor(win)[1] == 5, "arrow movement skips the closing fence")
vim.cmd.normal(vim.keycode("<Up>"))
check(api.nvim_win_get_cursor(win)[1] == 3, "up arrow skips the closing fence")
vim.cmd.normal("gj")
check(api.nvim_win_get_cursor(win)[1] == 5, "screen-line motion skips the closing fence")
vim.cmd.normal("gk")
check(api.nvim_win_get_cursor(win)[1] == 3, "reverse screen-line motion skips the closing fence")
check(vim.fn.maparg("j", "n", false, true).buffer == 1, "navigation is buffer-local")
vim.cmd.normal("999j")
check(
  api.nvim_win_get_cursor(win)[1] == api.nvim_buf_line_count(buf),
  "large counts stop at the bottom"
)
vim.cmd.normal("999k")
check(api.nvim_win_get_cursor(win)[1] == 1, "large counts stop at the top")
api.nvim_set_current_win(source)
check(vim.fn.maparg("j", "n") == "", "source navigation mappings are unchanged")
api.nvim_win_close(win, true)
buf, win = open({ "```lua", string.rep("x", 100), "```", "after" }, nil, { max_width = 24 })
api.nvim_set_current_win(win)
api.nvim_win_set_cursor(win, { 3, 1 })
vim.cmd.normal("gj")
check(
  api.nvim_win_get_cursor(win)[1] == 3 and api.nvim_win_get_cursor(win)[2] > 1,
  "gj moves within a wrapped code line"
)
vim.cmd.normal("gk")
check(
  api.nvim_win_get_cursor(win)[1] == 3 and api.nvim_win_get_cursor(win)[2] == 1,
  "gk preserves screen columns within wrapped text"
)
vim.cmd.normal("j")
check(api.nvim_win_get_cursor(win)[1] == 5, "logical j skips the fence after a wrapped line")
api.nvim_set_current_win(source)
api.nvim_win_close(win, true)
local start = vim.treesitter.start
vim.treesitter.start = function()
  error("missing parser")
end
buf, win = open({ "~~~~rust", "```", "pub total: Moments", "~~~~" })
vim.treesitter.start = start
local ns = api.nvim_create_namespace("lsp-tools.hover.float")
check(
  #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 2,
  "missing parser still conceals matching fences, preserving nested backticks"
)
api.nvim_win_close(win, true)
buf, win = open({ "literal **stars**", "```rust" }, "plaintext")
check(
  vim.bo[buf].filetype ~= "markdown" and #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0,
  "plaintext is never interpreted as Markdown"
)
api.nvim_win_close(win, true)
buf, win = open(nil, nil, { max_width = 28, max_height = 4, title = " Custom " })
check(
  api.nvim_win_get_width(win) == 28 and api.nvim_win_get_height(win) <= 4,
  "per-call native dimensions take precedence"
)
api.nvim_win_close(win, true)
buf, win = open({ "# Type", "---", "```rust", "// # code", "```" }, nil, { border = "none" })
check(api.nvim_win_get_config(win).title == nil, "borderless native calls do not inherit a title")
check(
  #api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 4,
  "headings and rules are rendered outside fenced code"
)
api.nvim_win_close(win, true)
local other_buf, other_win = vim.lsp.util.open_floating_preview({ "signature" }, "text", {})
check(not vim.b[other_buf].lsp_tools_hover_float, "signature help and unrelated previews untouched")
api.nvim_win_close(other_win, true)
vim.o.columns, vim.o.lines = 32, 12
buf, win = open(vim.split(string.rep("long documentation line with wrapping\n", 40), "\n"))
check(
  api.nvim_win_get_width(win) <= 28 and api.nvim_win_get_height(win) <= 8,
  "long documentation fits a small terminal and remains scrollable"
)
api.nvim_win_close(win, true)
vim.o.columns, vim.o.lines = 100, 35
local wrapper = vim.lsp.util.open_floating_preview
check(
  not pcall(tools.setup, { hover = { float = { max_height = 0 } } }),
  "invalid float options rejected"
)
check(vim.lsp.util.open_floating_preview == wrapper, "invalid setup preserves existing adapter")
tools.setup({ hover = { float = false } })
check(vim.lsp.util.open_floating_preview == original, "float styling can be disabled independently")
tools.setup({ hover = { float = {} } })
tools.setup({ hover = false })
check(vim.lsp.util.open_floating_preview == original, "disabling hover restores native renderer")
print(("hover float: %d assertions passed"):format(count))
vim.cmd("qa!")
