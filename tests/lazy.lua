vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local interactive =
  { "rename", "outline", "diagnostics", "hover", "links", "inspect", "hierarchy", "results" }
tools.setup({
  references = false,
  breadcrumbs = false,
  diagnostics = true,
  hover = true,
  links = true,
  inspect = true,
  hierarchy = true,
  results = true,
  rename = { backend = "delta" },
  outline = { width = 30 },
})
check(not package.loaded["input-tools"], "lsp-tools setup must not load input-tools")
for _, name in ipairs(interactive) do
  check(not package.loaded["lsp-tools." .. name], name .. " stays deferred after setup")
end
for _, name in ipairs({
  "code_actions.picker",
  "code_actions.preview",
  "code_actions.render",
  "workspace_edit",
  "panel",
}) do
  check(not package.loaded["lsp-tools." .. name], name .. " is not required for setup")
end
check(
  package.loaded["lsp-tools.code_actions"] and package.loaded["lsp-tools.inspect.recorder"],
  "native action adapter and recorder remain available"
)
check(
  not pcall(tools.setup, { rename = { backend = "bad" } }),
  "deferred diff options are validated at setup"
)
check(not package.loaded["lsp-tools.rename"], "validation does not load rename")
vim.api.nvim_exec_autocmds("LspRequest", {
  buffer = 0,
  data = {
    client_id = 7,
    request_id = 3,
    request = {
      bufnr = vim.api.nvim_get_current_buf(),
      method = "textDocument/hover",
      type = "complete",
    },
  },
})
local info = tools.inspect()
check(
  table.concat(vim.api.nvim_buf_get_lines(info.out, 0, -1, false), "\n"):find("request #3", 1, true),
  "inspection retains events from before first opening"
)
tools.setup({ inspect = false })
check(not vim.api.nvim_win_is_valid(info.win), "disabling an initialized view closes it")
check(tools.inspect() == false, "public entry cannot reactivate a disabled tool")
tools.setup({ hover = false })
check(
  tools.hover() == false and not package.loaded["lsp-tools.hover"],
  "disabled unused tools stay unloaded"
)
tools.setup({ outline = { width = 30 } })
vim.cmd("LspToolsOutlineOpen")
local sidebar
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "lsp-tools-outline" then
    sidebar = win
  end
end
check(
  sidebar and vim.api.nvim_win_get_width(sidebar) == 30,
  "first command initializes outline with saved options"
)
tools.close_outline()
tools.setup({ outline = false })
vim.cmd("LspToolsOutlineOpen")
check(tools.open_outline() == false, "disabled outline command does not reenable it")
check(
  not package.loaded["lsp-tools.rename"] and not package.loaded["lsp-tools.hierarchy"],
  "using another view leaves unrelated implementations deferred"
)
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
  rename = false,
  diagnostics = false,
  hover = false,
  links = false,
  inspect = false,
  hierarchy = false,
  results = false,
})
print(("lazy tools: %d assertions passed"):format(count))
vim.cmd("qa!")
