local M = {}
local names = {
  "code_actions",
  "references",
  "rename",
  "outline",
  "breadcrumbs",
  "lightbulb",
  "linked_editing",
  "diagnostics",
  "hover",
  "links",
  "inspect",
  "hierarchy",
  "results",
  "pickers",
}
local defaults =
  { code_actions = true, references = true, rename = true, outline = true, breadcrumbs = true }
local automatic = {
  references = "textDocument/documentHighlight",
  breadcrumbs = "textDocument/documentSymbol",
  lightbulb = "textDocument/codeAction",
  linked_editing = "textDocument/linkedEditingRange",
}
local options, enabled, ready = {}, {}, {}
local automatic_group, activating

local function load(name)
  if not enabled[name] then
    return nil
  end
  local module = require("lsp-tools." .. name)
  if ready[name] ~= module then
    module.setup(options[name])
    ready[name] = module
  end
  return module
end

local function call(name, method, ...)
  local module = load(name)
  if module then
    return module[method](...)
  end
  return false
end

local function pending_automatic()
  for name in pairs(automatic) do
    if enabled[name] and not ready[name] then
      return true
    end
  end
  return false
end

local function activate(buf)
  if
    activating
    or not vim.api.nvim_buf_is_valid(buf)
    or vim.bo[buf].buftype ~= ""
    or #vim.fn.win_findbuf(buf) == 0
  then
    return
  end
  activating = true
  local ok, err = pcall(function()
    for _, name in ipairs(names) do
      local method = automatic[name]
      if
        method
        and enabled[name]
        and not ready[name]
        and #vim.lsp.get_clients({ bufnr = buf, method = method }) > 0
      then
        load(name)
      end
    end
  end)
  activating = false
  if not pending_automatic() and automatic_group then
    vim.api.nvim_del_augroup_by_id(automatic_group)
    automatic_group = nil
  end
  if not ok then
    error(err)
  end
end

local function watch_automatic()
  if automatic_group then
    vim.api.nvim_del_augroup_by_id(automatic_group)
    automatic_group = nil
  end
  if not pending_automatic() then
    return
  end
  automatic_group = vim.api.nvim_create_augroup("LspToolsAutomatic", { clear = true })
  -- Cursor checks also catch capabilities dynamically registered after LspAttach.
  -- Until then these checks allocate no timers, highlights or per-buffer sessions.
  vim.api.nvim_create_autocmd({ "LspAttach", "BufEnter", "CursorMoved", "CursorMovedI" }, {
    group = automatic_group,
    callback = function(ev)
      activate(ev.buf)
    end,
  })
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    activate(vim.api.nvim_win_get_buf(win))
  end
end

---Configure tools without loading interactive implementations. No mappings are installed.
---@param opts? table
local function configure(opts, incremental)
  assert(opts == nil or type(opts) == "table", "lsp-tools: setup expects a table")
  opts = vim.deepcopy(opts or {})
  assert(
    opts.lua == nil or opts.lua == false,
    'lsp-tools: Lua libraries moved to lua-tools.nvim; move lua options to require("lua_tools").setup()'
  )
  if not incremental and opts.ui == nil then
    opts.ui = {}
  end
  if incremental and opts.ui ~= nil then
    opts.ui = vim.tbl_deep_extend("force", require("lsp-tools.keymaps").config(), opts.ui)
  end
  assert(type(opts) == "table", "lsp-tools options must be a table")
  local validation = require("lsp-tools.config")
  if opts.ui ~= nil then
    require("lsp-tools.keymaps").validate(opts.ui)
  end
  local pending = {}
  -- Validate supplied options before changing existing tool state.
  for _, name in ipairs(names) do
    local value = opts[name]
    assert(
      value == nil or type(value) == "boolean" or type(value) == "table",
      name .. " must be a boolean or table"
    )
    if not incremental or value ~= nil then
      local on = value ~= nil
          and value ~= false
          and not (type(value) == "table" and value.enabled == false)
        or value == nil and defaults[name] == true
      local config = incremental and options[name] or {}
      if on then
        config = vim.tbl_deep_extend("force", {}, config, type(value) == "table" and value or {})
        validation.tool(name, config)
      end
      pending[name] = { enabled = on, options = config }
    end
  end
  local servers = (
    opts.servers ~= nil
    or opts.server_activation ~= nil
    or opts.server_filetypes ~= nil
    or opts.server_provider ~= nil
  )
      and require("lsp-tools.servers")
    or nil
  local server_updates = servers
    and servers.prepare(
      opts.servers == nil and {} or opts.servers,
      opts.server_activation,
      opts.server_filetypes,
      opts.server_provider
    )
  if opts.ui ~= nil then
    require("lsp-tools.keymaps").configure(opts.ui)
  end
  for _, name in ipairs(names) do
    local update = pending[name]
    if update then
      enabled[name], options[name], ready[name] = update.enabled, update.options, nil
      local module = package.loaded["lsp-tools." .. name]
      if not update.enabled then
        if module then
          module.disable()
        end
      elseif module then
        module.setup(update.options)
        ready[name] = module
      elseif name == "code_actions" then
        load(name)
      end
      if name == "inspect" then
        local recorder = package.loaded["lsp-tools.inspect.recorder"]
        if update.enabled then
          require("lsp-tools.inspect.recorder").setup()
        elseif recorder then
          recorder.disable()
        end
      end
      if name == "hover" then
        local float = package.loaded["lsp-tools.hover.float"]
        if update.enabled then
          require("lsp-tools.hover.float").setup(update.options.float)
        elseif float then
          float.disable()
        end
      end
    end
  end
  watch_automatic()
  require("lsp-tools.user_command").create("LspToolsInfo", function()
    return M.inspect()
  end, { desc = "Inspect LSP clients, roots, providers and requests" })
  if enabled.outline then
    for command, method in pairs({
      LspToolsOutline = "toggle_outline",
      LspToolsOutlineOpen = "open_outline",
      LspToolsOutlineClose = "close_outline",
    }) do
      require("lsp-tools.user_command").create(command, function()
        return M[method]()
      end, { force = true, desc = command })
    end
  end
  if servers then
    servers.apply(server_updates)
  end
  return M
