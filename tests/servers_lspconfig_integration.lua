vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local provider = assert(vim.env.LSPCONFIG_DIR)
assert(
  vim.fn.filereadable(provider .. "/lsp/lua_ls.lua") == 1,
  "LSPCONFIG_DIR must contain lsp/lua_ls.lua"
)
vim.opt.rtp:prepend(provider)
local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
vim.fn.writefile({ "{}" }, project .. "/.luarc.json")
project = assert(vim.uv.fs_realpath(project))
local function run()
  local tools = require("lsp-tools")
  vim.api.nvim_buf_set_name(0, project .. "/main.lua")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local greeting = 'hello'", "print(greeting)" })
  vim.bo.filetype = "lua"
  local buf = vim.api.nvim_get_current_buf()
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = false,
    servers = { lua_ls = { cmd = { vim.env.LUA_LS or "lua-language-server" } } },
  })
  local function clients()
    return vim.lsp.get_clients({ name = "lua_ls", bufnr = buf })
  end
  assert(
    vim.wait(10000, function()
      return #clients() == 1 and clients()[1].initialized
    end, 10),
    "actual LuaLS attaches through upstream config"
  )
  local client = clients()[1]
  assert(client.root_dir == project, "upstream LuaLS root policy preserved")
  local response = client:request_sync("textDocument/rename", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = 8 },
    newName = "message",
  }, 10000, buf)
  assert(response and not response.err and response.result, "actual LuaLS returns semantic rename")
  vim.lsp.util.apply_workspace_edit(response.result, client.offset_encoding)
  assert(
    vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "local message = 'hello'",
    "real rename edits declaration"
  )
  assert(
    vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "print(message)",
    "real rename edits reference"
  )
  assert(tools.server_status(buf)[1].managed, "upstream config managed by lsp-tools")
  assert(not package.loaded["lspconfig"], "legacy lspconfig never required")
  tools.setup({ servers = false })
  assert(
    vim.wait(5000, function()
      return #clients() == 0
    end, 10),
    "managed LuaLS exits"
  )
  assert(vim.v.errmsg == "", vim.v.errmsg)
end
local ok, err = xpcall(run, debug.traceback)
for _, client in ipairs(vim.lsp.get_clients()) do
  client:stop(true)
end
vim.wait(1000, function()
  return #vim.lsp.get_clients() == 0
end, 10)
vim.fn.delete(project, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(
  "server integration: actual nvim-lspconfig LuaLS config, root detection, semantic rename and shutdown passed"
)
vim.cmd("qa!")
