local M = {}
local api = vim.api
local entries, sequence = {}, 0
local function stat(path)
  return require("lsp-tools.results.location").stat(path)
end
function M.stamp(v)
  local targets = {}
  for _, item in ipairs(v.items) do
    if item.uri and not targets[item.uri] then
      targets[item.uri] = {
        buf = item.bufnr,
        tick = item.bufnr and api.nvim_buf_is_loaded(item.bufnr) and api.nvim_buf_get_changedtick(
          item.bufnr
        ) or nil,
        path = item.filename,
        stat = stat(item.filename),
      }
    end
  end
  v.history_targets = targets
end
function M.capture(v)
  local limit = v.options.history
  if limit == 0 or v.loading or v.stale or v.history_snapshot or #v.items == 0 then
    return
  end
  local origin = v.query or v.ctx
  local identity = vim.inspect({
    v.options.id or "results",
    v.options.method,
    v.options.include_declaration,
    v.title,
    origin.buf,
    origin.uri,
    origin.pos,
    origin.tick,
    v.scope,
    v.native_list and v.native_list.id,
  })
  local old
  for index, entry in ipairs(entries) do
    if entry.identity == identity then
      old = table.remove(entries, index)
      break
    end
  end
  sequence = sequence + 1
  local item = not v.closed and require("lsp-tools.results").selected(v) or nil
  local state = {}
  for _, field in ipairs({
    "query",
    "scope",
    "native_list",
    "native_version",
    "filter",
    "folds",
    "fold_level",
    "fold_enable",
    "sort",
    "group_by",
  }) do
    state[field] = vim.deepcopy(v[field])
  end
  state.selected_id = item and item.id or v.selected_id
  state.pinned = true
  entries[1 + #entries] = {
    id = old and old.id or sequence,
    identity = identity,
    title = v.title,
    origin = vim.deepcopy(origin),
    items = vim.deepcopy(v.raw),
    options = vim.deepcopy(v.options),
    targets = vim.deepcopy(v.history_targets or {}),
    state = state,
    time = os.date("%H:%M:%S"),
  }
  while #entries > limit do
    table.remove(entries, 1)
  end
end
function M.list()
  local out = {}
  for index = #entries, 1, -1 do
    local entry = entries[index]
    out[#out + 1] = {
      id = entry.id,
      title = entry.title,
      origin = vim.deepcopy(entry.origin),
      count = #entry.items,
      time = entry.time,
    }
  end
  return out
end
local function valid(entry, item, v)
  for _, target in pairs(entry.targets) do
    if
      target.tick
      and (
        not api.nvim_buf_is_valid(target.buf)
        or api.nvim_buf_get_changedtick(target.buf) ~= target.tick
      )
    then
      return false
    end
    if not vim.deep_equal(target.stat, stat(target.path)) then
      return false
    end
    local buf = target.path and vim.fn.bufnr(target.path) or -1
    if not target.tick and buf > 0 and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      return false
    end
  end
  local origin = entry.origin
  if
    not api.nvim_buf_is_valid(origin.buf)
    or api.nvim_buf_get_changedtick(origin.buf) ~= origin.tick
    or vim.uri_from_bufnr(origin.buf) ~= origin.uri
  then
    return false
  end
  if entry.state.query then
    local clients = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = origin.buf })) do
      clients[client.id] = true
    end
    local attached = false
    for _, id in ipairs(item.data.client_ids or {}) do
      attached = attached or clients[id] == true
    end
    if not attached then
      return false
    end
  end
  return not entry.options.validate or entry.options.validate(item, v)
end
function M.restore(results, id, opts)
  local entry
  for _, candidate in ipairs(entries) do
    if candidate.id == id then
      entry = candidate
      break
    end
  end
  if not entry then
    return false
  end
  local options = vim.tbl_deep_extend("force", {}, entry.options, opts or {})
  options.context = require("lsp-tools.request").context()
  options.title, options.toggle = entry.title .. " · history", false
  options._state = vim.deepcopy(entry.state)
  options._state.history_snapshot = true
  options.validate = function(item, v)
    return valid(entry, item, v)
  end
  options.refresh = function(v)
    if not entry.options.refresh then
      v.status = "This snapshot has no refresh provider; repeat the original search"
      results.render(v)
      return
    end
    if entry.state.query then
      local origin = entry.origin
      if not api.nvim_buf_is_valid(origin.buf) or vim.uri_from_bufnr(origin.buf) ~= origin.uri then
        v.status = "Query source no longer exists; repeat the query from a source buffer"
        results.render(v)
        return
      end
      api.nvim_win_set_buf(v.ctx.win, origin.buf)
      api.nvim_win_set_cursor(
        v.ctx.win,
        { math.min(origin.pos[1], api.nvim_buf_line_count(origin.buf)), origin.pos[2] }
      )
    end
    v.history_snapshot, v.pinned = false, false
    v.options.validate, v.options.refresh = entry.options.validate, entry.options.refresh
    entry.options.refresh(v)
  end
  local v = results.open(vim.deepcopy(entry.items), options)
  if v then
    v.status = "History snapshot · pinned; refresh to query again"
    results.render(v)
  end
  return v
end
function M.open(results, opts)
  local choices = M.list()
  if #choices == 0 then
    vim.notify("lsp-tools: no result history in this session", vim.log.levels.INFO)
    return false
  end
  vim.ui.select(choices, {
    prompt = "Result history",
    format_item = function(entry)
      return entry.time .. "  " .. entry.title .. "  (" .. entry.count .. ")"
    end,
  }, function(entry)
    if entry then
      M.restore(results, entry.id, opts)
    end
  end)
  return true
end
return M
