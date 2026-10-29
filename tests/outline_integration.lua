local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local tex = vim.env.LSP_TOOLS_OUTLINE_SERVER == "texquill"
  local api = vim.api
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
  vim.cmd("enew!")
  local buf, source = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_name(buf, directory .. (tex and "/main.tex" or "/main.lua"))
  local lines = tex
      and {
        "\\documentclass{article}",
        "\\newcommand{\\mycmd}{text}",
        "\\begin{document}",
        "\\section{Alpha}",
        "body",
        "\\subsection{Beta}",
        "\\label{sec:beta}",
        "\\section{Gamma}",
        "tail",
        "\\end{document}",
      }
    or {
      "local function alpha()",
      "  local function beta()",
      "    return 1",
      "  end",
      "  return beta()",
      "end",
      "return alpha()",
    }
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = tex and "tex" or "lua"
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  -- No filesystem watching is needed for these unsaved, isolated document tests.
  capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
  local id = vim.lsp.start({
    capabilities = capabilities,
    name = "outline-real-" .. (tex and "texquill" or "luals"),
    cmd = tex and { "texquill", "lsp" } or {
      "lua-language-server",
      "--logpath=" .. directory .. "/log",
      "--metapath=" .. directory .. "/meta",
    },
    root_dir = directory,
    settings = { Lua = { workspace = { checkThirdParty = false }, telemetry = { enable = false } } },
  })
  local client = assert(vim.lsp.get_client_by_id(id))
  wait(function()
    return client.initialized
  end, "real server initializes")
  local tools = require("lsp-tools")
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = { debounce = 30, request_timeout = 10000 },
  })
  local win = tools.open_outline()
  local out = api.nvim_win_get_buf(win)
  local function text()
    return table.concat(api.nvim_buf_get_lines(out, 0, -1, false), "\n")
  end
  local title, child = tex and "Alpha" or "alpha", tex and "Beta" or "beta"
  wait(function()
    return text():find(title) and text():find(child)
  end, "real LSP returns nested symbols")
  assert(api.nvim_get_current_win() == source, "initial focus preserved")
  assert(not vim.wo[win].winbar:find("Invalid"), "successful response has no error status")
  local child_row
  for row, line in ipairs(api.nvim_buf_get_lines(out, 0, -1, false)) do
    if line:find(child) then
      child_row = row
      assert(line:find("^  "), "child is indented")
    end
  end
  if tex then
    assert(
      not text():find("mycmd") and not text():find("sec:beta"),
      "section mode excludes definitions and labels"
    )
  end
  local function key(value)
    if tui then
      api.nvim_input(value)
    else
      api.nvim_feedkeys(vim.keycode(value), "xt", false)
    end
  end
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { child_row, 0 })
  key("<CR>")
  wait(function()
    return api.nvim_get_current_win() == source
  end, "Enter returns to source")
  assert(api.nvim_win_get_cursor(source)[1] == (tex and 6 or 2), "jump uses symbol selection range")
  local namespace = api.nvim_create_namespace("lsp-tools.outline.current")
  api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  assert(#api.nvim_buf_get_extmarks(out, namespace, 0, -1, {}) == 1, "current symbol highlighted")
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { 1, 0 })
  local before = api.nvim_buf_line_count(out)
  key("za")
  wait(function()
    return api.nvim_buf_line_count(out) < before
  end, "real key collapses subtree")
  key("zR")
  wait(function()
    return api.nvim_buf_line_count(out) == before
  end, "real key expands subtree")
  if tex then
    key("m")
    wait(function()
      return text():find("mycmd") ~= nil
    end, "all mode includes macro definition")
    key("m")
    wait(function()
      return not text():find("mycmd")
    end, "switch back to sections")
  end
  api.nvim_set_current_win(source)
  local changed = vim.deepcopy(lines)
  local edit_row = tex and 8 or 2
  changed[edit_row] = tex and "\\section{Updated}" or "  local function updated()"
  api.nvim_buf_set_lines(buf, 0, -1, false, changed)
  api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  wait(function()
    return text():find(tex and "Updated" or "updated") ~= nil
  end, "editing refreshes actual LSP symbols")
  local cursor = api.nvim_win_get_cursor(source)
  api.nvim_set_current_win(win)
  key("q")
  wait(function()
    return not api.nvim_win_is_valid(win)
  end, "q closes sidebar")
  assert(
    api.nvim_get_current_win() == source and vim.deep_equal(cursor, api.nvim_win_get_cursor(source)),
    "close preserves latest source cursor"
  )
  tools.setup({ code_actions = false, references = false, rename = false, outline = false })
  client:stop(true)
  io.stdout:write(
    ("outline %s: real %s hierarchy, keys, focus, filtering and live updates passed\n"):format(
      tui and "TUI" or "headless",
      tex and "TeXquill" or "LuaLS"
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
