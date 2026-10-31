local M = {}
local api = vim.api
local function available(path)
  return #api.nvim_get_runtime_file(path, false) > 0
end
local function source_buffer()
  local current = api.nvim_get_current_buf()
  if vim.bo[current].buftype == "" then
    return current
  end
  local alternate = vim.fn.bufnr("#")
  if alternate > 0 and api.nvim_buf_is_valid(alternate) and vim.bo[alternate].buftype == "" then
    return alternate
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local buf = api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "" then
      return buf
    end
  end
end
local function syntax(health, buf)
  health.start("Source preview highlighting")
  local ft = buf and vim.bo[buf].filetype or ""
  if ft == "" then
    health.info(
      "No source filetype available; run this check from a source buffer for parser/syntax details"
    )
    return
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local parser, loaded = pcall(vim.treesitter.language.add, lang)
  local query, highlights = false, nil
  if parser and loaded then
    query, highlights = pcall(vim.treesitter.query.get, lang, "highlights")
  end
  if parser and loaded and query and highlights then
    health.ok(ft .. ": Tree-sitter parser and highlight query available (" .. lang .. ")")
  elseif available("syntax/" .. ft .. ".vim") or available("syntax/" .. ft .. ".lua") then
    health.info(ft .. ": using Vim syntax fallback; Tree-sitter parser/highlight query unavailable")
  else
    health.warn(
      ft .. ": no Tree-sitter highlights or Vim syntax fallback",
      { "Install a parser and highlight queries, or add a syntax file for this filetype" }
    )
  end
end
local function winbar(health)
  health.start("Result winbar ownership")
  local lualine = package.loaded.lualine
  if type(lualine) == "table" and type(lualine.get_config) == "function" then
    local ok, config = pcall(lualine.get_config)
    if not ok then
      health.warn("Unable to inspect lualine configuration: " .. tostring(config))
      return
    end
    local active = next(config.winbar or {}) or next(config.inactive_winbar or {})
    local excluded = ((config.options or {}).disabled_filetypes or {}).winbar or {}
    if active and not vim.tbl_contains(excluded, "lsp-tools-results") then
      health.warn(
        "lualine manages winbars without excluding lsp-tools-results; result titles may flicker",
        { 'Add "lsp-tools-results" to options.disabled_filetypes.winbar in lualine' }
      )
    else
      health.ok("lualine preserves the results winbar")
    end
  else
    health.info("lualine is not loaded; other winbar providers should exclude lsp-tools-results")
  end
  local count = 0
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "lsp-tools-results" then
      count = count + 1
      if api.nvim_get_option_value("winbar", { win = win }) == "" then
        health.info(
          "Window "
            .. win
            .. " has no winbar (expected for previews/help; a list should have its own title)"
        )
      end
    end
  end
  health.info(count .. " result/preview/help windows currently open")
end
function M.check()
  local health = vim.health
  health.start("lsp-tools.nvim runtime and configuration")
  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim " .. tostring(vim.version()) .. " supports the required native LSP APIs")
  else
    health.error("Neovim 0.12 or newer is required")
    return
  end
  local plugin = package.loaded["lsp-tools"]
  local config = plugin and plugin.configuration() or { enabled = {}, options = {} }
  local enabled = {}
  for name, on in pairs(config.enabled) do
    if on then
      enabled[#enabled + 1] = name
        .. (package.loaded["lsp-tools." .. name] and " (loaded)" or " (deferred)")
    end
  end
  table.sort(enabled)
  if #enabled == 0 then
    health.info("No tools enabled; setup may not have run yet")
  else
    health.ok("Enabled: " .. table.concat(enabled, ", "))
  end
  health.start("Optional dependencies")
  if available("lua/selection_tools/init.lua") then
    health.ok("selection-tools picker API available on runtimepath")
  elseif config.enabled.code_actions or config.enabled.rename then
    health.error(
      "selection-tools unavailable; enabled code action/rename pickers require it",
      { "Install/update Jacky-Lzx/selection-tools.nvim, or disable code_actions and rename" }
    )
  else
    health.info("selection-tools unavailable; native result views do not require it")
  end
  if available("lua/git_tools/diff/init.lua") then
    health.ok("git-tools diff API available on runtimepath")
  elseif config.enabled.code_actions or config.enabled.rename then
    health.error("git-tools unavailable; enabled code action/rename previews require it", {
      "Install/load git-tools.nvim, or disable code_actions and rename",
    })
  else
    health.info("git-tools unavailable; native result views do not require it")
  end
  for _, name in ipairs({ "code_actions", "rename" }) do
    local opts = config.options[name] or {}
    if config.enabled[name] and opts.backend == "delta" then
      local command = (opts.delta or {}).command or "delta"
      if vim.fn.executable(command) == 1 then
        health.ok(name .. ": delta executable available (" .. command .. ")")
      else
        health.warn(
          name
            .. ": delta executable missing ("
            .. command
            .. "); native diff fallback will be used",
          { 'Install delta or choose backend = "vim"' }
        )
      end
    end
  end
  local buf = source_buffer()
  syntax(health, buf)
  winbar(health)
  health.start("Attached LSP providers")
  local clients = buf and vim.lsp.get_clients({ bufnr = buf }) or {}
  if #clients == 0 then
    health.info(
      "No LSP clients attached to the source buffer; diagnostics, native lists and picker snapshots can still be used"
    )
  end
  for _, client in ipairs(clients) do
    local supported = {}
    for _, method in ipairs({
      "definition",
      "references",
      "documentSymbol",
      "hover",
      "codeAction",
      "linkedEditingRange",
    }) do
      if client:supports_method("textDocument/" .. method, buf) then
        supported[#supported + 1] = method
      end
    end
    health.ok(
      client.name
        .. " (#"
        .. client.id
        .. ", "
        .. (client.offset_encoding or "unknown encoding")
        .. "): "
        .. table.concat(supported, ", ")
    )
  end
  health.info(
    "Capability support is server-specific; use require('lsp-tools').inspect() for provider selection and request failures"
  )
end
return M
