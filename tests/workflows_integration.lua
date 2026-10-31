vim.opt.rtp:prepend(
  vim.env.SELECTION_TOOLS_DIR or (vim.env.LSP_TOOLS_ROOT .. "/../selection-tools.nvim")
)
local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  vim.opt.rtp:prepend(vim.env.SNACKS_DIR or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim"))
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local function wait(test, message)
    if not tui then
      assert(vim.wait(10000, test, 10), message)
      return
    end
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 10000, message)
      coroutine.yield()
    end
  end
  local tools = require("lsp-tools")
  tools.setup({
    lightbulb = { debounce = 10, text = "!" },
    diagnostics = true,
    inspect = true,
    references = false,
    breadcrumbs = false,
    outline = false,
  })
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  vim.api.nvim_buf_set_name(buf, directory .. "/main.lua")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world", "next" })
  local id = assert(vim.lsp.start({
    name = "workflow-fixture",
    cmd = { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/server.py" },
    root_dir = directory,
  }))
  local client = vim.lsp.get_client_by_id(id)
  wait(function()
    return client.initialized
  end, "workflow server initializes")
  local bulb_ns = vim.api.nvim_create_namespace("lsp-tools.lightbulb")
  wait(function()
    return #vim.api.nvim_buf_get_extmarks(buf, bulb_ns, 0, -1, {}) == 1
  end, "real LSP code action indicator appears")
  if tui then
    vim.cmd("redraw!")
    local position = vim.api.nvim_win_get_position(win)
    local line = ""
    for col = position[2] + 1, position[2] + vim.api.nvim_win_get_width(win) do
      line = line .. vim.fn.screenstring(position[1] + 1, col)
    end
    assert(line:find("!", 1, true), "code action indicator is visible in terminal")
  end
  local ns = vim.lsp.diagnostic.get_namespace(id, false)
  vim.diagnostic.set(
    ns,
    buf,
    { { lnum = 0, col = 0, end_col = 5, message = "Fix greeting", severity = 1 } }
  )
  local s = assert(tools.diagnostic())
  if tui then
    vim.api.nvim_input(vim.keycode("<LocalLeader>A"))
  else
    require("lsp-tools.diagnostics").fix(s, true)
  end
  local function picker()
    return require("lsp-tools.selection").current()
  end
  wait(function()
    return picker() and picker():current()
  end, "diagnostic key opens actual preview")
  local p = picker()
  wait(function()
    return vim.api.nvim_win_get_buf(p.preview_win)
      and table
        .concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(p.preview_win), 0, -1, false), "\n")
        :find("你好😀", 1, true)
  end, "resolved edit preview")
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "hello world")
  if tui then
    vim.api.nvim_input("<CR>")
  else
    p:confirm()
  end
  wait(function()
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "你好😀 world"
  end, "confirmed fix applies")
  assert(s.advance)
  vim.diagnostic.set(ns, buf, {})
  assert(not s.advance and #s.items == 0)
  vim.api.nvim_set_current_win(win)
  local info = assert(tools.inspect())
  local report = table.concat(vim.api.nvim_buf_get_lines(info.out, 0, -1, false), "\n")
  assert(
    report:find("workflow-fixture", 1, true) and report:find("textDocument/codeAction", 1, true)
  )
  assert(#require("lsp-tools.inspect").snapshot(buf).lifecycle > 0, "native lifecycle recorded")
  if tui then
    vim.cmd("redraw!")
    local screen = ""
    for row = 1, vim.o.lines do
      for col = 1, vim.o.columns do
        screen = screen .. vim.fn.screenstring(row, col)
      end
      screen = screen .. "\n"
    end
    assert(screen:find("LSP inspection", 1, true), "inspection visible in terminal")
    vim.api.nvim_input(vim.keycode("<LocalLeader>y"))
    wait(function()
      return vim.fn.getreg('"'):find("workflow-fixture", 1, true)
    end, "inspection copy key")
    vim.api.nvim_input(vim.keycode("<LocalLeader>q"))
    wait(function()
      return not vim.api.nvim_win_is_valid(info.win)
    end, "inspection closes")
    vim.api.nvim_set_current_win(s.win)
    vim.api.nvim_input(vim.keycode("<LocalLeader>q"))
    wait(function()
      return not vim.api.nvim_win_is_valid(s.win)
    end, "diagnostic window closes")
  else
    require("lsp-tools.inspect").disable()
    require("lsp-tools.diagnostics").disable()
  end
  assert(
    vim.api.nvim_get_current_win() == win and #vim.api.nvim_list_wins() == 1,
    "workflow restores source without leaked windows"
  )
  client:stop(true)
  print("workflows: real LSP diagnostic resolve/preview/apply and client inspection passed")
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
        { "diagnostic and inspection terminal passed" },
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
