vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api = vim.api
local tools = require("lsp-tools")
tools.setup({
  results = { auto_preview = false },
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local source, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_lines(source, 0, -1, false, { "source" })
local ns = api.nvim_create_namespace("result-options")
vim.diagnostic.set(ns, source, { { lnum = 0, col = 0, message = "warning", severity = 2 } })
vim.wo[win].foldminlines = 4
vim.wo[win].foldnestmax = 6
vim.wo[win][0].foldminlines = 2
vim.wo[win][0].foldnestmax = 8
vim.wo[win][0].foldmethod = "expr"
vim.wo[win][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
local names = { "foldminlines", "foldnestmax", "foldmethod", "foldexpr", "foldtext" }
local defaults, source_options = {}, {}
for _, name in ipairs(names) do
  defaults[name] = api.nvim_get_option_value(name, { scope = "global" })
  source_options[name] = vim.wo[win][name]
end

-- Model a stale Treesitter fold cache left by a buffer deleted without its
-- cleanup autocmds. Changing a global fold option traverses this invalid entry.
local stale = api.nvim_create_buf(false, true)
api.nvim_buf_call(stale, function()
  vim.treesitter.foldexpr(1)
end)
vim.cmd("noautocmd bwipeout! " .. stale)
assert(not api.nvim_buf_is_valid(stale))
local changes = {}
api.nvim_create_autocmd("OptionSet", {
  pattern = { "foldminlines", "foldnestmax" },
  callback = function(ev)
    changes[#changes + 1] = { name = ev.match, scope = vim.v.option_type }
  end,
})
local results = require("lsp-tools.results")
for _, focus in ipairs({ false, true, false }) do
  vim.v.errmsg = ""
  local v = tools.diagnostics({ focus = focus })
  assert(vim.v.errmsg == "", vim.v.errmsg)
  assert(api.nvim_get_current_win() == (focus and v.win or win))
  assert(vim.wo[v.win].foldminlines == 0 and vim.wo[v.win].foldnestmax == 20)
  assert(vim.wo[v.win].foldmethod == "expr")
  api.nvim_win_call(v.win, function()
    vim.cmd("normal! zM")
    assert(vim.fn.foldclosed(1) == 1, "native result folds still close")
    vim.cmd("normal! zR")
    assert(vim.fn.foldclosed(1) == -1, "native result folds still open")
  end)
  results.close("diagnostics")
  assert(vim.v.errmsg == "", vim.v.errmsg)
  for _, name in ipairs(names) do
    assert(
      api.nvim_get_option_value(name, { scope = "global" }) == defaults[name],
      name .. " default changed"
    )
    assert(vim.wo[win][name] == source_options[name], name .. " source option changed")
  end
end
assert(#changes > 0, "OptionSet callbacks must run during this regression")
for _, change in ipairs(changes) do
  assert(change.scope == "local", change.name .. " must only change locally")
end
print("result window options: stale Treesitter cache, focus, reopen and native folds passed")
vim.cmd("qa!")
