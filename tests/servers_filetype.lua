vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function listener()
  local ok, hooks = pcall(vim.api.nvim_get_autocmds, { group = "LspToolsServers" })
  return ok and #hooks or 0
end
for _, mode in ipairs({ false, true, "invalid", 1 }) do
  check(not pcall(tools.setup, { server_activation = mode }), "invalid activation mode rejected")
end
local invoked = 0
local function config(filetypes)
  return {
    cmd = function()
      invoked = invoked + 1
    end,
    filetypes = filetypes,
    root_dir = function()
      invoked = invoked + 1
    end,
  }
end
tools.setup({
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
  server_activation = "filetype",
  servers = {
    ft_lua = config({ "lua" }),
    ft_python = config({ "python" }),
    ft_any = config(),
    ft_none = config({}),
  },
})
check(
  invoked == 0 and not vim.lsp.is_enabled("ft_lua"),
  "unnamed empty-filetype buffer does not activate servers"
)
check(listener() == 1, "waiting servers share one FileType listener")
local status = tools.server_status()
check(
  #status == 4 and status[1].pending and not status[1].managed,
  "selected servers report pending without claiming native ownership"
)
check(
  require("lsp-tools.servers.status").describe(status[1]) == "Waiting for a matching filetype",
  "pending state has a distinct explanation"
)
check(
  tools.configuration().server_activation == "filetype",
  "configuration exposes activation mode"
)
local enable, calls = vim.lsp.enable, {}
vim.lsp.enable = function(names, on)
  calls[#calls + 1] = { names = vim.deepcopy(names), on = on }
  return enable(names, on)
end
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.bo.filetype = "lua"
check(
  vim.lsp.is_enabled("ft_lua") and vim.lsp.is_enabled("ft_any"),
  "matching and unrestricted configs activate on FileType"
)
check(
  not vim.lsp.is_enabled("ft_python") and not vim.lsp.is_enabled("ft_none"),
  "unrelated and empty-filetype-list configs remain inactive"
)
check(#calls == 1 and #calls[1].names == 2, "matching configs activate in one native batch")
local after = #calls
vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
check(#calls == after, "repeated FileType does not enable a config twice")
tools.setup({ servers = { ft_lua = false, ft_python = false, ft_none = false } })
check(
  not vim.lsp.is_enabled("ft_lua") and not vim.lsp.is_enabled("ft_python"),
  "disable handles active and pending configs"
)
check(listener() == 0, "no pending configs leaves no bootstrap listener")

-- Existing loaded buffers are checked, even when setup is invoked from a tool UI.
local hidden = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(hidden, vim.fn.tempname() .. ".py")
vim.bo[hidden].filetype = "python"
tools.setup({ servers = { ft_python = true } })
check(
  vim.lsp.is_enabled("ft_python") and listener() == 0,
  "already-loaded hidden buffers activate matching servers"
)
tools.setup({ servers = { ft_python = false } })
vim.bo[hidden].filetype = "text"
tools.setup({ servers = { ft_python = true } })
check(
  not vim.lsp.is_enabled("ft_python") and listener() == 1,
  "disabled server can wait for its next matching buffer"
)
enable("ft_python")
vim.api.nvim_exec_autocmds("FileType", { buffer = buf })
local external
for _, item in ipairs(tools.server_status()) do
  if item.name == "ft_python" then
    external = item
  end
end
check(
  external.enabled and not external.managed and not external.pending,
  "external activation of a waiting config retains external ownership"
)
tools.setup({ servers = false })
check(
  vim.lsp.is_enabled("ft_python") and listener() == 0,
  "bulk disable releases pending state while preserving externally enabled servers"
)
enable("ft_python", false)

tools.setup({ servers = { ft_python = true } })
check(not vim.lsp.is_enabled("ft_python"), "omitted mode preserves filetype activation")
tools.setup({ server_activation = "eager" })
check(
  vim.lsp.is_enabled("ft_python") and listener() == 0,
  "switching to eager activation enables waiting configs"
)
tools.setup({ servers = false })
vim.lsp.enable = enable
print(("filetype server activation: %d assertions passed"):format(count))
vim.cmd("qa!")
