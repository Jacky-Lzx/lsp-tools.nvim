vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local diagnostics = require("lsp-tools.diagnostics")
local panel = require("lsp-tools.panel")
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.o.columns = 160
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "other", "third" })
local ns = vim.api.nvim_create_namespace("test-diagnostics")
local original = {
  range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
  message = "full\nmessage",
  severity = 1,
  code = "E1",
  relatedInformation = {
    {
      message = "related",
      location = {
        uri = vim.uri_from_bufnr(buf),
        range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 1 } },
      },
    },
  },
}
local first = {
  lnum = 0,
  col = 0,
  end_col = 5,
  message = original.message,
  severity = 1,
  code = "E1",
  source = "test",
  user_data = { lsp = original },
}
local second = { lnum = 2, col = 0, message = "second", severity = 1 }
vim.diagnostic.set(ns, buf, { first, second })
diagnostics.setup()
local s = assert(diagnostics.open({ filter = { severity = 1 } }))
local count = 0
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
check(
  text():find("E1", 1, true) and text():find("full\nmessage", 1, true),
  "complete diagnostic and code"
)
check(#s.related == 1, "related information retained")
key("<CR>")
check(
  vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_cursor(win)[1] == 3,
  "related location opens in source"
)
vim.api.nvim_set_current_win(s.win)
key("<LocalLeader>b")
check(vim.api.nvim_win_get_cursor(win)[1] == 1, "return restores original diagnostic")
vim.api.nvim_set_current_win(s.win)
key("]d")
check(
  s.index == 2 and vim.api.nvim_win_get_cursor(win)[1] == 3,
  "next diagnostic keeps side window"
)
key("[d")
local applied
package.loaded["lsp-tools.code_actions"] = {
  pick = function(entries, callback)
    applied = callback
    check(#entries == 1, "selected diagnostic requests actions")
  end,
}
local client = { id = 7, name = "test", offset_encoding = "utf-16" }
function client:request(_, params, callback)
  check(
    params.range.start.character == 0 and params.range["end"].character == 5,
    "selected diagnostic range"
  )
  callback(nil, { { title = "Fix" } })
  return true, 1
end
function client:cancel_request() end
function client:stop() end
vim.lsp.get_clients = function()
  return { client }
end
check(diagnostics.fix(s, true), "fix workflow starts")
applied()
check(s.advance ~= nil, "fix waits for server diagnostics")
vim.diagnostic.set(ns, buf, { second })
check(s.advance == nil and s.items[s.index].message == "second", "confirmed refresh advances")
vim.diagnostic.set(ns, buf, { first, second })
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, { 1, 0 })
require("lsp-tools.panel").close(s)
s = diagnostics.open()
check(diagnostics.fix(s, true), "another fix starts")
vim.diagnostic.set(ns, buf, { second })
applied()
check(
  s.advance == nil and s.items[s.index].message == "second",
  "synchronous diagnostic refresh before apply callback still advances"
)
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
check(not diagnostics.fix(s, false), "stale source refuses a new fix")
diagnostics.disable()
check(not panel.alive(s), "disable closes owned panel")
print(("diagnostics: %d assertions passed"):format(count))
vim.cmd("qa!")
