local M = {}
local request = require("lsp-tools.request")
local enabled, group, active = false, nil, nil
local config = { request_timeout = 3000 }
local watch

local function cancel()
  if active and active.pending then
    active.pending.cancel()
  end
  active = nil
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end

local function valid(token)
  return enabled and active == token and request.valid(token.ctx, true)
end

local function fallback(token)
  if not valid(token) then
    return
  end
  cancel()
  if token.fallback then
    return token.fallback()
  end
  local target = vim.fn.expand("<cfile>")
  if target ~= "" then
    vim.ui.open(target)
  end
end

local function open_target(token, link)
  if not valid(token) then
    return
  end
  if type(link.target) ~= "string" or link.target == "" then
    fallback(token)
    return
  end
  cancel()
  local ok, _, err = pcall(token.open or vim.ui.open, link.target)
  if not ok or err then
    vim.notify("Cannot open link: " .. tostring(not ok and _ or err), vim.log.levels.WARN)
  end
end

local function choose(token, item)
  if not valid(token) then
    return
  end
  if item.link.target then
    open_target(token, item.link)
    return
  end
  local client = item.client
  if not client:supports_method("documentLink/resolve", token.ctx.buf) then
    fallback(token)
    return
  end
  token.pending = request.start({
    buf = token.ctx.buf,
    method = "documentLink/resolve",
    clients = { client },
    params = item.link,
    timeout = config.request_timeout,
  }, function(results)
    if not valid(token) then
      return
    end
    local response = results[1]
    if response and not response.error and response.result then
      open_target(token, response.result)
    else
      fallback(token)
    end
  end)
end

function M.open(opts)
  if not enabled or vim.bo.buftype ~= "" then
    return false
  end
  opts = opts or {}
  cancel()
  local token = {
    ctx = request.context(),
    fallback = opts.fallback or config.fallback,
    open = opts.open or config.open,
  }
  active = token
  watch()
  token.pending = request.start({
    buf = token.ctx.buf,
    method = "textDocument/documentLink",
    timeout = config.request_timeout,
    params = { textDocument = { uri = token.ctx.uri } },
  }, function(results)
    if not valid(token) then
      return
    end
    local found, seen = {}, {}
    local pos = { token.ctx.pos[1] - 1, token.ctx.pos[2] }
    local function before(a, b)
      return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
    end
    for _, response in ipairs(results) do
      if not response.error then
        for _, link in ipairs(response.result or {}) do
          local ok, first, last = pcall(function()
            return request.byte(token.ctx.buf, link.range.start, response.client.offset_encoding),
              request.byte(token.ctx.buf, link.range["end"], response.client.offset_encoding)
          end)
          if
            ok
            and not before(pos, first)
            and before(pos, last)
            and (not link.target or not seen[link.target])
          then
            if link.target then
              seen[link.target] = true
            end
            found[#found + 1] = { link = link, client = response.client }
          end
        end
      end
    end
    table.sort(found, function(a, b)
      return a.client.id < b.client.id
    end)
    if #found == 0 then
      fallback(token)
    elseif #found == 1 then
      choose(token, found[1])
    else
      token.selecting = true
      vim.ui.select(found, {
        prompt = "Open LSP link",
        format_item = function(item)
          return (item.link.tooltip or item.link.target or "Resolve link")
            .. " ["
            .. item.client.name
            .. "]"
        end,
      }, function(item)
        vim.schedule(function()
          token.selecting = false
          if item then
            choose(token, item)
          elseif active == token then
            cancel()
          end
        end)
      end)
    end
  end)
  return true
end

function M.disable()
  enabled = false
  cancel()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end

function M.setup(opts)
  local next_config = vim.tbl_extend("force", config, opts or {})
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  for _, name in ipairs({ "fallback", "open" }) do
    assert(
      next_config[name] == nil or type(next_config[name]) == "function",
      name .. " must be a function"
    )
  end
  M.disable()
  config, enabled = next_config, true
end

watch = function()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("LspToolsLinks", { clear = true })
  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "BufLeave",
    "WinLeave",
    "BufWipeout",
    "LspDetach",
  }, {
    group = group,
    callback = function(ev)
      -- A selection provider may temporarily focus its UI; final callbacks still
      -- validate the captured source. Real source changes always invalidate it.
      if active then
        local leaving = ev.buf == active.ctx.buf
          and (
            ev.event == "LspDetach"
            or ev.event == "BufWipeout"
            or not active.selecting and (ev.event == "BufLeave" or ev.event == "WinLeave")
          )
        if leaving or not request.valid(active.ctx, true, true) then
          cancel()
        end
      end
    end,
  })
end

return M
