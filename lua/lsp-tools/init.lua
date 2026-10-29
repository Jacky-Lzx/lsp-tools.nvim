local M = {}

---Configure independently enabled LSP tools. No key mappings are installed.
---@param opts? {code_actions?: boolean|table}
function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "lsp-tools options must be a table")
  local actions = opts.code_actions
  assert(
    actions == nil or type(actions) == "boolean" or type(actions) == "table",
    "code_actions must be a boolean or table"
  )
  if actions == false or type(actions) == "table" and actions.enabled == false then
    local loaded = package.loaded["lsp-tools.code_actions"]
    if loaded then
      loaded.disable()
    end
  else
    require("lsp-tools.code_actions").setup(type(actions) == "table" and actions or {})
  end
  return M
end

---Request code actions using Neovim's native range, context, and filter handling.
---@param opts? table
function M.code_action(opts)
  return vim.lsp.buf.code_action(opts)
end

return M
