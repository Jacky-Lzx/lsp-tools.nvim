vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
tools.setup({
  results = { debounce = 1, auto_preview = false },
  diagnostics = true,
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
local function buffer(path)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "second", "third" })
  return buf
end
local one, two, other =
  buffer(root .. "/one.lua"), buffer(root .. "/two.lua"), buffer(root .. "-other/outside.lua")
vim.api.nvim_win_set_buf(0, one)
local ns, lint =
  vim.api.nvim_create_namespace("test-server"), vim.api.nvim_create_namespace("test-lint")
vim.diagnostic.set(
  ns,
  one,
  { { lnum = 0, col = 0, message = "server error", severity = 1, code = "E1", source = "server" } }
)
vim.diagnostic.set(
  lint,
  one,
  { { lnum = 0, col = 0, message = "lint warning", severity = 2, source = "lint" } }
)
vim.diagnostic.set(ns, two, { { lnum = 1, col = 0, message = "other error", severity = 1 } })
vim.diagnostic.set(ns, other, { { lnum = 2, col = 0, message = "outside", severity = 1 } })
local v = tools.diagnostics({ root = root, focus = false })
local results = require("lsp-tools.results")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function key(lhs)
  vim.api.nvim_set_current_win(v.win)
  vim.fn.maparg(lhs, "n", false, true).callback()
end
check(#v.items == 4, "all received diagnostics includes non-LSP producers")
key("S")
check(v.scope == "project" and #v.items == 3, "project scope excludes path-prefix siblings")
key("S")
check(v.scope == "buffer" and #v.items == 2, "buffer scope retains every namespace")
local warning
for _, item in ipairs(v.items) do
  if item.source == "lint" then
    warning = item
  end
end
results.select(v, warning.id)
key("d")
local detail = require("lsp-tools.panel").get("diagnostics")
check(
  detail.items[detail.index].message == "lint warning",
  "details select the exact diagnostic among overlapping ranges"
)
require("lsp-tools.panel").close(detail)
key("F")
vim.diagnostic.set(ns, one, {})
vim.wait(10, function()
  return false
end, 1)
check(#v.items == 2, "pinned overview keeps its snapshot")
key("r")
check(#v.items == 1 and v.items[1].source == "lint", "manual refresh updates a pinned snapshot")
key("F")
vim.diagnostic.set(lint, one, {})
check(
  vim.wait(100, function()
    return #v.items == 0
  end, 1),
  "open overview follows diagnostic updates"
)
results.close("diagnostics")
check(not vim.api.nvim_win_is_valid(v.win), "closing releases overview")
vim.fn.delete(root, "rf")
print(("diagnostic results: %d assertions passed"):format(count))
vim.cmd("qa!")
