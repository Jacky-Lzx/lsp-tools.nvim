-- Real LuaLS and terminal input, optionally under the user's complete configuration.
local function run()
  local api = vim.api
  local root = assert(vim.env.LSP_TOOLS_ROOT)
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  local configured = vim.env.LSP_TOOLS_NVIM_CONFIG
  if configured then
    vim.env.NVIM_CONFIG_ROOT, vim.env.NVIM_SMOKE_TEST = configured, "1"
    vim.env.NVIM_LAZY_LOCKFILE = directory .. "/lock.json"
    vim.opt.rtp:prepend(configured)
    require("config.context").initialize({ profiles = {}, features = {} })
    vim.g.loaded_wakatime = true
    vim.o.loadplugins = true
    dofile(configured .. "/init.lua")
    local plugin = require("lazy.core.config").plugins["lsp-tools.nvim"]
    assert(vim.uv.fs_realpath(plugin.dir) == vim.uv.fs_realpath(root))
    assert(not plugin._.loaded, "picker key should support lazy first use")
  else
    vim.opt.rtp:prepend(root)
    require("lsp-tools").setup({
      pickers = true,
      code_actions = false,
      references = false,
      rename = false,
      outline = false,
      breadcrumbs = false,
    })
  end
  local function wait(test, message)
    local started = vim.uv.hrtime()
    while not test() do
      if (vim.uv.hrtime() - started) / 1e6 >= 15000 then
        local impl = package.loaded["lsp-tools.pickers"]
        local p = impl and impl.current()
        error(message .. ": " .. vim.inspect({
          query = p and p.query,
          mode = vim.fn.mode(),
          matches = p and vim.tbl_map(function(entry)
            return entry.text
          end, p.matches),
        }))
      end
      coroutine.yield()
    end
  end
  local function picker()
    local implementation = package.loaded["lsp-tools.pickers"]
    return implementation and implementation.current()
  end
  local function ready()
    wait(function()
      local p = picker()
      return p
        and not p.loading
        and not p.syntax_pending
        and #p.entries > 0
        and (not vim.env.LSP_TOOLS_TUI or vim.fn.mode():sub(1, 1) == "i")
    end, "search picker shows results and accepts input")
    return picker()
  end
  local function check_rows(p, semantic)
    vim.cmd("redraw!")
    local locations, colors = {}, {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
      if mark[4].hl_group == "SelectionToolsFileLocation" then
        locations[mark[2] + 1] = mark
      end
      if mark[4].hl_group == semantic then
        colors[mark[2] + 1] = mark
      end
    end
    local right
    for row, index in pairs(p.row_to_index) do
      local line = api.nvim_buf_get_lines(p.list_buf, row - 1, row, false)[1]
      local mark = assert(locations[row], "file location is in a distinct right column")
      assert(vim.fn.strwidth(line) == p.resolved.width, "row reaches the right edge")
      local endpoint = vim.fn.strwidth(line:sub(1, mark[4].end_col))
      right = right or endpoint
      assert(right == endpoint, "file locations have an aligned right edge")
      local item = p.matches[index].item
      if item.name then
        assert(line:find(item.name, 1, true) < mark[3], "symbol content is left of its path")
      end
      local color = colors[row]
      if color then
        assert(color[4].end_col <= mark[3], "semantic colors stay out of file metadata")
        if vim.env.LSP_TOOLS_TUI then
          local top, left = unpack(api.nvim_win_get_position(p.list_win))
          local content_col = left + vim.fn.strwidth(line:sub(1, color[3])) + 1
          local file_col = left + vim.fn.strwidth(line:sub(1, mark[3])) + 1
          assert(
            vim.fn.screenattr(top + row, content_col) ~= vim.fn.screenattr(top + row, file_col),
            "terminal displays different content and path colors"
          )
        end
      end
    end
    assert(next(colors), "content has the expected semantic highlight: " .. semantic)
  end
  local function close()
    local p = picker()
    if p then
      if vim.env.LSP_TOOLS_TUI then
        api.nvim_input("<Esc>")
      else
        p:close()
      end
      wait(function()
        return p.closed
      end, "Escape closes selection picker")
    end
  end
  local function choose(p, text)
    if vim.env.LSP_TOOLS_TUI then
      api.nvim_input(text)
    else
      p:set_query(text)
    end
    wait(function()
      local item = p:current()
      return p.query == text
        and not p.loading
        and not p.syntax_pending
        and item
        and (item.name == text or item.text == text)
    end, "typed query selects the expected result: " .. text)
    if vim.env.LSP_TOOLS_TUI then
      api.nvim_input("<CR>")
    else
      p:confirm()
    end
    wait(function()
      return p.closed
    end, "Enter chooses filtered result")
  end
  vim.cmd("enew!")
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_name(buf, directory .. "/source.lua")
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function alpha(x) return x end",
    "local function beta(x) return alpha(x) end",
    "local value = alpha(1)",
    "print(alpha(value), beta(value))",
  })
  vim.bo.filetype = "lua"
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
  local id = assert(vim.lsp.start({
    name = "picker-real-luals",
    cmd = {
      "lua-language-server",
      "--logpath=" .. directory .. "/log",
      "--metapath=" .. directory .. "/meta",
    },
    root_dir = directory,
    capabilities = capabilities,
    settings = { Lua = { workspace = { checkThirdParty = false } } },
  }))
  local client = vim.lsp.get_client_by_id(id)
  wait(function()
    return client.initialized
  end, "LuaLS initializes")
  api.nvim_win_set_cursor(win, { 3, 15 })
  local indexed, pending = false, false
  wait(function()
    if not indexed and not pending then
      pending = true
      local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
      params.context = { includeDeclaration = false }
      client:request("textDocument/references", params, function(err, result)
        indexed, pending = not err and result and #result == 3, false
      end, buf)
    end
    return indexed
  end, "LuaLS indexes real unsaved source")
  local tools = require("lsp-tools")
  if configured then
    api.nvim_input("gd")
  else
    tools.lsp_definitions()
  end
  wait(function()
    return not picker() and api.nvim_win_get_cursor(win)[1] == 1
  end, "single real definition jumps directly, including lazy key replay")
  api.nvim_win_set_cursor(win, { 3, 15 })
  if configured then
    api.nvim_input("gi")
  else
    tools.lsp_references()
  end
  local p = ready()
  assert(#p.entries >= 2, "multiple semantic references use searchable picker")
  close()
  if configured then
    api.nvim_input(vim.g.mapleader .. "ss")
  else
    tools.lsp_symbols()
  end
  p = ready()
  assert(p.preview_win and api.nvim_win_is_valid(p.preview_win), "source preview is mounted")
  check_rows(p, "Function")
  choose(p, "beta")
  assert(
    api.nvim_get_current_win() == win and api.nvim_win_get_cursor(win)[1] == 2,
    "document-symbol choice returns to original source"
  )
  if configured then
    api.nvim_input(vim.g.mapleader .. "sS")
  else
    tools.lsp_workspace_symbols()
  end
  wait(function()
    return picker() and (not vim.env.LSP_TOOLS_TUI or vim.fn.mode():sub(1, 1) == "i")
  end, "workspace symbols accepts input")
  p = picker()
  -- Multiple successive edits exercise real live-query cancellation.
  if vim.env.LSP_TOOLS_TUI then
    api.nvim_input("al")
  else
    p:set_query("al")
  end
  wait(function()
    return p.query == "al"
  end, "first live query reaches input")
  if vim.env.LSP_TOOLS_TUI then
    api.nvim_input("pha")
  else
    p:set_query("alpha")
  end
  wait(function()
    return p.query == "alpha" and not p.loading and #p.entries >= 1
  end, "latest workspace-symbol query returns real LuaLS results")
  assert(p:current().name:find("alpha", 1, true))
  check_rows(
    p,
    require("lsp-tools.symbols.icons")[vim.lsp.protocol.SymbolKind[p:current().kind]].hl
  )
  close()
  local ns = api.nvim_create_namespace("picker-integration")
  local other = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(other, directory .. "/other.lua")
  api.nvim_buf_set_lines(other, 0, -1, false, { "other" })
  vim.diagnostic.set(
    ns,
    buf,
    { { lnum = 1, col = 15, message = "selection warning", severity = 2, source = "test-lint" } }
  )
  vim.diagnostic.set(
    ns,
    other,
    { { lnum = 0, col = 0, message = "elsewhere error", severity = 1, source = "test-lint" } }
  )
  if configured then
    api.nvim_input(vim.g.mapleader .. "sD")
  else
    tools.pick_diagnostics({ scope = "buffer", namespace = ns })
  end
  p = ready()
  check_rows(p, "DiagnosticWarn")
  for _, entry in ipairs(p.entries) do
    assert(entry.item.bufnr == buf, "buffer picker stays scoped")
  end
  choose(p, "selection warning")
  assert(api.nvim_win_get_cursor(win)[1] == 2, "diagnostic chooser navigates exact source")
  if configured then
    api.nvim_input(vim.g.mapleader .. "sd")
  else
    tools.pick_diagnostics({ namespace = ns })
  end
  p = ready()
  choose(p, "elsewhere error")
  assert(api.nvim_get_current_buf() == other, "global diagnostic picker reaches another file")
  tools.setup({ pickers = false })
  client:stop(true)
  wait(function()
    return vim.lsp.get_client_by_id(id) == nil
  end, "LuaLS exits cleanly")
  if not configured then
    assert(not package.loaded.snacks, "standalone pickers never load Snacks")
  end
end

local thread = coroutine.create(run)
local function step()
  local ok, err = coroutine.resume(thread)
  if not ok then
    vim.fn.writefile(
      { tostring(err), debug.traceback(thread) },
      vim.env.LSP_TOOLS_TEST_TMP .. "/result"
    )
    vim.cmd("cquit 1")
  elseif coroutine.status(thread) == "dead" then
    vim.fn.writefile({
      "real LuaLS picker integration: definitions, references, typed document/workspace symbols, source previews, live cancellation and diagnostic scopes passed (configured="
        .. tostring(vim.env.LSP_TOOLS_NVIM_CONFIG ~= nil)
        .. ")",
    }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 50)
