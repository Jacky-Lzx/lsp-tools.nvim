vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
tools.setup({
  results = { auto_preview = false },
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local api, buf = vim.api, vim.api.nvim_get_current_buf()
api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo bar", "tail" })
api.nvim_win_set_cursor(0, { 1, 4 })
local other = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(other, vim.fn.tempname() .. "-other.lua")
api.nvim_buf_set_lines(other, 0, -1, false, { "foo" })
local count, calls = 0, {}
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function client(id, encoding)
  local c = { id = id, name = "server" .. id, offset_encoding = encoding }
  function c:request(method, params, callback)
    calls[#calls + 1] = { method = method, params = params, callback = callback }
    return true, #calls
  end
  function c:cancel_request(id)
    calls[id].cancelled = true
  end
  return c
end
local one, two = client(1, "utf-16"), client(2, "utf-8")
local original = vim.lsp.get_clients
vim.lsp.get_clients = function(opts)
  return opts.method == "textDocument/definition" and { one } or { one, two }
end
local function loc(target, first, last)
  return {
    uri = vim.uri_from_bufnr(target),
    range = { start = { line = 0, character = first }, ["end"] = { line = 0, character = last } },
  }
end
local results = require("lsp-tools.results")
local v = tools.locations({ method = "references", include_declaration = false })
check(
  calls[1].params.position.character == 2 and calls[2].params.position.character == 4,
  "request encodings differ by provider"
)
check(not calls[1].params.context.includeDeclaration, "reference declaration option preserved")
calls[1].callback(nil, { loc(buf, 2, 5), loc(other, 0, 3) })
calls[2].callback(nil, { loc(buf, 4, 7) })
check(#v.items == 2, "workspace references deduplicate encoded ranges across clients")
local first
for _, item in ipairs(v.items) do
  if item.bufnr == buf then
    first = item
  end
end
check(
  first.pos[2] == 4 and #first.data.client_ids == 2,
  "byte positions and provider provenance retained"
)
results.select(v, first.id)
api.nvim_set_current_win(v.win)
check(
  results.jump(v) and api.nvim_win_get_cursor(0)[2] == 4,
  "native source jump uses provider encoding"
)
results.close("lsp")
v = tools.locations({ method = "definitions" })
local call = calls[#calls]
call.callback(nil, {
  targetUri = vim.uri_from_bufnr(buf),
  targetRange = loc(buf, 0, 9).range,
  targetSelectionRange = loc(buf, 2, 5).range,
})
check(#v.items == 1 and v.items[1].pos[2] == 4, "single LocationLink uses target selection range")
results.refresh(v)
call = calls[#calls]
api.nvim_win_set_cursor(v.ctx.win, { 2, 0 })
call.callback(nil, loc(buf, 2, 5))
check(
  v.stale and v.status:find("Source position changed", 1, true),
  "late replies reject changed cursor context"
)
api.nvim_win_set_cursor(v.ctx.win, { 1, 4 })
results.refresh(v)
call = calls[#calls]
results.close("lsp")
check(call.cancelled, "closing cancels pending location queries")
vim.lsp.get_clients = original
print(("LSP location results: %d assertions passed"):format(count))
vim.cmd("qa!")
