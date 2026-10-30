local M = {}
local api = vim.api
local model = require("lsp-tools.outline.model")
local method = "textDocument/documentSymbol"
local defaults = {
  enabled = true,
  winbar = false,
  separator = " › ",
  debounce = 200,
  request_timeout = 3000,
  mode = "all",
  icons = require("lsp-tools.symbols.icons"),
}
local config = vim.deepcopy(defaults)
local enabled = false
local documents, windows = {}, {}
local expression = "%{%v:lua.require'lsp-tools'.breadcrumbs()%}"
local namespace = api.nvim_create_namespace("lsp-tools.breadcrumbs")

local function source(win)
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype == "" and api.nvim_buf_is_loaded(buf) then
    return buf
  end
end

local function cancel(doc)
  local pending = doc.pending
  doc.pending = nil
  if pending then
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
    end
    if pending.id then
      pcall(pending.client.cancel_request, pending.client, pending.id)
    end
  end
end

local function redraw()
  vim.cmd("redrawstatus")
end

local function clear(buf, doc)
  doc.roots = nil
  if api.nvim_buf_is_loaded(buf) then
    api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  end
end

-- Keep the previous snapshot usable while a new document-symbol request is
-- debounced/in flight. Extmarks follow edits, including changes before a scope.
local function track(buf, nodes)
  for _, node in ipairs(nodes) do
    local a, b = node.range[1], node.range[2]
    node.mark = api.nvim_buf_set_extmark(buf, namespace, a[1] - 1, a[2], {
      end_row = b[1] - 1,
      end_col = b[2],
      right_gravity = true,
      end_right_gravity = false,
      invalidate = true,
      strict = false,
    })
    track(buf, node.children)
  end
end

local function ranges(buf, nodes)
  for _, node in ipairs(nodes) do
    local mark = api.nvim_buf_get_extmark_by_id(buf, namespace, node.mark, { details = true })
    local details = mark[3]
    if details and not details.invalid then
      node.range = { { mark[1] + 1, mark[2] }, { details.end_row + 1, details.end_col } }
    else
      node.range = { { 1, 0 }, { 1, 0 } }
    end
    ranges(buf, node.children)
  end
end

local function readable(buf, doc)
  return doc
    and doc.roots
    and api.nvim_buf_is_loaded(buf)
    and doc.uri == vim.uri_from_bufnr(buf)
    and vim.lsp.get_client_by_id(doc.client.id) == doc.client
    and vim.lsp.buf_is_attached(buf, doc.client.id)
end

local function select_client(buf, doc)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  table.sort(clients, function(a, b)
    return a.id < b.id
  end)
  local selected
  for _, client in ipairs(clients) do
    if
      (not config.client_name or client.name == config.client_name)
      and (not config.client_filter or config.client_filter(client, buf))
    then
      if doc.client == client then
        return client
      end
      selected = selected or client
    end
  end
  return selected
end

