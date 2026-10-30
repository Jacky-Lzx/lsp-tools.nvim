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
}
local defaults =
  { code_actions = true, references = true, rename = true, outline = true, breadcrumbs = true }
local automatic = {
  code_actions = true,
  references = true,
  breadcrumbs = true,
  lightbulb = true,
  linked_editing = true,
}
local options, enabled, ready = {}, {}, {}

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

---Configure tools without loading interactive implementations. No mappings are installed.
---@param opts? table
function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "lsp-tools options must be a table")
  local validation = require("lsp-tools.config")
  local pending = {}
  -- Validate the complete update before changing existing tool state.
  for _, name in ipairs(names) do
    local value = opts[name]
    assert(
      value == nil or type(value) == "boolean" or type(value) == "table",
      name .. " must be a boolean or table"
    )
    if value ~= nil or defaults[name] then
      local on = value ~= false and not (type(value) == "table" and value.enabled == false)
      local config = options[name] or {}
      if on then
        if name == "outline" or name == "breadcrumbs" then
          config = {}
        end
        config = vim.tbl_deep_extend("force", {}, config, type(value) == "table" and value or {})
        validation.tool(name, config)
      end
      pending[name] = { enabled = on, options = config }
    end
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
      elseif automatic[name] then
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
    end
  end
  if enabled.outline then
    for command, method in pairs({
      LspToolsOutline = "toggle_outline",
      LspToolsOutlineOpen = "open_outline",
      LspToolsOutlineClose = "close_outline",
    }) do
      vim.api.nvim_create_user_command(command, function()
        return M[method]()
      end, { force = true, desc = command })
    end
  end
  return M
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

return M
