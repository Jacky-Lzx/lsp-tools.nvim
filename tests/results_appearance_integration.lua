local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  local api = vim.api
  local theme = vim.fn.stdpath("data") .. "/lazy/catppuccin"
  vim.o.termguicolors = true
  if vim.uv.fs_stat(theme) then
    vim.opt.rtp:prepend(theme)
    require("catppuccin").setup({ flavour = "mocha" })
    vim.cmd.colorscheme("catppuccin")
  else
    vim.cmd.colorscheme("habamax")
  end
  local icons = vim.fn.stdpath("data") .. "/lazy/nvim-web-devicons"
  if vim.uv.fs_stat(icons) then
    vim.opt.rtp:prepend(icons)
    require("nvim-web-devicons").setup()
  end
  local function wait(test, message)
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 5000, message)
      coroutine.yield()
    end
  end
  local root = assert(vim.env.LSP_TOOLS_TEST_TMP)
  vim.cmd.lcd(root)
  local function buffer(name)
    local buf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(buf, root .. "/" .. name)
    api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { 'local value = "😀hello"', "local options = {}", "return value" }
    )
    return buf
  end
  local one, two = buffer("lua/results/init.lua"), buffer("lua/sources/init.lua")
  local source = api.nvim_get_current_win()
  api.nvim_win_set_buf(source, one)
  local tools = require("lsp-tools")
  tools.setup({
    results = { auto_preview = false },
    code_actions = false,
    references = false,
    breadcrumbs = false,
    outline = false,
  })
  local ns = api.nvim_create_namespace("result-appearance")
  vim.diagnostic.set(ns, one, {
    {
      lnum = 0,
      col = 4,
      message = "类型错误 😀\nexpected string\nreceived number",
      source = "lua_ls",
      code = "E1",
      severity = 1,
    },
    { lnum = 1, col = 6, message = "Unused local `options`.", source = "lua_ls", severity = 2 },
  })
  vim.diagnostic.set(ns, two, {
    { lnum = 2, col = 0, message = "Undefined global `alpha`.", source = "lua_ls", severity = 1 },
  })
  local results = require("lsp-tools.results")
  local v = tools.diagnostics({ focus = true })
  local first = api.nvim_win_get_cursor(v.win)[1]
  vim.cmd("redraw!")
  local lines = api.nvim_buf_get_lines(v.out, 0, -1, false)
  assert(
    lines[1]:find(" lua/results", 1, true),
    "directory path is relative to source cwd, including symlink aliases"
  )
  assert(not vim.wo[v.win].wrap and vim.wo[v.win].cursorline, "compact list window options")
  local function attr(needle)
    local byte = assert(lines[first]:find(needle, 1, true))
    local cell = vim.fn.screenpos(v.win, first, byte)
    assert(cell.row > 0 and cell.col > 0, "diagnostic segment is on screen")
    return vim.fn.screenattr(cell.row, cell.col)
  end
  local icon = vim.diagnostic.config().signs
  icon = type(icon) == "table" and icon.text and icon.text[1] or ""
  assert(
    attr(icon) ~= attr("类型错误"),
    "severity color is limited to the icon in the actual theme"
  )
  assert(
    attr("lua_ls") ~= attr("类型错误"),
    "source metadata is visibly dimmer than the message"
  )
  local body = vim.fn.screenpos(v.win, 1, 1)
  local bar = ""
  for col = body.col, body.col + api.nvim_win_get_width(v.win) - 1 do
    bar = bar .. vim.fn.screenstring(body.row - 1, col)
  end
  assert(
    bar:find("Diagnostics", 1, true) and bar:find("? help", 1, true),
    "compact title and help hint occupy the winbar"
  )
  local capture = { "Bottom diagnostics (" .. vim.g.colors_name .. ")", bar }
  vim.list_extend(capture, lines)
  api.nvim_input("zc")
  local folded
  wait(function()
    folded = api.nvim_win_call(v.win, function()
      return vim.fn.foldclosed(first)
    end)
    return folded > 0
  end, "native zc folds the diagnostic's file")
  vim.cmd("redraw!")
  local at = vim.fn.screenpos(v.win, folded, 1)
  local caption = ""
  for col = at.col, at.col + api.nvim_win_get_width(v.win) - 1 do
    caption = caption .. vim.fn.screenstring(at.row, col)
  end
  assert(
    caption:find("", 1, true) and caption:find("init.lua", 1, true),
    "native closed fold retains the styled file caption"
  )
  local header = lines[folded]
  local name_col = at.col
    + vim.fn.strdisplaywidth(header:sub(1, assert(header:find("init.lua", 1, true)) - 1))
  local count_col = at.col + vim.fn.strdisplaywidth(header:sub(1, assert(header:find("2$")) - 1))
  assert(
    vim.fn.screenattr(at.row, name_col) ~= vim.fn.screenattr(at.row, count_col),
    "native foldtext preserves file and count colors in the actual theme"
  )
  api.nvim_input("zo")
  wait(function()
    return api.nvim_win_call(v.win, function()
      return vim.fn.foldclosed(first) == -1
    end)
  end, "native zo restores the diagnostic lines")
  results.select(v, v.items[1].id)
  api.nvim_input(vim.keycode("<LocalLeader>p"))
  wait(function()
    return v.preview
  end, "preview opens with language highlighting")
  local p = v.preview
  assert(
    p.highlight_backend == "treesitter" and p.filetype == "lua",
    "preview uses actual Lua highlight queries"
  )
  vim.cmd("redraw!")
  local function preview_attr(row, needle)
    local text = api.nvim_buf_get_lines(p.buf, row - 1, row, false)[1]
    local byte = assert(text:find(needle, 1, true))
    local cell = vim.fn.screenpos(p.win, row, byte)
    assert(cell.row > 0 and cell.col > 0, "preview segment is visible")
    return vim.fn.screenattr(cell.row, cell.col)
  end
  assert(
    preview_attr(p.code_start, "local") ~= preview_attr(p.code_start, "hello"),
    "Lua keywords and strings have distinct colors in the actual preview"
  )
  assert(
    preview_attr(p.code_start, "local") ~= preview_attr(p.code_start + 1, "local"),
    "the target line has a visible background"
  )
  assert(
    preview_attr(1, "init.lua") ~= preview_attr(3, "类型错误"),
    "path and diagnostic message have distinct preview colors"
  )
  api.nvim_win_set_cursor(v.win, { first + 1, 0 })
  api.nvim_input("]q")
  wait(function()
    return results.selected(v).text == "Unused local `options`."
  end, "next result skips multiline continuation")
  api.nvim_input(vim.keycode("<LocalLeader>?"))
  wait(function()
    return v.help
  end, "real help key opens popup")
  api.nvim_input("<Esc>")
  wait(function()
    return not v.help and api.nvim_get_current_win() == v.win
  end, "help closes back into list")
  api.nvim_input("<Esc>")
  wait(function()
    return not results.current("diagnostics")
  end, "diagnostic view closes")
  v = tools.results({
    {
      bufnr = one,
      section = "References",
      text = "local value = alpha(1)",
      pos = { 1, 4 },
      source = "LSP",
    },
    {
      bufnr = two,
      section = "References",
      text = "return alpha",
      pos = { 3, 0 },
      source = "LSP",
    },
  }, {
    id = "narrow",
    title = "LSP · alpha",
    position = "right",
    width = 0.35,
    focus = true,
    group_by = { "section", "file" },
  })
  vim.cmd("redraw!")
  lines = api.nvim_buf_get_lines(v.out, 0, -1, false)
  local text = table.concat(lines, "\n")
  assert(
    text:find("lua/results", 1, true) and text:find("lua/sources", 1, true),
    "same-name files retain directory context"
  )
  assert(api.nvim_win_get_width(v.win) < 60 and vim.wo[v.win].winbar:find("LSP", 1, true))
  capture[#capture + 1] = ""
  capture[#capture + 1] = "Right LSP (" .. api.nvim_win_get_width(v.win) .. " columns)"
  vim.list_extend(capture, lines)
  results.close("narrow")
  assert(api.nvim_get_current_win() == source and #api.nvim_list_wins() == 1)
  if vim.env.LSP_TOOLS_APPEARANCE_CAPTURE then
    vim.fn.writefile(capture, vim.env.LSP_TOOLS_APPEARANCE_CAPTURE)
  end
  return vim.g.colors_name
end

local thread = coroutine.create(run)
local function step()
  local ok, value = coroutine.resume(thread)
  if not ok then
    vim.fn.writefile(
      { tostring(value), debug.traceback(thread) },
      vim.env.LSP_TOOLS_TEST_TMP .. "/result"
    )
    vim.cmd("cquit 1")
  elseif coroutine.status(thread) == "dead" then
    vim.fn.writefile({
      "result appearance: "
        .. value
        .. ", bottom/right layouts, preview syntax colors, multiline navigation and help keys passed",
    }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 50)
