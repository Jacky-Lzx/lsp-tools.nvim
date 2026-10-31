vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api = vim.api
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, -1, false, { "original" })
local calls, applied, cancelled = {}, 0, 0
local client = { offset_encoding = "utf-16" }
function client:supports_method()
  return true
end
function client:request(_, _, callback)
  calls[#calls + 1] = callback
  return true, #calls
end
function client:cancel_request() end
vim.lsp.get_client_by_id = function()
  return client
end
vim.lsp.util.apply_workspace_edit = function()
  applied = applied + 1
end
vim.notify = function() end
local picker = require("lsp-tools.code_actions.picker")
local function open()
  return picker.open({
    { action = { title = "First" }, ctx = { client_id = 1, bufnr = buf } },
    { action = { title = "Second" }, ctx = { client_id = 1, bufnr = buf } },
  }, {
    format_item = function(entry)
      return entry.action.title
    end,
  }, function()
    cancelled = cancelled + 1
  end, { resolve_timeout = 500, backend = "vim", delta = {}, picker = {} })
end
local function flush()
  vim.wait(20, function()
    return false
  end, 1)
end
local p = open()
p:confirm()
local first = calls[1]
p:move(1)
p:move(-1)
first(nil, { title = "First", edit = { changes = {} } })
flush()
assert(applied == 0 and not p.closed, "moving away and back invalidates pending confirmation")
p:confirm()
flush()
assert(
  applied == 1 and p.closed and cancelled == 0,
  "cached action applies once without cancellation"
)
p = open()
api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
p:confirm()
calls[#calls](nil, { title = "First", edit = { changes = {} } })
flush()
assert(
  applied == 1 and not p.closed and not p.confirmation,
  "source edits reject confirmation and keep the picker usable"
)
p:close()
assert(cancelled == 1)
p = open()
local old = p
p = open()
assert(
  old.closed and not p.closed and cancelled == 2,
  "replacement cleans up only the previous transaction"
)
p:close()
assert(cancelled == 3 and not require("lsp-tools.selection").current())
p = open()
local late = calls[#calls]
p:confirm()
p:move(1)
p:confirm()
calls[#calls](nil, { title = "Second", edit = { changes = {} } })
flush()
assert(
  p.closed and applied == 2 and cancelled == 3,
  "a new selection can confirm while an obsolete resolve is pending"
)
late(nil, { title = "First", edit = { changes = {} } })
flush()
assert(applied == 2, "late obsolete confirmation cannot apply after the new choice")
assert(
  not package.loaded["snacks"] and not package.loaded["snacks.picker"],
  "code actions use no Snacks UI"
)
print(
  "selection adapter: stale async confirmation, reject/retry, replacement, apply and cancellation passed without Snacks"
)
vim.cmd("qa!")
