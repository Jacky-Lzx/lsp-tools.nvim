-- LSP semantics live here; selection-tools owns matching, windows and preview frames.
local M = {}
local api = vim.api
local request = require("lsp-tools.request")
local model = require("lsp-tools.pickers.model")
local config = {}
local active
function M.current()
  return active and not active.picker.closed and active.picker or nil
end
local methods = {
  definitions = { "Definitions", "textDocument/definition" },
  declarations = { "Declarations", "textDocument/declaration" },
  references = { "References", "textDocument/references" },
  implementations = { "Implementations", "textDocument/implementation" },
  type_definitions = { "Type definitions", "textDocument/typeDefinition" },
  symbols = { "Document symbols", "textDocument/documentSymbol" },
  workspace_symbols = { "Workspace symbols", "workspace/symbol" },
}

local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function cancel(s)
  stop(s.timer)
  stop(s.auto_timer)
  s.timer = nil
  s.auto_timer = nil
  for _, token in ipairs(s.tokens) do
    token.cancel()
  end
  s.tokens = {}
end

function M.disable()
  if active then
    active.picker:close()
  end
end

function M.setup(opts)
  M.disable()
  config = vim.tbl_deep_extend(
    "force",
    { request_timeout = 3000, debounce = 100, jump_single = true, picker = {} },
    opts or {}
  )
end

local function origin_valid(s)
  local origin = s.origin
  if s.kind == "diagnostics" then
    return api.nvim_win_is_valid(origin.win)
      and api.nvim_buf_is_valid(origin.buf)
      and api.nvim_win_get_buf(origin.win) == origin.buf
      and vim.uri_from_bufnr(origin.buf) == origin.uri
  end
  return not s.stale and request.valid(origin, s.locations, true)
end

local function provider(s, item, method)
  for _, client in
    ipairs(vim.lsp.get_clients({ bufnr = s.origin.buf, method = method or s.method }))
  do
    if vim.tbl_contains(item.data.client_ids, client.id) then
      return client
    end
  end
end

local function valid(s, item)
  if not origin_valid(s) then
    return false, "Source changed; reopen this picker"
  end
  if s.kind == "diagnostics" then
    if not model.diagnostic_valid(item) then
      return false, "Diagnostic changed; choose an updated diagnostic"
    end
    return true
  end
  if not provider(s, item) then
    return false, "The location provider detached"
  end
  if item.data.unresolved then
    return true
  end
  if not model.target_valid(item) then
    return false, "Target changed; reopen this picker"
  end
  return true
end

local function jump(s, item)
  local ok, err = valid(s, item)
  if not ok then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  api.nvim_set_current_win(s.origin.win)
  local destination
  if s.jump_mode then
    vim.cmd(({ split = "split", vsplit = "vsplit", tab = "tabnew" })[s.jump_mode])
    destination = api.nvim_get_current_win()
  end
  local success, result = pcall(function()
    if s.kind ~= "diagnostics" then
      return vim.lsp.util.show_document(
        item.data.location,
        item.data.encoding,
        { focus = true, reuse_win = not s.jump_mode }
      )
    end
    local location = {
      uri = item.uri,
      range = {
        start = { line = item.pos[1] - 1, character = item.pos[2] },
        ["end"] = { line = item.end_pos[1] - 1, character = item.end_pos[2] },
      },
    }
    return vim.lsp.util.show_document(
      location,
      "utf-8",
      { focus = true, reuse_win = not s.jump_mode }
    )
  end)
  if not success or not result then
    if destination and api.nvim_win_is_valid(destination) then
      api.nvim_win_close(destination, true)
    end
    vim.notify("Unable to jump to result: " .. tostring(result), vim.log.levels.WARN)
  end
end

