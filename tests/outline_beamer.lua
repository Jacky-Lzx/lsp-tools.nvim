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
  local path = vim.env.LSP_TOOLS_BEAMER_FILE
  if path then
    vim.cmd.edit(vim.fn.fnameescape(path))
  else
    path = directory .. "/slides.tex"
    api.nvim_buf_set_name(0, path)
    api.nvim_buf_set_lines(0, 0, -1, false, {
      "\\documentclass{beamer}",
      "\\begin{document}",
      "\\section{Progress}",
      "\\begin{frame}{Test}",
      "hello",
      "\\end{frame}",
      "\\begin{frame}{Comparison with the Existing Methods}",
      "\\begin{itemize}",
      "\\item Our method",
      "\\begin{itemize}",
      "\\item uses an easy-to-implement function as the bias",
      "\\end{itemize}",
      "\\end{itemize}",
      "\\end{frame}",
      "\\begin{frame}",
      "\\frametitle{Baseline Methods}",
      "\\end{frame}",
      "\\begin{frame}[allowframebreaks]{References}",
      "\\end{frame}",
      "\\end{document}",
    })
  end
  vim.bo.filetype = "tex"
  local buf, source = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local original = api.nvim_buf_get_lines(buf, 0, -1, false)
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
  local id = vim.lsp.start({
    name = "outline-beamer",
    cmd = { vim.env.TEXQUILL_BIN or "texquill", "lsp" },
    root_dir = vim.fs.dirname(path),
    capabilities = capabilities,
  })
  local client = assert(vim.lsp.get_client_by_id(id))
  wait(function()
    return client.initialized
  end, "TeXquill initializes")
  local tools = require("lsp-tools")
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = { debounce = 30, request_timeout = 10000 },
  })
  local win = assert(tools.open_outline())
  local out = api.nvim_win_get_buf(win)
  local function lines()
    return api.nvim_buf_get_lines(out, 0, -1, false)
  end
  local function text()
    return table.concat(lines(), "\n")
  end
  wait(function()
    return text():find("Our method", 1, true) ~= nil
  end, "real TeXquill provides Beamer structure")
  assert(vim.wo[win].winbar:find("Structure"), "TeX defaults to structure mode")
  for _, name in ipairs({
    "Progress",
    "Test",
    "Comparison with the Existing Methods",
    "Baseline Methods",
    "References",
    "itemize",
  }) do
    assert(text():find(name, 1, true), "Missing scope: " .. name)
  end
  local leaf = "uses an easy-to-implement function as the bias"
  local row, indent
  for index, line in ipairs(lines()) do
    if line:find(leaf, 1, true) then
      row, indent = index, #line:match("^%s*")
    end
  end
  assert(row and indent >= 5, "compact nested item preview retains its parent list and item")
  local source_row
  for index, line in ipairs(original) do
    if line:find(leaf, 1, true) then
      source_row = index
    end
  end
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { row, 0 })
  local function key(value)
    if tui then
      api.nvim_input(value)
    else
      api.nvim_feedkeys(vim.keycode(value), "xt", false)
    end
  end
  key("<CR>")
  wait(function()
    return api.nvim_get_current_win() == source
  end, "Enter returns to source")
  assert(
    api.nvim_win_get_cursor(source)[1] == source_row,
    "item jump uses its original source line"
  )
  wait(function()
    return tools.breadcrumbs({ color = false, icons = false }):find(leaf, 1, true) ~= nil
  end, "breadcrumb follows rich LSP scopes")
  local ns = api.nvim_create_namespace("lsp-tools.outline.current")
  api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  local marks = api.nvim_buf_get_extmarks(out, ns, 0, -1, {})
  assert(#marks == 1 and marks[1][2] == row - 1, "current item is highlighted")
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { 2, 0 })
  key("m")
  wait(function()
    return vim.wo[win].winbar:find("All") ~= nil
  end, "m opens all symbols")
  key("m")
  wait(function()
    return vim.wo[win].winbar:find("Structure") ~= nil
  end, "m restores structure")
  assert(text():find(leaf, 1, true), "structure remains complete after mode switching")
  key("q")
  wait(function()
    return not api.nvim_win_is_valid(win)
  end, "q closes the outline")
  assert(
    vim.deep_equal(original, api.nvim_buf_get_lines(buf, 0, -1, false)),
    "presentation source stays unchanged"
  )
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = false,
  })
  client:stop(true)
  io.stdout:write(
    ("outline Beamer %s: frames, nested lists/items, breadcrumbs, source jumps and mode switching passed (%s)\n"):format(
      tui and "TUI" or "headless",
      path
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
