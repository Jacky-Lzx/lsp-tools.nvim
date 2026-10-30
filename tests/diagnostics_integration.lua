vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
vim.opt.rtp:prepend(vim.env.SNACKS_DIR or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim"))
vim.o.columns, vim.o.lines = 160, 40
require("snacks").setup({ picker = { enabled = true } })
require("snacks.picker").setup()
local tools = require("lsp-tools")
tools.setup({ diagnostics = true, references = false, breadcrumbs = false, outline = false })
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "next" })
local id = assert(vim.lsp.start({
  name = "diagnostic-test",
  cmd = { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/server.py" },
  root_dir = vim.fn.getcwd(),
}))
local client = vim.lsp.get_client_by_id(id)
assert(vim.wait(5000, function()
  return client.initialized
end, 10))
local ns = vim.lsp.diagnostic.get_namespace(id, false)
local diagnostic = {
  lnum = 0,
  col = 0,
  end_col = 5,
  message = "Fix greeting",
  severity = 1,
  user_data = {
    lsp = {
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      message = "Fix greeting",
    },
  },
}
vim.diagnostic.set(ns, buf, { diagnostic })
local s = tools.diagnostic()
assert(require("lsp-tools.diagnostics").fix(s, true))
local function picker()
  return require("snacks.picker").get()[1]
end
assert(vim.wait(5000, function()
  return picker() and picker():current()
end, 10))
local p = picker()
assert(
  vim.wait(5000, function()
    return p.preview.win.buf
      and table
        .concat(vim.api.nvim_buf_get_lines(p.preview.win.buf, 0, -1, false), "\n")
        :find("你好😀", 1, true)
  end, 10),
  "diagnostic fix uses actual resolved preview"
)
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "hello world")
p.opts.confirm(p, p:current())
assert(vim.wait(3000, function()
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "你好😀 world"
end, 10))
assert(s.advance, "advance starts only after successful application")
vim.diagnostic.set(ns, buf, {})
assert(not s.advance and #s.items == 0)
require("lsp-tools.diagnostics").disable()
client:stop(true)
print("diagnostics integration: real LSP resolve, Snacks preview, apply and refresh passed")
vim.cmd("qa!")
