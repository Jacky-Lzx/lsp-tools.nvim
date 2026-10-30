vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
vim.g.maplocalleader = " "
local api, results = vim.api, require("lsp-tools.results")
local buf, source = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/src/main.lua")
api.nvim_buf_set_lines(buf, 0, -1, false, { "😀alpha", "beta", "tail" })
vim.wo[source].winbar = " Source window "
vim.wo[source].wrap, vim.wo[source].list, vim.wo[source].foldenable = true, true, true
vim.wo[source].cursorline = false
results.setup({ auto_preview = false, icons = false })
local v = results.open({
  {
    id = "alpha",
    bufnr = buf,
    pos = { 1, 4 },
    text = "类型错误 😀\nexpected string\nreceived number",
    source = "lua_ls",
    code = "E1",
    severity = 1,
  },
  { id = "beta", bufnr = buf, pos = { 2, 0 }, text = "second message", severity = 2 },
}, { title = "100% %{literal}", focus = true })
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function key(lhs)
  api.nvim_set_current_win(v.win)
  vim.fn.maparg(lhs, "n", false, true).callback()
end
local lines = api.nvim_buf_get_lines(v.out, 0, -1, false)
for _, lhs in ipairs({
  "g",
  "G",
  "h",
  "j",
  "k",
  "l",
  "w",
  "b",
  "e",
  "f",
  "F",
  "d",
  "y",
  "p",
  "q",
  "r",
  "s",
  "/",
  "?",
}) do
  check(vim.fn.maparg(lhs, "n") == "", "native " .. lhs .. " is not remapped")
end
api.nvim_feedkeys(vim.keycode("G"), "xt", false)
check(api.nvim_win_get_cursor(v.win)[1] == #lines, "native G reaches the last line")
local grouping = vim.deepcopy(v.group_by)
api.nvim_feedkeys(vim.keycode("gg"), "xt", false)
check(
  api.nvim_win_get_cursor(v.win)[1] == 1 and vim.deep_equal(v.group_by, grouping),
  "native gg reaches the first line without toggling grouping"
)
check(
  not table.concat(lines, "\n"):find("Enter jump", 1, true),
  "key legend no longer occupies result rows"
)
local bar = api.nvim_eval_statusline(vim.wo[v.win].winbar, { winid = v.win, use_winbar = true }).str
check(
  bar:find("100% %{literal}", 1, true) and bar:find("2", 1, true),
  "winbar shows literal titles and counts without evaluating user text"
)
results.select(v, "alpha")
local first = api.nvim_win_get_cursor(v.win)[1]
check(
  lines[first + 1]:find("expected string", 1, true)
    and lines[first + 2]:find("received number", 1, true),
  "multiline diagnostics retain readable continuation lines"
)
api.nvim_win_set_cursor(v.win, { first + 1, 0 })
check(results.selected(v).id == "alpha", "continuation rows retain the correct diagnostic identity")
key("]q")
check(results.selected(v).id == "beta", "next result skips multiline continuation rows")
key("[q")
check(results.selected(v).id == "alpha", "previous result navigates to the preceding diagnostic")
api.nvim_win_set_cursor(v.win, { first + 2, 0 })
check(
  results.jump(v) and api.nvim_win_get_cursor(0)[2] == 4,
  "continuation row jumps using the diagnostic UTF8 position"
)
local marks = api.nvim_buf_get_extmarks(
  v.out,
  api.nvim_create_namespace("lsp-tools.results"),
  { first - 1, 0 },
  { first - 1, -1 },
  { details = true }
)
local icon, message, meta
for _, mark in ipairs(marks) do
  local hl = mark[4].hl_group
  local text = lines[first]:sub(mark[3] + 1, mark[4].end_col)
  if hl == "DiagnosticError" then
    icon = text
  end
  if hl == "LspToolsResultsText" then
    message = text
  end
  if hl == "LspToolsResultsMeta" and text:find("lua_ls", 1, true) then
    meta = text
  end
end
check(
  icon == "E " and message == "类型错误 😀" and meta,
  "severity, message and metadata have separate UTF8-safe highlight spans"
)
vim.keymap.set("n", "<C-w>", function() end, { buffer = v.out, desc = "which-key-trigger" })
vim.keymap.set("n", "<F12>", function() end, { buffer = v.out, desc = "Unrelated action" })
key("<LocalLeader>?")
local help = v.help
check(help and api.nvim_get_current_win() == help.win, "help opens on demand")
local help_text = table.concat(api.nvim_buf_get_lines(help.buf, 0, -1, false), "\n")
check(
  not help_text:find("which-key-trigger", 1, true)
    and not help_text:find("Unrelated action", 1, true),
  "help only includes owned bindings and native navigation guidance"
)
check(
  help_text:find("<Space>f", 1, true) and help_text:find("gg / G", 1, true),
  "help shows the expanded local leader and preserved Vim motions"
)
vim.fn.maparg("<Esc>", "n", false, true).callback()
check(not v.help and api.nvim_get_current_win() == v.win, "closing help restores result focus")
results.filter(v, { text = "missing" })
check(
  not results.selected(v) and not results.jump(v),
  "empty-state rows cannot select or jump to a result"
)
key("<LocalLeader>?")
help = v.help
api.nvim_win_close(source, true)
results.close()
check(not api.nvim_win_is_valid(help.win), "closing an orphaned view releases its help window")
check(
  vim.wo.winbar == " Source window "
    and vim.wo.wrap
    and vim.wo.list
    and vim.wo.foldenable
    and not vim.wo.cursorline,
  "last-window close restores the source's display options"
)
results.disable()
print(("result presentation: %d assertions passed"):format(count))
vim.cmd("qa!")
