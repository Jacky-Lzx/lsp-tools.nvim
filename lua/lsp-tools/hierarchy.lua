local M = {}
local request = require("lsp-tools.request")
local panel = require("lsp-tools.panel")
local enabled = false
local config = { width = 0.35, request_timeout = 3000, max_nodes = 500, max_depth = 20 }
local sessions, choosing = {}, {}
local specs = {
  call = {
    prepare = "textDocument/prepareCallHierarchy",
    directions = { "incoming", "outgoing" },
    incoming = "callHierarchy/incomingCalls",
    outgoing = "callHierarchy/outgoingCalls",
  },
  type = {
    prepare = "textDocument/prepareTypeHierarchy",
    directions = { "supertypes", "subtypes" },
    supertypes = "typeHierarchy/supertypes",
    subtypes = "typeHierarchy/subtypes",
  },
}
local render, expand, prepare
local function key(item)
  local p = (item.selectionRange or item.range).start
  return table.concat({ item.uri, p.line, p.character, item.name }, ":")
end
local function disk(uri)
  if uri:sub(1, 7) ~= "file://" then
    return nil
  end
  local ok, path = pcall(vim.uri_to_fname, uri)
  local stat = ok and vim.uv.fs_stat(path)
  return stat and { size = stat.size, mtime = stat.mtime } or false
end
local function node(s, item, parent, sites)
  if
    type(item) ~= "table"
    or not item.uri
    or not item.name
    or not (item.selectionRange or item.range)
  then
    return
  end
  local ok, id = pcall(key, item)
  if not ok or s.count >= config.max_nodes then
    return
  end
  local n = {
    item = item,
    parent = parent,
    sites = sites or {},
    depth = parent and parent.depth + 1 or 0,
    key = id,
    disk = disk(item.uri),
  }
  for buf, tick in pairs(s.baseline) do
    if vim.api.nvim_buf_is_valid(buf) and vim.uri_from_bufnr(buf) == item.uri then
      n.buf, n.tick = buf, tick
      break
    end
  end
  local ancestor = parent
  while ancestor do
    if ancestor.key == id then
      n.cycle = true
      break
    end
    ancestor = ancestor.parent
  end
  s.count = s.count + 1
  return n
end
local function fresh(s, n)
  if not panel.alive(s) or vim.lsp.get_client_by_id(s.client.id) ~= s.client then
    return false
  end
  if
    not vim.api.nvim_buf_is_valid(s.ctx.buf)
    or vim.api.nvim_buf_get_changedtick(s.ctx.buf) ~= s.ctx.tick
  then
    return false
  end
  if n then
    if n.parent and not fresh(s, n.parent) then
      return false
    end
    if
      n.buf
      and (
        not vim.api.nvim_buf_is_valid(n.buf) or vim.api.nvim_buf_get_changedtick(n.buf) ~= n.tick
      )
    then
      return false
    end
    if not vim.deep_equal(n.disk, disk(n.item.uri)) then
      return false
    end
  end
  return true
end
local function cancel(s)
  for n, pending in pairs(s.pending or {}) do
    pending.cancel()
    n.loading = false
  end
  s.pending = {}
  s.generation = (s.generation or 0) + 1
end
local function current(s)
  return s.rows[vim.api.nvim_win_get_cursor(s.win)[1]]
