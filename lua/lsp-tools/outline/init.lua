local M = {}
local api = vim.api
local model = require("lsp-tools.outline.model")
local method = "textDocument/documentSymbol"
local ns = api.nvim_create_namespace("lsp-tools.outline")
local current_ns = api.nvim_create_namespace("lsp-tools.outline.current")
local defaults = {
  enabled = true,
  width = 0.25,
  min_width = 20,
  max_width = 60,
  indent = 1,
  focus_on_open = false,
  follow_cursor = true,
  debounce = 200,
  request_timeout = 3000,
  mode = "auto",
  icons = require("lsp-tools.symbols.icons"),
}
local config = vim.deepcopy(defaults)
local sessions = {}
local enabled = false
local window_options = {
  number = false,
  relativenumber = false,
  wrap = false,
  spell = false,
  list = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldmethod = "manual",
  foldenable = false,
  cursorline = true,
  winfixwidth = true,
  winfixbuf = true,
}
local function source_options(win)
  local options = { winbar = vim.wo[win].winbar }
  for key in pairs(window_options) do
    options[key] = vim.wo[win][key]
  end
  return options
end
local function set_options(win, options)
  for key, value in pairs(options) do
    vim.wo[win][key] = value
  end
end
local render, refresh, update_current, close
local function valid(win)
  return win and api.nvim_win_is_valid(win)
end
local function source(win)
  if not valid(win) or api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype == "" then
    return buf
  end
end
local function alive(s)
  return not s.closed
    and valid(s.win)
    and api.nvim_buf_is_valid(s.out)
    and api.nvim_win_get_buf(s.win) == s.out
    and sessions[s.tab] == s
end
local function cancel(s)
  local pending = s.pending
  s.pending = nil
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
local function snapshot(buf)
  return api.nvim_buf_get_changedtick(buf), vim.uri_from_bufnr(buf)
end
local function fresh(s)
  if not s.doc or not api.nvim_buf_is_valid(s.buf) then
    return false
  end
  local tick, uri = snapshot(s.buf)
  return s.doc.tick == tick and s.doc.uri == uri
end
local function filter(s)
  return s.doc and s.doc.mode ~= "all" and s.doc.mode or false
end
local function clean(value)
  return tostring(value):gsub("[%c]", " ")
end
local function highlights()
  api.nvim_set_hl(0, "LspToolsOutlineCurrent", { default = true, link = "Visual" })
end
local function width(s)
  local total = vim.o.columns
  local requested = config.width < 1 and math.floor(total * config.width) or config.width
  requested = math.floor(requested)
  api.nvim_win_set_width(
    s.win,
    math.max(1, math.min(math.max(config.min_width, requested), config.max_width, total - 12))
  )
end

update_current = function(s)
  if not alive(s) then
    return
  end
  api.nvim_buf_clear_namespace(s.out, current_ns, 0, -1)
  if not fresh(s) or not valid(s.source) or api.nvim_win_get_buf(s.source) ~= s.buf then
    return
  end
  local node = model.current(s.doc.roots, api.nvim_win_get_cursor(s.source), filter(s))
  while node do
    for row, entry in ipairs(s.rows or {}) do
      if entry.node.key == node.key then
        api.nvim_buf_set_extmark(s.out, current_ns, row - 1, 0, {
          line_hl_group = "LspToolsOutlineCurrent",
          priority = 90,
        })
        if config.follow_cursor and api.nvim_get_current_win() == s.source then
          api.nvim_win_set_cursor(s.win, { row, 0 })
        end
        return
      end
    end
    node = node.parent
  end
end

