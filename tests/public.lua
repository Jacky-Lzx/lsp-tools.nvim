vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local original = vim.ui.select
local mappings = vim.api.nvim_get_keymap("n")
local tools = require("lsp-tools")
check(vim.ui.select == original, "requiring the plugin does not install behavior")
tools.setup({ code_actions = false, references = false, rename = false, outline = false })
check(not package.loaded["lsp-tools.code_actions"], "disabled tools stay unloaded")
check(not package.loaded["lsp-tools.references"], "disabled reference tool stays unloaded")
check(not package.loaded["lsp-tools.rename"], "disabled rename tool stays unloaded")
check(not package.loaded["lsp-tools.outline"], "disabled outline tool stays unloaded")
check(not tools.open_outline(), "opening an initially disabled outline does nothing")
check(not package.loaded["code_actions"], "the old plugin is not loaded")
tools.setup({ code_actions = { backend = "vim", resolve_timeout = 50 } })
local adapter = vim.ui.select
check(adapter ~= original, "public setup enables the code action adapter")
check(not package.loaded["snacks.picker"], "Snacks is loaded only when opening code actions")
tools.setup()
check(vim.ui.select == adapter, "public setup is idempotent")
local forwarded
vim.lsp.buf.code_action = function(opts)
  forwarded = opts
  return "native-result"
end
local options = { context = { only = { "quickfix" } }, apply = true }
check(tools.code_action(options) == "native-result", "public action returns native results")
check(forwarded == options, "public action preserves native options")
tools.setup({ code_actions = { enabled = false } })
check(vim.ui.select == original, "disable restores the previous select provider")
vim.api.nvim_exec_autocmds("UIEnter", {})
vim.wait(10, function()
  return false
end, 1)
check(vim.ui.select == original, "disabled tools are not reinstalled by UIEnter")
tools.setup({ code_actions = true })
check(vim.ui.select ~= original, "a disabled tool can be enabled again")
local newer = function() end
vim.ui.select = newer
tools.setup({ code_actions = false })
check(vim.ui.select == newer, "disable preserves a newer UI provider")
local delegated = 0
vim.ui.select = function()
  delegated = delegated + 1
end
tools.setup()
local wrapped = vim.ui.select
local after = function(...)
  return wrapped(...)
end
vim.ui.select = after
tools.setup({ code_actions = false })
vim.ui.select({ { action = { title = "old" }, ctx = { client_id = 1, bufnr = 1 } } }, {
  kind = "codeaction",
  format_item = function()
    return "old"
  end,
}, function() end)
check(delegated == 1, "disabled wrappers delegate even when captured by another provider")
tools.setup()
check(not pcall(tools.setup, { code_actions = "bad" }), "invalid feature configuration fails")
check(not pcall(tools.setup, { references = "bad" }), "invalid reference configuration fails")
check(not pcall(tools.setup, { rename = "bad" }), "invalid rename configuration fails")
check(not pcall(tools.setup, { outline = "bad" }), "invalid outline configuration fails")
check(not pcall(tools.setup, { code_actions = { resolve_timeout = 0 } }), "invalid timeout fails")
check(vim.deep_equal(mappings, vim.api.nvim_get_keymap("n")), "setup installs no user mappings")
check(not package.loaded["code_actions"], "code-actions.nvim is never required")
tools.setup({ code_actions = false, references = false, rename = false, outline = false })
print(("lsp-tools public API: %d assertions passed"):format(count))
vim.cmd("qa!")
