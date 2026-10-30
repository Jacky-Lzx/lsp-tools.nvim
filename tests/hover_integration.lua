local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local function wait(test, message)
    if not tui then
      assert(vim.wait(15000, test, 10), message)
      return
    end
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 15000, message)
      coroutine.yield()
    end
  end
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(buf, directory .. "/hover.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---Greeting documentation",
    "---@param name string",
    "---@return string",
    "local function greet(name)",
    "  return 'Hello ' .. name",
    "end",
    "print(greet('World'))",
  })
  vim.bo[buf].filetype = "lua"
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
  local id = assert(vim.lsp.start({
    name = "hover-real-luals",
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
  end, "LuaLS initialized")
  vim.api.nvim_win_set_cursor(win, { 7, 7 })
  local ready, pending = false, false
  wait(function()
    if not pending and not ready then
      pending = true
      client:request(
        "textDocument/hover",
        vim.lsp.util.make_position_params(win, client.offset_encoding),
        function(err, result)
          ready = not err
            and result
            and result.contents
            and vim.inspect(result.contents):find("Greeting documentation", 1, true) ~= nil
          pending = false
        end,
        buf
      )
    end
    return ready
  end, "LuaLS semantic hover ready")
  local tools = require("lsp-tools")
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = false,
    hover = true,
  })
  local s = assert(tools.hover())
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(s.out, 0, -1, false), "\n")
  end
  wait(function()
    return text():find("Greeting documentation", 1, true)
  end, "real hover document pinned")
  assert(text():find("greet", 1, true) and text():find("string", 1, true))
  if tui then
    vim.cmd("redraw!")
    local rendered = ""
    for row = 1, vim.o.lines do
      for col = 1, vim.o.columns do
        rendered = rendered .. vim.fn.screenstring(row, col)
      end
      rendered = rendered .. "\n"
    end
    assert(
      rendered:find("Pinned LSP documentation", 1, true),
      "pinned heading is visible in terminal"
    )
    vim.api.nvim_input("y")
    wait(function()
      return vim.fn.getreg('"'):find("greet", 1, true)
    end, "terminal y copies signature")
    vim.api.nvim_input("q")
    wait(function()
      return not vim.api.nvim_win_is_valid(s.win)
    end, "terminal q closes document")
    assert(vim.api.nvim_get_current_win() == win, "closing returns source focus")
  else
    require("lsp-tools.hover").disable()
  end
  client:stop(true)
  print(
    "hover integration: real LuaLS signature/documentation"
      .. (tui and ", terminal rendering and keys" or "")
      .. " passed"
  )
end

if vim.env.LSP_TOOLS_TUI == "1" then
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
      vim.fn.writefile({ "hover terminal passed" }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
      vim.cmd("qa!")
    else
      vim.defer_fn(step, 10)
    end
  end
  vim.defer_fn(step, 50)
else
  run()
  vim.cmd("qa!")
end
