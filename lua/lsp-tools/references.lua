local M = {}
local method = "textDocument/documentHighlight"
local namespace = vim.api.nvim_create_namespace("lsp-tools.references")
local config = {
  debounce = 200,
  request_timeout = 1500,
  wrap = false,
  jumplist = true,
  foldopen = true,
  notify_end = true,
}
local enabled = false
local state, group

local function stop_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function cancel_requests(token)
  for _, request in ipairs(token.requests or {}) do
    if not request.done then
      request.done = true
      if request.id then
        request.client:cancel_request(request.id)
      end
    end
  end
end

local function clear()
  local old = state
  state = nil
  if not old then
    return
  end
  stop_timer(old.timer)
  stop_timer(old.timeout)
  cancel_requests(old)
  if vim.api.nvim_buf_is_valid(old.buf) then
    vim.api.nvim_buf_clear_namespace(old.buf, namespace, 0, -1)
  end
end

local function before(a, b)
  return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
end

local function current_index(token, cursor)
  for i, item in ipairs(token.items) do
    if not before(cursor, item.from) and before(cursor, item.to) then
      return i
    end
  end
end

local function allowed()
  local mode = vim.api.nvim_get_mode().mode
  return enabled
    and vim.bo.buftype == ""
    and (mode == "n" or mode:match("^ni") ~= nil or mode:match("^[ic]") ~= nil)
end

local function valid(token, cursor)
  return state == token
    and allowed()
    and vim.api.nvim_win_is_valid(token.win)
    and vim.api.nvim_get_current_win() == token.win
    and vim.api.nvim_win_get_buf(token.win) == token.buf
    and vim.api.nvim_buf_get_changedtick(token.buf) == token.tick
    and (not cursor or vim.deep_equal(vim.api.nvim_win_get_cursor(token.win), token.pos))
end

local function notify(message)
  if config.notify_end then
    vim.notify(message, vim.log.levels.INFO, { title = "LSP References" })
  end
end

local function jump(token, count, wrap)
  local index = current_index(token, vim.api.nvim_win_get_cursor(token.win))
  if not index then
    notify("No reference at the cursor")
    return false
  end
  local target = index + count
  if wrap then
    target = (target - 1) % #token.items + 1
  end
  if not token.items[target] then
    notify("No more references")
    return false
  end
  if target == index then
    return true
  end
  if config.jumplist then
    vim.cmd.normal({ "m`", bang = true })
  end
  vim.api.nvim_win_set_cursor(token.win, token.items[target].from)
  if config.foldopen then
    vim.cmd.normal({ "zv", bang = true })
  end
  return true
end

