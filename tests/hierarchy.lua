vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local hierarchy = require("lsp-tools.hierarchy")
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.o.columns = 160
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀root()", "child()", "root()" })
local uri = vim.uri_from_bufnr(buf)
local function item(name, row, col)
  local range = {
    start = { line = row, character = col or 0 },
    ["end"] = { line = row, character = (col or 0) + #name },
  }
  return {
    name = name,
    kind = 12,
    uri = uri,
    range = range,
    selectionRange = range,
    data = { opaque = name },
  }
end
local root, child = item("root", 0, 2), item("child", 1)
local calls, count = {}, 0
local client = {
  id = 1,
  name = "hierarchy",
  offset_encoding = "utf-16",
  rpc = {
    is_closing = function()
      return true
    end,
  },
}
function client:supports_method()
  return true
end
function client:request(method, params, callback)
  calls[#calls + 1] = { method = method, params = params, callback = callback }
  return true, #calls
end
function client:cancel_request(id)
  calls[id].cancelled = true
end
function client:stop() end
vim.lsp.get_clients = function()
  return { client }
end
vim.lsp.get_client_by_id = function()
  return client
end
local function check(value, message)
  assert(value, message)
  count = count + 1
end
hierarchy.setup({ request_timeout = 25 })
local s = assert(hierarchy.open("call"))
calls[#calls].callback(nil, { root })
check(
  calls[#calls].method == "callHierarchy/incomingCalls"
    and calls[#calls].params.item.data.opaque == "root",
  "lazy calls preserve opaque server data"
)
calls[#calls].callback(nil, { { from = child, fromRanges = { child.range } } })
local n = s.trees.incoming[1].children[1]
check(n.item.name == "child" and n.sites[1].uri == uri, "incoming caller and call sites")
local function key(lhs, row)
  vim.api.nvim_set_current_win(s.win)
  if row then
    vim.api.nvim_win_set_cursor(s.win, { row, 0 })
  end
  vim.fn.maparg(lhs, "n", false, true).callback()
end
key("l", 6)
calls[#calls].callback(nil, { { from = root, fromRanges = { root.range } } })
check(n.children[1].cycle, "recursive call is marked as cycle")
local total = #calls
key("l", 7)
check(#calls == total, "cycles never expand recursively")
key("h", 6)
check(not n.expanded, "collapse keeps child state")
key("l", 6)
check(n.expanded and #calls == total, "expand reuses cached children")
key("d")
check(calls[#calls].method == "callHierarchy/outgoingCalls", "direction switches lazily")
calls[#calls].callback(nil, { { to = child, fromRanges = { root.range } } })
key("d")
check(
  s.trees.incoming[1].children[1] == n and n.expanded,
  "direction switches preserve expanded tree"
)
key("<CR>", 5)
check(
  vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_cursor(win)[2] == 4,
  "symbol jump uses UTF-16 encoding"
)
hierarchy.disable()
vim.api.nvim_set_current_win(win)
hierarchy.setup({ request_timeout = 25 })
s = hierarchy.open("type", { direction = "subtypes" })
calls[#calls].callback(nil, { root })
check(
  calls[#calls].method == "typeHierarchy/subtypes",
  "type subtypes use proper protocol: " .. calls[#calls].method .. " " .. tostring(s.status)
)
calls[#calls].callback(nil, { child })
key("d")
check(calls[#calls].method == "typeHierarchy/supertypes", "type supertypes supported")
local pending = calls[#calls]
vim.wait(60, function()
  return pending.cancelled
end, 1)
check(pending.cancelled and s.status:find("timed out", 1, true), "child requests time out visibly")
vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "edited" })
total = #calls
key("l", 5)
check(
  #calls == total and s.status:find("Source changed", 1, true),
  "edited documents reject stale expansions"
)
hierarchy.disable()
check(not require("lsp-tools.panel").alive(s), "disable closes tree")
print(("hierarchies: %d assertions passed"):format(count))
vim.cmd("qa!")