render = function(s)
  if not alive(s) then
    return
  end
  local selected
  if s.rows then
    local entry = s.rows[api.nvim_win_get_cursor(s.win)[1]]
    selected = entry and entry.node.key
  end
  s.rows = s.doc and model.rows(s.doc.roots, s.doc.folds, filter(s)) or {}
  local lines, marks = {}, {}
  for _, entry in ipairs(s.rows) do
    local node = entry.node
    local kind = vim.lsp.protocol.SymbolKind[node.kind] or "Unknown"
    local icon = config.icons[kind]
    local glyph = type(icon) == "table" and icon.icon
      or type(icon) == "string" and icon
      or kind:sub(1, 1)
    local prefix = string.rep(" ", config.indent * entry.depth)
      .. (entry.children and (s.doc.folds[node.key] and "▸ " or "▾ ") or "  ")
    local text = prefix .. glyph .. " " .. clean(node.name)
    lines[#lines + 1] = text .. (node.detail ~= "" and "  " .. clean(node.detail) or "")
    marks[#marks + 1] = { #prefix, #text, type(icon) == "table" and icon.hl or "@type" }
  end
  if #lines == 0 then
    lines = { s.status or (filter(s) and "No structure (m: all symbols)" or "No symbols") }
  end
  vim.bo[s.out].modifiable = true
  api.nvim_buf_set_lines(s.out, 0, -1, false, lines)
  vim.bo[s.out].modifiable = false
  api.nvim_buf_clear_namespace(s.out, ns, 0, -1)
  for row, mark in ipairs(marks) do
    api.nvim_buf_set_extmark(s.out, ns, row - 1, 0, { end_col = mark[1], hl_group = "Comment" })
    api.nvim_buf_set_extmark(s.out, ns, row - 1, mark[1], { end_col = mark[2], hl_group = mark[3] })
    if #lines[row] > mark[2] then
      api.nvim_buf_set_extmark(
        s.out,
        ns,
        row - 1,
        mark[2],
        { end_col = #lines[row], hl_group = "Comment" }
      )
    end
    if s.rows[row].node.key == selected then
      api.nvim_win_set_cursor(s.win, { row, 0 })
    end
  end
  local name = s.buf and vim.fn.fnamemodify(api.nvim_buf_get_name(s.buf), ":t") or ""
  vim.wo[s.win].winbar = (" Outline · %s · %s%s"):format(
    clean(name):gsub("%%", "%%%%"),
    s.doc and ({ sections = "Sections", structure = "Structure", all = "All" })[s.doc.mode] or "All",
    s.status and " · " .. clean(s.status):gsub("%%", "%%%%") or ""
  )
  update_current(s)
end

local function select_client(s)
  local clients = vim.lsp.get_clients({ bufnr = s.buf, method = method })
  table.sort(clients, function(a, b)
    return a.id < b.id
  end)
  local preferred
  for _, client in ipairs(clients) do
    if
      (not config.client_name or client.name == config.client_name)
      and (not config.client_filter or config.client_filter(client, s.buf))
    then
      if s.doc and client.id == s.doc.client_id then
        return client
      end
      preferred = preferred or client
    end
  end
  return preferred
end

refresh = function(s)
  if not alive(s) or not s.buf or not api.nvim_buf_is_loaded(s.buf) then
    return
  end
  cancel(s)
  s.generation = (s.generation or 0) + 1
  local client = select_client(s)
  if not client then
    s.doc = nil
    s.status = "No documentSymbol provider"
    render(s)
    return
  end
  local tick, uri = snapshot(s.buf)
  local buf = s.buf
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local pending = { client = client }
  s.pending = pending
  s.status = "Loading"
  render(s)
  local function finish(err, result)
    if s.pending ~= pending then
      return
    end
    s.pending = nil
    if pending.timer then
      pending.timer:stop()
      pending.timer:close()
      pending.timer = nil
    end
    if not alive(s) or s.buf ~= buf or not api.nvim_buf_is_loaded(buf) then
      return
    end
    local now, name = snapshot(buf)
    if
      tick ~= now
      or uri ~= name
      or vim.lsp.get_client_by_id(client.id) ~= client
      or not vim.lsp.buf_is_attached(buf, client.id)
    then
      return
    end
    if err then
      s.doc = nil
      s.status = "Symbols: " .. clean(err.message or err)
    else
      local old = s.doc or s.docs[buf]
      local mode = old and old.mode or config.mode
      if mode == "auto" then
        mode = vim.bo[buf].filetype == "tex" and "structure" or "all"
      end
      local ok, roots = pcall(model.normalize, result or {}, lines, client.offset_encoding, uri)
      s.doc = {
        roots = ok and roots or {},
        tick = tick,
        uri = uri,
        client_id = client.id,
        folds = old and old.folds or {},
        mode = mode,
      }
      s.docs[buf] = s.doc
      s.status = nil
      if not ok then
        s.status = "Invalid symbol response"
      end
    end
    render(s)
  end
  local ok, id = client:request(method, { textDocument = { uri = uri } }, function(err, result)
    vim.schedule(function()
      finish(err, result)
    end)
  end, buf)
  if not ok then
    finish({ message = "Request failed" })
    return
  end
  pending.id = id
  pending.timer = vim.uv.new_timer()
  pending.timer:start(
    config.request_timeout,
    0,
    vim.schedule_wrap(function()
      if s.pending == pending then
        pcall(client.cancel_request, client, id)
        finish({ message = "Request timed out (r: retry)" })
      end
    end)
  )
end

local function queue(s)
  cancel(s)
  s.generation = (s.generation or 0) + 1
  local generation = s.generation
  vim.defer_fn(function()
    if alive(s) and generation == s.generation then
      refresh(s)
    end
  end, config.debounce)
end

local function track(s, win)
  local buf = source(win)
  if not buf then
    return
  end
  s.source = win
  s.source_options = source_options(win)
  if s.buf ~= buf then
    cancel(s)
    s.generation = (s.generation or 0) + 1
    s.buf, s.doc, s.status = buf, s.docs[buf], nil
    render(s)
    refresh(s)
  elseif not fresh(s) and not s.pending then
    queue(s)
  else
    update_current(s)
  end
end

close = function(s)
  if not s or s.closed then
    return
  end
  s.closed = true
  sessions[s.tab] = nil
  cancel(s)
  local focused = api.nvim_get_current_win() == s.win
  if valid(s.win) then
    local ok = false
    if #api.nvim_tabpage_list_wins(s.tab) > 1 then
      ok = pcall(api.nvim_win_close, s.win, true)
    end
    if not ok and valid(s.win) then
      -- Keep the tab when its last window is the sidebar.
      local buf = s.buf and api.nvim_buf_is_valid(s.buf) and s.buf
        or api.nvim_create_buf(true, false)
      vim.wo[s.win].winfixbuf = false
      api.nvim_win_set_buf(s.win, buf)
      set_options(s.win, s.source_options)
    end
  end
  if focused and valid(s.source) then
    api.nvim_set_current_win(s.source)
  end
end

local function navigate(s)
  if not fresh(s) then
    refresh(s)
    return
  end
  local entry = s.rows[api.nvim_win_get_cursor(s.win)[1]]
  if not entry then
    return
  end
  if not valid(s.source) or api.nvim_win_get_buf(s.source) ~= s.buf then
    s.source = nil
    for _, win in ipairs(api.nvim_tabpage_list_wins(s.tab)) do
      if win ~= s.win and api.nvim_win_get_buf(win) == s.buf then
        s.source = win
        break
      end
    end
    if not s.source then
      s.source = api.nvim_open_win(s.buf, false, { split = "left", win = s.win })
      set_options(s.source, s.source_options)
    end
  end
  api.nvim_set_current_win(s.source)
  vim.cmd("normal! m'")
  api.nvim_win_set_cursor(s.source, entry.node.position)
  vim.cmd("normal! zv")
  update_current(s)
end

local function fold(s, action)
  if not s.doc then
    return
  end
  local row = api.nvim_win_get_cursor(s.win)[1]
  local entry = s.rows[row]
  if not entry then
    return
  end
  local key = entry.node.key
  if action == "toggle" then
    s.doc.folds[key] = not s.doc.folds[key]
  elseif action == "close" then
    if entry.children and not s.doc.folds[key] then
      s.doc.folds[key] = true
    elseif entry.parent then
      for index, item in ipairs(s.rows) do
        if item.node == entry.parent then
          api.nvim_win_set_cursor(s.win, { index, 0 })
          break
        end
      end
    end
  elseif action == "open" then
    if entry.children and s.doc.folds[key] then
      s.doc.folds[key] = nil
    elseif entry.children then
      api.nvim_win_set_cursor(s.win, { math.min(row + 1, #s.rows), 0 })
    end
  end
  render(s)
end

function M.open(opts)
  if not enabled then
    return
  end
  opts = opts or {}
  local tab = api.nvim_get_current_tabpage()
  local s = sessions[tab]
  if s and alive(s) then
    if opts.focus ~= false then
      api.nvim_set_current_win(s.win)
    end
    return s.win
  end
  local original = api.nvim_get_current_win()
  local buf = source(original)
  if not buf then
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if source(win) then
        original, buf = win, source(win)
        break
      end
    end
  end
  if not buf then
    vim.notify("Outline: open a source file first", vim.log.levels.INFO)
    return
  end
  local out = api.nvim_create_buf(false, true)
  vim.bo[out].buftype, vim.bo[out].bufhidden = "nofile", "wipe"
  vim.bo[out].swapfile, vim.bo[out].filetype = false, "lsp-tools-outline"
  -- Split directly into the scratch buffer; never transiently display the source in the sidebar.
  local win = api.nvim_open_win(out, false, { split = "right", win = -1, width = 30 })
  s = {
    tab = tab,
    win = win,
    out = out,
    source = original,
    buf = buf,
    docs = {},
    rows = {},
    source_options = source_options(original),
  }
  sessions[tab] = s
  set_options(win, window_options)
  width(s)
  local function map(keys, callback, desc)
    vim.keymap.set("n", keys, callback, { buffer = out, silent = true, nowait = true, desc = desc })
  end
  map("<CR>", function()
    navigate(s)
  end, "Jump to symbol")
  for _, key in ipairs({ "<Tab>", "za" }) do
    map(key, function()
      fold(s, "toggle")
    end, "Toggle symbol fold")
  end
  for _, key in ipairs({ "h", "zc" }) do
    map(key, function()
      fold(s, "close")
    end, "Collapse symbol")
  end
  for _, key in ipairs({ "l", "zo" }) do
    map(key, function()
      fold(s, "open")
    end, "Expand symbol")
  end
  for _, key in ipairs({ "zM", "zR" }) do
    map(key, function()
      if not s.doc then
        return
      end
      local function walk(nodes)
        for _, node in ipairs(nodes) do
          s.doc.folds[node.key] = key == "zM" or nil
          walk(node.children)
        end
      end
      walk(s.doc.roots)
      render(s)
    end, key == "zM" and "Collapse all symbols" or "Expand all symbols")
  end
  map("r", function()
    refresh(s)
  end, "Refresh symbols")
  map("m", function()
    if s.doc then
      local filtered = config.mode == "sections" and "sections"
        or vim.bo[s.buf].filetype == "tex" and "structure"
        or "sections"
      s.doc.mode = s.doc.mode == "all" and filtered or "all"
      render(s)
    end
  end, "Toggle structure/all symbols")
  map("q", function()
    close(s)
  end, "Close outline")
  map("<Esc>", function()
    close(s)
  end, "Close outline")
  refresh(s)
  if opts.focus == true or opts.focus == nil and config.focus_on_open then
    api.nvim_set_current_win(win)
  end
  return win
end

function M.close()
  close(sessions[api.nvim_get_current_tabpage()])
end
function M.toggle()
  local s = sessions[api.nvim_get_current_tabpage()]
  if s and alive(s) then
    close(s)
  else
    return M.open()
  end
end

function M.disable()
  enabled = false
  local active = vim.tbl_values(sessions)
  for _, s in ipairs(active) do
    close(s)
  end
  pcall(api.nvim_del_augroup_by_name, "LspToolsOutline")
end

function M.setup(opts)
  M.disable()
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(
    type(config.indent) == "number" and config.indent >= 0 and config.indent % 1 == 0,
    "outline.indent must be a non-negative integer"
  )
  for _, key in ipairs({ "width", "min_width", "max_width", "debounce", "request_timeout" }) do
    assert(
      type(config[key]) == "number" and config[key] > 0,
      "outline." .. key .. " must be positive"
    )
  end
  assert(
    config.mode == "auto"
      or config.mode == "all"
      or config.mode == "sections"
      or config.mode == "structure",
    "invalid outline.mode"
  )
  enabled = config.enabled ~= false
  if not enabled then
    return
  end
  highlights()
  local group = api.nvim_create_augroup("LspToolsOutline", { clear = true })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local s = sessions[api.nvim_get_current_tabpage()]
      if s and alive(s) then
        track(s, api.nvim_get_current_win())
      end
    end,
  })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function()
      local s = sessions[api.nvim_get_current_tabpage()]
      if s and api.nvim_get_current_win() == s.source then
        update_current(s)
      end
    end,
  })
  api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI", "TextChangedP", "BufFilePost", "LspAttach", "LspDetach" },
    {
      group = group,
      callback = function(event)
        for _, s in pairs(sessions) do
          if s.buf == event.buf then
            queue(s)
          end
        end
      end,
    }
  )
  api.nvim_create_autocmd({ "WinClosed", "BufWipeout", "TabClosed" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, s in pairs(sessions) do
          if
            not alive(s)
            or not api.nvim_tabpage_is_valid(s.tab)
            or not api.nvim_buf_is_valid(s.out)
          then
            close(s)
          elseif s.buf and not api.nvim_buf_is_valid(s.buf) then
            cancel(s)
            s.buf, s.doc, s.status = nil, nil, "Source closed"
            render(s)
          end
        end
      end)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      for _, s in pairs(sessions) do
        if alive(s) then
          width(s)
        end
      end
    end,
  })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  for name, callback in pairs({
    LspToolsOutline = M.toggle,
    LspToolsOutlineOpen = M.open,
    LspToolsOutlineClose = M.close,
  }) do
    api.nvim_create_user_command(name, function()
      callback()
    end, { force = true, desc = name })
  end
end

return M
