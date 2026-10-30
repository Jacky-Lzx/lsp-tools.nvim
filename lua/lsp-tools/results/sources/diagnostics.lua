local M = {}
local api = vim.api
local panel = require("lsp-tools.panel")
local function signature(d)
  return table.concat(
    { d.namespace or "", d.bufnr, d.message, d.source or "", d.code or "" },
    "\31"
  )
end
local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end
function M.open(results, opts)
  local ctx = opts.context or require("lsp-tools.request").context()
  local root = opts.root
    or vim.fs.root(ctx.buf, { ".git" })
    or (api.nvim_buf_get_name(ctx.buf) ~= "" and vim.fs.dirname(api.nvim_buf_get_name(ctx.buf)))
    or vim.fn.getcwd()
  root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
  local function collect(v)
    local diagnostics = vim.diagnostic.get(
      v.scope == "buffer" and ctx.buf or nil,
      opts.namespace and { namespace = opts.namespace } or {}
    )
    table.sort(diagnostics, function(a, b)
      if a.bufnr ~= b.bufnr then
        return a.bufnr < b.bufnr
      end
      if a.lnum ~= b.lnum then
        return a.lnum < b.lnum
      end
      if a.col ~= b.col then
        return a.col < b.col
      end
      return (a.namespace or 0) < (b.namespace or 0)
    end)
    local items, seen = {}, {}
    for _, d in ipairs(diagnostics) do
      local filename = api.nvim_buf_get_name(d.bufnr)
      if v.scope ~= "project" or filename ~= "" and vim.fs.relpath(root, filename) then
        local key = signature(d)
        seen[key] = (seen[key] or 0) + 1
        items[#items + 1] = {
          id = key .. ":" .. seen[key],
          bufnr = d.bufnr,
          pos = { d.lnum + 1, d.col },
          end_pos = { (d.end_lnum or d.lnum) + 1, d.end_col or d.col },
          text = d.message,
          severity = d.severity,
          code = d.code,
          source = d.source or "",
          data = { diagnostic = d, signature = key, tick = api.nvim_buf_get_changedtick(d.bufnr) },
        }
      end
    end
    return items
  end
  local function refresh(v)
    v.title = "Diagnostics · " .. v.scope .. (v.scope == "all" and " (received)" or "")
    local items = collect(v)
    results.set_items(v, items)
    if v.advance then
      local count = 0
      for _, item in ipairs(items) do
        if item.data.signature == v.advance.signature then
          count = count + 1
        end
      end
      if count < v.advance.count then
        local advance = v.advance
        v.advance = nil
        stop(v.advance_timer)
        v.advance_timer = nil
        local next_item = v.filtered[math.min(advance.ordinal, #v.filtered)]
        if next_item then
          results.select(v, next_item.id)
          if
            api.nvim_win_is_valid(advance.win)
            and api.nvim_win_get_buf(advance.win) == advance.buf
            and api.nvim_buf_get_changedtick(advance.buf) == advance.tick
            and vim.deep_equal(api.nvim_win_get_cursor(advance.win), advance.pos)
          then
            local current = api.nvim_get_current_win()
            if current == v.win or current == advance.win then
              results.jump(v, current == v.win)
            end
          end
        end
        v.status = "Fix confirmed; continued to the next matching diagnostic"
        results.render(v)
      end
    end
  end
  local function detail(item, v, fix, advance)
    if not results.jump(v) then
      return
    end
    local raw, ordinal, matches = item.data.diagnostic, 1, 0
    for i, candidate in ipairs(v.filtered) do
      if candidate.id == item.id then
        ordinal = i
      end
    end
    for _, candidate in ipairs(v.items) do
      if candidate.data.signature == item.data.signature then
        matches = matches + 1
      end
    end
    local source = require("lsp-tools.request").context()
    local s = require("lsp-tools").diagnostic({
      diagnostic = raw,
      focus = not fix,
      on_applied = function()
        if not panel.alive(v) then
          return
        end
        if advance then
          v.advance = {
            signature = item.data.signature,
            count = matches,
            ordinal = ordinal,
            win = source.win,
            buf = source.buf,
            tick = api.nvim_buf_get_changedtick(source.buf),
            pos = api.nvim_win_get_cursor(source.win),
          }
          stop(v.advance_timer)
          v.advance_timer = assert(vim.uv.new_timer())
          local timer = v.advance_timer
          timer:start(
            opts.advance_timeout or 5000,
            0,
            vim.schedule_wrap(function()
              stop(timer)
              if v.advance_timer ~= timer then
                return
              end
              v.advance_timer = nil
              if panel.alive(v) and v.advance then
                v.advance = nil
                v.status = "Waiting for confirmed diagnostics; refresh manually to continue"
                results.render(v)
              end
            end)
          )
        end
        if not v.pinned then
          refresh(v)
        end
      end,
    })
    if s and fix then
      require("lsp-tools.diagnostics").fix(s, false)
    elseif not s then
      v.status = "Enable diagnostics for details and fix previews"
      results.render(v)
    end
  end
  local options = vim.tbl_deep_extend("force", {
    id = "diagnostics",
    title = "Diagnostics",
    group_by = { "directory", "file" },
    sort = "severity",
  }, opts)
  options.context, options.refresh = ctx, refresh
  options.descriptions = vim.tbl_extend("force", opts.descriptions or {}, {
    d = "Diagnostic details",
    a = "Preview diagnostic fix",
    A = "Fix and continue",
    S = "Cycle all/project/buffer scope",
  })
  options.validate = function(item)
    local d = item.data.diagnostic
    if
      not api.nvim_buf_is_valid(d.bufnr)
      or api.nvim_buf_get_changedtick(d.bufnr) ~= item.data.tick
    then
      return false
    end
    for _, current in ipairs(vim.diagnostic.get(d.bufnr, { namespace = d.namespace })) do
      if current.lnum == d.lnum and current.col == d.col and signature(current) == signature(d) then
        return true
      end
    end
    return false
  end
  options.watch = function(v)
    v.scope = opts.scope or "all"
    assert(
      v.scope == "all" or v.scope == "project" or v.scope == "buffer",
      "Invalid diagnostic scope"
    )
    api.nvim_create_autocmd({ "DiagnosticChanged", "BufWipeout" }, {
      group = v.group,
      callback = function(ev)
        if ev.buf ~= v.out then
          results.schedule(v)
        end
      end,
    })
    return function()
      stop(v.advance_timer)
    end
  end
  options.actions = vim.tbl_extend("force", opts.actions or {}, {
    d = function(item, v)
      detail(item, v, false)
    end,
    a = function(item, v)
      detail(item, v, true, false)
    end,
    A = function(item, v)
      detail(item, v, true, true)
    end,
  })
  options.keys = vim.tbl_extend("force", opts.keys or {}, {
    S = function(v)
      v.scope = v.scope == "all" and "project" or v.scope == "project" and "buffer" or "all"
      refresh(v)
    end,
  })
  local v = results.open({}, options)
  if v then
    refresh(v)
  end
  return v
end
return M