end
render = function(s)
  if not panel.alive(s) then
    return
  end
  local selected = s.rows and current(s)
  local lines = {
    s.kind .. " hierarchy · " .. s.direction .. " · " .. s.client.name,
    "Lazy call/type hierarchy",
    s.bindings:hint(),
    "",
  }
  s.rows = {}
  local cursor = 1
  local function visit(n)
    local icon = n.cycle and "↻"
      or n.loading and "…"
      or n.children and #n.children == 0 and " "
      or n.expanded and "▾"
      or "▸"
    lines[#lines + 1] = string.rep("  ", n.depth) .. icon .. " " .. n.item.name:gsub("[\r\n]", " ")
    s.rows[#lines] = n
    if n == selected then
      cursor = #lines
    end
    if n.expanded then
      for _, child in ipairs(n.children or {}) do
        visit(child)
      end
    end
  end
  for _, root in ipairs(s.trees[s.direction] or {}) do
    visit(root)
  end
  if s.status then
    lines[#lines + 1] = ""
    lines[#lines + 1] = s.status
  end
  panel.write(s, lines)
  if cursor == 1 and s.rows[5] then
    cursor = 5
  end
  vim.api.nvim_win_set_cursor(s.win, { cursor, 0 })
end
expand = function(s, n)
  if not n or n.cycle or n.loading then
    return
  end
  if not fresh(s, n) then
    s.status = "Source changed or client detached; r to refresh"
    render(s)
    return
  end
  if n.depth >= config.max_depth then
    s.status = "Maximum hierarchy depth reached"
    render(s)
    return
  end
  if n.children then
    n.expanded = true
    render(s)
    return
  end
  local method = specs[s.kind][s.direction]
  if not s.client:supports_method(method, s.ctx.buf) then
    s.status = "Unsupported: " .. method
    render(s)
    return
  end
  n.loading = true
  local generation, direction = s.generation, s.direction
  local pending = request.start({
    buf = s.ctx.buf,
    method = method,
    clients = { s.client },
    params = { item = n.item },
    timeout = config.request_timeout,
  }, function(results)
    if not panel.alive(s) or generation ~= s.generation then
      return
    end
    s.pending[n], n.loading = nil, false
    local response = results[1]
    if not fresh(s, n) or not response or response.error then
      s.status = response
          and response.error
          and (response.error.message or tostring(response.error))
        or "Source changed; r to refresh"
      render(s)
      return
    end
    n.children, n.expanded = {}, true
    local seen = {}
    for _, entry in ipairs(response.result or {}) do
      local item, sites = entry, {}
      if s.kind == "call" then
        item = direction == "incoming" and entry.from or entry.to
        if item then
          for _, range in ipairs(entry.fromRanges or {}) do
            sites[#sites + 1] =
              { uri = direction == "incoming" and item.uri or n.item.uri, range = range }
          end
        end
      end
      local child = node(s, item, n, sites)
      if child and not seen[child.key] then
        seen[child.key] = true
        n.children[#n.children + 1] = child
      end
    end
    table.sort(n.children, function(a, b)
      return a.key < b.key
    end)
    s.status = s.count >= config.max_nodes
        and "Node limit reached; narrow the query or raise max_nodes"
      or nil
    render(s)
  end)
  if pending.active then
    s.pending[n] = pending
  end
  render(s)
end
local function jump(s, location, n)
  if not fresh(s, n) then
    s.status = "Source changed; r to refresh before jumping"
    render(s)
    return
  end
  if vim.api.nvim_win_is_valid(s.ctx.win) then
    vim.api.nvim_set_current_win(s.ctx.win)
    vim.lsp.util.show_document(location, s.client.offset_encoding, { focus = true })
    if location.uri == n.item.uri and not n.buf then
      n.buf = vim.api.nvim_get_current_buf()
      n.tick = vim.api.nvim_buf_get_changedtick(n.buf)
    end
  end
end
local function preview(s, n)
  if not n or not fresh(s, n) then
    return
  end
  local location = n.sites[1] or { uri = n.item.uri, range = n.item.selectionRange or n.item.range }
  local ok, buf = pcall(vim.uri_to_bufnr, location.uri)
  if not ok or not pcall(vim.fn.bufload, buf) then
    return
  end
  if location.uri == n.item.uri and not n.buf then
    n.buf, n.tick = buf, vim.api.nvim_buf_get_changedtick(buf)
  end
  local row = location.range.start.line
  local first, last = math.max(0, row - 3), math.min(vim.api.nvim_buf_line_count(buf), row + 9)
  if first >= last then
    return
  end
  local lines = { location.uri .. ":" .. (row + 1), "" }
  vim.list_extend(lines, vim.api.nvim_buf_get_lines(buf, first, last, false))
  local preview_buf, win = vim.lsp.util.open_floating_preview(lines, vim.bo[buf].filetype, {
    focus_id = "lsp-tools-hierarchy-preview",
    border = "rounded",
    focus = false,
    max_width = math.max(1, math.min(100, vim.o.columns - 4)),
    max_height = 16,
    close_events = { "CursorMoved", "BufLeave" },
  })
  s.preview, s.preview_buf = win, preview_buf
end
prepare = function(s)
  cancel(s)
  s.ctx = vim.api.nvim_win_call(s.ctx.win, request.context)
  if vim.bo[s.ctx.buf].buftype ~= "" then
    return
  end
  s.baseline = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      s.baseline[buf] = vim.api.nvim_buf_get_changedtick(buf)
    end
  end
  s.count, s.trees, s.items, s.status = 0, {}, nil, "Loading…"
  local generation, ctx = s.generation, s.ctx
  local pending = request.start({
    buf = ctx.buf,
    method = specs[s.kind].prepare,
    clients = { s.client },
    params = function(client)
      return request.position(ctx, client)
    end,
    timeout = config.request_timeout,
  }, function(results)
    if not panel.alive(s) or generation ~= s.generation then
      return
    end
    s.pending[s] = nil
    local response = results[1]
    if not request.valid(ctx, true, true) or not response or response.error then
      s.status = response
          and response.error
          and (response.error.message or tostring(response.error))
        or "Source changed; r to refresh"
      render(s)
      return
    end
    s.items, s.trees[s.direction] = response.result or {}, {}
    for _, item in ipairs(s.items) do
      local root = node(s, item)
      if root then
        s.trees[s.direction][#s.trees[s.direction] + 1] = root
      end
    end
    s.status = #s.items == 0 and "No hierarchy at this position" or nil
    render(s)
    for _, root in ipairs(s.trees[s.direction]) do
      expand(s, root)
    end
  end)
  if pending.active then
    s.pending[s] = pending
  end
  render(s)
end
local function open(ctx, client, kind, direction, opts)
  local s = panel.open(kind .. "-hierarchy", ctx, {
    keymaps = opts.keymaps or config.keymaps,
    key_prefix = opts.key_prefix or config.key_prefix,
    width = config.width,
    focus = opts.focus ~= false,
  })
  s.client, s.kind, s.direction = client, kind, direction
  s.pending, s.trees, s.rows, s.generation = {}, {}, {}, 0
  sessions[s] = true
  s.on_close = function()
    cancel(s)
    sessions[s] = nil
    if
      s.preview
      and vim.api.nvim_win_is_valid(s.preview)
      and vim.api.nvim_win_get_buf(s.preview) == s.preview_buf
    then
      vim.api.nvim_win_close(s.preview, true)
    end
  end
  local function map(lhs, fn, desc)
    return s.bindings:legacy(lhs, fn, desc, "hierarchy")
  end
  for _, lhs in ipairs({ "<Tab>", "l" }) do
    map(lhs, function()
      expand(s, current(s))
    end)
  end
  map("h", function()
    local n = current(s)
    if n then
      n.expanded = false
      render(s)
    end
  end)
  map("<CR>", function()
    local n = current(s)
    if n then
      jump(s, { uri = n.item.uri, range = n.item.selectionRange or n.item.range }, n)
    end
  end)
  map("g", function()
    local n = current(s)
    if not n or #n.sites == 0 then
      return
    end
    if #n.sites == 1 then
      jump(s, n.sites[1], n)
      return
    end
    vim.ui.select(n.sites, {
      prompt = "Call location",
      format_item = function(site)
        return site.uri .. ":" .. (site.range.start.line + 1)
      end,
    }, function(site)
      vim.schedule(function()
        if site then
          jump(s, site, n)
        end
      end)
    end)
  end)
  map("p", function()
    preview(s, current(s))
  end)
  map("b", function()
    panel.source(s, true)
  end)
  map("r", function()
    if vim.api.nvim_win_is_valid(s.ctx.win) then
      prepare(s)
    end
  end)
  map("d", function()
    cancel(s)
    s.status = nil
    local directions = specs[kind].directions
    s.direction = s.direction == directions[1] and directions[2] or directions[1]
    if not s.trees[s.direction] and s.items then
      s.trees[s.direction] = {}
      for _, item in ipairs(s.items) do
        local root = node(s, item)
        if root then
          s.trees[s.direction][#s.trees[s.direction] + 1] = root
        end
      end
    end
    render(s)
    for _, root in ipairs(s.trees[s.direction] or {}) do
      if not root.children then
        expand(s, root)
      end
    end
  end)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "LspDetach" }, {
    group = s.group,
    callback = function(ev)
      if ev.buf == s.ctx.buf and (ev.event ~= "LspDetach" or ev.data.client_id == s.client.id) then
        cancel(s)
        s.status = "Source changed or client detached; r to refresh"
        render(s)
      end
    end,
  })
  prepare(s)
  return s
end
function M.open(kind, opts)
  if not enabled or vim.bo.buftype ~= "" then
    return false
  end
  opts = opts or {}
  local spec = assert(specs[kind], "Unknown hierarchy kind")
  local direction = opts.direction or spec.directions[1]
  assert(vim.tbl_contains(spec.directions, direction), "Invalid hierarchy direction")
  local ctx = request.context()
  local clients = vim.lsp.get_clients({ bufnr = ctx.buf, method = spec.prepare, name = opts.name })
  table.sort(clients, function(a, b)
    return a.id < b.id
  end)
  if #clients == 0 then
    vim.notify("No server supports " .. kind .. " hierarchy", vim.log.levels.INFO)
    return false
  end
  local token = {}
  choosing[kind] = token
  if #clients == 1 then
    return open(ctx, clients[1], kind, direction, opts)
  end
  vim.ui.select(clients, {
    prompt = "Hierarchy provider",
    format_item = function(client)
      return client.name .. " (#" .. client.id .. ")"
    end,
  }, function(client)
    vim.schedule(function()
      if client and enabled and choosing[kind] == token and request.valid(ctx, true) then
        open(ctx, client, kind, direction, opts)
      end
    end)
  end)
  return true
end
function M.disable()
  enabled, choosing = false, {}
  for s in pairs(vim.tbl_extend("force", {}, sessions)) do
    panel.close(s)
  end
end
function M.setup(opts)
  local next_config = vim.tbl_extend("force", config, opts or {})
  for _, name in ipairs({ "request_timeout", "max_nodes", "max_depth" }) do
    assert(
      type(next_config[name]) == "number" and next_config[name] > 0,
      name .. " must be positive"
    )
  end
  M.disable()
  config, enabled = next_config, true
end
return M
