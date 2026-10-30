local M = {}
local panel = require("lsp-tools.panel")
local request = require("lsp-tools.request")
local enabled = false
local config = { width = 0.35, request_timeout = 3000, advance_timeout = 5000 }
local sessions = {}
local render, refresh

local function identity(d)
  return table.concat(
    { d.namespace or "", d.lnum, d.col, d.message, d.code or "", d.source or "" },
    ":"
  )
end

local function signature(d)
  return table.concat({ d.namespace or "", d.message, d.code or "", d.source or "" }, ":")
end

local function items(s)
  local result = vim.diagnostic.get(s.ctx.buf, s.filter)
  table.sort(result, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    if a.col ~= b.col then
      return a.col < b.col
    end
    return identity(a) < identity(b)
  end)
  return result
end

render = function(s)
  local d = s.items[s.index]
  local lines = {
    "Diagnostic " .. s.index .. "/" .. #s.items,
    "a fix · A fix then next · ]d/[d next/previous",
    "<CR> related location · b return · r refresh · q close",
    "",
  }
  s.related = {}
  if d then
    local severity = vim.diagnostic.severity[d.severity] or "UNKNOWN"
    lines[#lines + 1] = severity
      .. " · "
      .. (d.source or "unknown source")
      .. " · code "
      .. tostring(d.code or "—")
    lines[#lines + 1] = ("%s:%d:%d"):format(
      vim.api.nvim_buf_get_name(s.ctx.buf),
      d.lnum + 1,
      d.col + 1
    )
    vim.list_extend(lines, vim.split(d.message, "\n", { plain = true }))
    local original = d.user_data and d.user_data.lsp or {}
    if original.codeDescription and original.codeDescription.href then
      lines[#lines + 1] = "Documentation: " .. original.codeDescription.href
    end
    for _, related in ipairs(original.relatedInformation or {}) do
      lines[#lines + 1] = ""
      lines[#lines + 1] = "↳ " .. related.message
      lines[#lines + 1] = related.location.uri .. ":" .. (related.location.range.start.line + 1)
      s.related[#s.related + 1] = { row = #lines, location = related.location }
    end
  else
    lines[#lines + 1] = "No matching diagnostics"
  end
  if s.status then
    lines[#lines + 1] = ""
    lines[#lines + 1] = s.status
  end
  panel.write(s, lines)
end

local function go(s, index)
  if #s.items == 0 then
    return
  end
  s.index = (index - 1) % #s.items + 1
  s.status = nil
  local d = s.items[s.index]
  if panel.source(s, true) then
    vim.cmd.normal({ "m`", bang = true })
    vim.api.nvim_win_set_cursor(s.ctx.win, { d.lnum + 1, d.col })
    s.ctx.pos = vim.api.nvim_win_get_cursor(s.ctx.win)
    s.ctx.tick = vim.api.nvim_buf_get_changedtick(s.ctx.buf)
    vim.cmd.normal({ "zv", bang = true })
    vim.api.nvim_set_current_win(s.win)
  end
  render(s)
end

refresh = function(s)
  if not panel.alive(s) then
    return
  end
  local old = s.items[s.index]
  local key = old and identity(old)
  s.items = items(s)
  s.index = math.min(s.index, math.max(1, #s.items))
  for i, d in ipairs(s.items) do
    if identity(d) == key then
      s.index = i
    end
  end
  if s.advance then
    local remaining = 0
    for _, d in ipairs(s.items) do
      if signature(d) == s.advance.key then
        remaining = remaining + 1
      end
    end
    if remaining < s.advance.count then
      local advance = s.advance
      s.advance = nil
      local index = 1
      for i, d in ipairs(s.items) do
        if d.lnum >= advance.row then
          index = i
          break
        end
      end
      local current = vim.api.nvim_get_current_win()
      local source_unchanged = vim.api.nvim_win_is_valid(s.ctx.win)
        and vim.api.nvim_win_get_buf(s.ctx.win) == s.ctx.buf
        and vim.api.nvim_buf_get_changedtick(s.ctx.buf) == advance.tick
        and vim.deep_equal(vim.api.nvim_win_get_cursor(s.ctx.win), advance.pos)
      if source_unchanged and (current == s.win or current == s.ctx.win) then
        go(s, index)
      else
        s.index = index
      end
      s.status = "Fix applied; diagnostics refreshed"
    end
  end
  render(s)
end

function M.fix(s, advance)
  s = s or panel.get("diagnostics")
  if not enabled or not panel.alive(s) or not s.items[s.index] then
    return false
  end
  local d = s.items[s.index]
  local current = items(s)
  if
    not vim.tbl_contains(vim.tbl_map(identity, current), identity(d))
    or vim.api.nvim_buf_get_changedtick(s.ctx.buf) ~= s.ctx.tick
  then
    s.status = "Diagnostic changed; refresh before fixing"
    render(s)
    return false
  end
  if not panel.source(s, true) then
    return false
  end
  vim.api.nvim_win_set_cursor(s.ctx.win, { d.lnum + 1, d.col })
  local ctx = request.context()
  if s.pending then
    s.pending.cancel()
  end
  s.pending = request.start({
    buf = ctx.buf,
    method = "textDocument/codeAction",
    timeout = config.request_timeout,
    params = function(client)
      local params = request.position(ctx, client)
      local line = vim.api.nvim_buf_get_lines(
        ctx.buf,
        d.end_lnum or d.lnum,
        (d.end_lnum or d.lnum) + 1,
        false
      )[1] or ""
      params.range = {
        start = params.position,
        ["end"] = {
          line = d.end_lnum or d.lnum,
          character = vim.str_utfindex(line, client.offset_encoding, d.end_col or d.col, false),
        },
      }
      params.position = nil
      local own = request.diagnostic_namespaces(client)[d.namespace]
      params.context = {
        triggerKind = 1,
        diagnostics = own and d.user_data and d.user_data.lsp and { d.user_data.lsp } or {},
      }
      return params
    end,
  }, function(results)
    if not panel.alive(s) or not request.valid(ctx, true) then
      return
    end
    local entries = {}
    for _, result in ipairs(results) do
      for _, action in ipairs(not result.error and result.result or {}) do
        entries[#entries + 1] = {
          action = action,
          ctx = {
            bufnr = ctx.buf,
            client_id = result.client.id,
            method = "textDocument/codeAction",
          },
        }
      end
    end
    if #entries == 0 then
      s.status = "No code actions for this diagnostic"
      render(s)
      return
    end
    require("lsp-tools.code_actions").pick(entries, function()
      if not panel.alive(s) then
        return
      end
      s.status = "Fix applied"
      if advance then
        local matches = 0
        for _, item in ipairs(s.items) do
          if signature(item) == signature(d) then
            matches = matches + 1
          end
        end
        s.advance = {
          key = signature(d),
          row = d.lnum,
          count = matches,
          tick = vim.api.nvim_buf_get_changedtick(s.ctx.buf),
          pos = vim.api.nvim_win_get_cursor(s.ctx.win),
        }
        local token = s.advance
        vim.defer_fn(function()
          if panel.alive(s) and s.advance == token then
            s.advance = nil
            s.status = "No confirmed diagnostic refresh; use r or ]d to continue"
            render(s)
          end
        end, config.advance_timeout)
      end
      render(s)
    end)
  end)
  return true
end

function M.open(opts)
  if not enabled or vim.bo.buftype ~= "" then
    return false
  end
  opts = opts or {}
  local ctx = request.context()
  local s = panel.open("diagnostics", ctx, { width = config.width, focus = opts.focus ~= false })
  sessions[s] = true
  s.filter, s.index = opts.filter or {}, 1
  s.items = items(s)
  for i, d in ipairs(s.items) do
    if d.lnum <= ctx.pos[1] - 1 then
      s.index = i
    end
  end
  s.on_close = function()
    sessions[s] = nil
    if s.pending then
      s.pending.cancel()
    end
  end
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = s.out, nowait = true })
  end
  map("]d", function()
    go(s, s.index + vim.v.count1)
  end)
  map("[d", function()
    go(s, s.index - vim.v.count1)
  end)
  map("a", function()
    M.fix(s, false)
  end)
  map("A", function()
    M.fix(s, true)
  end)
  map("r", function()
    s.ctx.tick = vim.api.nvim_buf_get_changedtick(s.ctx.buf)
    refresh(s)
  end)
  map("b", function()
    panel.source(s, true)
  end)
  map("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(s.win)[1]
    local target
    for _, item in ipairs(s.related) do
      if item.row <= row then
        target = item
      end
    end
    target = target or s.related[1]
    if target and panel.source(s, true) then
      local d = s.items[s.index]
      local encoding = "utf-16"
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = s.ctx.buf })) do
        if request.diagnostic_namespaces(client)[d.namespace] then
          encoding = client.offset_encoding
          break
        end
      end
      vim.lsp.util.show_document(target.location, encoding, { focus = true })
    end
  end)
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = s.group,
    buffer = ctx.buf,
    callback = function()
      refresh(s)
    end,
  })
  render(s)
  return s
end

function M.disable()
  enabled = false
  for s in pairs(vim.tbl_extend("force", {}, sessions)) do
    panel.close(s)
  end
end

function M.setup(opts)
  local next_config = vim.tbl_extend("force", config, opts or {})
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  assert(
    type(next_config.advance_timeout) == "number" and next_config.advance_timeout > 0,
    "advance_timeout must be positive"
  )
  M.disable()
  config, enabled = next_config, true
end

return M