local function add(token, highlights, encoding)
  for _, item in ipairs(highlights or {}) do
    -- A broken range from one client must not hide valid results from another.
    local ok, reference = pcall(function()
      local range = item.range
      local function position(pos)
        local line = vim.api.nvim_buf_get_lines(token.buf, pos.line, pos.line + 1, false)[1]
        assert(line, "Invalid highlight line")
        return { pos.line + 1, vim.str_byteindex(line, encoding, pos.character, false) }
      end
      local kind = item.kind
      return {
        from = position(range.start),
        to = position(range["end"]),
        kind = (kind == 2 or kind == 3) and kind or 1,
      }
    end)
    if ok and before(reference.from, reference.to) then
      token.items[#token.items + 1] = reference
    end
  end
end

local function finish(token)
  if not valid(token, true) then
    if state == token then
      clear()
    end
    return
  end
  stop_timer(token.timeout)
  token.ready = true
  table.sort(token.items, function(a, b)
    if vim.deep_equal(a.from, b.from) then
      return before(a.to, b.to)
    end
    return before(a.from, b.from)
  end)
  local items = {}
  for _, item in ipairs(token.items) do
    local last = items[#items]
    if last and vim.deep_equal(last.from, item.from) and vim.deep_equal(last.to, item.to) then
      last.kind = math.max(last.kind, item.kind)
    else
      items[#items + 1] = item
    end
  end
  token.items = items
  local groups = { "LspReferenceText", "LspReferenceRead", "LspReferenceWrite" }
  for _, item in ipairs(items) do
    vim.api.nvim_buf_set_extmark(token.buf, namespace, item.from[1] - 1, item.from[2], {
      end_row = item.to[1] - 1,
      end_col = item.to[2],
      hl_group = groups[item.kind] or groups[1],
      priority = vim.hl.priorities.user,
    })
  end
  if token.count and token.count ~= 0 then
    jump(token, token.count, token.wrap)
  end
end

local function request(token)
  if token.started then
    return
  end
  if not valid(token, true) then
    if state == token then
      clear()
    end
    return
  end
  token.started = true
  local clients = vim.lsp.get_clients({ bufnr = token.buf, method = method })
  token.remaining = #clients
  if #clients == 0 then
    if token.count then
      notify("No language server supports document highlights in this buffer")
    end
    clear()
    return
  end
  for _, client in ipairs(clients) do
    local pending = { client = client }
    token.requests[#token.requests + 1] = pending
    local function response(err, result)
      if pending.done then
        return
      end
      if not valid(token, true) then
        if state == token then
          clear()
        end
        return
      end
      pending.done = true
      if not err then
        add(token, result, client.offset_encoding or "utf-16")
      end
      token.remaining = token.remaining - 1
      if token.remaining == 0 then
        finish(token)
      end
    end
    local params = vim.lsp.util.make_position_params(token.win, client.offset_encoding)
    local sent, id = client:request(method, params, response, token.buf)
    pending.id = id
    if not sent then
      response({ message = "Could not send documentHighlight" })
    end
  end
  if not token.ready then
    token.timeout = vim.defer_fn(function()
      if valid(token, true) then
        cancel_requests(token)
        finish(token)
      elseif state == token then
        clear()
      end
    end, config.request_timeout)
  end
end

local function context()
  return {
    buf = vim.api.nvim_get_current_buf(),
    win = vim.api.nvim_get_current_win(),
    tick = vim.api.nvim_buf_get_changedtick(0),
    pos = vim.api.nvim_win_get_cursor(0),
    items = {},
    requests = {},
  }
end

local function refresh()
  if state and valid(state, not state.ready) then
    if not state.ready or current_index(state, vim.api.nvim_win_get_cursor(0)) then
      return
    end
  end
  clear()
  if not allowed() or #vim.lsp.get_clients({ bufnr = 0, method = method }) == 0 then
    return
  end
  state = context()
  local token = state
  token.timer = vim.defer_fn(function()
    request(token)
  end, config.debounce)
end

---Jump between the current symbol's document highlights. Requests are asynchronous.
---@param count? integer Positive goes forward; negative goes backward.
---@param opts? {wrap?: boolean}
---@return boolean accepted Whether the jump was made or queued.
function M.jump(count, opts)
  count = count or 1
  assert(type(count) == "number" and count % 1 == 0, "reference count must be an integer")
  if count == 0 or not allowed() then
    return false
  end
  local wrap = opts and opts.wrap
  if wrap == nil then
    wrap = config.wrap
  end
  if state and valid(state, false) then
    if state.ready and current_index(state, vim.api.nvim_win_get_cursor(0)) then
      return jump(state, count, wrap)
    elseif not state.ready and vim.deep_equal(state.pos, vim.api.nvim_win_get_cursor(0)) then
      state.count = (state.count or 0) + count
      state.wrap = wrap
      if not state.started then
        stop_timer(state.timer)
        request(state)
      end
      return true
    end
  end
  clear()
  state = context()
  state.count, state.wrap = count, wrap
  request(state)
  return true
end

function M.disable()
  enabled = false
  if group then
    vim.api.nvim_clear_autocmds({ group = group })
  end
  clear()
end

function M.setup(opts)
  local next_config = vim.tbl_deep_extend("force", config, opts or {})
  assert(
    type(next_config.debounce) == "number" and next_config.debounce >= 0,
    "debounce must be nonnegative"
  )
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  for _, key in ipairs({ "wrap", "jumplist", "foldopen", "notify_end" }) do
    assert(type(next_config[key]) == "boolean", key .. " must be a boolean")
  end
  M.disable()
  config = next_config
  enabled = true
  group = vim.api.nvim_create_augroup("LspToolsReferences", { clear = true })
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "BufEnter", "WinEnter", "ModeChanged", "LspAttach" },
    {
      group = group,
      callback = refresh,
    }
  )
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function()
      clear()
      refresh()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "BufWipeout", "LspDetach" }, {
    group = group,
    callback = function(event)
      if state and state.buf == event.buf then
        clear()
      end
      if event.event == "LspDetach" then
        vim.schedule(function()
          if enabled then
            refresh()
          end
        end)
      end
    end,
  })
  refresh()
end

return M
