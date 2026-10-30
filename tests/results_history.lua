vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools, api = require("lsp-tools"), vim.api
tools.setup({
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
  results = { auto_preview = false, history = 3 },
})
local results, history = require("lsp-tools.results"), require("lsp-tools.results.history")
local source, owner = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
api.nvim_buf_set_lines(source, 0, -1, false, { "😀foo", "second" })
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local target = { bufnr = source, pos = { 1, 4 }, text = "first" }
local v = tools.results(
  { target, { bufnr = source, pos = { 2, 0 }, text = "second" } },
  { id = "generic" }
)
results.filter(v, { text = "second" })
results.close("generic")
local id = history.list()[1].id
v = history.restore(results, id, { focus = true })
check(
  v.pinned and v.filter.text == "second" and results.selected(v).text == "second",
  "history restores filter, selection and pinned state"
)
v = history.restore(results, id, { focus = true })
check(
  api.nvim_win_is_valid(v.win) and v.ctx.win == owner,
  "history can replace its currently focused panel"
)
check(results.jump(v, true), "unchanged snapshot can jump")
api.nvim_buf_set_lines(source, 0, 1, false, { "changed" })
local windows = #api.nvim_list_wins()
check(
  not results.jump(v, false, "tab") and #api.nvim_list_wins() == windows,
  "changed historical positions cannot open a destination"
)
results.close("generic")
api.nvim_set_current_win(owner)
local calls = {}
local client = { id = 17, name = "fixture", offset_encoding = "utf-16" }
function client:request(method, params, callback)
  calls[#calls + 1] = { params = params, callback = callback }
  return true, #calls
end
function client:cancel_request(request)
  calls[request].cancelled = true
end
vim.lsp.get_clients = function()
  return { client }
end
api.nvim_win_set_cursor(owner, { 2, 0 })
v = tools.locations({ method = "references" })
calls[#calls].callback(nil, {
  uri = vim.uri_from_bufnr(source),
  range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 3 } },
})
id = history.list()[1].id
results.close("lsp")
api.nvim_win_set_cursor(owner, { 1, 0 })
v = history.restore(results, id, { focus = true })
check(v.query.pos[1] == 2 and #calls == 1, "restoring LSP history does not issue a request")
check(results.jump(v, true), "LSP snapshot preserves native validation and encoding")
api.nvim_buf_set_lines(source, 1, -1, false, { "changed target" })
check(not results.jump(v), "history rejects source edits")
results.refresh(v)
check(
  #calls == 2 and calls[2].params.position.line == 1 and not v.pinned,
  "explicit refresh reruns recorded origin"
)
results.close("lsp")
check(calls[2].cancelled, "closing refreshed history cancels pending requests")
api.nvim_set_current_win(owner)
vim.fn.setqflist({}, " ", { items = { { bufnr = source, lnum = 2, text = "native" } } })
v = tools.quickfix()
id = history.list()[1].id
results.close("qflist")
vim.fn.setqflist({}, " ", { items = { { bufnr = source, lnum = 1, text = "replacement" } } })
v = history.restore(results, id, { focus = true })
check(
  v.items[1].text == "native" and not results.jump(v),
  "replaced canonical list cannot redirect an old snapshot"
)
results.refresh(v)
check(
  v.items[1].text == "replacement" and results.jump(v, true),
  "explicit refresh uses current native list"
)
results.close("qflist")
check(#history.list() <= 3, "history is bounded")
local selected = vim.ui.select
vim.ui.select = function(items, _, callback)
  callback(items[#items])
end
check(tools.results_history({ focus = true }), "public history entry point opens selected snapshot")
vim.ui.select = selected
for _, win in ipairs(api.nvim_list_wins()) do
  if vim.bo[api.nvim_win_get_buf(win)].filetype == "lsp-tools-results" then
    api.nvim_win_close(win, true)
  end
end
print(("result history: %d assertions passed"):format(count))
vim.cmd("qa!")
