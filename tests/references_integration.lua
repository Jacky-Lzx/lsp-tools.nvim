local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  local tools = require("lsp-tools")
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local configured = vim.env.LSP_TOOLS_CONFIG == "1"
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
  local project = assert(vim.env.LSP_TOOLS_TEST_TMP)
  vim.fn.mkdir(project .. "/project", "p")
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, project .. "/project/main.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "local target = 1",
    "print(target)",
    "do",
    "  local target = 2",
    "  print(target)",
    "end",
    "print('😀', target)",
  })
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  local id = vim.lsp.start({
    name = "reference-integration-luals",
    cmd = {
      vim.env.LUA_LS or "lua-language-server",
      "--logpath=" .. project .. "/luals-log",
      "--metapath=" .. project .. "/luals-meta",
    },
    root_dir = project .. "/project",
    settings = { Lua = { workspace = { checkThirdParty = false }, telemetry = { enable = false } } },
  })
  local client = assert(vim.lsp.get_client_by_id(id))
  wait(function()
    return client.initialized
  end, "real Lua language server initializes")
  -- Wait for real semantic analysis before testing navigation; the inner `target`
  -- deliberately has the same spelling and must be excluded from all results.
  local ready, pending = false, false
  wait(function()
    if not pending and not ready then
      pending = true
      client:request(
        "textDocument/documentHighlight",
        vim.lsp.util.make_position_params(0, client.offset_encoding),
        function(err, result)
          ready = not err and result and #result == 3
          pending = false
        end,
        buf
      )
    end
    return ready
  end, "LuaLS identifies the three outer references and excludes the shadowed local")
  if not configured then
    tools.setup({ code_actions = false, references = { debounce = 1000 } })
    vim.keymap.set("n", "]r", function()
      tools.jump_reference(vim.v.count1)
    end)
    vim.keymap.set("n", "[r", function()
      tools.jump_reference(-vim.v.count1)
    end)
  end
  local namespace = vim.api.nvim_create_namespace("lsp-tools.references")
  local function marks()
    return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, {})
  end
  local function at(row, col)
    return vim.deep_equal(vim.api.nvim_win_get_cursor(0), { row, col })
  end
  local function key(keys, count)
    if tui then
      vim.api.nvim_input(keys)
    else
      tools.jump_reference(count)
    end
  end
  key("]r", 1)
  wait(function()
    return at(2, 6)
  end, "cold forward mapping reaches the next semantic reference")
  assert(#marks() == 3, "real language server results are highlighted")
  for _, mark in ipairs(marks()) do
    assert(mark[2] ~= 3 and mark[2] ~= 4, "shadowed local is excluded")
  end
  key("[r", -1)
  wait(function()
    return at(1, 6)
  end, "backward mapping returns to the declaration")
  key("2]r", 2)
  local last_col = assert(vim.api.nvim_buf_get_lines(buf, 6, 7, false)[1]:find("target", 1, true))
    - 1
  wait(function()
    return at(7, last_col)
  end, "count skips two references and handles preceding emoji")
  if tui then
    vim.api.nvim_input("<C-o>")
    wait(function()
      return at(1, 6)
    end, "Ctrl-O returns to the jump origin")
  else
    assert(vim.fn.getpos("''")[2] == 1, "jumplist preserves the jump origin")
  end
  if configured then
    local plugins = require("lazy.core.config").plugins
    assert(plugins["lsp-tools.nvim"]._.loaded, "configured plugin owns reference navigation")
    assert(not package.loaded["snacks.words"], "configured navigation never loads Snacks.words")
    assert(
      vim.fn.maparg("]]", "n") == "" and vim.fn.maparg("[[", "n") == "",
      "native section keys remain free"
    )
    assert(
      vim.fn.maparg("]r", "t") == "" and vim.fn.maparg("[r", "t") == "",
      "terminal input remains free"
    )
  else
    assert(not package.loaded["snacks"], "standalone references require no Snacks")
  end
  client:stop(true)
  io.stdout:write(
    "lsp-tools references: real LuaLS passed (shadowing, Unicode, counts, backward, jumplist"
      .. (tui and ", TUI keys" or "")
      .. (configured and ", full configuration" or ", no Snacks")
      .. ")\n"
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
    elseif coroutine.status(thread) ~= "dead" then
      vim.defer_fn(step, 10)
    end
  end
  vim.schedule(step)
else
  run()
end
