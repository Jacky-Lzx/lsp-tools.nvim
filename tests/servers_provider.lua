vim.opt.runtimepath:prepend(assert(vim.env.LSP_TOOLS_ROOT))
local servers = require("lsp-tools.servers")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/lsp", "p")
vim.fn.writefile(
  { "return {cmd={'fake-server'}, filetypes={'providerft'}, root_markers={'.git'}}" },
  dir .. "/lsp/provider_fixture.lua"
)
local calls = 0
local source = function()
  calls = calls + 1
  vim.opt.runtimepath:prepend(dir)
end
local pending = servers.prepare(
  { provider_fixture = true },
  "filetype",
  { provider_fixture = { "providerft" } },
  source
)
servers.apply(pending)
assert(calls == 0, "provider ran while registering filetype hints")
vim.bo.filetype = "otherft"
assert(calls == 0)
local start = vim.lsp.start
vim.lsp.start = function()
  return nil
end
vim.bo.filetype = "providerft"
assert(calls == 1 and vim.lsp.is_enabled("provider_fixture"))
servers.activate(0)
servers.ensure_provider()
assert(calls == 1, "provider was initialized more than once")
local owned = select(2, servers.configuration())
local ok = pcall(servers.prepare, {}, "filetype", {}, true)
assert(not ok and vim.deep_equal(owned, select(2, servers.configuration())))
servers.apply(servers.prepare(false))
vim.lsp.start = start
vim.opt.runtimepath:remove(dir)
vim.fn.delete(dir, "rf")
print(
  "server provider: deferred registration, native resolution, once-only loading and validation passed"
)
