vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, directory .. "/main.tex")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  "\\documentclass{article}",
  "\\begin{document}",
  "\\href{https://example.com/semantic}{Link}",
  "\\end{document}",
})
vim.bo[buf].filetype = "tex"
local executable = vim.env.NVIM_TEXQUILL or vim.fn.exepath("texquill")
assert(executable ~= "", "Install texquill or set NVIM_TEXQUILL")
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
local id = assert(vim.lsp.start({
  name = "links-real-texquill",
  cmd = { executable, "--stdio" },
  root_dir = directory,
  capabilities = capabilities,
  init_options = { distribution = { enabled = false } },
}))
local client = vim.lsp.get_client_by_id(id)
assert(vim.wait(5000, function()
  return client.initialized
end, 10))
local opened, fallback
local links = require("lsp-tools.links")
links.setup({
  open = function(uri)
    opened = uri
  end,
  fallback = function()
    fallback = true
  end,
})
vim.api.nvim_win_set_cursor(0, { 3, 15 })
links.open()
assert(vim.wait(5000, function()
  return opened ~= nil or fallback
end, 10))
assert(
  opened == "https://example.com/semantic",
  "real TeXquill semantic target opens: " .. tostring(opened)
)
assert(not fallback)
links.disable()
client:stop(true)
vim.fn.delete(directory, "rf")
print("links integration: real TeXquill documentLink target passed")
vim.cmd("qa!")
