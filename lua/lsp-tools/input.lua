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
  -- Preserve a readable label for providers that only support vim.ui.input.
  if
    opts.title ~= nil
    or opts.title_pos ~= nil
    or opts.position ~= nil
    or opts.width ~= nil
    or opts.vim_mode ~= nil
  then
    local title = opts.title
    opts = vim.tbl_extend("force", {}, opts)
    opts.title, opts.title_pos, opts.position, opts.width, opts.vim_mode = nil, nil, nil, nil, nil
    if type(title) == "string" and title ~= "" and (opts.prompt == nil or opts.prompt == "") then
      opts.prompt = title .. ": "
    end
  end
  return vim.ui.input(opts, on_confirm)
end

return M
