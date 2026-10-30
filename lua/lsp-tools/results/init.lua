local M = {}
local api = vim.api
local panel = require("lsp-tools.panel")
local model = require("lsp-tools.results.model")
local view = require("lsp-tools.results.view")
local folds = require("lsp-tools.results.folds")
local config = {
  position = "bottom",
  width = 0.35,
  height = 0.3,
  focus = false,
  group_by = { "file" },
  sort = "position",
  auto_preview = true,
  debounce = 80,
  max_items = 5000,
  icons = true,
  indent_guides = true,
  multiline = true,
}
local enabled = false
local sessions, cache, cache_order = {}, {}, {}
local ns = api.nvim_create_namespace("lsp-tools.results")
local render, refresh, preview
local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end
function M.current(id)
  return panel.get("results-" .. (id or "results"))
end
local function selected(v)
  if not panel.alive(v) then
    return
  end
  local row = v.line_rows[api.nvim_win_get_cursor(v.win)[1]]
  return row and row.item, row
end
local function close_preview(v)
  if
    v.preview
    and api.nvim_win_is_valid(v.preview.win)
    and api.nvim_win_get_buf(v.preview.win) == v.preview.buf
  then
    pcall(api.nvim_win_close, v.preview.win, true)
  end
  if v.preview and api.nvim_buf_is_valid(v.preview.buf) then
    pcall(api.nvim_buf_delete, v.preview.buf, { force = true })
  end
  v.preview = nil
end
local function close_help(v)
  if v.help then
    if api.nvim_win_is_valid(v.help.win) then
      pcall(api.nvim_win_close, v.help.win, true)
    end
    if api.nvim_buf_is_valid(v.help.buf) then
      pcall(api.nvim_buf_delete, v.help.buf, { force = true })
    end
    v.help = nil
  end
