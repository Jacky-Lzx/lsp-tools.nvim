vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT or vim.fn.getcwd())
local api, uv = vim.api, vim.uv
local initial = require("lsp-tools.languages.lua")
initial.setup({})
assert(
  not package.loaded["lsp-tools.languages.lua.resolve"]
    and not package.loaded["lsp-tools.languages.lua.scan"],
  "empty editor must not load indexing or scanning"
)
initial.disable()
local folder = vim.fn.tempname()
vim.fn.mkdir(folder, "p")
folder = assert(uv.fs_realpath(folder))
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines or { "error('must never execute plugin source')" }, path)
end
local plugins = folder .. "/plugins"
for _, name in ipairs({ "needed", "other", "annotation", "conditional" }) do
  write(plugins .. "/" .. name .. "/lua/" .. name .. "/init.lua")
end
local function buffer(name, lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, folder .. "/" .. name .. "/main.lua")
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "lua"
  return buf
end
local a = buffer("a", {
  'local real = require("needed")',
  "local quoted = \"require('other')\"",
  '-- require("other")',
  '--[=[ require("other") ]=]',
  '---@module "annotation"',
  "local uv = vim.uv",
})
local b = buffer("b", { 'return require "other"' })
local c = buffer("c", { 'return require "other"' })
write(folder .. "/c/.luarc.json", { "{}" })
local scan = require("lsp-tools.languages.lua.scan")
assert(
  vim.deep_equal(
    scan.modules(table.concat(api.nvim_buf_get_lines(a, 0, -1, false), "\n")),
    { needed = true, annotation = true }
  )
)
assert(
  vim.deep_equal(
    scan.modules(
      "local x = pcall(require, 'nested.mod'); object.require('no'); local x = [[require('no')]]"
    ),
    { ["nested.mod"] = true }
  )
)
local function client(id, buf, name)
  local root = folder .. "/" .. name
  vim.fn.mkdir(root, "p")
  return {
    id = id,
    name = "lua_ls",
    root_dir = root,
    initialized = true,
    attached_buffers = { [buf] = true },
    settings = {
      Lua = {
        runtime = { version = "Lua 5.4" },
        workspace = { library = { "/existing" } },
        diagnostics = { globals = { "user_global" } },
      },
    },
    calls = 0,
    is_stopped = function()
      return false
    end,
    notify = function(self, method)
      assert(method == "workspace/didChangeConfiguration")
      self.calls = self.calls + 1
    end,
  }
end
local first, second, skipped = client(1, a, "a"), client(2, b, "b"), client(3, c, "c")
local baseline = vim.deepcopy(first.settings)
local original = vim.lsp.get_clients
local available = { first, second, skipped }
vim.lsp.get_clients = function()
  return available
end
local lua = require("lsp-tools.languages.lua")
local config = {
  plugin_roots = { plugins },
  debounce = 1,
  library = {
    { path = "${3rd}/luv/library", words = { "vim%.uv" } },
    { path = "conditional", mods = { "needed" } },
  },
}
lua.setup(config)
local function has(c, suffix)
  return vim.tbl_contains(c.settings.Lua.workspace.library, suffix)
end
assert(has(first, plugins .. "/needed/lua") and has(first, plugins .. "/annotation/lua"))
assert(has(first, plugins .. "/conditional/lua") and has(first, "${3rd}/luv/library"))
assert(not has(first, plugins .. "/other/lua") and not has(second, plugins .. "/needed/lua"))
assert(has(first, "/existing") and has(first, vim.env.VIMRUNTIME .. "/lua"))
assert(first.settings.Lua.runtime.version == "Lua 5.4")
assert(skipped.calls == 0, "project .luarc is respected by default")
local calls = first.calls
lua.refresh()
assert(calls == first.calls, "unchanged settings do not notify")
api.nvim_buf_set_lines(a, 0, -1, false, { 'local x = require("late")' })
write(plugins .. "/late/lua/late.lua")
lua.refresh(true)
assert(has(first, plugins .. "/late/lua") and not has(first, plugins .. "/needed/lua"))
assert(not has(first, "${3rd}/luv/library"), "unused conditional libraries are released")
api.nvim_buf_set_lines(a, 0, -1, false, { 'return require("needed")' })
api.nvim_exec_autocmds("TextChanged", { buffer = a })
assert(vim.wait(1000, function()
  return has(first, plugins .. "/needed/lua")
end, 10))
second.settings.Lua.diagnostics.external = true
available = { first, skipped }
lua.refresh()
assert(
  second.settings.Lua.diagnostics.external
    and vim.deep_equal(second.settings.Lua.workspace.library, { "/existing" })
)
lua.disable()
assert(vim.deep_equal(first.settings, baseline), "disable restores preexisting settings exactly")
assert(vim.fn.exists(":LspToolsLua") == 0)
config.enabled = true
lua.setup(config)
assert(
  skipped.calls > 0 and has(skipped, plugins .. "/other/lua"),
  "explicit enable can supplement .luarc projects"
)
lua.disable()
vim.lsp.get_clients = original
local tools = require("lsp-tools")
tools.setup({
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
  lua = config,
})
assert(tools.configuration().enabled.lua)
tools.setup({ lua = false })
assert(not tools.configuration().enabled.lua and vim.fn.exists(":LspToolsLua") == 0)
assert(not package.loaded.needed and not package.loaded.other and not package.loaded.lazydev)
vim.fn.delete(folder, "rf")
print(
  "Lua libraries: lexical scanning, isolated clients, conditional types, changedtick/debounce, refresh, .luarc policy and teardown passed"
)
