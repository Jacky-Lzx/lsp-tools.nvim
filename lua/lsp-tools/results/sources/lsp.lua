local M = {}
local api = vim.api
local request = require("lsp-tools.request")
local location = require("lsp-tools.results.location")
local methods = {
  { "definitions", "Definitions", "textDocument/definition" },
  { "references", "References", "textDocument/references" },
  { "implementations", "Implementations", "textDocument/implementation" },
  { "type_definitions", "Type Definitions", "textDocument/typeDefinition" },
  { "declarations", "Declarations", "textDocument/declaration" },
}
for i, method in ipairs(methods) do
  method[4] = i
end
local function context(v)
  if api.nvim_win_is_valid(v.ctx.win) and vim.bo[api.nvim_win_get_buf(v.ctx.win)].buftype == "" then
    return api.nvim_win_call(v.ctx.win, request.context)
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(v.tab)) do
    if vim.bo[api.nvim_win_get_buf(win)].buftype == "" then
      return api.nvim_win_call(win, request.context)
    end
  end
end
local function cancel(v)
  v.query_generation = (v.query_generation or 0) + 1
  for _, token in pairs(v.requests or {}) do
    token.cancel()
  end
  v.requests = {}
  v.loading = false
end
local function origin_valid(v)
  return v.query
    and api.nvim_buf_is_valid(v.query.buf)
    and api.nvim_buf_get_changedtick(v.query.buf) == v.query.tick
    and vim.uri_from_bufnr(v.query.buf) == v.query.uri
end
function M.open(results, opts)
  local selected = {}
  for _, method in ipairs(methods) do
    if not opts.method or opts.method == method[1] or opts.method == method[3] then
      selected[#selected + 1] = method
    end
  end
  assert(#selected > 0, "Unknown location method")
  local function refresh(v)
    local ctx = context(v)
    if not ctx then
      v.status = "Open a source window before querying LSP locations"
      results.render(v)
      return
    end
    cancel(v)
    v.query, v.stale = ctx, false
    v.loading = true
    v.ctx.win = ctx.win
    v.title = "LSP · "
      .. vim.fn.fnamemodify(api.nvim_buf_get_name(ctx.buf), ":t")
      .. ":"
      .. ctx.pos[1]
    v.status = "Loading locations…"
    results.render(v)
    local generation, remaining = v.query_generation, #selected
    local sections, errors, cache = {}, {}, {}
    for _, method in ipairs(selected) do
      local token = request.start({
        buf = ctx.buf,
        method = method[3],
        timeout = opts.request_timeout or 3000,
        params = function(client)
          local params = request.position(ctx, client)
          if method[1] == "references" then
            params.context = { includeDeclaration = opts.include_declaration ~= false }
          end
          return params
        end,
      }, function(responses)
        if not require("lsp-tools.panel").alive(v) or generation ~= v.query_generation then
          return
        end
        if not request.valid(ctx, true, true) then
          cancel(v)
          v.stale = true
          v.status = "Source position changed; r queries the current source"
          results.render(v)
          return
        end
        local items, seen = {}, {}
        if #responses == 0 then
          errors[#errors + 1] = method[2] .. ": unsupported"
        end
        for _, response in ipairs(responses) do
          if response.error then
            errors[#errors + 1] = response.client.name
              .. ": "
              .. tostring(response.error.message or response.error)
          else
            local entries = response.result or {}
            if type(entries) ~= "table" then
              errors[#errors + 1] = response.client.name .. ": invalid location response"
              entries = {}
            end
            if entries.uri or entries.targetUri then
              entries = { entries }
            end
            for _, value in ipairs(entries) do
              local ok, item = pcall(location.lsp, value, response.client, cache)
              if ok then
                local key = table.concat({
                  method[1],
                  item.uri,
                  item.pos[1],
                  item.pos[2],
                  item.end_pos[1],
                  item.end_pos[2],
                  item.column_unknown and item.data.encoding or "",
                }, "\31")
                if seen[key] then
                  seen[key].data.client_ids[#seen[key].data.client_ids + 1] = response.client.id
                else
                  item.id, item.section, item.source, item.section_order =
                    key, method[2], "LSP", method[4]
                  seen[key] = item
                  items[#items + 1] = item
                end
              else
                errors[#errors + 1] = response.client.name .. ": invalid location"
              end
            end
          end
        end
        sections[method[1]] = items
        remaining = remaining - 1
        if remaining == 0 then
          v.loading = false
          local all = {}
          for _, kind in ipairs(selected) do
            vim.list_extend(all, sections[kind[1]] or {})
          end
          v.status = #errors > 0 and table.concat(errors, " · ") or nil
          results.set_items(v, all)
        end
      end)
      if token.active then
        v.requests[method[1]] = token
      end
    end
  end
  local options = vim.tbl_deep_extend(
    "force",
    { id = "lsp", title = "LSP locations", group_by = { "section", "file" }, sort = "position" },
    opts
  )
  options.refresh = refresh
  options.validate = function(item, v)
    if v.loading or v.stale or not origin_valid(v) then
      return false
    end
    if
      item.bufnr
      and item.data.tick
      and (
        not api.nvim_buf_is_valid(item.bufnr)
        or api.nvim_buf_get_changedtick(item.bufnr) ~= item.data.tick
      )
    then
      return false
    end
    return vim.deep_equal(item.data.stat, location.stat(item.filename))
  end
  options.on_jump = function(item)
    local ok = vim.lsp.util.show_document(item.data.location, item.data.encoding, { focus = true })
    if ok then
      item.bufnr = api.nvim_get_current_buf()
      item.data.tick = api.nvim_buf_get_changedtick(item.bufnr)
    end
    return ok
  end
  options.to_quickfix = function(item)
    return vim.lsp.util.locations_to_items({ item.data.location }, item.data.encoding)[1]
  end
  options.watch = function(v)
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWipeout", "LspDetach" }, {
      group = v.group,
      callback = function(ev)
        if not v.query then
          return
        end
        local affected = ev.buf == v.query.buf
        for _, item in ipairs(v.items) do
          if item.bufnr == ev.buf then
            affected = true
            break
          end
        end
        if affected then
          cancel(v)
          v.stale = true
          v.status = "Source changed or client detached; r refreshes locations"
          results.render(v)
        end
      end,
    })
    if opts.follow_symbol then
      api.nvim_create_autocmd("CursorMoved", {
        group = v.group,
        callback = function()
          if not v.pinned and api.nvim_get_current_win() == v.ctx.win and vim.bo.buftype == "" then
            results.schedule(v)
          end
        end,
      })
    end
    return function()
      cancel(v)
    end
  end
  local v = results.open({}, options)
  if v then
    refresh(v)
  end
  return v
end
return M
