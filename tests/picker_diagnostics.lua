vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api, tools = vim.api, require("lsp-tools")
local model = require("lsp-tools.pickers.model")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local ns = api.nvim_create_namespace("picker-unloaded-diagnostics")
vim.diagnostic.config({ virtual_text = false, signs = false, underline = false })
vim.notify = function() end
tools.setup({
  pickers = true,
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
})
local origin = api.nvim_get_current_buf()
api.nvim_buf_set_lines(origin, 0, -1, false, { "origin" })
local win = api.nvim_get_current_win()
local function open(name)
  api.nvim_set_current_win(win)
  api.nvim_win_set_buf(win, origin)
  local file = directory .. "/" .. name .. ".lua"
  vim.fn.writefile({ "first", "second diagnostic", "third" }, file)
  local buf = vim.fn.bufadd(file)
  vim.diagnostic.set(ns, buf, { { lnum = 1, col = 3, message = name } })
  local p = tools.pick_diagnostics({ namespace = ns, query = name })
  check(not api.nvim_buf_is_loaded(buf), "opening the picker leaves the target unloaded")
  check(p:current() and p:current().bufnr == buf, "picker selects the unopened file")
  return p, buf, file
end
local function rejected(p, message)
  p:confirm()
  check(not p.closed, message)
  p:close()
end

local p, buf = open("unopened")
check(model.diagnostic_valid(p:current()), "unchanged unloaded diagnostics remain valid")
p:confirm()
check(p.closed, "confirm closes the diagnostic picker")
check(api.nvim_get_current_buf() == buf, "confirm opens the diagnostic's file")
check(
  vim.deep_equal(api.nvim_win_get_cursor(win), { 2, 3 }),
  "jump uses the exact diagnostic position"
)

local file
p, buf, file = open("disk-change")
vim.fn.writefile({ "changed file with different size", "second diagnostic" }, file)
rejected(p, "disk edits invalidate diagnostics collected from unloaded buffers")

p, buf = open("removed")
vim.diagnostic.reset(ns, buf)
rejected(p, "removed diagnostics cannot confirm before the scheduled refresh")

p, buf = open("loaded-before-confirm")
vim.fn.bufload(buf)
check(
  model.diagnostic_valid(p:current()),
  "loading unchanged text does not invalidate an unloaded snapshot"
)
p:confirm()
check(p.closed and api.nvim_get_current_buf() == buf, "a newly loaded target remains jumpable")

p, buf = open("modified-before-confirm")
vim.fn.bufload(buf)
api.nvim_buf_set_lines(buf, 0, 1, false, { "modified" })
rejected(p, "unsaved edits after loading invalidate an unloaded snapshot")

p, buf = open("loaded-edit")
p:close()
vim.fn.bufload(buf)
p = tools.pick_diagnostics({ namespace = ns, query = "loaded-edit" })
check(p:current().bufnr == buf, "loaded target selected")
api.nvim_buf_set_lines(buf, 0, 1, false, { "new unsaved text" })
rejected(p, "loaded-buffer changedtick still rejects stale positions")

vim.fn.delete(directory, "rf")
print(("Diagnostic picker navigation: %d assertions passed"):format(count))
vim.cmd("qa!")
