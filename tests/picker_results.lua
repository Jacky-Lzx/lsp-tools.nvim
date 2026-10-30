vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
tools.setup({
  results = { auto_preview = false },
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local api, count = vim.api, 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local directory = vim.fn.tempname()
api.nvim_buf_set_name(buf, directory .. "/source.lua")
api.nvim_buf_set_lines(buf, 0, -1, false, { "😀alpha", "beta" })
local first = { buf = buf, file = "source.lua", pos = { 1, 4 }, line = "alpha" }
local second = { file = "other.lua", pos = { 2, 1 }, text = "beta" }
local function picker(selected)
  return {
    main = win,
    opts = { source = "grep" },
    selected = function()
      return selected or {}
    end,
    items = function()
      return { first, second }
    end,
    cwd = function()
      return directory
    end,
    close = function(self)
      self.closed = true
    end,
  }
end
local function import(p, opts)
  local token = tools.from_picker(p, opts)
  check(p.closed and token.active, "picker closes before deferred import")
  assert(vim.wait(1000, function()
    return not token.active
  end, 5))
  return require("lsp-tools.results").current("picker")
end
local results = require("lsp-tools.results")
local v = import(picker({ first }))
check(#v.items == 1 and v.items[1].pos[2] == 4, "smart imports selection with UTF8 byte column")
check(v.ctx.win == win and api.nvim_get_current_win() == win, "source focus and context preserved")
check(
  v.items[1].filename == directory .. "/source.lua",
  "relative file resolves against picker cwd"
)
v = import(picker(), { append = true })
check(#v.items == 3, "append retains prior snapshot and imports all filtered items")
results.close("picker")
v = import(picker({ second }), { type = "all", add = true })
check(#v.items == 5, "append also restores a closed snapshot; all overrides selection")
v = import(picker(), { type = "selected" })
check(#v.items == 0, "explicit empty selection remains empty")
local p = picker()
p.items = function()
  return {
    { text = "command", name = "build" },
    { file = "/private/tmp/absolute.lua", cwd = "/other" },
  }
end
v = import(p)
check(
  not v.items[1].uri and v.items[2].filename == "/private/tmp/absolute.lua",
  "unlocated rows stay unlocated and absolute paths ignore cwd"
)
results.select(v, v.items[1].id)
check(not results.jump(v), "non-location items cannot open a guessed file")
results.close("picker")
local token = tools.from_picker(picker())
token.cancel()
vim.wait(10, function()
  return false
end, 1)
check(not results.current("picker"), "cancelled scheduled import opens no window")
token = tools.from_picker(picker())
tools.setup({ results = false })
vim.wait(10, function()
  return false
end, 1)
check(not token.active and not results.current("picker"), "disable cancels deferred imports")
print(("picker results: %d assertions passed"):format(count))
vim.cmd("qa!")
