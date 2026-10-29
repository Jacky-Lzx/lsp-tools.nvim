local M = {}

---Configure independently enabled LSP tools. No key mappings are installed.
---@param opts? {code_actions?: boolean|table, references?: boolean|table}
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
  return M
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
