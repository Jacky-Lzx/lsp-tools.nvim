vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local hover = require("lsp-tools.hover")
local panel = require("lsp-tools.panel")
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.o.columns = 160
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo", "bar" })
vim.api.nvim_win_set_cursor(win, { 1, 4 })
local calls, count = {}, 0
local client = { id = 3, name = "documentation", offset_encoding = "utf-16" }
function client:request(method, params, callback)
  assert(method == "textDocument/hover")
  calls[#calls + 1] = { callback = callback, params = params }
  return true, #calls
end
function client:cancel_request(id)
  calls[id].cancelled = true
end
function client:stop() end
vim.lsp.get_clients = function()
  return { client }
end
vim.notify = function() end
hover.setup({ debounce = 1, request_timeout = 25 })
local s = hover.open()
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(s.out, 0, -1, false), "\n")
end
local function key(lhs)
  vim.api.nvim_set_current_win(s.win)
  vim.fn.maparg(lhs, "n", false, true).callback()
end
check(calls[1].params.position.character == 2, "hover uses per-client encoding")
calls[1].callback(
  nil,
  {
    contents = {
      kind = "markdown",
      value = "```lua\nfoo(x)\n```\n[Docs](https://example.com/docs)",
    },
  }
)
check(
  text():find("foo(x)", 1, true) and vim.bo[s.out].filetype == "markdown",
  "Markdown content survives in pinned buffer"
)
key("y")
check(vim.fn.getreg('"'):find("foo(x)", 1, true), "copy documentation")
local opened
vim.ui.open = function(url)
  opened = url
end
for row, line in ipairs(vim.api.nvim_buf_get_lines(s.out, 0, -1, false)) do
  if line:find("[Docs]", 1, true) then
    vim.api.nvim_win_set_cursor(s.win, { row, 1 })
  end
end
key("gx")
check(opened == "https://example.com/docs", "open Markdown documentation URL")
key("b")
vim.api.nvim_win_set_cursor(win, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
check(
  #calls == 1 and text():find("foo(x)", 1, true),
  "pinned documentation does not request on movement"
)
key("f")
calls[#calls].callback(nil, { contents = "bar docs" })
check(s.follow and text():find("bar docs", 1, true), "follow mode refreshes the source position")
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 1, 4 })
local n = #calls
vim.api.nvim_exec_autocmds("CursorMoved", {})
assert(vim.wait(100, function()
  return #calls > n
end, 1))
local pending = calls[#calls]
vim.api.nvim_win_set_cursor(win, { 2, 0 })
pending.callback(nil, { contents = "stale" })
check(not text():find("stale", 1, true), "follow ignores stale cursor replies")
key("r")
pending = calls[#calls]
hover.disable()
check(pending.cancelled and not panel.alive(s), "disable cancels requests and closes pinned window")
print(("hover: %d assertions passed"):format(count))
vim.cmd("qa!")
