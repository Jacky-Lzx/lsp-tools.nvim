-- Owned scratch side windows. Opening a tool never reuses another tool's window.
local M = {}
local sessions = {}

function M.alive(s)
  return s
    and not s.closed
    and vim.api.nvim_win_is_valid(s.win)
    and vim.api.nvim_buf_is_valid(s.out)
    and vim.api.nvim_win_get_buf(s.win) == s.out
end

function M.get(name)
  local s = sessions[name .. ":" .. vim.api.nvim_get_current_tabpage()]
  return M.alive(s) and s or nil
end

function M.source(s, restore)
  local ctx = s.ctx
  if not vim.api.nvim_win_is_valid(ctx.win) or not vim.api.nvim_buf_is_valid(ctx.buf) then
    return false
  end
  if vim.api.nvim_win_get_buf(ctx.win) ~= ctx.buf then
    if not restore then
      return false
    end
    vim.api.nvim_win_set_buf(ctx.win, ctx.buf)
  end
  vim.api.nvim_set_current_win(ctx.win)
  if restore then
    local line = math.min(ctx.pos[1], vim.api.nvim_buf_line_count(ctx.buf))
    vim.api.nvim_win_set_cursor(ctx.win, { line, ctx.pos[2] })
  end
  return true
end

function M.close(s)
  if not s or s.closed then
    return
  end
  s.closed = true
  sessions[s.key] = nil
  if s.on_close then
    s.on_close()
  end
  if s.group then
    vim.api.nvim_del_augroup_by_id(s.group)
  end
  if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.out then
    vim.api.nvim_win_close(s.win, true)
  end
  if vim.api.nvim_buf_is_valid(s.out) then
    vim.api.nvim_buf_delete(s.out, { force = true })
  end
end

function M.write(s, lines)
  if not M.alive(s) then
    return
  end
  vim.bo[s.out].modifiable = true
  vim.api.nvim_buf_set_lines(s.out, 0, -1, false, lines)
  vim.bo[s.out].modifiable = false
end

function M.open(name, ctx, opts)
  opts = opts or {}
  local existing = M.get(name)
  if existing then
    M.close(existing)
  end
  local original = vim.api.nvim_get_current_win()
  local out = vim.api.nvim_create_buf(false, true)
  vim.bo[out].bufhidden = "wipe"
  vim.bo[out].filetype = opts.filetype or "lsp-tools-" .. name
  local width = opts.width or 0.35
  width = math.max(
    1,
    math.min(vim.o.columns - 2, math.floor(width <= 1 and vim.o.columns * width or width))
  )
  local win = vim.api.nvim_open_win(
    out,
    opts.focus ~= false,
    { split = "right", win = ctx.win, width = width }
  )
  for option, value in pairs({
    number = false,
    relativenumber = false,
    wrap = true,
    spell = false,
    signcolumn = "no",
    foldcolumn = "0",
    winfixwidth = true,
  }) do
    vim.wo[win][option] = value
  end
  local key = name .. ":" .. vim.api.nvim_get_current_tabpage()
  local s = { key = key, out = out, win = win, ctx = ctx }
  sessions[key] = s
  local function close()
    if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_is_valid(ctx.win) then
      vim.api.nvim_set_current_win(ctx.win)
    end
    M.close(s)
  end
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = out, nowait = true, desc = "Close tool" })
  end
  s.group = vim.api.nvim_create_augroup("LspToolsPanel" .. out, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = s.group,
    pattern = tostring(win),
    callback = function()
      M.close(s)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = s.group,
    buffer = ctx.buf,
    callback = function()
      M.close(s)
    end,
  })
  if opts.focus == false and vim.api.nvim_win_is_valid(original) then
    vim.api.nvim_set_current_win(original)
  end
  return s
end

return M
