local M = {}

---Configure independently enabled LSP tools. No key mappings are installed.
---@param opts? {code_actions?: boolean|table, references?: boolean|table, rename?: boolean|table, outline?: boolean|table}
function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "lsp-tools options must be a table")
  local actions = opts.code_actions
  assert(
    actions == nil or type(actions) == "boolean" or type(actions) == "table",
    "code_actions must be a boolean or table"
  )
  local references = opts.references
  assert(
    references == nil or type(references) == "boolean" or type(references) == "table",
    "references must be a boolean or table"
  )
  local rename = opts.rename
  local outline = opts.outline
  assert(
    outline == nil or type(outline) == "boolean" or type(outline) == "table",
    "outline must be a boolean or table"
  )
  assert(
    rename == nil or type(rename) == "boolean" or type(rename) == "table",
    "rename must be a boolean or table"
  )
  if actions == false or type(actions) == "table" and actions.enabled == false then
    local loaded = package.loaded["lsp-tools.code_actions"]
    if loaded then
      loaded.disable()
    end
  else
    require("lsp-tools.code_actions").setup(type(actions) == "table" and actions or {})
  end
  if references == false or type(references) == "table" and references.enabled == false then
    local loaded = package.loaded["lsp-tools.references"]
    if loaded then
      loaded.disable()
    end
  else
    require("lsp-tools.references").setup(type(references) == "table" and references or {})
  end
  if rename == false or type(rename) == "table" and rename.enabled == false then
    local loaded = package.loaded["lsp-tools.rename"]
    if loaded then
      loaded.disable()
    end
  else
    require("lsp-tools.rename").setup(type(rename) == "table" and rename or {})
  end
  if outline == false or type(outline) == "table" and outline.enabled == false then
    local loaded = package.loaded["lsp-tools.outline"]
    if loaded then
      loaded.disable()
    end
  else
    require("lsp-tools.outline").setup(type(outline) == "table" and outline or {})
  end
  return M
end

function M.open_outline(opts)
  return require("lsp-tools.outline").open(opts)
end

function M.toggle_outline()
  return require("lsp-tools.outline").toggle()
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
  return require("lsp-tools.rename").rename(new_name, opts)
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
  return require("lsp-tools.references").jump(count, opts)
end

---Request code actions using Neovim's native range, context, and filter handling.
---@param opts? table
function M.code_action(opts)
  return vim.lsp.buf.code_action(opts)
end

return M