end
---Configure all features from fresh defaults. Native server definitions remain native overlays.
function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "lsp-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  return configure(opts, false)
end

---Apply a partial feature/service update without resetting unrelated features.
function M.update(opts)
  return configure(opts, true)
end

function M.dispose()
  if automatic_group then
    vim.api.nvim_del_augroup_by_id(automatic_group)
    automatic_group = nil
  end
  for _, name in ipairs(names) do
    local module = package.loaded["lsp-tools." .. name]
    if module then
      module.disable()
    end
  end
  for _, name in ipairs({ "hover.float", "inspect.recorder" }) do
    local module = package.loaded["lsp-tools." .. name]
    if module then
      module.disable()
    end
  end
  local servers = package.loaded["lsp-tools.servers"]
  if servers then
    servers.dispose()
  end
  local commands = require("lsp-tools.user_command")
  for _, name in ipairs({
    "LspToolsInfo",
    "LspToolsOutline",
    "LspToolsOutlineOpen",
    "LspToolsOutlineClose",
  }) do
    commands.delete(name)
  end
  options, enabled, ready = {}, {}, {}
  require("lsp-tools.keymaps").configure({})
end

function M.configuration()
  local servers = package.loaded["lsp-tools.servers"]
  local configs, _, activation, _, hints, provider
  if servers then
    configs, _, activation, _, hints, provider = servers.configuration()
  end
  return {
    enabled = vim.deepcopy(enabled),
    options = vim.deepcopy(options),
    ui = require("lsp-tools.keymaps").config(),
    servers = configs or {},
    server_activation = activation or "eager",
    server_filetypes = hints or {},
    server_provider = provider,
  }
end

---Inspect servers selected through setup without loading an interactive view.
---@param buf? integer
---@return table[]
function M.server_status(buf)
  if not package.loaded["lsp-tools.servers"] then
    return {}
  end
  return require("lsp-tools.servers.status").snapshot(buf)
end

---Render the enclosing symbol path for lualine or a native statusline/winbar.
---@param opts? {winid?: integer, color?: boolean, icons?: boolean}
---@return string
function M.breadcrumbs(opts)
  local loaded = package.loaded["lsp-tools.breadcrumbs"]
  return loaded and loaded.statusline(opts) or ""
end

function M.open_outline(opts)
  return call("outline", "open", opts)
end

function M.toggle_outline()
  return call("outline", "toggle")
end

function M.close_outline()
  local loaded = package.loaded["lsp-tools.outline"]
  if loaded then
    loaded.close()
  end
end

---Request and preview all workspace edits before applying a rename.
---@param new_name? string
---@param opts? table
function M.rename(new_name, opts)
  return call("rename", "rename", new_name, opts)
end

---Cancel the active rename request or preview.
function M.cancel_rename()
  local loaded = package.loaded["lsp-tools.rename"]
  if loaded then
    loaded.cancel()
  end
end

---Jump between references to the symbol under the cursor in the current document.
---@param count? integer Positive goes forward; negative goes backward.
---@param opts? {wrap?: boolean}
function M.jump_reference(count, opts)
  return call("references", "jump", count, opts)
end

---Request code actions using Neovim's native range, context, and filter handling.
---@param opts? table
function M.code_action(opts)
  return vim.lsp.buf.code_action(opts)
end

---Open persistent diagnostic details and contextual fixes for this buffer.
function M.diagnostic(opts)
  return call("diagnostics", "open", opts)
end

---Pin hover documentation in a searchable Markdown side window.
function M.hover(opts)
  return call("hover", "open", opts)
end

---Open the server's document link at the cursor, optionally falling back to a path opener.
function M.open_link(opts)
  return call("links", "open", opts)
end

---Inspect this buffer's clients, feature providers and recent request outcomes.
function M.inspect(opts)
  return call("inspect", "open", opts)
end

function M.call_hierarchy(opts)
  return call("hierarchy", "open", "call", opts)
end

function M.type_hierarchy(opts)
  return call("hierarchy", "open", "type", opts)
end

---Open a persistent location/result list; item positions use one-based rows and byte columns.
function M.results(items, opts)
  return call("results", "open", items, opts)
end
function M.results_history(opts)
  return call("results", "history", opts)
end
function M.diagnostics(opts)
  return call("results", "source", "diagnostics", opts)
end
function M.close_results(id)
  local module = package.loaded["lsp-tools.results"]
  if module then
    module.close(id)
  end
end

function M.quickfix(opts)
  return call("results", "source", "qflist", opts)
end
function M.loclist(opts)
  return call("results", "source", "loclist", opts)
end

function M.locations(opts)
  return call("results", "source", "lsp", opts)
end
function M.from_picker(picker, opts)
  return call("results", "from_picker", picker, opts)
end

---Search LSP locations and symbols using selection-tools. Enable pickers in setup().
for _, kind in ipairs({
  "definitions",
  "declarations",
  "references",
  "implementations",
  "type_definitions",
  "symbols",
  "workspace_symbols",
}) do
  M["lsp_" .. kind] = function(opts)
    return call("pickers", "open", kind, opts)
  end
end

---Search diagnostics already received by Neovim; persistent diagnostics() is unchanged.
function M.pick_diagnostics(opts)
  return call("pickers", "open", "diagnostics", opts)
end

return M
