vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local root = assert(vim.env.LSP_TOOLS_TEST_TMP)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, root .. "/locations.lua")
vim.api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  { "local function alpha(x) return x end", "local value = alpha(1)", "print(alpha(value))" }
)
vim.bo.filetype = "lua"
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
local id = assert(vim.lsp.start({
  name = "locations-real-luals",
  cmd = {
    "lua-language-server",
    "--logpath=" .. root .. "/log",
    "--metapath=" .. root .. "/meta",
  },
  root_dir = root,
  capabilities = capabilities,
  settings = { Lua = { workspace = { checkThirdParty = false } } },
}))
local client = vim.lsp.get_client_by_id(id)
local function wait(test, message)
  assert(vim.wait(15000, test, 10), message)
end
wait(function()
  return client.initialized
end, "LuaLS initializes")
vim.api.nvim_win_set_cursor(0, { 2, 15 })
local ready, pending = false, false
wait(function()
  if not ready and not pending then
    pending = true
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    params.context = { includeDeclaration = false }
    client:request("textDocument/references", params, function(err, result)
      ready = not err and result and #result == 2
      pending = false
    end, buf)
  end
  return ready
end, "real references indexed")
local tools = require("lsp-tools")
tools.setup({
  results = { auto_preview = false },
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local v = tools.locations({ method = "references", include_declaration = false })
wait(function()
  return #v.items == 2
end, "persistent references show both semantic uses")
local results = require("lsp-tools.results")
results.select(v, v.items[2].id)
vim.api.nvim_set_current_win(v.win)
assert(results.jump(v) and vim.api.nvim_win_get_cursor(0)[1] == 3)
results.close("lsp")
v = tools.locations({ method = "definitions" })
wait(function()
  return #v.items == 1
end, "real definition result arrives")
vim.api.nvim_set_current_win(v.win)
assert(results.jump(v) and vim.api.nvim_win_get_cursor(0)[1] == 1)
results.close("lsp")
client:stop(true)
wait(function()
  return vim.lsp.get_client_by_id(id) == nil
end, "server exits")
print(
  "location results integration: real LuaLS references, definitions and persistent-list source jumps passed"
)
vim.cmd("qa!")
