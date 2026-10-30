vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools, api = require("lsp-tools"), vim.api
tools.setup({
  results = { presets = { Warnings = { severity = 2 } } },
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local buf = api.nvim_get_current_buf()
local one, two = api.nvim_create_namespace("filters-one"), api.nvim_create_namespace("filters-two")
vim.diagnostic.set(
  one,
  buf,
  { { lnum = 0, col = 0, message = "bad", severity = 1, source = "compiler", code = "E1" } }
)
vim.diagnostic.set(two, buf, {
  { lnum = 0, col = 0, message = "spelling", severity = 2, source = "Harper", code = "W1" },
  { lnum = 0, col = 0, message = "hint", severity = 4, source = "Harper", code = "H1" },
})
local v = tools.diagnostics({ focus = true })
local results, filters = require("lsp-tools.results"), require("lsp-tools.results.filters")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local old_select, old_input = vim.ui.select, vim.ui.input
local choices = {}
vim.ui.select = function(items, opts, cb)
  local desired = table.remove(choices, 1)
  for _, item in ipairs(items) do
    if (type(item) == "table" and item.label or item) == desired then
      cb(item)
      return
    end
  end
  cb(nil)
end
local function choose(field, value)
  choices = { field, value }
  filters.open(results, v)
end
choose("Severity", "Errors and warnings")
check(#v.filtered == 2, "severity combinations filter received diagnostics")
choose("Source", "compiler")
check(#v.filtered == 1 and v.filtered[1].text == "bad", "source picker combines with severity")
vim.ui.input = function(_, cb)
  cb("Build")
end
choices = { "Save preset" }
filters.open(results, v)
choose("Reset")
check(#v.filtered == 3, "reset clears filters without clearing native diagnostics")
choose("Load preset", "Build")
check(
  #v.filtered == 1 and v.filter.source == "compiler",
  "session presets restore complete combinations"
)
choose("Load preset", "Warnings")
check(
  #v.filtered == 1 and v.filtered[1].text == "spelling" and not v.filter.source,
  "configured presets replace previous combinations"
)
choose("Reset")
choose("Namespace", "filters-two")
check(#v.filtered == 2, "namespace picker preserves non-LSP producer identity")
choose("Diagnostic code", "H1")
check(#v.filtered == 1 and v.filtered[1].severity == 4, "code picker combines with namespace")
local callback
vim.ui.select = function(_, _, cb)
  callback = cb
end
filters.open(results, v)
results.close("diagnostics")
callback("Reset")
check(#vim.diagnostic.get(buf) == 3, "late/cancelled filter dialogs cannot delete diagnostics")
vim.ui.select, vim.ui.input = old_select, old_input
print(("result filters: %d assertions passed"):format(count))
vim.cmd("qa!")
