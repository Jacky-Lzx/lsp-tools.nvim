vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
vim.g.mapleader = " "
local tools, api = require("lsp-tools"), vim.api
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
  results = true,
  hover = { keymaps = { follow = false } },
  ui = { key_prefix = "<Leader>x", keymaps = { copy = false } },
})
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local refreshed = 0
local v = tools.results({ { bufnr = api.nvim_get_current_buf(), text = "hello" } }, {
  focus = true,
  keymaps = { preview = false, refresh = { "<prefix>r", "<F6>" } },
  refresh = function()
    refreshed = refreshed + 1
  end,
})
check(
  vim.fn.maparg("<Leader>xp", "n") == "" and not v.keymaps["<Space>xp"],
  "disabled actions install no key or help row"
)
vim.fn.maparg("<F6>", "n", false, true).callback()
check(refreshed == 1 and v.keymaps["<F6>"], "multiple custom keys invoke the semantic action")
check(
  vim.fn.maparg("g", "n") == "" and vim.fn.maparg("f", "n") == "",
  "native motions stay available"
)
vim.fn.maparg("<Leader>x?", "n", false, true).callback()
check(
  v.help
    and not table
      .concat(api.nvim_buf_get_lines(v.help.buf, 0, -1, false), "\n")
      :find("Preview source", 1, true),
  "help reflects the effective action configuration"
)
vim.fn.maparg("<Leader>x?", "n", false, true).callback()
check(not v.help and api.nvim_get_current_win() == v.win, "help closes using the configured prefix")
check(
  not pcall(tools.setup, { ui = { keymaps = { preview = 123 } } }) and api.nvim_win_is_valid(v.win),
  "invalid configuration preserves an existing view"
)
tools.close_results()
local h = tools.hover()
api.nvim_set_current_win(h.win)
check(
  vim.fn.maparg("<Leader>xr", "n", false, true).callback and vim.fn.maparg("r", "n") == "",
  "other panels share the prefix and preserve native letters"
)
check(
  vim.fn.maparg("<Leader>xf", "n") == "" and vim.fn.maparg("<Leader>xy", "n") == "",
  "tool and shared action disabling combine"
)
vim.fn.maparg("<Leader>x?", "n", false, true).callback()
local help = h.bindings.help
check(help and api.nvim_win_is_valid(help), "other panels expose owned key help")
require("lsp-tools.hover").disable()
check(not api.nvim_win_is_valid(help), "closing a panel cleans up its help")
tools.setup({ results = false, hover = false })
local buf = api.nvim_create_buf(false, true)
local bindings = require("lsp-tools.keymaps").new(buf)
bindings:map("first", "<F8>", function() end)
bindings:map("second", "<F8>", function() end)
bindings:map("first", "<F9>", function() end)
local retained = api.nvim_buf_call(buf, function()
  return vim.fn.maparg("<F8>", "n", false, true)
end)
check(
  #bindings.actions.second == 1
    and bindings.entries["<F8>"].action == "second"
    and retained.desc == "second",
  "rebinding a replaced action preserves the effective owner"
)
check(not pcall(tools.setup, { ui = false }), "non-table shared UI options are rejected")
api.nvim_buf_delete(buf, { force = true })
print(("action keymaps: %d assertions passed"):format(count))
vim.cmd("qa!")
