vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("lsp-tools")
local options = {}
local caller = vim.deepcopy(options)
plugin.setup(options)
assert(vim.deep_equal(caller, options), "setup mutated caller configuration")
local commands = vim.api.nvim_get_commands({})
local handlers = vim.api.nvim_get_autocmds({})
assert(not pcall(plugin.setup, false), "setup(false) must reject an invalid configuration type")
assert(vim.deep_equal(commands, vim.api.nvim_get_commands({})), "Invalid setup replaced commands")
assert(vim.deep_equal(handlers, vim.api.nvim_get_autocmds({})), "Invalid setup replaced handlers")
plugin.setup(caller)
assert(#vim.api.nvim_get_autocmds({}) == #handlers, "Repeated setup duplicated automatic handlers")
print(
  "lsp-tools.nvim: setup input isolation, invalid configuration and registration lifetime passed"
)

local opts = {
  rename = { delta = { args = { "--width=40" } } },
  lightbulb = { debounce = 12 },
  ui = { keymaps = { close = { "z" } } },
}
plugin.setup(opts)
opts.rename.delta.args[1] = "changed"
assert(plugin.configuration().options.rename.delta.args[1] == "--width=40")
plugin.update({ references = false })
assert(
  plugin.configuration().enabled.lightbulb
    and plugin.configuration().options.lightbulb.debounce == 12
)
assert(plugin.configuration().options.rename.delta.args[1] == "--width=40")
local before = plugin.configuration()
local moved, message = pcall(plugin.setup, { lua = true })
assert(not moved and tostring(message):find("lua-tools.nvim", 1, true))
assert(vim.deep_equal(before, plugin.configuration()), "Migration error changed existing tools")
assert(not package.loaded.lua_tools and not package.loaded["lsp-tools.languages.lua"])
assert(not pcall(plugin.setup, { rename = { request_timeout = -1 } }))
assert(vim.deep_equal(before, plugin.configuration()))
plugin.setup()
assert(not plugin.configuration().enabled.lightbulb)
assert(next(plugin.configuration().options.rename) == nil)
assert(next(plugin.configuration().ui.keymaps) == nil)
local custom = function() end
vim.api.nvim_create_user_command("LspToolsInfo", custom, { force = true })
plugin.dispose()
plugin.dispose()
assert(not plugin.configuration().enabled.rename)
assert(vim.fn.exists("#LspToolsAutomatic") == 0)
assert(vim.fn.exists(":LspToolsInfo") == 2, "Disposal removed a user replacement")
vim.api.nvim_del_user_command("LspToolsInfo")
plugin.setup(caller)
plugin.dispose()
