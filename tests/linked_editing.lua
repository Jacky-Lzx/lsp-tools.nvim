vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local linked = require("lsp-tools.linked_editing")
local buf = vim.api.nvim_get_current_buf()
local client = { id = 10, name = "html", offset_encoding = "utf-16" }
function client:stop() end
vim.lsp.linked_editing_range.enable = function() end
local calls, count = {}, 0
function client:supports_method()
  return true
end
function client:request(_, params, callback)
  calls[#calls + 1] = { callback = callback, params = params }
  return true, #calls
end
function client:cancel_request(id)
  calls[id].cancelled = true
end
vim.lsp.get_clients = function()
  return { client }
end
local ns = vim.api.nvim_create_namespace("lsp-tools.linked_editing:10:" .. buf)
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀tag tag" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
linked.setup({ request_timeout = 20 })
local result = {
  wordPattern = "[a-zA-Z0-9_-]+",
  ranges = {
    { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 5 } },
    { start = { line = 0, character = 6 }, ["end"] = { line = 0, character = 9 } },
  },
}
calls[#calls].callback(nil, result)
check(#marks() == 2 and marks()[1][3] == 4, "UTF-16 ranges map to byte positions")
vim.api.nvim_exec_autocmds("CursorMoved", {})
local call = calls[#calls]
vim.api.nvim_win_set_cursor(0, { 1, 8 })
call.callback(nil, result)
check(#marks() == 2, "stale reply does not replace tracked ranges")
vim.api.nvim_exec_autocmds("CursorMoved", {})
call = calls[#calls]
vim.api.nvim_exec_autocmds("BufLeave", { buffer = buf })
call.callback(nil, result)
check(#marks() == 0 and call.cancelled, "leaving clears and cancels session")
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
call = calls[#calls]
call.callback(nil, { ranges = { result.ranges[1], result.ranges[1] } })
check(#marks() == 0, "overlapping ranges are rejected")
vim.api.nvim_exec_autocmds("CursorMoved", {})
call = calls[#calls]
vim.wait(50, function()
  return call.cancelled
end, 1)
check(call.cancelled, "linked requests time out")
call.callback(nil, result)
check(#marks() == 0, "timeout rejects late results")
linked.disable()
check(#marks() == 0, "disable clears sessions")
print(("linked editing: %d assertions passed"):format(count))
vim.cmd("qa!")