local function confirm(s, ctx)
  local mode = s.mode
  local ok, err = valid(s, ctx.item)
  if not ok then
    return false, err
  end
  if not ctx.item.data.unresolved then
    s.jump_mode = mode
    return true
  end
  local client = provider(s, ctx.item, "workspaceSymbol/resolve")
  if not client then
    return false, "The server cannot resolve this workspace symbol"
  end
  cancel(s)
  local token = request.start({
    buf = s.origin.buf,
    clients = { client },
    method = "workspaceSymbol/resolve",
    timeout = s.opts.request_timeout,
    params = ctx.item.data.unresolved,
  }, function(responses)
    if ctx.is_cancelled() then
      return
    end
    local response = responses[1]
    if not response or response.error or type(response.result) ~= "table" then
      ctx.reject(
        response and response.error and response.error.message
          or "Unable to resolve workspace symbol"
      )
      return
    end
    local success, item = pcall(model.location, response.result.location, client, {})
    if not success then
      ctx.reject("Invalid resolved workspace symbol")
      return
    end
    item.name, item.kind, item.depth, item.detail =
      ctx.item.name, ctx.item.kind, ctx.item.depth, ctx.item.detail
    for key, value in pairs(item) do
      ctx.item[key] = value
    end
    local accepted, message = valid(s, ctx.item)
    if accepted then
      s.jump_mode = mode
      ctx.accept()
    else
      ctx.reject(message)
    end
  end)
  s.tokens[#s.tokens + 1] = token
end

local function same_position(item, origin)
  if item.uri ~= origin.uri then
    return false
  end
  local a, b, pos = item.pos, item.end_pos, origin.pos
  local function before(x, y)
    return x[1] < y[1] or x[1] == y[1] and x[2] < y[2]
  end
  return not before(pos, a) and (before(pos, b) or vim.deep_equal(a, b) and vim.deep_equal(pos, a))
end

local function find(s, ctx)
  cancel(s)
  s.finder = ctx
  local function start()
    s.timer = nil
    if ctx.is_cancelled() then
      return
    end
    if not origin_valid(s) then
      ctx.fail("Source changed; reopen this picker")
      return
    end
    local token = request.start({
      buf = s.origin.buf,
      method = s.method,
      timeout = s.opts.request_timeout,
      params = function(client)
        if s.kind == "workspace_symbols" then
          return { query = ctx.query }
        end
        if s.kind == "symbols" then
          return { textDocument = { uri = s.origin.uri } }
        end
        local params = request.position(s.origin, client)
        if s.kind == "references" then
          params.context = { includeDeclaration = s.opts.include_declaration ~= false }
        end
        return params
      end,
    }, function(responses)
      if ctx.is_cancelled() then
        return
      end
      if not origin_valid(s) then
        ctx.fail("Source changed; reopen this picker")
        return
      end
      local items, seen, errors, cache = {}, {}, {}, {}
      local function add(item)
        if s.locations and s.opts.include_current ~= true and same_position(item, s.origin) then
          return
        end
        local key = model.key(item)
        if seen[key] then
          vim.list_extend(seen[key].data.client_ids, item.data.client_ids)
        else
          seen[key] = item
          items[#items + 1] = item
        end
      end
      for _, response in ipairs(responses) do
        if response.error then
          errors[#errors + 1] = response.client.name
            .. ": "
            .. tostring(response.error.message or response.error)
        elseif response.result then
          local ok, err = pcall(function()
            if not s.locations then
              model.symbols(
                response.result,
                response.client,
                s.origin.uri,
                cache,
                add,
                s.kind == "workspace_symbols"
              )
            else
              local values = response.result
              assert(type(values) == "table", "Invalid location response")
              if values.uri or values.targetUri then
                values = { values }
              end
              for _, value in ipairs(values) do
                add(model.location(value, response.client, cache))
              end
            end
          end)
          if not ok then
            errors[#errors + 1] = response.client.name .. ": " .. tostring(err)
          end
        end
      end
      if #responses == 0 then
        ctx.fail("No LSP provider supports " .. s.method)
        return
      end
      if #items == 0 and #errors > 0 then
        ctx.fail(table.concat(errors, " · "))
        return
      end
      if #errors > 0 then
        vim.notify(table.concat(errors, " · "), vim.log.levels.WARN)
      end
      ctx.set_items(items)
      ctx.done()
      if s.locations and s.opts.jump_single and #items == 1 then
        local started = vim.uv.hrtime()
        local function choose_single()
          s.auto_timer = nil
          local picker = s.picker
          if ctx.is_cancelled() or picker.query ~= ctx.query or picker:current() ~= items[1] then
            return
          end
          if picker.syntax_pending then
            -- Confirmation waits for the same ready syntax frame as manual Enter.
            if (vim.uv.hrtime() - started) / 1e6 < s.opts.request_timeout then
              s.auto_timer = vim.defer_fn(choose_single, 10)
            end
          else
            picker:confirm()
          end
        end
        vim.schedule(choose_single)
      end
    end)
    s.tokens[#s.tokens + 1] = token
  end
  s.timer = vim.defer_fn(start, s.kind == "workspace_symbols" and s.opts.debounce or 0)
  return function()
    cancel(s)
  end
end

local function export(s, picker, loclist, all)
  if picker.closed or picker.matching or picker.loading then
    return
  end
  local items = not all and picker:selected() or {}
  if #items == 0 then
    for _, entry in ipairs(picker.matches) do
      items[#items + 1] = entry.item
    end
  end
  for _, item in ipairs(items) do
    local ok, err = valid(s, item)
    if not ok or item.data.unresolved or item.column_unknown then
      vim.notify(
        err or "Confirm this symbol to resolve its location before exporting",
        vim.log.levels.WARN
      )
      return
    end
  end
  require("selection_tools.actions").export(picker, loclist, all)
end

function M.open(kind, opts)
  opts = vim.tbl_deep_extend("force", {}, config, opts or {})
  local definition = methods[kind]
  assert(definition or kind == "diagnostics", "Unknown LSP picker")
  local s = {
    kind = kind,
    opts = opts,
    origin = request.context(),
    tokens = {},
    method = definition and definition[2],
    locations = definition and kind ~= "symbols" and kind ~= "workspace_symbols",
  }
  local spec = vim.tbl_deep_extend("force", {}, opts.picker, {
    prompt = definition and definition[1]
      or "Diagnostics · " .. (opts.scope or "all") .. " (received)",
    history_key = "lsp-tools:" .. kind,
    resume = false,
    multi = false,
    live = kind == "workspace_symbols",
    query = opts.query or "",
    preview = {
      enabled = true,
      providers = vim.list_extend({
        function(ctx)
          if not ctx.item.data.unresolved then
            return false -- Let selection-tools preview the source at item.pos.
          end
          ctx.set_lines(
            { ctx.item.name, "", ctx.item.detail, "", "Confirm to resolve this symbol's location." },
            "text"
          )
          return true
        end,
      }, vim.deepcopy((opts.picker.preview or {}).providers or {})),
    },
    result_layout = opts.picker.result_layout or "grep",
    syntax = vim.tbl_deep_extend(
      "force",
      { enabled = s.locations == true },
      opts.picker.syntax or {}
    ),
    format_item = model.format,
    highlight_item = model.highlights,
    before_confirm = function(ctx)
      return confirm(s, ctx)
    end,
    on_choice = function(item)
      if item then
        if vim.fn.mode():sub(1, 1) == "i" then
          -- stopinsert takes effect after the confirmation mapping returns.
          -- Jump afterwards so leaving Insert mode cannot move the target cursor.
          vim.schedule(function()
            jump(s, item)
          end)
        else
          jump(s, item)
        end
      end
    end,
    on_close = function()
      cancel(s)
      if s.group then
        api.nvim_del_augroup_by_id(s.group)
      end
      if active == s then
        active = nil
      end
    end,
  })
  spec.actions = spec.actions or {}
  for _, mode in ipairs({ "split", "vsplit", "tab" }) do
    spec.actions[mode] = function(picker)
      s.mode = mode
      picker:confirm()
      s.mode = nil
    end
  end
  for _, name in ipairs({ "quickfix", "quickfix_all", "loclist", "loclist_all" }) do
    spec.actions[name] = function(picker)
      export(s, picker, name:match("^loclist") ~= nil, name:match("_all$") ~= nil)
    end
  end
  if kind == "diagnostics" then
    spec.items = model.diagnostics(opts, s.origin)
  else
    spec.finder = function(ctx)
      return find(s, ctx)
    end
  end
  s.picker = require("selection_tools").open(spec)
  active = s
  s.group = api.nvim_create_augroup("LspToolsPicker" .. s.picker.input_buf, { clear = true })
  api.nvim_create_autocmd(
    kind == "diagnostics" and { "DiagnosticChanged", "BufWipeout" }
      or { "TextChanged", "TextChangedI", "BufWipeout", "LspDetach" },
    {
      group = s.group,
      callback = function(ev)
        if kind == "diagnostics" then
          vim.schedule(function()
            if not s.picker.closed and origin_valid(s) then
              s.picker:set_items(model.diagnostics(opts, s.origin))
            end
          end)
        elseif ev.buf == s.origin.buf and not s.stale then
          s.stale = true
          cancel(s)
          s.picker:set_items({})
          if s.finder then
            s.finder.fail("Source changed or provider detached; reopen this picker")
          end
        end
      end,
    }
  )
  return s.picker
end

return M
