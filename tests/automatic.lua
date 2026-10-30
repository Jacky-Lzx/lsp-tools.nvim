vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo" })
local count, timers, requests, capabilities = 0, 0, {}, {}
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local new_timer = vim.uv.new_timer
vim.uv.new_timer = function(...)
  timers = timers + 1
  return new_timer(...)
end
local client = { id = 1, name = "dynamic", offset_encoding = "utf-8", _enabled_capabilities = {} }
function client:request(method, _, callback)
  requests[#requests + 1] = method
  callback(nil, nil)
  return true, #requests
end
function client:cancel_request() end
function client:supports_method(method, target)
  return (capabilities[target] or {})[method] or false
end
local get_clients, get_client = vim.lsp.get_clients, vim.lsp.get_client_by_id
vim.lsp.get_clients = function(opts)
  local target = opts.bufnr == 0 and vim.api.nvim_get_current_buf() or opts.bufnr
  return client:supports_method(opts.method, target) and { client } or {}
end
vim.lsp.get_client_by_id = function()
  return client
end
local native_linked = vim.lsp.linked_editing_range.enable
vim.lsp.linked_editing_range.enable = function() end
tools.setup({
  code_actions = false,
  rename = false,
  outline = false,
  lightbulb = { debounce = 1 },
  linked_editing = true,
  references = { debounce = 1 },
  breadcrumbs = { debounce = 1 },
})
for _, name in ipairs({ "references", "breadcrumbs", "lightbulb", "linked_editing" }) do
  check(not package.loaded["lsp-tools." .. name], name .. " remains deferred without a provider")
end
for _, event in ipairs({ "CursorMoved", "TextChanged", "BufEnter" }) do
  vim.api.nvim_exec_autocmds(event, { buffer = buf })
end
check(timers == 0 and #requests == 0, "unsupported buffers allocate no feature timers or requests")
local hidden = vim.api.nvim_create_buf(true, false)
capabilities[hidden] = { ["textDocument/codeAction"] = true }
vim.api.nvim_exec_autocmds("LspAttach", { buffer = hidden, data = { client_id = 1 } })
check(vim.v.errmsg == "", "hidden attachment respects native client lifecycle")
check(
  not package.loaded["lsp-tools.lightbulb"],
  "hidden buffers do not initialize automatic engines"
)
capabilities[buf] = { ["textDocument/documentHighlight"] = true }
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check(
  package.loaded["lsp-tools.references"] and not package.loaded["lsp-tools.lightbulb"],
  "capabilities activate independently"
)
assert(vim.wait(100, function()
  return #requests > 0
end, 1))
capabilities[buf]["textDocument/codeAction"] = true
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check(
  package.loaded["lsp-tools.lightbulb"],
  "dynamic capability becomes active without a second LspAttach"
)
capabilities[buf]["textDocument/documentSymbol"] = true
capabilities[buf]["textDocument/linkedEditingRange"] = true
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check(
  package.loaded["lsp-tools.breadcrumbs"] and package.loaded["lsp-tools.linked_editing"],
  "other newly supported engines activate"
)
local hooks_ok = pcall(vim.api.nvim_get_autocmds, { group = "LspToolsAutomatic" })
check(not hooks_ok, "bootstrap listeners disappear when all enabled engines are initialized")
local unsupported = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, unsupported)
vim.wait(10, function()
  return false
end, 1)
local before = timers
for _, event in ipairs({ "CursorMoved", "TextChanged", "BufEnter" }) do
  vim.api.nvim_exec_autocmds(event, { buffer = unsupported })
end
check(timers == before, "initialized engines avoid timers in unsupported buffers")
local previous_requests = #requests
capabilities[unsupported] =
  { ["textDocument/documentSymbol"] = true, ["textDocument/linkedEditingRange"] = true }
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = unsupported })
local discovered = {}
for i = previous_requests + 1, #requests do
  discovered[requests[i]] = true
end
check(
  discovered["textDocument/documentSymbol"] and discovered["textDocument/linkedEditingRange"],
  "already initialized engines detect dynamic providers in another buffer"
)
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  rename = false,
  outline = false,
  lightbulb = false,
  linked_editing = false,
})
vim.uv.new_timer = new_timer
vim.lsp.get_clients, vim.lsp.get_client_by_id = get_clients, get_client
vim.lsp.linked_editing_range.enable = native_linked
print(("automatic activation: %d assertions passed"):format(count))
vim.cmd("qa!")
