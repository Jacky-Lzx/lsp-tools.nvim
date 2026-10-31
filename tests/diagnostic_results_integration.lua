vim.opt.rtp:prepend(
  vim.env.SELECTION_TOOLS_DIR or (vim.env.LSP_TOOLS_ROOT .. "/../selection-tools.nvim")
)
vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
vim.opt.rtp:prepend(vim.env.SNACKS_DIR or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim"))
local tools = require("lsp-tools")
tools.setup({
  results = { debounce = 1, auto_preview = false },
  diagnostics = true,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local a, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local root = vim.env.LSP_TOOLS_TEST_TMP or vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.api.nvim_buf_set_name(a, root .. "/a.lua")
vim.api.nvim_buf_set_lines(a, 0, -1, false, { "hello world" })
local b = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(b, root .. "/b.lua")
vim.api.nvim_buf_set_lines(b, 0, -1, false, { "next diagnostic" })
local id = assert(vim.lsp.start({
  name = "overview-fix",
  cmd = { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/server.py" },
  root_dir = root,
}))
local client = vim.lsp.get_client_by_id(id)
local function wait(test, message)
  assert(vim.wait(5000, test, 5), message)
end
wait(function()
  return client.initialized
end, "server initializes")
local ns = vim.lsp.diagnostic.get_namespace(id, false)
vim.diagnostic.set(
  ns,
  a,
  { { lnum = 0, col = 0, end_col = 5, message = "first error", severity = 1 } }
)
vim.diagnostic.set(ns, b, { { lnum = 0, col = 0, message = "second error", severity = 1 } })
local v = tools.diagnostics({ focus = true, group_by = {} })
vim.fn.maparg("<LocalLeader>A", "n", false, true).callback()
local function picker()
  return require("lsp-tools.selection").current()
end
wait(function()
  return picker() and picker():current()
end, "overview opens actual code-action picker")
local p = picker()
wait(function()
  return vim.api.nvim_win_get_buf(p.preview_win)
    and table
      .concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(p.preview_win), 0, -1, false), "\n")
      :find("你好😀", 1, true)
end, "overview fix resolves actual edit")
p:confirm()
wait(function()
  return v.advance ~= nil
end, "advance waits for confirmed diagnostic refresh")
vim.diagnostic.set(ns, a, {})
wait(function()
  return #v.items == 1 and not v.advance
end, "overview confirms fixed diagnostic")
assert(vim.api.nvim_win_get_buf(win) == b, "continuation crosses to the next matching file")
assert(require("lsp-tools.results").selected(v).bufnr == b)
require("lsp-tools.results").close("diagnostics")
require("lsp-tools.diagnostics").disable()
client:stop(true)
wait(function()
  return vim.lsp.get_client_by_id(id) == nil
end, "server exits")
print(
  "diagnostic overview integration: actual resolve/preview/apply and cross-file continuation passed"
)
vim.cmd("qa!")
