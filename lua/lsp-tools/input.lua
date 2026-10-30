local M = {}

---Resolve the general input-tools API at use time, without a setup dependency.
---Missing/older input-tools installations fall back to the global provider.
---@param opts table
---@param on_confirm fun(value: string?)
function M.input(opts, on_confirm)
  local ok, tools = pcall(require, "input-tools")
  if ok and type(tools) == "table" and type(tools.input) == "function" then
    return tools.input(opts, on_confirm)
  end
  return vim.ui.input(opts, on_confirm)
end

return M
