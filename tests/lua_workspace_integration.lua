vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT or vim.fn.getcwd())
vim.opt.rtp:prepend(
  vim.env.LSPCONFIG_DIR or vim.fn.expand("~/.local/share/nvim/lazy/nvim-lspconfig")
)
local api = vim.api
local folder = vim.fn.tempname()
vim.fn.mkdir(folder .. "/project", "p")
vim.fn.mkdir(folder .. "/plugins/fixture/lua/on_demand_fixture", "p")
folder = assert(vim.uv.fs_realpath(folder))
local library = folder .. "/plugins/fixture/lua/on_demand_fixture/init.lua"
vim.fn.writefile(
  { "local M = {}", "---@return integer", "function M.answer() return 42 end", "return M" },
  library
)
local function run()
  api.nvim_buf_set_name(0, folder .. "/project/main.lua")
  api.nvim_buf_set_lines(0, 0, -1, false, {
    'local lib = require("on_demand_fixture")',
    "local answer = lib.answer()",
    "print(vim.api.nvim_get_current_buf(), answer)",
  })
  vim.bo.filetype = "lua"
  local buf = api.nvim_get_current_buf()
  local tools = require("lsp-tools")
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = false,
    lua = { plugin_roots = { folder .. "/plugins" }, debounce = 5 },
    servers = {
      lua_ls = {
        cmd = { vim.env.LUA_LS or "lua-language-server" },
        root_dir = folder .. "/project",
        settings = { Lua = { telemetry = { enable = false } } },
      },
    },
  })
  local client
  assert(
    vim.wait(15000, function()
      client = vim.lsp.get_clients({ name = "lua_ls", bufnr = buf })[1]
      return client
        and client.initialized
        and vim.tbl_contains(
          vim.tbl_get(client.settings, "Lua", "workspace", "library") or {},
          folder .. "/plugins/fixture/lua"
        )
    end, 20),
    "LuaLS attaches and receives the required library"
  )
  local response
  local params =
    { textDocument = { uri = vim.uri_from_bufnr(buf) }, position = { line = 1, character = 20 } }
  assert(
    vim.wait(15000, function()
      response = client:request_sync("textDocument/definition", params, 2000, buf)
      local result = response and response.result
      local location = result and (result[1] or result)
      return location and (location.uri or location.targetUri) == vim.uri_from_fname(library)
    end, 50),
    "actual LuaLS resolves an initially unloaded plugin module"
  )
  local hover = client:request_sync("textDocument/hover", params, 5000, buf)
  assert(
    hover and hover.result and vim.inspect(hover.result):find("integer", 1, true),
    "LuaLS returns plugin type information"
  )
  assert(not package.loaded.on_demand_fixture and not package.loaded.lazydev)
  tools.setup({ lua = false, servers = false })
  assert(vim.wait(5000, function()
    return #vim.lsp.get_clients() == 0
  end, 10))
  assert(vim.v.errmsg == "", vim.v.errmsg)
end
local ok, err = xpcall(run, debug.traceback)
for _, client in ipairs(vim.lsp.get_clients()) do
  client:stop(true)
end
vim.wait(1000, function()
  return #vim.lsp.get_clients() == 0
end, 10)
vim.fn.delete(folder, "rf")
local message = ok
    and "Lua workspace integration: real LuaLS definition, plugin return types and server shutdown passed"
  or err
if vim.env.LSP_TOOLS_TEST_TMP then
  vim.fn.writefile({ message }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
end
print(message)
vim.cmd(ok and "qa!" or "cquit 1")
