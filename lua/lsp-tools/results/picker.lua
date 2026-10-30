local M = {}
local api = vim.api
local pending = {}

local function item(value, cwd, source)
  local file = value.file or value.filename
  if file then
    file = vim.startswith(file, "/") and vim.fs.normalize(file)
      or vim.fs.abspath(vim.fs.joinpath(value.cwd or cwd, file))
  end
  return {
    bufnr = value.buf or value.bufnr,
    filename = file,
    uri = value.uri,
    pos = value.pos and vim.deepcopy(value.pos) or { 1, 0 },
    end_pos = value.end_pos and vim.deepcopy(value.end_pos),
    text = value.line or value.comment or value.label or value.name or value.detail or value.text,
    severity = value.severity,
    source = source,
    data = { picker_item = value },
  }
end

---Import a Snacks-compatible picker snapshot, after its source window is restored.
function M.open(results, picker, opts)
  opts = opts or {}
  local kind = opts.type or "smart"
  assert(kind == "smart" or kind == "all" or kind == "selected", "Unknown picker import type")
  if picker.closed then
    return false
  end
  local tab = api.nvim_get_current_tabpage()
  if pending[tab] then
    pending[tab].cancel()
  end
  local chosen = picker:selected()
  if kind == "all" or kind == "smart" and #chosen == 0 then
    chosen = picker:items()
  end
  local cwd = picker:cwd() or vim.fn.getcwd()
  local source = opts.source or (picker.opts or {}).source or "picker"
  local items = {}
  for _, value in ipairs(chosen) do
    items[#items + 1] = item(value, cwd, source)
  end
  local ctx
  if picker.main and api.nvim_win_is_valid(picker.main) then
    ctx = api.nvim_win_call(picker.main, require("lsp-tools.request").context)
  end
  local options = vim.tbl_extend("force", {
    id = "picker",
    title = "Picker · " .. source,
    sort = "none",
  }, opts, { context = ctx })
  local token = { active = true }
  function token.cancel()
    token.active = false
    if pending[tab] == token then
      pending[tab] = nil
    end
  end
  pending[tab] = token
  picker:close()
  vim.schedule(function()
    if not token.active then
      return
    end
    token.cancel()
    if
      api.nvim_get_current_tabpage() ~= tab
      or ctx and (not api.nvim_win_is_valid(ctx.win) or not api.nvim_buf_is_valid(ctx.buf))
    then
      return
    end
    local append = opts.append or opts.add
    local initial
    if not append then
      initial = items
    end
    local view = results.open(initial, options)
    if view and append then
      results.set_items(view, items, true)
    end
  end)
  return token
end

function M.cancel()
  for _, token in pairs(vim.tbl_extend("force", {}, pending)) do
    token.cancel()
  end
end
return M
