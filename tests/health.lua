vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local root_calls = 0
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
  rename = { backend = "delta", delta = { command = "/missing/lsp-tools-delta" } },
  results = true,
  servers = {
    lsp_tools_health = {
      cmd = { "/missing/lsp-tools-health-server" },
      filetypes = { "lsp-tools-health" },
      root_dir = function()
        root_calls = root_calls + 1
      end,
    },
  },
})
vim.bo.filetype = "lua"
local reports = {}
for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
  vim.health[level] = function(message)
    reports[#reports + 1] = { level, message }
  end
end
local health = require("lsp-tools.health")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function has(level, needle)
  for _, report in ipairs(reports) do
    if report[1] == level and report[2]:find(needle, 1, true) then
      return true
    end
  end
  return false
end
local active
package.loaded.lualine = {
  get_config = function()
    return active
  end,
}
active =
  { winbar = { lualine_c = { "filename" } }, options = { disabled_filetypes = { winbar = {} } } }
health.check()
check(has("warn", "executable missing; rename"), "missing configured delta is actionable")
check(has("warn", "result titles may flicker"), "lualine ownership conflict detected")
check(not has("warn", "No LSP clients"), "an idle server is not a warning")
check(has("info", "Details: :LspToolsInfo"), "full details have an explicit entry point")
check(not has("info", "deferred"), "normal deferred modules do not add inventory noise")
check(
  has("warn", "Executable missing: /missing/lsp-tools-health-server"),
  "missing managed server command reported"
)
check(root_calls == 0, "health does not invoke dynamic root callbacks")
check(
  not package.loaded["lsp-tools.results"]
    and not package.loaded["lsp-tools.rename"]
    and not package.loaded["git_tools.diff"]
    and not package.loaded["selection_tools.picker"]
    and not package.loaded["snacks.picker"],
  "health does not load interactive implementations or providers"
)
active.options.disabled_filetypes.winbar = { "lsp-tools-results" }
reports = {}
health.check()
check(not has("warn", "result titles may flicker"), "proper winbar exclusion accepted")
local buf, contents, maps =
  vim.api.nvim_get_current_buf(),
  vim.api.nvim_buf_get_lines(0, 0, -1, false),
  vim.api.nvim_get_keymap("n")
health.check()
check(
  vim.api.nvim_get_current_buf() == buf
    and vim.deep_equal(contents, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    and vim.deep_equal(maps, vim.api.nvim_get_keymap("n")),
  "health leaves source and global mappings unchanged"
)
print(("health checks: %d assertions passed"):format(count))
vim.cmd("qa!")
