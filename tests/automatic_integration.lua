vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  rename = false,
  outline = false,
  lightbulb = { debounce = 1 },
})
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "foo" })
vim.bo.filetype = "lua"
local id = assert(vim.lsp.start({
  name = "dynamic-capabilities",
  cmd = { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/dynamic_server.py" },
  root_dir = vim.fn.getcwd(),
}))
local client = vim.lsp.get_client_by_id(id)
local method = "textDocument/codeAction"
local function wait(test, message)
  assert(vim.wait(5000, test, 5), message)
end
wait(function()
  return client.initialized
end, "fixture initializes")
assert(
  not package.loaded["lsp-tools.lightbulb"],
  "unsupported engine stays deferred after real LspAttach"
)
client:request("workspace/executeCommand", { command = "register" }, function() end, buf)
wait(function()
  return client:supports_method(method, buf)
end, "client receives dynamic registration")
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
local namespace = vim.api.nvim_create_namespace("lsp-tools.lightbulb")
wait(function()
  return #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 1
end, "dynamic action becomes visible without another attach")
client:request("workspace/executeCommand", { command = "unregister" }, function() end, buf)
wait(function()
  return not client:supports_method(method, buf)
end, "client receives capability removal")
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
assert(
  #vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {}) == 0,
  "removed capability clears indicator"
)
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  rename = false,
  outline = false,
  lightbulb = false,
})
client:stop(true)
wait(function()
  return vim.lsp.get_client_by_id(id) == nil
end, "fixture exits")
assert(vim.v.errmsg == "", vim.v.errmsg)
print("automatic integration: real LSP dynamic registration/removal and deferred activation passed")
vim.cmd("qa!")
