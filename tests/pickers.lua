vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api, tools = vim.api, require("lsp-tools")
local count, calls, notices, notice_levels = 0, {}, {}, {}
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function wait(fn, message)
  check(
    vim.wait(1500, function()
      local implementation = package.loaded["lsp-tools.pickers"]
      local current = implementation and implementation.current()
      return fn() and not (current and current.syntax_pending)
    end, 1),
    message
  )
end
local function flush()
  vim.wait(20, function()
    return false
  end, 1)
end
vim.notify = function(message, level)
  notices[#notices + 1] = tostring(message)
  notice_levels[#notices] = level
end
tools.setup({
  pickers = { debounce = 1, jump_single = false },
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
})
check(not package.loaded["lsp-tools.pickers"], "picker implementation remains deferred after setup")
local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(buf, vim.fn.tempname() .. "-source.lua")
api.nvim_buf_set_lines(buf, 0, -1, false, { "😀alpha", "beta", "gamma" })
api.nvim_win_set_cursor(win, { 3, 0 })
local function client(id, encoding)
  local c = { id = id, name = "server" .. id, offset_encoding = encoding }
  function c:request(method, params, cb)
    calls[#calls + 1] = { method = method, params = params, callback = cb, client = self }
    return true, #calls
  end
  function c:cancel_request(id)
    calls[id].cancelled = true
  end
  function c:stop() end
  return c
end
local one, two = client(1, "utf-16"), client(2, "utf-8")
local clients = { one, two }
local client_filter
vim.lsp.get_clients = function(filter)
  client_filter = filter
  return clients
end
local methods = {
  definitions = "textDocument/definition",
  declarations = "textDocument/declaration",
  references = "textDocument/references",
  implementations = "textDocument/implementation",
  type_definitions = "textDocument/typeDefinition",
  symbols = "textDocument/documentSymbol",
  workspace_symbols = "workspace/symbol",
}
clients = {}
for kind, method in pairs(methods) do
  local windows, buffers, before = api.nvim_list_wins(), api.nvim_list_bufs(), #notices
  check(tools["lsp_" .. kind]() == false, kind .. " rejects a missing provider")
  check(#notices == before + 1 and notices[#notices]:find(method, 1, true), kind .. " warns")
  check(notice_levels[#notices] == vim.log.levels.WARN, kind .. " uses warning severity")
  check(client_filter.bufnr == buf and client_filter.method == method, kind .. " checks capability")
  check(vim.deep_equal(windows, api.nvim_list_wins()), kind .. " opens no windows")
  check(vim.deep_equal(buffers, api.nvim_list_bufs()), kind .. " allocates no picker buffers")
  check(api.nvim_get_current_win() == win, kind .. " preserves source focus")
end
check(not package.loaded.selection_tools, "unavailable LSP pickers do not load selection-tools")
check(#calls == 0, "unavailable LSP pickers send no requests")
local all_clients = vim.lsp.get_clients
vim.lsp.get_clients = function(filter)
  return filter.method and {} or { one }
end
check(
  #vim.lsp.get_clients({ bufnr = buf }) == 1,
  "unsupported-method fixture has an attached client"
)
check(tools.lsp_definitions() == false, "an attached client without the capability cannot open UI")
vim.lsp.get_clients = all_clients
clients = { one, two }
local function loc(row, first, last)
  return {
    uri = vim.uri_from_bufnr(buf),
    range = {
      start = { line = row, character = first },
      ["end"] = { line = row, character = last },
    },
  }
end
local function opened(kind, opts)
  local before = #calls
  local p = tools["lsp_" .. kind](opts)
  wait(function()
    return #calls == before + #clients
  end, kind .. " requests every provider")
  return p, calls[before + 1], calls[before + 2]
end
local p, a, b = opened("references", { include_declaration = false })
check(not a.params.context.includeDeclaration, "reference declaration option reaches server")
a.callback(nil, { loc(0, 2, 7), loc(1, 0, 4) })
b.callback(nil, { loc(0, 4, 9) })
wait(function()
  return not p.loading
end, "references finish")
check(#p.entries == 2, "references deduplicate across UTF encodings")
check(
  p.entries[1].item.pos[2] == 4 and #p.entries[1].item.data.client_ids == 2,
  "byte columns and provider provenance survive deduplication"
)
check(
  p.opts.result_layout == "grep" and p.opts.syntax.enabled,
  "location rows share grep's columns and source syntax"
)
p:confirm()
check(
  p.closed and api.nvim_get_current_win() == win and api.nvim_win_get_cursor(win)[2] == 4,
  "confirmation jumps with original provider encoding"
)
check(#vim.fn.gettagstack(win).items > 0, "LSP navigation preserves tagstack")

clients = { one }
for _, kind in ipairs({ "definitions", "declarations", "implementations", "type_definitions" }) do
  api.nvim_win_set_cursor(win, { 3, 0 })
  p, a = opened(kind)
  a.callback(nil, {
    targetUri = vim.uri_from_bufnr(buf),
    targetRange = loc(0, 0, 7).range,
    targetSelectionRange = loc(0, 2, 7).range,
  })
  wait(function()
    return #p.entries == 1
  end, kind .. " accepts LocationLink")
  check(p.entries[1].item.pos[2] == 4, kind .. " uses target selection range")
  p:close()
end
api.nvim_win_set_cursor(win, { 3, 0 })
p, a = opened("definitions", { jump_single = true })
a.callback(nil, loc(0, 2, 7))
wait(function()
  return p.closed
end, "a unique location jumps directly")
check(api.nvim_win_get_cursor(win)[2] == 4, "automatic jump uses byte column")
p, a = opened("references")
a.callback(nil, { loc(0, 2, 7), loc(1, 0, 4) })
wait(function()
  return not p.loading
end, "current location filter finishes")
check(#p.entries == 1 and p.entries[1].item.pos[1] == 2, "current reference is excluded by default")
p:close()

api.nvim_win_set_cursor(win, { 3, 0 })
p, a = opened("definitions")
api.nvim_win_set_cursor(win, { 2, 0 })
a.callback(nil, loc(0, 2, 7))
wait(function()
  return p.error ~= nil
end, "late response rejects source cursor changes")
check(#p.entries == 0, "stale response cannot populate picker")
p:close()
p, a = opened("references")
p:close()
check(a.cancelled, "closing a picker cancels pending request")
a.callback(nil, { loc(0, 2, 7) })
flush()
check(p.closed and #p.entries == 0, "late response cannot reopen a closed picker")

p, a = opened("symbols")
a.callback(nil, {
  {
    name = "parent",
    kind = 12,
    range = loc(0, 2, 7).range,
    selectionRange = loc(0, 2, 7).range,
    children = {
      {
        name = "child",
        kind = 13,
        range = loc(1, 0, 4).range,
        selectionRange = loc(1, 0, 4).range,
      },
    },
  },
})
wait(function()
  return not p.loading
end, "hierarchical symbols finish")
check(
  #p.entries == 2 and p.entries[2].item.depth == 1,
  "nested document symbols retain their depth"
)
local symbol_line = api.nvim_buf_get_lines(p.list_buf, 0, 1, false)[1]
check(symbol_line:match("^parent %[%w+%]"), "symbol content precedes file metadata")
check(vim.fn.strwidth(symbol_line) == p.resolved.width, "symbol file metadata is right aligned")
local semantic = false
for _, mark in ipairs(api.nvim_buf_get_extmarks(p.list_buf, -1, 0, -1, { details = true })) do
  if mark[4].hl_group == "Function" then
    semantic = true
  end
end
check(semantic, "symbol names use their kind's semantic color")
check(p.entries[2].item.display_code:sub(1, 2) == "  ", "nested symbols preserve left indentation")
p:set_query("child")
check(#p.matches == 1 and p:current().name == "child", "document symbols are searchable")
p:confirm()
check(p.closed and api.nvim_win_get_cursor(win)[1] == 2, "document symbol confirmation jumps")

p, a = opened("symbols")
a.callback(nil, { { name = "flat", kind = 12, location = loc(0, 2, 7), containerName = "module" } })
wait(function()
  return not p.loading
end, "SymbolInformation finishes")
check(p:current().name == "flat", "flat SymbolInformation is accepted")
p:close()

p, a = opened("workspace_symbols")
p:set_query("new")
wait(function()
  return #calls > 0 and calls[#calls].params.query == "new"
end, "workspace query reaches server")
local latest = calls[#calls]
check(a.cancelled, "typing cancels obsolete workspace query")
a.callback(nil, { { name = "obsolete", kind = 12, location = loc(0, 2, 7) } })
latest.callback(nil, { { name = "new_symbol", kind = 12, location = loc(1, 0, 4) } })
wait(function()
  return not p.loading and #p.entries == 1
end, "latest workspace result arrives")
check(p:current().name == "new_symbol", "obsolete workspace result cannot replace latest query")
p:close()

p, a = opened("workspace_symbols")
a.callback(nil, {
  {
    name = "lazy_symbol",
    kind = 12,
    location = { uri = vim.uri_from_bufnr(buf) },
    data = { id = 7 },
  },
})
wait(function()
  return not p.loading
end, "unresolved workspace symbols finish")
p.opts.actions.vsplit(p)
latest = calls[#calls]
check(
  latest.method == "workspaceSymbol/resolve" and latest.params.data.id == 7,
  "URI-only workspace symbols resolve with original server data"
)
latest.callback(nil, { name = "lazy_symbol", kind = 12, location = loc(0, 2, 7) })
check(
  p.closed and #api.nvim_list_wins() == 2 and api.nvim_get_current_win() ~= win,
  "asynchronous resolution preserves split destination"
)
check(api.nvim_win_get_cursor(0)[2] == 4, "resolved symbol jumps with UTF encoding")
vim.cmd("close")
api.nvim_set_current_win(win)

p, a = opened("workspace_symbols")
a.callback(nil, { { name = "lazy", kind = 12, location = { uri = vim.uri_from_bufnr(buf) } } })
wait(function()
  return not p.loading
end, "second unresolved symbol arrives")
p:confirm()
latest = calls[#calls]
local before_cancel = api.nvim_win_get_cursor(win)
p:close()
check(latest.cancelled, "closing cancels pending workspace symbol resolution")
latest.callback(nil, { name = "lazy", kind = 12, location = loc(1, 0, 4) })
check(
  vim.deep_equal(api.nvim_win_get_cursor(win), before_cancel),
  "late resolve cannot jump after cancellation"
)

clients = { one, two }
p, a, b = opened("workspace_symbols")
for _, call in ipairs({ a, b }) do
  call.callback(nil, {
    {
      name = "shared",
      kind = 12,
      location = { uri = vim.uri_from_bufnr(buf) },
      data = { owner = call.client.id },
    },
  })
end
wait(function()
  return not p.loading
end, "multi-provider unresolved symbols arrive")
check(#p.entries == 2, "server-specific workspace resolve data is never merged across providers")
p:close()

clients = { one }
api.nvim_win_set_cursor(win, { 3, 0 })
p, a = opened("references")
api.nvim_exec_autocmds("LspDetach", { buffer = buf, data = { client_id = one.id } })
wait(function()
  return not p.loading and p.error ~= nil
end, "detach ends loading with an explanatory error")
check(a.cancelled, "detach cancels pending location requests")
p:close()

local target = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(target, vim.fn.tempname() .. "-target.lua")
api.nvim_buf_set_lines(target, 0, -1, false, { "target" })
p, a = opened("references")
a.callback(nil, { { uri = vim.uri_from_bufnr(target), range = loc(0, 0, 4).range } })
wait(function()
  return not p.loading
end, "separate target result arrives")
api.nvim_buf_set_lines(target, 0, -1, false, { "changed target" })
p.opts.actions.vsplit(p)
check(
  not p.closed and #api.nvim_list_wins() > 1,
  "stale target split is rejected while picker stays open"
)
p:close()
check(#api.nvim_list_wins() == 1, "rejected target split leaves no extra destination")

clients = { one, two }
api.nvim_win_set_cursor(win, { 3, 0 })
p, a, b = opened("references")
a.callback({ message = "one server failed" })
b.callback(nil, { loc(0, 4, 9) })
wait(function()
  return not p.loading
end, "partial provider failure finishes")
check(
  #p.entries == 1 and notices[#notices]:find("one server failed", 1, true),
  "partial provider failure retains valid results and reports error"
)
api.nvim_buf_set_lines(buf, 0, 1, false, { "edited source" })
p:confirm()
check(not p.closed, "changed source cannot confirm a stale result")
p:close()
clients = { one }
p, a = opened("references", { request_timeout = 10 })
wait(function()
  return p.error ~= nil
end, "request timeout is reported")
check(a.cancelled, "request timeout cancels transport")
p:close()

local other = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(other, vim.fn.tempname() .. "-other.lua")
api.nvim_buf_set_lines(other, 0, -1, false, { "other" })
local ns, lint =
  api.nvim_create_namespace("picker-server"), api.nvim_create_namespace("picker-lint")
vim.diagnostic.config({ virtual_text = false, signs = false, underline = false })
vim.diagnostic.set(
  ns,
  buf,
  { { lnum = 0, col = 0, message = "source error", severity = 1, source = "server" } }
)
vim.diagnostic.set(
  lint,
  buf,
  { { lnum = 1, col = 0, message = "lint warning", severity = 2, source = "lint" } }
)
vim.diagnostic.set(ns, other, { { lnum = 0, col = 0, message = "other error", severity = 1 } })
clients = {}
p = tools.pick_diagnostics()
check(
  #p.entries == 3 and p.entries[1].item.severity == 1,
  "global diagnostics include every producer sorted by severity"
)
p:close()
p = tools.pick_diagnostics({ scope = "buffer", namespace = lint })
check(#p.entries == 1 and p:current().source == "lint", "buffer and namespace filters are honored")
vim.diagnostic.set(
  lint,
  buf,
  { { lnum = 1, col = 0, message = "updated warning", severity = 2, source = "lint" } }
)
wait(function()
  return p:current() and p:current().text == "updated warning"
end, "diagnostic changes refresh open picker")
p:confirm()
check(p.closed and api.nvim_win_get_cursor(win)[1] == 2, "diagnostic selection jumps to source")
p = tools.pick_diagnostics({ scope = "buffer" })
vim.diagnostic.reset(ns, buf)
p:confirm()
check(not p.closed, "removed diagnostic cannot confirm before refresh")
wait(function()
  return #p.entries == 1
end, "removed diagnostics disappear from picker")
p.opts.actions.quickfix(p)
check(
  p.closed and #vim.fn.getqflist() == 1 and vim.fn.getqflist()[1].lnum == 2,
  "filtered diagnostics export to native quickfix"
)
vim.cmd("cclose")
api.nvim_set_current_win(win)
clients = { one }
p, a = opened("references")
tools.setup({ pickers = false })
check(
  p.closed and a.cancelled and not tools.lsp_references(),
  "disabling pickers closes UI and cancels pending requests"
)
check(
  not package.loaded.snacks and not package.loaded["snacks.picker"],
  "LSP pickers require no Snacks"
)
print(("LSP selection pickers: %d assertions passed"):format(count))
vim.cmd("qa!")