end
local function help(v)
  close_help(v)
  close_preview(v)
  local mappings = vim.tbl_values(v.keymaps)
  table.sort(mappings, function(a, b)
    return a.lhs < b.lhs
  end)
  vim.list_extend(mappings, {
    { lhs = "gg / G", desc = "First / last line (Vim)" },
    { lhs = "za / zo / zc", desc = "Toggle / open / close fold (Vim)" },
    { lhs = "zM / zR", desc = "Close / open all folds (Vim)" },
    { lhs = "zm / zr", desc = "Decrease / increase fold level (Vim)" },
    { lhs = "zj / zk", desc = "Next / previous fold (Vim)" },
    { lhs = "w / b / e", desc = "Word motions (Vim)" },
    { lhs = "f / F", desc = "Find character (Vim)" },
    { lhs = "/ / ?", desc = "Search forward / backward (Vim)" },
  })
  local lines, columns = {}, 0
  for _, mapping in ipairs(mappings) do
    columns = math.max(columns, vim.fn.strdisplaywidth(mapping.lhs))
  end
  for _, mapping in ipairs(mappings) do
    lines[#lines + 1] = "  "
      .. mapping.lhs
      .. string.rep(" ", columns + 2 - vim.fn.strdisplaywidth(mapping.lhs))
      .. mapping.desc
  end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
  vim.bo[buf].filetype = "lsp-tools-results"
  local width, height =
    math.max(1, math.min(64, vim.o.columns - 4)), math.max(1, math.min(#lines, vim.o.lines - 6))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Result keys ",
  })
  v.help = { win = win, buf = buf }
  for i in ipairs(lines) do
    api.nvim_buf_set_extmark(
      buf,
      ns,
      i - 1,
      2,
      { end_col = 2 + #mappings[i].lhs, hl_group = "Special" }
    )
  end
  for _, lhs in ipairs({ "<Esc>", "<LocalLeader>q", "<LocalLeader>?" }) do
    vim.keymap.set("n", lhs, function()
      close_help(v)
      if panel.alive(v) then
        api.nvim_set_current_win(v.win)
      end
    end, { buffer = buf, nowait = true, desc = "Close help" })
  end
end
local function remember(v)
  cache[v.cache_key] = {
    raw = v.raw,
    filter = vim.deepcopy(v.filter),
    folds = vim.deepcopy(v.folds),
    fold_level = v.fold_level,
    fold_enable = v.fold_enable,
    sort = v.sort,
    group_by = vim.deepcopy(v.group_by),
    selected = v.selected_id,
    pinned = v.pinned,
    title = v.title,
  }
  for i = #cache_order, 1, -1 do
    if cache_order[i] == v.cache_key then
      table.remove(cache_order, i)
    end
  end
  cache_order[#cache_order + 1] = v.cache_key
  if #cache_order > 20 then
    cache[table.remove(cache_order, 1)] = nil
  end
end
function M.close(id)
  panel.close(M.current(id))
end
local function target_window(v)
  if
    api.nvim_win_is_valid(v.ctx.win)
    and api.nvim_win_get_tabpage(v.ctx.win) == v.tab
    and vim.bo[api.nvim_win_get_buf(v.ctx.win)].buftype == ""
  then
    return v.ctx.win
  end
  if api.nvim_tabpage_is_valid(v.tab) then
    for _, win in ipairs(api.nvim_tabpage_list_wins(v.tab)) do
      if win ~= v.win and vim.bo[api.nvim_win_get_buf(win)].buftype == "" then
        v.ctx.win = win
        return win
      end
    end
    api.nvim_set_current_win(v.win)
    vim.cmd("aboveleft new")
    v.ctx.win = api.nvim_get_current_win()
    return v.ctx.win
  end
end
local function location(item)
  if not item.uri then
    return
  end
  local pos = item.pos
  return {
    uri = item.uri,
    range = {
      start = { line = pos[1] - 1, character = pos[2] },
      ["end"] = { line = pos[1] - 1, character = pos[2] },
    },
  }
end
function M.jump(v, keep_focus)
  local item = selected(v)
  if not item then
    return false
  end
  if v.options.validate and not v.options.validate(item, v) then
    v.status = "Result changed; refresh before jumping"
    render(v)
    return false
  end
  local loc = location(item)
  if not loc then
    v.status = "This result has no source location"
    render(v)
    return false
  end
  local win = target_window(v)
  if not win then
    return false
  end
  close_preview(v)
  api.nvim_set_current_win(win)
  local ok, handled = pcall(function()
    if v.options.on_jump and v.options.on_jump(item, v) then
      return true
    end
    return vim.lsp.util.show_document(loc, "utf-8", { focus = true })
  end)
  if not ok then
    v.status = tostring(handled)
    render(v)
  end
  if keep_focus and panel.alive(v) then
    api.nvim_set_current_win(v.win)
  end
  return ok and handled
end
preview = function(v, changes)
  if not panel.alive(v) then
    return
  end
  local item = selected(v)
  if not item then
    close_preview(v)
    return
  end
  local focused = v.preview and api.nvim_get_current_win() == v.preview.win
  v.preview_options = vim.tbl_deep_extend(
    "force",
    {},
    v.options.preview or {},
    v.preview_options or {},
    changes or {}
  )
  close_preview(v)
  v.preview = require("lsp-tools.results.preview").open(item, v.preview_options, {
    options = v.options,
    return_list = function()
      if panel.alive(v) then
        api.nvim_set_current_win(v.win)
      end
      close_preview(v)
    end,
    reopen = function(opts)
      preview(v, opts)
    end,
  })
  if focused then
    api.nvim_set_current_win(v.preview.win)
  end
end
local function schedule_preview(v)
  stop(v.preview_timer)
  v.preview_timer = nil
  if not v.auto_preview or api.nvim_get_current_win() ~= v.win then
    return
  end
  v.preview_timer = assert(vim.uv.new_timer())
  local timer = v.preview_timer
  timer:start(
    v.options.debounce,
    0,
    vim.schedule_wrap(function()
      stop(timer)
      if v.preview_timer ~= timer then
        return
      end
      v.preview_timer = nil
      if panel.alive(v) and api.nvim_get_current_win() == v.win then
        preview(v)
      end
    end)
  )
end
render = function(v)
  if not panel.alive(v) then
    return
  end
  folds.capture(v)
  local reveal = v.selected_id ~= nil
  local old, old_row = selected(v)
  local id = v.selected_id or (old and old.id)
  local key = old_row and old_row.key
  v.rows, v.filtered =
    model.rows(v.items, { filter = v.filter, sort = v.sort, group_by = v.group_by })
  local layout = view.layout(v)
  v.line_rows, v.row_lines = layout.line_rows, layout.row_lines
  panel.write(v, layout.lines)
  api.nvim_buf_clear_namespace(v.out, ns, 0, -1)
  for line, spans in ipairs(layout.highlights) do
    for _, span in ipairs(spans) do
      api.nvim_buf_set_extmark(
        v.out,
        ns,
        line - 1,
        span[1],
        { end_col = span[2], hl_group = span[3] }
      )
    end
  end
  folds.apply(v, layout)
  vim.wo[v.win].winbar = view.winbar(v)
  local cursor, fallback
  for index, row in ipairs(v.rows) do
    if row.item then
      fallback = fallback or v.row_lines[index]
      if row.item.id == id then
        cursor = v.row_lines[index]
      end
    elseif row.key == key and not v.selected_id then
      cursor = v.row_lines[index]
    end
  end
  if reveal and cursor then
    folds.reveal(v, cursor)
  else
    api.nvim_win_set_cursor(v.win, { cursor or fallback or 1, 0 })
  end
  v.selected_id = nil
  schedule_preview(v)
end
function M.set_items(v, items, append)
  if not panel.alive(v) then
    return
  end
  local item = selected(v)
  v.selected_id = item and item.id or v.selected_id
  v.raw = append and vim.list_extend(vim.list_extend({}, v.raw), items) or items
  v.items = model.normalize(v.raw, v.options.max_items)
  if #v.raw > v.options.max_items then
    v.status = "Result limit reached (" .. v.options.max_items .. ")"
  end
  render(v)
end
refresh = function(v)
  if not panel.alive(v) or not v.options.refresh then
    return
  end
  local ok, err = pcall(v.options.refresh, v)
  if not ok then
    v.status = tostring(err)
    render(v)
  end
end
function M.refresh(v)
  refresh(v)
end
function M.schedule(v)
  stop(v.refresh_timer)
  v.refresh_timer = nil
  if v.pinned or not panel.alive(v) then
    return
  end
  v.refresh_timer = assert(vim.uv.new_timer())
  local timer = v.refresh_timer
  timer:start(
    v.options.debounce,
    0,
    vim.schedule_wrap(function()
      stop(timer)
      if v.refresh_timer ~= timer then
        return
      end
      v.refresh_timer = nil
      refresh(v)
    end)
  )
end
function M.filter(v, filter)
  v.filter = vim.tbl_extend("force", v.filter, filter or {})
  render(v)
end
function M.select(v, id)
  for _, item in ipairs(v.items) do
    if item.id == id and model.matches(item, v.filter) then
      v.selected_id = id
      render(v)
      return true
    end
  end
  return false
end
function M.export(v)
  local entries = {}
  for _, item in ipairs(v.filtered) do
    if item.uri then
      if v.options.to_quickfix then
        local converted = v.options.to_quickfix(item)
        if converted then
          entries[#entries + 1] = converted
        end
      else
        entries[#entries + 1] = {
          bufnr = item.bufnr,
          filename = item.filename,
          lnum = item.pos[1],
          col = item.pos[2] + 1,
          end_lnum = item.end_pos and item.end_pos[1],
          end_col = item.end_pos and item.end_pos[2] + 1,
          text = item.text,
          type = ({ "E", "W", "I", "H" })[item.severity] or "",
        }
      end
    end
  end
  vim.fn.setqflist({}, " ", { title = v.title, items = entries })
  v.status = "Exported " .. #entries .. " locations to quickfix"
  render(v)
end
function M.open(items, opts)
  if not enabled then
    return false
  end
  opts = opts or {}
  local id = opts.id or "results"
  local existing = M.current(id)
  if existing and opts.toggle then
    panel.close(existing)
    return false
  end
  local tab = api.nvim_get_current_tabpage()
  local cache_key = tostring(tab) .. ":" .. id
  if existing then
    panel.close(existing)
  end
  local saved = cache[cache_key] or {}
  local ctx = opts.context or require("lsp-tools.request").context()
  if vim.bo[ctx.buf].buftype ~= "" then
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if vim.bo[api.nvim_win_get_buf(win)].buftype == "" then
        ctx = api.nvim_win_call(win, require("lsp-tools.request").context)
        break
      end
    end
  end
  local options = vim.tbl_deep_extend("force", {}, config, opts)
  local v = panel.open("results-" .. id, ctx, {
    position = options.position,
    width = options.width,
    height = options.height,
    focus = options.focus,
    persistent = true,
    filetype = "lsp-tools-results",
    close_keys = {},
    keymaps = options.keymaps,
    key_prefix = options.key_prefix,
  })
  for name, value in pairs({
    wrap = false,
    list = false,
    foldenable = true,
    foldmethod = "expr",
    foldexpr = "get(get(b:, 'lsp_tools_result_foldlevels', []), v:lnum - 1, 0)",
    foldtext = "v:lua.require'lsp-tools.results.folds'.text()",
    foldminlines = 0,
    foldnestmax = 20,
    cursorline = true,
    cursorlineopt = "line",
    fillchars = "eob: ,fold: ",
    winhighlight = "CursorLine:LspToolsResultsCursorLine,WinBar:LspToolsResultsWinBar,WinBarNC:LspToolsResultsWinBarNC,Folded:LspToolsResultsFolded",
  }) do
    vim.wo[v.win][name] = value
  end
  v.cache_key, v.tab, v.options, v.title =
    cache_key, tab, options, opts.title or saved.title or "Results"
  v.filter, v.folds =
    vim.deepcopy(opts.filter or saved.filter or {}), vim.deepcopy(saved.folds or {})
  v.sort, v.group_by =
    opts.sort or saved.sort or options.sort,
    vim.deepcopy(opts.group_by or saved.group_by or options.group_by)
  v.fold_level, v.fold_enable = saved.fold_level or #v.group_by, saved.fold_enable ~= false
  v.pinned, v.auto_preview =
    opts.pinned == nil and saved.pinned or opts.pinned, options.auto_preview
  v.raw, v.items, v.rows = {}, {}, {}
  v.line_rows, v.row_lines = {}, {}
  v.keymaps = v.bindings.entries
  v.help_key = ""
  v.selected_id, v.stops = saved.selected, {}
  sessions[v] = true
  v.on_close = function()
    if api.nvim_win_is_valid(v.win) then
      local row = v.line_rows[api.nvim_win_get_cursor(v.win)[1]]
      v.selected_id = row and row.item and row.item.id or v.selected_id
    end
    folds.capture(v)
    remember(v)
    folds.release(v)
    stop(v.preview_timer)
    stop(v.refresh_timer)
    close_preview(v)
    close_help(v)
    for _, cleanup in ipairs(v.stops) do
      pcall(cleanup)
    end
    sessions[v] = nil
    if options.on_close then
      options.on_close(v)
    end
  end
  local function map(lhs, fn, desc)
    local action = ({
      ["<Esc>"] = "close",
      ["<LocalLeader>q"] = "close",
      ["<LocalLeader>?"] = "help",
      ["<CR>"] = "jump",
      ["<LocalLeader>o"] = "jump_keep",
      ["<LocalLeader>p"] = "preview",
      ["<LocalLeader>P"] = "auto_preview",
      ["<LocalLeader>f"] = "filter",
      ["<LocalLeader>e"] = "errors",
      ["<LocalLeader>s"] = "sort",
      ["<LocalLeader>g"] = "group",
      ["<LocalLeader>F"] = "pin",
      ["<LocalLeader>r"] = "refresh",
      ["<LocalLeader>Q"] = "export",
      ["<LocalLeader>b"] = "return_source",
      ["]q"] = "next",
      ["[q"] = "previous",
      ["<LocalLeader>d"] = "details",
      ["<LocalLeader>a"] = "fix",
      ["<LocalLeader>A"] = "fix_next",
      ["<LocalLeader>S"] = "scope",
    })[lhs] or lhs
    local default = lhs:gsub("<LocalLeader>", "<prefix>")
    if action == "close" then
      default = { "<Esc>", "<prefix>q" }
    end
    local keys = v.bindings:map(action, default, fn, desc)
    if action == "help" then
      v.help_key = keys[1] and require("lsp-tools.keymaps").label(keys[1]) or ""
    end
  end
  local function fold()
    local _, row = selected(v)
    if row and not row.item then
      api.nvim_win_call(v.win, function()
        vim.cmd.normal({ args = { "za" }, bang = true })
      end)
    end
  end
  local function close()
    if api.nvim_get_current_win() == v.win and api.nvim_win_is_valid(v.ctx.win) then
      api.nvim_set_current_win(v.ctx.win)
    end
    panel.close(v)
  end
  map("<LocalLeader>q", close, "Close results")
  map("<LocalLeader>?", function()
    help(v)
  end, "Show key bindings")
  map("<CR>", function()
    local item = selected(v)
    if item then
      M.jump(v)
    else
      fold()
    end
  end, "Jump or fold")
  map("<LocalLeader>o", function()
    M.jump(v, true)
  end, "Jump and keep list focus")
  map("<LocalLeader>p", function()
    preview(v)
  end, "Preview source")
  v.bindings:map("focus_preview", "<prefix>w", function()
    if not v.preview or not api.nvim_win_is_valid(v.preview.win) then
      preview(v)
    end
    if v.preview then
      api.nvim_set_current_win(v.preview.win)
    end
  end, "Focus source preview")
  map("<LocalLeader>P", function()
    v.auto_preview = not v.auto_preview
    if not v.auto_preview then
      close_preview(v)
    else
      preview(v)
    end
  end, "Toggle automatic preview")
  map("<LocalLeader>f", function()
    vim.ui.input({ prompt = "Filter results: ", default = v.filter.text }, function(text)
      if text ~= nil and panel.alive(v) then
        v.filter.text = text
        render(v)
      end
    end)
  end, "Filter results")
  map("<LocalLeader>e", function()
    if v.filter.severity then
      v.filter.severity = nil
    else
      v.filter.severity = vim.diagnostic.severity.ERROR
    end
    render(v)
  end, "Toggle errors only")
  map("<LocalLeader>s", function()
    v.sort = v.sort == "position" and "severity" or v.sort == "severity" and "none" or "position"
    render(v)
  end, "Cycle sort")
  map("<LocalLeader>g", function()
    v.group_by = #v.group_by > 0 and {} or { "directory", "file" }
    render(v)
  end, "Toggle grouping")
  map("<LocalLeader>F", function()
    v.pinned = not v.pinned
    if not v.pinned then
      refresh(v)
    end
    render(v)
  end, "Pin results")
  map("<LocalLeader>r", function()
    refresh(v)
  end, "Refresh results")
  map("<LocalLeader>Q", function()
    M.export(v)
  end, "Export results to quickfix")
  map("<LocalLeader>b", function()
    if api.nvim_win_is_valid(v.ctx.win) then
      api.nvim_set_current_win(v.ctx.win)
    end
  end, "Return to source")
  for lhs, direction in pairs({ ["]q"] = 1, ["[q"] = -1 }) do
    map(lhs, function()
      local current = v.line_rows[api.nvim_win_get_cursor(v.win)[1]]
      local row = current and current.index or (direction > 0 and 0 or #v.rows + 1)
      for _ = 1, vim.v.count1 do
        repeat
          row = row + direction
        until row < 1 or row > #v.rows or v.rows[row].item
        if row < 1 or row > #v.rows then
          return
        end
      end
      folds.reveal(v, v.row_lines[row])
    end, "Navigate results")
  end
  local function extra(entries, item_action)
    for name, spec in pairs(entries or {}) do
      local defined = type(spec) == "table"
      local fn, keys = defined and spec.action or spec, defined and spec.keys or name
      v.bindings:map(defined and name or "custom:" .. name, keys, function()
        if item_action then
          local item = selected(v)
          if item then
            fn(item, v)
          end
        else
          fn(v)
        end
      end, defined and spec.desc or (options.descriptions or {})[name] or name)
    end
  end
  extra(options.actions, true)
  extra(options.keys, false)
  api.nvim_create_autocmd("CursorMoved", {
    group = v.group,
    buffer = v.out,
    callback = function()
      schedule_preview(v)
    end,
  })
  if options.follow then
    api.nvim_create_autocmd("CursorMoved", {
      group = v.group,
      callback = function(ev)
        if ev.buf == v.out or api.nvim_get_current_win() == v.win then
          return
        end
        local pos = api.nvim_win_get_cursor(0)
        for row, entry in ipairs(v.rows) do
          if entry.item and entry.item.bufnr == ev.buf and entry.item.pos[1] == pos[1] then
            folds.reveal(v, v.row_lines[row])
            break
          end
        end
      end,
    })
  end
  if options.watch then
    local cleanup = options.watch(v)
    if cleanup then
      v.stops[#v.stops + 1] = cleanup
    end
  end
  M.set_items(v, items or saved.raw or {})
  return v
end
function M.source(name, opts)
  opts = opts or {}
  local id = opts.id or name
  if opts.toggle and M.current(id) then
    M.close(id)
    return false
  end
  return require("lsp-tools.results.sources." .. name).open(
    M,
    vim.tbl_deep_extend("force", {}, config[name] or {}, opts)
  )
end
function M.from_picker(picker, opts)
  return require("lsp-tools.results.picker").open(M, picker, opts)
end
function M.selected(v)
  return selected(v)
end
function M.render(v)
  render(v)
end
function M.preview(v)
  preview(v)
end
function M.disable()
  enabled = false
  view.disable()
  if package.loaded["lsp-tools.results.picker"] then
    package.loaded["lsp-tools.results.picker"].cancel()
  end
  for v in pairs(vim.tbl_extend("force", {}, sessions)) do
    panel.close(v)
  end
end
function M.setup(opts)
  local next_config = vim.tbl_deep_extend("force", config, opts or {})
  assert(
    next_config.position == "bottom" or next_config.position == "right",
    "results.position must be bottom or right"
  )
  assert(
    next_config.max_items > 0 and next_config.max_items % 1 == 0,
    "max_items must be a positive integer"
  )
  assert(next_config.debounce >= 0, "debounce must be nonnegative")
  M.disable()
  view.setup()
  config, enabled = next_config, true
end
return M
