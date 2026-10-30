vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local bulb = require("lsp-tools.lightbulb")
local ns = vim.api.nvim_create_namespace("lsp-tools.lightbulb")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo", "next" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
local calls, count = {}, 0
local client = { id = 1, name = "test", offset_encoding = "utf-16" }
function client:request(method, params, callback)
  assert(method == "textDocument/codeAction")
  calls[#calls + 1] = { params = params, callback = callback }
  return true, #calls
end
function client:cancel_request(id)
  calls[id].cancelled = true
end
vim.lsp.get_clients = function(opts)
  assert(opts.method == "textDocument/codeAction")
  return { client }
end
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end
local function refresh()
  local n = #calls
  vim.api.nvim_exec_autocmds("CursorMoved", {})
  assert(vim.wait(100, function()
    return #calls > n
  end, 1))
  return calls[#calls]
end
bulb.setup({ debounce = 1, request_timeout = 30 })
local call = refresh()
check(
  call.params.range.start.character == 2 and call.params.context.triggerKind == 2,
  "Unicode position and automatic trigger"
)
call.callback(nil, { { title = "disabled", disabled = { reason = "no" } } })
check(#marks() == 0, "disabled actions do not light up")
call = refresh()
call.callback(nil, { { title = "fix", data = {} } })
check(
  #marks() == 1 and marks()[1][4].virt_text[1][1] == "",
  "unresolved actions display without resolve"
)
call = refresh()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
call.callback(nil, { { title = "old" } })
check(#marks() == 0, "cursor movement rejects late replies")
call = refresh()
vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "edited" })
call.callback(nil, { { title = "old" } })
check(#marks() == 0, "buffer edits reject late replies")
call = refresh()
vim.wait(60, function()
  return call.cancelled
end, 1)
check(call.cancelled and #marks() == 0, "timeout cancels requests")
call.callback(nil, { { title = "late" } })
check(#marks() == 0, "timed out responses stay discarded")
bulb.setup({ sign = true, text = "!" })
call = refresh()
call.callback(nil, { { title = "fix" } })
check(marks()[1][4].sign_text:find("!", 1, true), "sign rendering")
bulb.disable()
check(#marks() == 0, "disable clears owned decoration")
check(
  #require("lsp-tools.request").history(buf) >= 3,
  "request outcomes are available for inspection"
)
print(("lightbulb: %d assertions passed"):format(count))
vim.cmd("qa!")
