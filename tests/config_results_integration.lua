-- Opt-in verification of the user's real Lazy mappings and picker bridge.
local function run()
  local config = assert(vim.env.LSP_TOOLS_NVIM_CONFIG, "Set LSP_TOOLS_NVIM_CONFIG")
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  vim.env.NVIM_CONFIG_ROOT, vim.env.NVIM_SMOKE_TEST = config, "1"
  vim.env.NVIM_LAZY_LOCKFILE = directory .. "/lock.json"
  vim.opt.rtp:prepend(config)
  local debugging = vim.env.LSP_TOOLS_TEST_DEBUGGING == "1"
  require("config.context").initialize({ profiles = {}, features = { debugging = debugging } })
  vim.g.loaded_wakatime = true
  vim.o.loadplugins = true
  dofile(config .. "/init.lua")
  local api = vim.api
  local function wait(test, message)
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 8000, message)
      coroutine.yield()
    end
  end
  local plugins = require("lazy.core.config").plugins
  local spec = assert(plugins["lsp-tools.nvim"])
  assert(vim.uv.fs_realpath(spec.dir) == vim.uv.fs_realpath(vim.env.LSP_TOOLS_ROOT))
  assert(not plugins["trouble.nvim"] and not package.loaded["trouble"])
  vim.cmd("enew!")
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_name(buf, directory .. "/source.txt")
  api.nvim_buf_set_lines(buf, 0, -1, false, { "😀alpha", "beta" })
  assert(not spec._.loaded and not package.loaded["lsp-tools.results"])
  local p = require("snacks").picker({
    source = "configured-results",
    items = { { file = "source.txt", buf = buf, pos = { 1, 4 }, text = "alpha" } },
    cwd = directory,
    format = "file",
    preview = "none",
    show_delay = 0,
  })
  wait(function()
    return p:current() and p.input.win:valid() and vim.fn.mode():sub(1, 1) == "i"
  end, "configured picker ready")
  assert(not spec._.loaded, "configuring and opening a picker must keep LSP tools deferred")
  api.nvim_input("<C-t>")
  local results, v
  wait(function()
    results = package.loaded["lsp-tools.results"]
    v = results and results.current("picker")
    return v and #v.items == 1
  end, "configured Insert <C-t> loads plugin and imports results without an LSP")
  assert(spec._.loaded and p.closed and v.ctx.win == win and api.nvim_get_current_win() == win)
  assert(not package.loaded["lsp-tools.results.sources.lsp"])
  api.nvim_set_current_win(v.win)
  require("which-key")
  wait(function()
    for _, mapping in ipairs(api.nvim_buf_get_keymap(v.out, "n")) do
      if mapping.desc and mapping.desc:find("which-key-trigger", 1, true) then
        return true
      end
    end
  end, "actual which-key installs its automatic buffer triggers")
  local grouping = vim.deepcopy(v.group_by)
  api.nvim_input("G")
  wait(function()
    return api.nvim_win_get_cursor(v.win)[1] == api.nvim_buf_line_count(v.out)
  end, "native G reaches the final row")
  api.nvim_input("gg")
  wait(function()
    return api.nvim_win_get_cursor(v.win)[1] == 1
  end, "native gg works with actual which-key active")
  assert(vim.deep_equal(grouping, v.group_by), "gg must not toggle grouping")
  api.nvim_input("G0fa")
  local last = api.nvim_buf_line_count(v.out)
  local line = api.nvim_buf_get_lines(v.out, last - 1, last, false)[1]
  local col = assert(line:find("alpha", 1, true)) - 1
  wait(function()
    return api.nvim_win_get_cursor(v.win)[2] == col
  end, "native f finds a character")
  api.nvim_input("e")
  wait(function()
    return api.nvim_win_get_cursor(v.win)[2] == col + 4
  end, "native e moves to word end")
  api.nvim_input("b")
  wait(function()
    return api.nvim_win_get_cursor(v.win)[2] == col
  end, "native b moves to word start")
  api.nvim_input("?alpha<CR>")
  wait(function()
    return vim.fn.getreg("/") == "alpha" and vim.fn.mode() == "n"
  end, "question mark retains native backward search")
  assert(not v.help)
  api.nvim_input(vim.keycode("<LocalLeader>?"))
  wait(function()
    return v.help
  end, "Space question mark opens result help")
  local help = table.concat(api.nvim_buf_get_lines(v.help.buf, 0, -1, false), "\n")
  assert(
    help:find("<Space>f", 1, true) and not help:find("which-key-trigger", 1, true),
    "owned help excludes actual which-key internals and displays the configured prefix"
  )
  api.nvim_input("<Esc>")
  wait(function()
    return not v.help and api.nvim_get_current_win() == v.win
  end, "Escape closes help")
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'local alpha = "hello"', "return alpha" })
  vim.bo[buf].filetype = "lua"
  results.select(v, v.items[1].id)
  api.nvim_input(vim.keycode("<LocalLeader>p"))
  wait(function()
    return v.preview
  end, "configured preview opens")
  local preview = v.preview
  assert(preview.highlight_backend == "treesitter" and preview.filetype == "lua")
  require("lualine").refresh({ scope = "tabpage", place = { "winbar" }, force = true })
  assert(vim.wo[preview.win].winbar == "", "lualine leaves the preview float alone")
  vim.cmd("redraw!")
  local keyword = vim.fn.screenpos(preview.win, preview.code_start, 1)
  local literal = vim.fn.screenpos(preview.win, preview.code_start, 16)
  assert(
    keyword.row > 0
      and literal.row > 0
      and vim.fn.screenattr(keyword.row, keyword.col)
        ~= vim.fn.screenattr(literal.row, literal.col),
    "actual configured preview displays distinct Lua keyword/string colors"
  )
  assert(
    vim.fn.screenpos(preview.win, 1, 1).row > 0,
    "preview metadata stays visible despite the source scrolloff"
  )
  results.select(v, v.items[1].id)
  api.nvim_set_current_win(v.win)
  api.nvim_input("<CR>")
  wait(function()
    return api.nvim_get_current_win() == win and api.nvim_win_get_cursor(win)[2] == 4
  end, "imported source jump")
  api.nvim_set_current_win(v.win)
  api.nvim_input("<Esc>")
  wait(function()
    return not results.current("picker")
  end, "snapshot closes")
  local ns = api.nvim_create_namespace("configured-results")
  vim.diagnostic.set(ns, buf, { { lnum = 0, col = 4, message = "warning", severity = 2 } })
  vim.fn.setqflist({}, " ", {
    title = "Configured build",
    items = { { bufnr = buf, lnum = 2, col = 1, text = "build row" } },
  })
  vim.fn.setloclist(win, {}, " ", {
    title = "Configured local",
    items = { { bufnr = buf, lnum = 1, col = 5, text = "local row" } },
  })
  for _, binding in ipairs({
    { "gd", "diagnostics" },
    { "gq", "qflist" },
    { "gL", "loclist" },
    { "gl", "lsp" },
  }) do
    api.nvim_set_current_win(win)
    api.nvim_input(vim.g.mapleader .. binding[1])
    wait(function()
      v = results.current(binding[2])
      return v
    end, "configured " .. binding[1] .. " opens result view")
    assert(api.nvim_get_current_win() == win, "opening retains source focus")
    local lualine = require("lualine")
    local excluded = lualine.get_config().options.disabled_filetypes.winbar
    assert(
      vim.tbl_contains(excluded, "lsp-tools-results"),
      "resolved winbar exclusions retain result windows"
    )
    if debugging then
      for _, filetype in ipairs({ "dap-view", "dap-view-term", "dap-repl" }) do
        assert(vim.tbl_contains(excluded, filetype), "resolved exclusions also retain " .. filetype)
      end
    end
    lualine.refresh({ scope = "tabpage", place = { "winbar" }, force = true })
    assert(
      vim.wo[v.win].winbar:find("LspToolsResultsTitle", 1, true),
      "lualine refresh preserves the result title bar"
    )
    if binding[2] == "diagnostics" then
      api.nvim_set_current_win(v.win)
      api.nvim_input("ggzc")
      wait(function()
        return api.nvim_win_call(v.win, function()
          return vim.fn.foldclosed(1) == 1
        end)
      end, "native zc closes diagnostics with actual which-key enabled")
      local foreign_bars = {}
      api.nvim_create_autocmd("OptionSet", {
        group = v.group,
        pattern = "winbar",
        callback = function()
          if api.nvim_win_is_valid(v.win) then
            local bar = vim.wo[v.win].winbar
            if not bar:find("LspToolsResultsTitle", 1, true) then
              foreign_bars[#foreign_bars + 1] = bar
            end
          end
        end,
      })
      local deadline, iteration = vim.uv.hrtime() + 3e9, 0
      while vim.uv.hrtime() < deadline do
        iteration = iteration + 1
        api.nvim_set_current_win(iteration % 2 == 0 and v.win or win)
        vim.diagnostic.set(
          ns,
          buf,
          { { lnum = 0, col = 4, message = "warning " .. iteration, severity = 2 } }
        )
        lualine.refresh({ scope = "tabpage", place = { "winbar" }, force = true })
        local next_frame = vim.uv.hrtime() + 100e6
        while vim.uv.hrtime() < next_frame do
          coroutine.yield()
        end
        assert(
          vim.wo[v.win].winbar:find("LspToolsResultsTitle", 1, true),
          "focus, diagnostic and timer refreshes keep the result winbar stable"
        )
        assert(
          api.nvim_win_call(v.win, function()
            return vim.fn.foldclosed(1) == 1
          end),
          "live diagnostic refresh preserves the native closed directory"
        )
      end
      wait(function()
        return v.items[1].text == "warning " .. iteration
      end, "live diagnostics continue refreshing while the title stays stable")
      assert(
        #foreign_bars == 0,
        "no intermediate filename/empty winbar was written: " .. vim.inspect(foreign_bars)
      )
      vim.cmd("redraw!")
      local first = vim.fn.screenpos(v.win, 1, 1)
      local bar = ""
      for col = first.col, first.col + api.nvim_win_get_width(v.win) - 1 do
        bar = bar .. vim.fn.screenstring(first.row - 1, col)
      end
      assert(
        bar:find("Diagnostics", 1, true) and not bar:find("[No Name]", 1, true),
        "actual terminal retains the diagnostics title after repeated refreshes"
      )
      api.nvim_set_current_win(v.win)
      api.nvim_input("zR")
      wait(function()
        return api.nvim_win_call(v.win, function()
          return vim.fn.foldclosed(2) == -1
        end)
      end, "native zR opens diagnostics after live refreshes")
    end
    if binding[2] == "lsp" then
      wait(function()
        return v.status and v.status:find("unsupported", 1, true)
      end, "unsupported methods reported")
      local position = api.nvim_win_get_position(v.win)
      assert(position[2] > api.nvim_win_get_position(win)[2], "LSP panel remains on the right")
    else
      assert(#v.items == 1, "configured source projects canonical content")
    end
    api.nvim_set_current_win(v.win)
    api.nvim_input(vim.g.mapleader .. binding[1])
    wait(function()
      return not results.current(binding[2])
    end, "configured entry toggles closed")
  end
  assert(#api.nvim_list_wins() == 1 and not package.loaded["trouble"])
end

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
    vim.fn.writefile({
      "configured terminal: lazy picker, native Vim keys, clean help, stable winbars (debugging="
        .. tostring(vim.env.LSP_TOOLS_TEST_DEBUGGING == "1")
        .. ") and result toggles passed",
    }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 50)
