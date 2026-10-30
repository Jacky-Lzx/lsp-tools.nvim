-- Bounded asynchronous requests shared by the optional tools.
local M = {}
local history = {}

function M.context()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  return {
    win = win,
    buf = buf,
    pos = vim.api.nvim_win_get_cursor(win),
    tick = vim.api.nvim_buf_get_changedtick(buf),
    uri = vim.uri_from_bufnr(buf),
  }
end

function M.valid(ctx, cursor)
  return vim.api.nvim_win_is_valid(ctx.win)
    and vim.api.nvim_get_current_win() == ctx.win
    and vim.api.nvim_win_get_buf(ctx.win) == ctx.buf
    and vim.api.nvim_buf_get_changedtick(ctx.buf) == ctx.tick
    and vim.uri_from_bufnr(ctx.buf) == ctx.uri
    and (not cursor or vim.deep_equal(vim.api.nvim_win_get_cursor(ctx.win), ctx.pos))
end

function M.position(ctx, client)
  return vim.api.nvim_win_call(ctx.win, function()
    return vim.lsp.util.make_position_params(0, client.offset_encoding)
  end)
end

function M.byte(buf, position, encoding)
  local line = assert(vim.api.nvim_buf_get_lines(buf, position.line, position.line + 1, false)[1])
  return { position.line, vim.str_byteindex(line, encoding, position.character, true) }
end

function M.history(buf)
  return vim.deepcopy(vim.tbl_filter(function(item)
    return not buf or item.buf == buf
  end, history))
end

-- Include named pull providers, including dynamically registered identifiers.
function M.diagnostic_namespaces(client)
  local result = { [vim.lsp.diagnostic.get_namespace(client.id, false)] = true }
  local prefix = ("nvim.lsp.%s.%d."):format(client.name, client.id)
  for id, namespace in pairs(vim.diagnostic.get_namespaces()) do
    if namespace.name:sub(1, #prefix) == prefix then
      result[id] = true
    end
  end
  return result
end

function M.start(opts, callback)
  local clients = opts.clients or vim.lsp.get_clients({ bufnr = opts.buf, method = opts.method })
  local token = { active = true, requests = {}, results = {} }
  local remaining = #clients
  local timer
  local function stop_timer()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end
  function token.cancel()
    if not token.active then
      return
    end
    token.active = false
    stop_timer()
    for _, call in ipairs(token.requests) do
      if not call.done and call.id then
        call.done = true
        call.client:cancel_request(call.id)
      end
    end
  end
  local function finish(call, err, result)
    if not token.active or call.done then
      return
    end
    call.done = true
    if result == vim.NIL then
      result = nil
    end
    local entry = {
      buf = opts.buf,
      client_id = call.client.id,
      client = call.client.name or tostring(call.client.id),
      method = opts.method,
      error = err and (type(err) == "table" and err.message or tostring(err)) or nil,
      empty = result == nil or result == vim.NIL or type(result) == "table" and next(result) == nil,
      elapsed_ms = math.floor((vim.uv.hrtime() - call.started) / 1e6),
    }
    history[#history + 1] = entry
    if #history > 80 then
      table.remove(history, 1)
    end
    token.results[#token.results + 1] = { client = call.client, error = err, result = result }
    remaining = remaining - 1
    if remaining == 0 then
      token.active = false
      stop_timer()
      callback(token.results)
    end
  end
  if remaining == 0 then
    token.active = false
    callback({})
    return token
  end
  -- Prepare all calls first: test transports and local clients may reply inline.
  for _, client in ipairs(clients) do
    token.requests[#token.requests + 1] = { client = client, started = vim.uv.hrtime() }
  end
  timer = assert(vim.uv.new_timer())
  timer:start(
    opts.timeout or 3000,
    0,
    vim.schedule_wrap(function()
      for _, call in ipairs(token.requests) do
        if not call.done then
          if call.id then
            call.client:cancel_request(call.id)
          end
          finish(call, { message = "Request timed out" })
        end
      end
    end)
  )
  for _, call in ipairs(token.requests) do
    local ok, params = pcall(function()
      return type(opts.params) == "function" and opts.params(call.client) or opts.params
    end)
    if not ok then
      finish(call, { message = tostring(params) })
    else
      local sent, id
      ok, sent, id = pcall(
        call.client.request,
        call.client,
        opts.method,
        params,
        function(err, result)
          finish(call, err, result)
        end,
        opts.buf
      )
      if not ok or not sent then
        finish(call, { message = not ok and tostring(sent) or "Could not send request" })
      elseif not call.done then
        call.id = id
      end
    end
  end
  return token
end

return M
