-- Opt-in test against an editable Neovim config using this development checkout.
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
  local function wait(test, message)
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 10000, message)
      coroutine.yield()
    end
  end
  local spec = assert(require("lazy.core.config").plugins["lsp-tools.nvim"])
  assert(
    vim.uv.fs_realpath(spec.dir) == vim.uv.fs_realpath(vim.env.LSP_TOOLS_ROOT),
    "Config must use this checkout"
  )
  vim.cmd("enew!")
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(buf, directory .. "/main.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
  local opener = require("utils.open")
  local original, fallbacks = opener.open_at_cursor, 0
  opener.open_at_cursor = function()
    fallbacks = fallbacks + 1
  end
  assert(not spec._.loaded and not package.loaded["lsp-tools"], "plugin starts unloaded")
  vim.api.nvim_input("go")
  wait(function()
    return fallbacks == 1
  end, "terminal go reaches path fallback")
  assert(not spec._.loaded and not package.loaded["lsp-tools"], "path open keeps plugin unloaded")
  local id = assert(vim.lsp.start({
    name = "lazy-config-fixture",
    cmd = { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/server.py" },
    root_dir = directory,
  }))
  local client = vim.lsp.get_client_by_id(id)
  wait(function()
    return client.initialized and spec._.loaded
  end, "LspAttach loads lightweight setup")
  for _, name in ipairs({
    "rename",
    "outline",
    "diagnostics",
    "hover",
    "links",
    "inspect",
    "hierarchy",
    "results",
    "results.picker",
    "results.sources.diagnostics",
    "results.sources.lsp",
    "workspace_edit",
    "panel",
    "code_actions.picker",
    "code_actions.preview",
    "code_actions.render",
    "breadcrumbs",
    "linked_editing",
    "references",
  }) do
    assert(not package.loaded["lsp-tools." .. name], name .. " remains deferred after attachment")
  end
  vim.api.nvim_input(" a")
  local function picker()
    return require("lsp-tools.selection").current()
  end
  wait(function()
    return picker() and picker():current()
  end, "first code-action key opens picker")
  local p = picker()
  wait(function()
    return vim.api.nvim_win_get_buf(p.preview_win)
      and table
        .concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(p.preview_win), 0, -1, false), "\n")
        :find("你好😀", 1, true)
  end, "first action resolves and previews")
  assert(
    package.loaded["lsp-tools.code_actions.picker"] and not package.loaded["lsp-tools.rename"],
    "action loads only its interactive implementation"
  )
  vim.api.nvim_input("<Esc>")
  wait(function()
    return not picker() and vim.api.nvim_get_current_win() == win
  end, "cancel restores source focus")
  vim.api.nvim_input(" go")
  local function sidebar()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "lsp-tools-outline" then
        return w
      end
    end
  end
  wait(function()
    return sidebar()
  end, "first outline key opens sidebar")
  local out = sidebar()
  assert(
    package.loaded["lsp-tools.outline"] and not package.loaded["lsp-tools.hover"],
    "outline leaves unrelated views deferred"
  )
  vim.api.nvim_set_current_win(out)
  vim.api.nvim_input(vim.keycode("<LocalLeader>q"))
  wait(function()
    return not sidebar() and vim.api.nvim_get_current_win() == win
  end, "closing sidebar restores source")
  assert(
    not pcall(vim.api.nvim_get_autocmds, { group = "LspToolsOutline" }),
    "closed sidebar leaves no listeners"
  )
  assert(
    vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "hello world",
    "first-use checks preserve source"
  )
  opener.open_at_cursor = original
  client:stop(true)
  wait(function()
    return vim.lsp.get_client_by_id(id) == nil
  end, "fixture transport exits")
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
      { "configured terminal lazy first-use paths passed" },
      vim.env.LSP_TOOLS_TEST_TMP .. "/result"
    )
    vim.cmd("qa!")
  else
    vim.defer_fn(step, 10)
  end
end
vim.defer_fn(step, 50)
