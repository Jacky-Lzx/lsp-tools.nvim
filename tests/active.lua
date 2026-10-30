vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local rename = require("lsp-tools.rename")
local links = require("lsp-tools.links")
local outline = require("lsp-tools.outline")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo" })
local count, calls, available = 0, {}, false
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function hooks(group)
  local ok, result = pcall(vim.api.nvim_get_autocmds, { group = group })
  return ok and #result or 0
end
local client = { id = 1, name = "active", offset_encoding = "utf-16" }
function client:supports_method()
  return false
end
function client:request(method, _, callback)
  calls[#calls + 1] = { method = method, callback = callback }
  return true, #calls
end
function client:cancel_request(id)
  calls[id].cancelled = true
end
local original_clients, original_client = vim.lsp.get_clients, vim.lsp.get_client_by_id
vim.lsp.get_clients = function(opts)
  return available and opts.method ~= "textDocument/documentSymbol" and { client } or {}
end
vim.lsp.get_client_by_id = function()
  return client
end
vim.notify = function() end
rename.setup()
links.setup({ fallback = function() end })
outline.setup({ focus_on_open = false })
for _, group in ipairs({ "LspToolsRename", "LspToolsLinks", "LspToolsOutline" }) do
  check(hooks(group) == 0, group .. " has no idle hooks after setup")
end
rename.rename("bar")
check(hooks("LspToolsRename") == 0, "unsupported rename installs no cancellation hooks")
available = true
rename.rename("bar")
check(hooks("LspToolsRename") > 0, "active rename installs cancellation hooks")
local pending = calls[#calls]
rename.cancel()
check(
  pending.cancelled and hooks("LspToolsRename") == 0,
  "cancelled rename releases request and hooks"
)
rename.rename("bar")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "changed" })
vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
check(hooks("LspToolsRename") == 0, "stale rename releases hooks")
links.open()
check(hooks("LspToolsLinks") > 0, "pending link request installs hooks")
calls[#calls].callback(nil, {})
check(hooks("LspToolsLinks") == 0, "fallback finishes link hooks")
links.open()
links.disable()
check(
  hooks("LspToolsLinks") == 0 and calls[#calls].cancelled,
  "disable cancels active link and releases hooks"
)
local tab = vim.api.nvim_get_current_tabpage()
outline.open()
check(hooks("LspToolsOutline") > 0, "opening first sidebar installs watchers")
vim.cmd("tabnew")
outline.open()
outline.close()
check(hooks("LspToolsOutline") > 0, "closing one tab retains watchers for another sidebar")
vim.api.nvim_set_current_tabpage(tab)
outline.close()
check(hooks("LspToolsOutline") == 0, "closing last sidebar removes watchers")
outline.open()
check(hooks("LspToolsOutline") > 0, "reopening restores watchers")
outline.disable()
rename.disable()
check(hooks("LspToolsOutline") == 0, "disable releases sidebar watchers")
vim.lsp.get_clients, vim.lsp.get_client_by_id = original_clients, original_client
print(("active tool lifetimes: %d assertions passed"):format(count))
vim.cmd("qa!")
