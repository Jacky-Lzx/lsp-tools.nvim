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
  if vim.env.LSP_TOOLS_NVIM_CONFIG then
    local config = vim.env.LSP_TOOLS_NVIM_CONFIG
    vim.env.NVIM_CONFIG_ROOT, vim.env.NVIM_SMOKE_TEST = config, "1"
    vim.env.NVIM_LAZY_LOCKFILE = directory .. "/lock.json"
    vim.opt.rtp:prepend(config)
    require("config.context").initialize({ profiles = {}, features = {} })
    vim.g.loaded_wakatime = true
    vim.o.loadplugins = true
    dofile(config .. "/init.lua")
    vim.cmd("enew!")
  end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(buf, directory .. "/hover.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "---**Greeting documentation** with `name`.",
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
  if tui then
    vim.api.nvim_input("K")
  else
    vim.lsp.buf.hover()
  end
  local float
  wait(function()
    float = vim.b[buf].lsp_floating_preview
    return float and vim.api.nvim_win_is_valid(float)
  end, "native K opens styled documentation")
  assert(vim.api.nvim_get_current_win() == win, "K preserves source focus")
  local out = vim.api.nvim_win_get_buf(float)
  assert(vim.bo[out].filetype == "markdown" and vim.treesitter.highlighter.active[out])
  local function screen()
    vim.cmd("redraw!")
    local rendered = ""
    local pos = vim.api.nvim_win_get_position(float)
    for row = pos[1] + 1, pos[1] + vim.api.nvim_win_get_height(float) do
      for col = pos[2] + 1, pos[2] + vim.api.nvim_win_get_width(float) do
        rendered = rendered .. vim.fn.screenstring(row, col)
      end
      rendered = rendered .. "\n"
    end
    return rendered
  end
  if tui then
    wait(function()
      local rendered = screen()
      return rendered:find("Greeting documentation", 1, true)
        and not rendered:find("```", 1, true)
        and not rendered:find("**Greeting", 1, true)
    end, "native hover visibly conceals fences and inline Markdown")
    vim.api.nvim_input("K")
    wait(function()
      return vim.api.nvim_get_current_win() == float
    end, "KK focuses the existing hover")
    for row, line in ipairs(vim.api.nvim_buf_get_lines(out, 0, -1, false)) do
      if line:find("Greeting documentation", 1, true) then
        vim.api.nvim_win_set_cursor(float, { row, 1 })
      end
    end
    local rendered = screen()
    assert(not rendered:find("```", 1, true), "focused hover keeps fences hidden")
    assert(not rendered:find("**Greeting", 1, true), "cursor-line Markdown stays hidden")
    local hidden = {}
    for _, mark in
      ipairs(
        vim.api.nvim_buf_get_extmarks(
          out,
          vim.api.nvim_create_namespace("lsp-tools.hover.float"),
          0,
          -1,
          { details = true }
        )
      )
    do
      if mark[4].conceal_lines ~= nil then
        hidden[mark[2] + 1] = true
      end
    end
    assert(next(hidden), "real hover includes hidden fence rows")
    local visible = {}
    for row = 1, vim.api.nvim_buf_line_count(out) do
      if not hidden[row] then
        visible[#visible + 1] = row
      end
    end
    local function move(keys, expected)
      local before = vim.api.nvim_win_get_cursor(float)[1]
      vim.api.nvim_input(keys)
      wait(function()
        return vim.api.nvim_win_get_cursor(float)[1] ~= before
      end, "terminal hover movement: " .. keys)
      assert(
        vim.api.nvim_win_get_cursor(float)[1] == expected,
        keys .. " lands on the next visible row without stopping on hidden Markdown"
      )
    end
    vim.api.nvim_win_set_cursor(float, { visible[1], 0 })
    for index = 2, #visible do
      move("j", visible[index])
    end
    for index = #visible - 1, 1, -1 do
      move("k", visible[index])
    end
    move("2j", visible[3])
    move("2k", visible[1])
    move("<Down>", visible[2])
    move("<Up>", visible[1])
    move("gj", visible[2])
    move("gk", visible[1])
    move("vj", visible[2])
    assert(
      vim.fn.mode() == "v" and vim.fn.getpos("v")[2] == visible[1],
      "Visual movement retains its selection anchor"
    )
    move("k", visible[1])
    vim.api.nvim_input(vim.keycode("<Esc>"))
    wait(function()
      return vim.fn.mode() == "n"
    end, "exit hover selection")
    vim.api.nvim_input("q")
    wait(function()
      return not vim.api.nvim_win_is_valid(float)
    end, "q closes the native hover")
    assert(vim.api.nvim_get_current_win() == win, "native hover restores source focus")
  else
    vim.api.nvim_win_close(float, true)
  end
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
    vim.api.nvim_input(vim.keycode("<LocalLeader>y"))
    wait(function()
      return vim.fn.getreg('"'):find("greet", 1, true)
    end, "terminal y copies signature")
    vim.api.nvim_input(vim.keycode("<LocalLeader>q"))
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
