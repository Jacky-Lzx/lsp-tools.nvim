vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local links = require("lsp-tools.links")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀link tail" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
local calls, clients, opened, fallback, count = {}, {}, {}, 0, 0
local function client(id, encoding)
  local c = { id = id, name = "client" .. id, offset_encoding = encoding }
  function c:request(method, params, callback)
    calls[#calls + 1] = { method = method, params = params, callback = callback }
    return true, #calls
  end
  function c:cancel_request(id)
    calls[id].cancelled = true
  end
  function c:supports_method()
    return true
  end
  function c:stop() end
  return c
end
clients = { client(1, "utf-16") }
vim.lsp.get_clients = function()
  return clients
end
links.setup({
  request_timeout = 20,
  open = function(target)
    opened[#opened + 1] = target
  end,
  fallback = function()
    fallback = fallback + 1
  end,
})
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local link = {
  range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 6 } },
  target = "https://example.com/中文",
}
links.open()
calls[#calls].callback(nil, { link })
check(opened[1] == link.target and fallback == 0, "server target opens at UTF-16 cursor")
links.open()
local unresolved = vim.deepcopy(link)
unresolved.target = nil
unresolved.data = { id = 1 }
calls[#calls].callback(nil, { unresolved })
check(calls[#calls].method == "documentLink/resolve", "resolve missing target")
calls[#calls].callback(nil, link)
check(#opened == 2, "resolved target opens")
links.open()
calls[#calls].callback(nil, {})
check(fallback == 1, "empty results fall back once")
links.open()
local call = calls[#calls]
vim.api.nvim_win_set_cursor(0, { 1, 8 })
call.callback(nil, { link })
check(#opened == 2 and fallback == 1, "moved cursor cannot open a late link")
vim.api.nvim_win_set_cursor(0, { 1, 4 })
links.open()
call = calls[#calls]
vim.wait(60, function()
  return call.cancelled
end, 1)
check(call.cancelled and fallback == 2, "timeout cancels and falls back")
clients = { client(1, "utf-16"), client(2, "utf-8") }
local choice
vim.ui.select = function(items, _, callback)
  check(#items == 2, "ambiguous targets offer a choice")
  choice = callback
end
links.open()
calls[#calls - 1].callback(nil, { link })
local other = vim.deepcopy(link)
other.target = "https://example.com/other"
other.range.start.character = 4
other.range["end"].character = 8
calls[#calls].callback(nil, { other })
choice(nil)
vim.wait(5, function()
  return false
end, 1)
check(#opened == 2 and fallback == 2, "cancelled choice does not open or fall back")
links.open()
call = calls[#calls]
links.disable()
check(call.cancelled, "disable cancels pending requests")
print(("links: %d assertions passed"):format(count))
vim.cmd("qa!")
