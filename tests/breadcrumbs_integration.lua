local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  local api = vim.api
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local function wait(test, message)
    if not tui then
      assert(vim.wait(15000, test, 20), message)
      return
    end
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 15000, message)
      coroutine.yield()
    end
  end
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_name(buf, directory .. "/main.lua")
  api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local function alpha()",
    "  local function beta()",
    "    return 1",
    "  end",
    "  return beta()",
    "end",
    "return alpha()",
  })
  vim.bo[buf].filetype = "lua"
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
  local id = vim.lsp.start({
    name = "breadcrumbs-real-luals",
    cmd = {
      "lua-language-server",
      "--logpath=" .. directory .. "/log",
      "--metapath=" .. directory .. "/meta",
    },
    root_dir = directory,
    capabilities = capabilities,
    settings = { Lua = { workspace = { checkThirdParty = false }, telemetry = { enable = false } } },
  })
  local client = assert(vim.lsp.get_client_by_id(id))
  wait(function()
    return client.initialized
  end, "LuaLS initializes")
  local requests = 0
  local request = client.request
  client.request = function(self, method, ...)
    if method == "textDocument/documentSymbol" then
      requests = requests + 1
    end
    return request(self, method, ...)
  end
  local tools = require("lsp-tools")
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = { winbar = true, debounce = 30, request_timeout = 10000 },
  })
  api.nvim_win_set_cursor(win, { 3, 4 })
  local function text(target)
    return tools.breadcrumbs({ winid = target or win, icons = false, color = false })
  end
  wait(function()
    return text() == "alpha › beta"
  end, "LuaLS supplies nested breadcrumb path")
  local function winbar(target)
    return api.nvim_eval_statusline(
      vim.wo[target].winbar,
      { winid = target, use_winbar = true, highlights = true }
    )
  end
  assert(
    winbar(win).str:find("alpha", 1, true) and winbar(win).str:find("beta", 1, true),
    "native winbar renders both scopes"
  )
  if tui then
    wait(function()
      vim.cmd("redraw!")
      local line = ""
      for col = 1, vim.o.columns do
        line = line .. vim.fn.screenstring(1, col)
      end
      return line:find("alpha", 1, true) and line:find("beta", 1, true)
    end, "terminal top row displays both scopes")
  end
  local before = requests
  api.nvim_win_set_cursor(win, { 5, 2 })
  api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  assert(text() == "alpha", "cursor leaving child scope updates immediately")
  vim.cmd("vsplit")
  local split = api.nvim_get_current_win()
  api.nvim_win_set_cursor(split, { 3, 4 })
  assert(text(split) == "alpha › beta" and text(win) == "alpha", "split paths are independent")
  assert(requests == before, "navigation does not query LuaLS")
  -- Exercise the installed lualine implementation, replacing the Trouble function.
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = { debounce = 30, request_timeout = 10000 },
  })
  vim.opt.rtp:append(assert(vim.env.LUALINE_DIR))
  local lualine = require("lualine")
  lualine.setup({
    options = {
      icons_enabled = false,
      theme = "auto",
      component_separators = "",
      section_separators = "",
    },
    winbar = {
      lualine_a = { "filename" },
      lualine_b = { {
        function()
          return tools.breadcrumbs()
        end,
      } },
    },
    inactive_winbar = {
      lualine_b = { {
        function()
          return tools.breadcrumbs()
        end,
      } },
    },
  })
  wait(function()
    return text(split) == "alpha › beta"
  end, "component mode receives symbols")
  local function actual(target)
    return api.nvim_win_call(target, function()
      return lualine.winbar()
    end)
  end
  assert(
    actual(split):find("alpha", 1, true) and actual(split):find("beta", 1, true),
    "actual lualine component renders hierarchy"
  )
  assert(
    actual(win):find("alpha", 1, true) and not actual(win):find("beta", 1, true),
    "inactive lualine window uses its own cursor"
  )
  api.nvim_buf_set_lines(buf, 1, 2, false, { "  local function updated()" })
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  assert(text(split) == "", "editing clears stale path immediately")
  wait(function()
    return text(split) == "alpha › updated"
  end, "LuaLS refreshes renamed scope")
  lualine.refresh({ force = true })
  assert(actual(split):find("updated", 1, true), "actual lualine reflects live symbol edits")
  api.nvim_win_close(split, true)
  api.nvim_win_set_cursor(win, { 7, 0 })
  assert(text() == "", "outside any function renders empty")
  local previous = vim.wo[win].winbar
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = false,
  })
  assert(vim.wo[win].winbar == previous, "disable leaves lualine winbar owned by lualine")
  client:stop(true)
  io.stdout:write(
    ("breadcrumbs %s: real LuaLS, native winbar, lualine, split cursors and live edits passed\n"):format(
      tui and "TUI" or "headless"
    )
  )
  vim.cmd("qa!")
end
if vim.env.LSP_TOOLS_TUI == "1" then
  local thread = coroutine.create(run)
  local function step()
    local ok, err = coroutine.resume(thread)
    if not ok then
      io.stderr:write(tostring(err) .. "\n")
      vim.cmd("cquit 1")
      return
    end
    if coroutine.status(thread) ~= "dead" then
      vim.defer_fn(step, 10)
    end
  end
  vim.schedule(step)
else
  run()
end
