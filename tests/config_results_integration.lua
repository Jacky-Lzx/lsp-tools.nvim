-- Opt-in verification of the user's real Lazy mappings and picker bridge.
local function run()
  local config = assert(vim.env.LSP_TOOLS_NVIM_CONFIG, "Set LSP_TOOLS_NVIM_CONFIG")
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  vim.env.NVIM_CONFIG_ROOT, vim.env.NVIM_SMOKE_TEST = config, "1"
  vim.env.NVIM_LAZY_LOCKFILE = directory .. "/lock.json"
  vim.opt.rtp:prepend(config)
  require("config.context").initialize({ profiles = {}, features = {} })
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
  results.select(v, v.items[1].id)
  api.nvim_set_current_win(v.win)
  api.nvim_input("<CR>")
  wait(function()
    return api.nvim_get_current_win() == win and api.nvim_win_get_cursor(win)[2] == 4
  end, "imported source jump")
  api.nvim_set_current_win(v.win)
  api.nvim_input("q")
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
    if binding[2] == "lsp" then
      wait(function()
        return v.status and v.status:find("unsupported", 1, true)
      end, "unsupported methods reported")
      local position = api.nvim_win_get_position(v.win)
      assert(position[2] > api.nvim_win_get_position(win)[2], "LSP panel remains on the right")
    else
      assert(#v.items == 1, "configured source projects canonical content")
    end
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
    vim.fn.writefile(
      { "configured terminal: lazy Snacks <C-t>, diagnostic/LSP/quickfix/loclist toggles passed" },
      vim.env.LSP_TOOLS_TEST_TMP .. "/result"
    )
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 50)
