local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  vim.opt.rtp:prepend(vim.env.SNACKS_DIR)
  local tools = require("lsp-tools")
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local configured = vim.env.LSP_TOOLS_CONFIG == "1"
  local real = vim.env.LSP_TOOLS_REAL_LSP == "1"
  local backend = vim.env.LSP_TOOLS_BACKEND or "vim"
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
  if not configured then
    require("snacks").setup({ picker = { enabled = true }, input = { enabled = true } })
    require("snacks.picker").setup()
    tools.setup({ code_actions = false, references = false, rename = { backend = backend } })
    vim.g.mapleader = " "
    vim.keymap.set("n", "<leader>rn", function()
      tools.rename()
    end)
  end
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  local project = vim.env.LSP_TOOLS_TEST_TMP .. "/project"
  vim.fn.mkdir(project .. "/.git", "p")
  project = assert(vim.uv.fs_realpath(project))
  vim.api.nvim_buf_set_name(buf, project .. "/main.lua")
  local original = real
      and {
        "local foo = 1",
        "print(foo)",
        "do",
        "  local foo = 2",
        "  print(foo)",
        "end",
        "print('😀', foo)",
      }
    or { "中文😀foo foo" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  vim.bo.filetype = "lua"
  vim.api.nvim_win_set_cursor(0, { 1, real and 6 or 10 })
  local other
  local cmd = real
      and {
        vim.env.LUA_LS or "lua-language-server",
        "--logpath=" .. vim.env.LSP_TOOLS_TEST_TMP .. "/log",
        "--metapath=" .. vim.env.LSP_TOOLS_TEST_TMP .. "/meta",
      }
    or { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/server.py" }
  local id = vim.lsp.start({
    name = "rename-integration",
    cmd = cmd,
    root_dir = project,
    settings = { Lua = { workspace = { checkThirdParty = false } } },
  })
  local client = assert(vim.lsp.get_client_by_id(id))
  wait(function()
    return client.initialized
  end, "rename server initializes")
  if not real then
    other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(other, project .. "/other.lua")
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "foo" })
    vim.lsp.buf_attach_client(other, id)
  else
    local ready, pending = false, false
    wait(function()
      if not ready and not pending then
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
    end, "real LuaLS semantic analysis is ready")
  end
  local function current()
    return require("snacks.picker").get()[1]
  end
  local input_seen = false
  if not tui then
    vim.ui.input = function(opts, callback)
      assert(opts.default == "foo", "prepareRename prefills the original name")
      input_seen = true
      callback("bar")
    end
  end
  if tui then
    vim.api.nvim_input(" rn")
    wait(function()
      return vim.bo.filetype == "snacks_input" and vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    end, "actual rename input opens")
    assert(
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("foo", 1, true),
      "original name appears in input"
    )
    vim.api.nvim_input("<C-u>bar")
    wait(function()
      return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "bar"
    end, "typed name reaches the input buffer")
    vim.api.nvim_input("<CR>")
  else
    tools.rename()
  end
  wait(function()
    return current() and current():current()
  end, "rename preview opens")
  local picker = current()
  assert(tui or input_seen, "input stage was exercised")
  assert(#picker:items() == (real and 1 or 2), "one picker row per affected file")
  assert(
    picker.opts.title:find(real and "1 file · 3 edits" or "2 files · 3 edits", 1, true),
    "complete edit totals appear in title"
  )
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original),
    "preview does not mutate the source"
  )
  local function text()
    local b = picker.preview.win.buf
    return b
        and vim.api.nvim_buf_is_valid(b)
        and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
      or ""
  end
  wait(function()
    return text():find("bar", 1, true)
  end, "diff renders the new name")
  if backend == "delta" or configured then
    wait(function()
      return vim.bo[picker.preview.win.buf].buftype == "terminal"
    end, "delta ANSI diff is rendered")
  end
  if not real then
    assert(
      picker:current().lines[1]:find("Rename symbol", 1, true),
      "change annotations appear in preview"
    )
    local other_item = picker:items()[2]
    picker.list:move(picker.list.reverse and 1 or 2, true)
    picker:show_preview()
    wait(function()
      return picker:current() == other_item and text():find("bar", 1, true)
    end, "file list navigates the second diff")
  end
  if tui then
    vim.api.nvim_input("<CR>")
  else
    picker.opts.confirm(picker)
  end
  wait(function()
    return not current()
  end, "Enter closes the rename preview")
  assert(vim.api.nvim_get_current_buf() == buf, "confirmation returns to the source buffer")
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if real then
    assert(
      after[1] == "local bar = 1" and after[2] == "print(bar)" and after[7] == "print('😀', bar)",
      "real semantic rename applies all outer references"
    )
    assert(
      after[4] == "  local foo = 2" and after[5] == "  print(foo)",
      "shadowed local remains untouched"
    )
  else
    assert(
      after[1] == "中文😀bar bar" and vim.api.nvim_buf_get_lines(other, 0, 1, false)[1] == "bar",
      "full cross-file edit applies even when another file is selected"
    )
    assert(
      not vim.uv.fs_stat(project .. "/main.lua"),
      "text renames do not save buffers automatically"
    )
    -- Cancellation and a stale second file use fresh requests and real Snacks UI.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
    vim.api.nvim_buf_set_lines(other, 0, -1, false, { "foo" })
    vim.api.nvim_win_set_cursor(0, { 1, 10 })
    local synced = false
    client:request("fixture/barrier", {}, function()
      synced = true
    end, other)
    wait(function()
      return synced
    end, "other document changes reach the fixture before another rename")
    tools.rename("cancelled")
    wait(function()
      return current() and current():current()
    end, "second preview opens")
    picker = current()
    if tui then
      vim.api.nvim_input("<Esc>")
      wait(function()
        return not current()
      end, "Escape cancels")
    else
      picker:close()
    end
    assert(
      vim.api.nvim_buf_get_lines(other, 0, 1, false)[1] == "foo",
      "cancel leaves all files unchanged"
    )
    tools.rename("stale")
    wait(function()
      return current() and current():current()
    end, "stale-check preview opens")
    picker = current()
    vim.api.nvim_buf_set_lines(other, 0, 1, false, { "edited during review" })
    local notice
    vim.notify = function(message)
      notice = message
    end
    picker.opts.confirm(picker)
    assert(
      not picker.closed and notice:find("changed since preview", 1, true),
      "stale other file blocks the entire rename"
    )
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original),
      "stale refusal applies no source edits"
    )
    picker:close()
  end
  client:stop(true)
  io.stdout:write(
    "lsp-tools rename: "
      .. (real and "real LuaLS" or "real LSP fixture")
      .. " passed (prepare, input, diff, full apply"
      .. (real and ", shadowing" or ", multi-file, annotations, cancel, stale guards")
      .. (tui and ", TUI" or "")
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