local function refresh(buf, doc)
  if not enabled or documents[buf] ~= doc or not api.nvim_buf_is_loaded(buf) then
    return
  end
  cancel(doc)
  local client = select_client(buf, doc)
  if client ~= doc.client then
    clear(buf, doc)
  end
  doc.client = client
  redraw()
  if not client then
    return
  end
  local tick, uri = api.nvim_buf_get_changedtick(buf), vim.uri_from_bufnr(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local pending = { client = client }
  doc.pending = pending
  local function finish(err, result)
    if documents[buf] ~= doc or doc.pending ~= pending then
      return
    end
    doc.pending = nil
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
      pending.timer = nil
    end
    if
      not enabled
      or not api.nvim_buf_is_loaded(buf)
      or tick ~= api.nvim_buf_get_changedtick(buf)
      or uri ~= vim.uri_from_bufnr(buf)
      or vim.lsp.get_client_by_id(client.id) ~= client
      or not vim.lsp.buf_is_attached(buf, client.id)
    then
      return
    end
    if not err then
      local ok, roots = pcall(model.normalize, result or {}, lines, client.offset_encoding, uri)
      if ok then
        clear(buf, doc)
        track(buf, roots)
        doc.roots, doc.uri, doc.range_tick = roots, uri, tick
      else
        clear(buf, doc)
      end
    else
      clear(buf, doc)
    end
    redraw()
  end
  local ok, id = client:request(method, { textDocument = { uri = uri } }, function(err, result)
    vim.schedule(function()
      finish(err, result)
    end)
  end, buf)
  if not ok then
    finish(true)
    return
  end
  pending.id = id
  pending.timer = vim.uv.new_timer()
  pending.timer:start(
    config.request_timeout,
    0,
    vim.schedule_wrap(function()
      if doc.pending == pending then
        pcall(client.cancel_request, client, id)
        finish(true)
      end
    end)
  )
end

local function queue(buf, doc, invalidate)
  cancel(doc)
  if invalidate then
    clear(buf, doc)
  end
  doc.generation = (doc.generation or 0) + 1
  local generation = doc.generation
  redraw()
  vim.defer_fn(function()
    if documents[buf] == doc and generation == doc.generation then
      refresh(buf, doc)
    end
  end, config.debounce)
end

local function restore(win)
  if api.nvim_win_is_valid(win) and vim.wo[win].winbar == expression then
    vim.wo[win].winbar = windows[win]
  end
  windows[win] = nil
end

local function scan()
  if not enabled then
    return
  end
  local visible = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    local buf = source(win)
    if not buf and windows[win] ~= nil then
      restore(win)
    end
    if buf then
      visible[buf] = true
      -- Existing winbars (including lualine) keep ownership of their window.
      if
        config.winbar
        and windows[win] == nil
        and (vim.wo[win].winbar == "" or vim.wo[win].winbar == expression)
      then
        -- Splits inherit the source window's expression.
        windows[win] = ""
        vim.wo[win].winbar = expression
      end
      if not documents[buf] then
        local doc = {}
        documents[buf] = doc
        refresh(buf, doc)
      end
    end
  end
  for buf, doc in pairs(documents) do
    if not visible[buf] then
      cancel(doc)
      clear(buf, doc)
      documents[buf] = nil
    end
  end
  for win in pairs(windows) do
    if not api.nvim_win_is_valid(win) then
      windows[win] = nil
    end
  end
end

local function target(win)
  return win or tonumber(vim.g.statusline_winid) or api.nvim_get_current_win()
end

---Read the outer-to-inner path without requests or UI mutations.
function M.get(win)
  if not enabled then
    return {}
  end
  win = target(win)
  local buf = source(win)
  local doc = buf and documents[buf]
  if not buf or not readable(buf, doc) then
    return {}
  end
  local tick = api.nvim_buf_get_changedtick(buf)
  if doc.range_tick ~= tick then
    ranges(buf, doc.roots)
    doc.range_tick = tick
  end
  local sections = config.mode == "sections"
    or config.mode == "auto" and vim.bo[buf].filetype == "tex"
  local node = model.current(doc.roots, api.nvim_win_get_cursor(win), sections)
  local path = {}
  while node do
    if not sections or model.section(node) then
      table.insert(path, 1, { name = node.name, kind = node.kind })
    end
    node = node.parent
  end
  return path
end

local function escape(value)
  return (value:gsub("[%c]", " "):gsub("%%", "%%%%"))
end

---Return escaped statusline text; safe in lualine and %{%...%} expressions.
function M.statusline(opts)
  opts = opts or {}
  local parts = {}
  for _, node in ipairs(M.get(opts.winid)) do
    local kind = vim.lsp.protocol.SymbolKind[node.kind] or "Unknown"
    local icon = config.icons[kind]
    local glyph = type(icon) == "table" and icon.icon
      or type(icon) == "string" and icon
      or kind:sub(1, 1)
    local text = (opts.icons == false and "" or glyph .. " ") .. node.name
    local hl = type(icon) == "table" and icon.hl or "Identifier"
    if opts.color ~= false and type(hl) == "string" and hl:match("^[@%w_.]+$") then
      text = "%#" .. hl .. "#" .. escape(text) .. "%*"
    else
      text = escape(text)
    end
    parts[#parts + 1] = text
  end
  return table.concat(parts, escape(config.separator))
end

function M.disable()
  enabled = false
  pcall(api.nvim_del_augroup_by_name, "LspToolsBreadcrumbs")
  for buf, doc in pairs(documents) do
    cancel(doc)
    clear(buf, doc)
  end
  documents = {}
  for win in pairs(windows) do
    restore(win)
  end
  redraw()
end

function M.setup(opts)
  M.disable()
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  for _, key in ipairs({ "debounce", "request_timeout" }) do
    assert(
      type(config[key]) == "number" and config[key] > 0,
      "breadcrumbs." .. key .. " must be positive"
    )
  end
  assert(type(config.separator) == "string", "breadcrumbs.separator must be a string")
  assert(
    config.mode == "all" or config.mode == "auto" or config.mode == "sections",
    "invalid breadcrumbs.mode"
  )
  enabled = config.enabled ~= false
  if not enabled then
    return
  end
  local group = api.nvim_create_augroup("LspToolsBreadcrumbs", { clear = true })
  api.nvim_create_autocmd({ "BufWinEnter", "BufWinLeave", "WinEnter", "WinClosed", "BufWipeout" }, {
    group = group,
    callback = function()
      vim.schedule(scan)
    end,
  })
  api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI", "TextChangedP", "BufFilePost", "LspAttach", "LspDetach" },
    {
      group = group,
      callback = function(event)
        local doc = documents[event.buf]
        if doc then
          queue(event.buf, doc, not event.event:match("^TextChanged"))
        end
      end,
    }
  )
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ColorScheme" }, {
    group = group,
    callback = redraw,
  })
  scan()
end

return M
