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
  local function typing(target, render)
    if not tui then
      return
    end
    local changes, samples = 0, 0
    local autocmd = api.nvim_create_autocmd("TextChangedI", {
      buffer = buf,
      callback = function()
        changes = changes + 1
      end,
    })
    local function stable()
      assert(text(target) == "alpha › beta", "typing never blanks the cached path")
      local rendered = render()
      assert(
        rendered:find("alpha", 1, true) and rendered:find("beta", 1, true),
        "typing never blanks the rendered winbar"
      )
      vim.cmd("redraw!")
      local line = ""
      local position = api.nvim_win_get_position(target)
      for col = position[2] + 1, position[2] + api.nvim_win_get_width(target) do
        line = line .. vim.fn.screenstring(position[1] + 1, col)
      end
      assert(
        line:find("alpha", 1, true) and line:find("beta", 1, true),
        "typing keeps both scopes visible on the terminal: " .. vim.inspect({ position, line })
      )
      samples = samples + 1
    end
    api.nvim_win_set_cursor(target, { 3, 11 })
    api.nvim_input("A")
    wait(function()
      return vim.fn.mode() == "i"
    end, "enters real Insert mode")
    local before = requests
    for character in ("2345"):gmatch(".") do
      local previous = changes
      api.nvim_input(character)
      wait(function()
        stable()
        return changes > previous
      end, "typed input triggers TextChangedI")
      local start = vim.uv.hrtime()
      wait(function()
        stable()
        return (vim.uv.hrtime() - start) / 1e6 >= 100
      end, "path stays visible through debounce and the LSP response")
    end
    assert(requests > before, "typing exercises real document-symbol refreshes")
    api.nvim_input("<Esc>")
    wait(function()
      return vim.fn.mode() == "n"
    end, "leaves Insert mode")
    api.nvim_del_autocmd(autocmd)
    io.stdout:write(("stable Insert-mode winbar: %d screen samples\n"):format(samples))
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
  typing(win, function()
    return winbar(win).str
  end)
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
  typing(split, function()
    lualine.refresh({ force = true })
    return actual(split)
  end)
  api.nvim_buf_set_lines(buf, 1, 2, false, { "  local function updated()" })
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  assert(
    text(split) == "alpha › beta",
    "editing preserves the path until its replacement arrives"
  )
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
