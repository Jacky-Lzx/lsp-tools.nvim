local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  vim.opt.rtp:prepend(vim.env.SNACKS_DIR or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim"))
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local function wait(test, message)
    if not tui then
      assert(vim.wait(8000, test, 10), message)
      return
    end
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 8000, message)
      coroutine.yield()
    end
  end
  local tools, api = require("lsp-tools"), vim.api
  tools.setup({
    results = { auto_preview = false },
    code_actions = false,
    references = false,
    breadcrumbs = false,
    outline = false,
  })
  local results = require("lsp-tools.results")
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local root = assert(vim.env.LSP_TOOLS_TEST_TMP)
  api.nvim_buf_set_name(buf, root .. "/source.lua")
  api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "second" })
  local other = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(other, root .. "/other.lua")
  api.nvim_buf_set_lines(other, 0, -1, false, { "😀beta", "tail" })
  local ns = api.nvim_create_namespace("results-integration")
  vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "alpha warning", severity = 2 } })
  vim.diagnostic.set(ns, other, { { lnum = 0, col = 4, message = "beta error", severity = 1 } })
  local v = tools.diagnostics({ focus = false })
  assert(api.nvim_get_current_win() == win and #v.items == 2)
  if tui then
    vim.cmd("redraw!")
    local screen = ""
    for row = 1, vim.o.lines do
      for col = 1, vim.o.columns do
        screen = screen .. vim.fn.screenstring(row, col)
      end
    end
    assert(screen:find("beta error", 1, true), "diagnostic row visible in terminal")
  end
  local function key(lhs)
    api.nvim_set_current_win(v.win)
    if tui then
      api.nvim_input(lhs)
    else
      vim.fn.maparg(lhs, "n", false, true).callback()
    end
  end
  local full = #v.rows
  key("zM")
  wait(function()
    return #v.rows < full
  end, "real fold key collapses groups")
  key("zR")
  wait(function()
    return #v.rows == full
  end, "real expand key restores groups")
  results.select(v, v.items[1].id)
  key("p")
  wait(function()
    return v.preview and api.nvim_win_is_valid(v.preview.win)
  end, "preview key opens float")
  key("q")
  wait(function()
    return not api.nvim_win_is_valid(v.win)
  end, "close key releases result view")
  assert(not v.preview and api.nvim_get_current_win() == win)
  require("snacks").setup({ picker = { enabled = true } })
  require("snacks.picker").setup()
  local p = require("snacks.picker")({
    source = "result-fixture",
    items = {
      { file = "source.lua", buf = buf, text = "alpha", pos = { 1, 0 } },
      { file = "other.lua", buf = other, text = "beta", pos = { 1, 4 } },
    },
    cwd = root,
    format = "file",
    preview = "none",
    show_delay = 0,
    actions = {
      results_open = function(picker)
        tools.from_picker(picker)
      end,
    },
    win = { input = { keys = { ["<c-t>"] = { "results_open", mode = { "n", "i" } } } } },
  })
  wait(function()
    return p:count() == 2 and p.input.win:valid() and p:current()
  end, "actual Snacks picker ready")
  if tui then
    wait(function()
      return vim.fn.mode():sub(1, 1) == "i"
    end, "picker enters input mode")
    api.nvim_input("<C-t>")
  else
    p.opts.actions.results_open(p)
  end
  wait(function()
    v = results.current("picker")
    return v and #v.items == 2
  end, "picker action imports both filtered results")
  assert(p.closed and v.ctx.win == win and api.nvim_get_current_win() == win)
  local target
  for _, value in ipairs(v.items) do
    if value.bufnr == other then
      target = value
    end
  end
  results.select(v, target.id)
  key("<CR>")
  wait(function()
    return api.nvim_get_current_buf() == other and api.nvim_win_get_cursor(0)[2] == 4
  end, "Enter jumps to original UTF8 byte position")
  api.nvim_buf_delete(buf, { force = true })
  assert(api.nvim_win_is_valid(v.win), "imported snapshot outlives original buffer")
  key("q")
  wait(function()
    return not api.nvim_win_is_valid(v.win)
  end, "picker snapshot closes cleanly")
  assert(#api.nvim_list_wins() == 1, "no leaked picker, preview or result windows")
  print(
    "result workflows: diagnostics, fold/preview keys and actual Snacks import/source jumps passed"
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
      vim.fn.writefile(
        { "persistent results and Snacks <C-t> terminal passed" },
        vim.env.LSP_TOOLS_TEST_TMP .. "/result"
      )
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
