local M = {}

function M.check()
  vim.health.start("lsp-tools.nvim")
  if vim.fn.has("nvim-0.12") == 0 then
    vim.health.error("Neovim 0.12+ is required", { "Upgrade Neovim" })
    return
  end
  local issues = {}
  local function problem(level, message, advice)
    issues[#issues + 1] = { level = level, message = message, advice = advice }
  end
  local plugin = package.loaded["lsp-tools"]
  local config = plugin and plugin.configuration()
  if not config or not next(config.enabled) then
    vim.health.info("Not configured; LSP tool checks skipped.")
    return
  end
  local function available(path)
    return #vim.api.nvim_get_runtime_file(path, false) > 0
  end
  if
    (config.enabled.code_actions or config.enabled.rename or config.enabled.pickers)
    and not available("lua/selection_tools/init.lua")
  then
    problem(
      "error",
      "selection-tools is unavailable; enabled action, rename or location pickers cannot open.",
      { "Install/mount selection-tools.nvim or disable the affected tools" }
    )
  end
  if
    (config.enabled.code_actions or config.enabled.rename)
    and not available("lua/git_tools/diff/init.lua")
  then
    problem(
      "error",
      "git-tools is unavailable; enabled action or rename previews cannot open.",
      { "Install/mount git-tools.nvim or disable the affected tools" }
    )
  end
  local missing = {}
  for _, name in ipairs({ "code_actions", "rename" }) do
    local opts = config.options[name] or {}
    local cmd = (opts.delta or {}).command or "delta"
    if config.enabled[name] and opts.backend == "delta" and vim.fn.executable(cmd) == 0 then
      missing[cmd] = missing[cmd] or {}
      table.insert(missing[cmd], name)
    end
  end
  for cmd, tools in pairs(missing) do
    problem(
      "warn",
      cmd .. ": executable missing; " .. table.concat(tools, ", ") .. " use native diff.",
      { 'Install the configured delta executable or choose backend = "vim"' }
    )
  end
  if package.loaded["lsp-tools.servers"] then
    local status = require("lsp-tools.servers.status")
    for _, server in ipairs(status.snapshot()) do
      if server.error or server.requested and not server.configured then
        problem(
          "error",
          server.name .. ": " .. status.describe(server),
          { "Correct the server configuration" }
        )
      elseif server.requested and server.executable == false then
        problem(
          "warn",
          server.name .. ": " .. status.describe(server),
          { "Install the server or override its cmd; inspect :LspToolsInfo" }
        )
      end
    end
  end
  local lualine = package.loaded.lualine
  if
    config.enabled.results
    and type(lualine) == "table"
    and type(lualine.get_config) == "function"
  then
    local ok, value = pcall(lualine.get_config)
    if ok then
      local active = next(value.winbar or {}) or next(value.inactive_winbar or {})
      local excluded = ((value.options or {}).disabled_filetypes or {}).winbar or {}
      if active and not vim.tbl_contains(excluded, "lsp-tools-results") then
        problem(
          "warn",
          "lualine also manages result winbars; result titles may flicker.",
          { 'Add "lsp-tools-results" to options.disabled_filetypes.winbar in lualine' }
        )
      end
    end
  end

  table.sort(issues, function(a, b)
    if a.level ~= b.level then
      return a.level == "error"
    end
    return a.message < b.message
  end)
  for _, issue in ipairs(issues) do
    vim.health[issue.level](issue.message, issue.advice)
  end
  if #issues == 0 then
    vim.health.ok("Enabled LSP tools and server configurations are valid.")
  end
  vim.health.info("Details: :LspToolsInfo")
end

return M
