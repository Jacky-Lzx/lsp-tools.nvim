vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local function run()
  local api = vim.api
  vim.cmd("enew!")
  local tools = require("lsp-tools")
  tools.setup({
    code_actions = false,
    rename = false,
    references = false,
    breadcrumbs = false,
    outline = false,
    results = { auto_preview = false },
    hover = true,
  })
  local panel, results = require("lsp-tools.panel"), require("lsp-tools.results")
  local source, owner = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
  api.nvim_buf_set_lines(source, 0, -1, false, { "local value = 1", "return value" })
  local other = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(other, vim.fn.tempname() .. "-other.lua")
  api.nvim_buf_set_lines(other, 0, -1, false, { "target" })
  local count = 0
  local function check(value, message)
    assert(value, message)
    count = count + 1
  end
  local function protected(win, buf, label)
    check(vim.wo[win].winfixbuf, label .. " locks its buffer")
    api.nvim_win_call(win, function()
      for _, command in ipairs({ "buffer " .. other, "edit " .. api.nvim_buf_get_name(other) }) do
        local ok, err = pcall(vim.cmd, command)
        check(not ok and tostring(err):find("E1513", 1, true), label .. " rejects " .. command)
        check(api.nvim_win_get_buf(win) == buf, label .. " retains its content")
      end
    end)
  end
  local function key(lhs, done)
    if vim.env.LSP_TOOLS_TUI == "1" then
      api.nvim_input(vim.keycode(lhs))
      local start = vim.uv.hrtime()
      while not done() do
        assert((vim.uv.hrtime() - start) / 1e6 < 3000, "key timed out: " .. lhs)
        coroutine.yield()
      end
    else
      vim.fn.maparg(lhs, "n", false, true).callback()
      check(done(), "key completed: " .. lhs)
    end
  end
  local ctx = require("lsp-tools.request").context()
  local s = panel.open("protection", ctx)
  panel.write(s, { "Shared diagnostic / hierarchy / inspection panel" })
  protected(s.win, s.out, "shared panel")
  s.bindings:show_help(s.win)
  local help = s.bindings.help
  protected(help, api.nvim_win_get_buf(help), "shared panel help")
  key("<Esc>", function()
    return not api.nvim_win_is_valid(help) and api.nvim_get_current_win() == s.win
  end)
  api.nvim_win_set_buf(owner, other)
  vim.wo[owner].winfixbuf = true
  check(not panel.source(s, true), "source restoration respects a newly locked editor")
  check(api.nvim_win_get_buf(owner) == other, "source restoration preserves the locked buffer")
  vim.wo[owner].winfixbuf = false
  api.nvim_win_set_buf(owner, source)
  panel.close(s)
  api.nvim_set_current_win(owner)
  check(not vim.wo[owner].winfixbuf, "source remains replaceable")

  local v = tools.results({ { bufnr = other, pos = { 1, 0 }, text = "protected result" } }, {
    focus = true,
    group_by = {},
  })
  protected(v.win, v.out, "results")
  key("<LocalLeader>?", function()
    return v.help ~= nil
  end)
  protected(v.help.win, v.help.buf, "results help")
  key("<Esc>", function()
    return not v.help and api.nvim_get_current_win() == v.win
  end)
  for _, layout in ipairs({ "float", "right", "bottom" }) do
    results.preview(v, { layout = layout })
    protected(v.preview.win, v.preview.buf, layout .. " source preview")
  end

  -- Neither the original editor nor other protected/temporary editors may be replaced.
  vim.wo[owner].winfixbuf = true
  local floating = api.nvim_open_win(source, false, {
    relative = "editor",
    row = 1,
    col = 1,
    width = 20,
    height = 2,
  })
  local preview = api.nvim_open_win(source, false, { split = "right", win = owner })
  vim.wo[preview].previewwindow = true
  api.nvim_set_current_win(v.win)
  local before = #api.nvim_list_wins()
  key("<CR>", function()
    return api.nvim_get_current_buf() == other
  end)
  local target = api.nvim_get_current_win()
  check(
    target ~= owner and target ~= floating and target ~= preview,
    "jump creates a usable editor"
  )
  check(#api.nvim_list_wins() == before, "jump replaces the preview with one source split")
  check(not vim.wo[target].winfixbuf, "new source editor is replaceable")
  check(
    api.nvim_win_get_buf(owner) == source and vim.wo[owner].winfixbuf,
    "locked source survives jump"
  )
  check(
    api.nvim_win_get_buf(floating) == source and api.nvim_win_get_buf(preview) == source,
    "temporary editors survive jump"
  )
  protected(v.win, v.out, "results after jump")
  results.close()
  api.nvim_win_close(floating, true)
  api.nvim_win_close(preview, true)
  api.nvim_win_close(target, true)
  vim.wo[owner].winfixbuf = false
  api.nvim_set_current_win(owner)

  local hover = tools.hover()
  protected(hover.win, hover.out, "pinned documentation")
  panel.close(hover)
  api.nvim_set_current_win(owner)
  local buf, win = vim.lsp.util.open_floating_preview({ "Documentation" }, "plaintext", {
    focus_id = "textDocument/hover",
  })
  protected(win, buf, "native hover")
  api.nvim_win_close(win, true)

  -- A panel left as the tab's last window must unlock only during its own teardown.
  api.nvim_set_current_win(owner)
  s = panel.open("last-window", require("lsp-tools.request").context())
  api.nvim_win_close(owner, true)
  panel.close(s)
  check(
    api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == source,
    "last panel restores its source"
  )
  check(
    not vim.wo[s.win].winfixbuf and not api.nvim_buf_is_valid(s.out),
    "last panel restores unlocked editor options"
  )
  print(("window protection: %d assertions passed"):format(count))
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
        { "window protection terminal passed" },
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
