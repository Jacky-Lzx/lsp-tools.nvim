vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api = vim.api
local tools = require("lsp-tools")
local breadcrumbs = require("lsp-tools.breadcrumbs")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function flush(ms)
  vim.wait(ms or 10, function()
    return false
  end, 1)
end
local calls, clients = {}, {}
local function client(id)
  local c = { id = id, name = "fixture" .. id, offset_encoding = "utf-16" }
  function c:request(method, params, callback, buf)
    check(method == "textDocument/documentSymbol", "only requests document symbols")
    calls[#calls + 1] = { callback = callback, buf = buf, client = self, params = params }
    return true, #calls
  end
  function c:cancel_request(id)
    calls[id].cancelled = true
  end
  function c:stop() end
  return c
end
local first, second = client(1), client(2)
clients = { second, first }
vim.lsp.get_clients = function()
  return vim.list_slice(clients)
end
vim.lsp.get_client_by_id = function(id)
  for _, c in ipairs(clients) do
    if c.id == id then
      return c
    end
  end
end
vim.lsp.buf_is_attached = function(_, id)
  return vim.lsp.get_client_by_id(id) ~= nil
end
local function range(a, b, c, d)
  return { start = { line = a, character = b }, ["end"] = { line = c, character = d } }
end
local symbols = {
  {
    name = "impl Circuit",
    kind = 19,
    range = range(0, 0, 5, 0),
    children = {
      { name = "next%{bad}\nname", kind = 6, range = range(1, 2, 3, 0) },
    },
  },
}
local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".rs")
api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  { "impl Circuit {", "😀fn next() {", "}", "tail", "}", "outside" }
)
local function setup(opts)
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = vim.tbl_extend("force", { debounce = 20, request_timeout = 100 }, opts or {}),
  })
end
local function reply(value)
  calls[#calls].callback(nil, value or symbols)
  flush()
end
local function text(target)
  return tools.breadcrumbs({ winid = target or win, icons = false, color = false })
end
setup({ winbar = true })
check(calls[1].client == first, "lowest eligible provider is selected")
check(text() == "", "pending request renders empty")
reply()
api.nvim_win_set_cursor(win, { 2, 4 })
check(text() == "impl Circuit › next%%{bad} name", "hierarchy, Unicode byte cursor and escaping")
check(#breadcrumbs.get(win) == 2, "public path is outer to inner")
local path = breadcrumbs.get(win)
path[1].name = "changed"
check(breadcrumbs.get(win)[1].name == "impl Circuit", "callers cannot mutate cached symbols")
local rendered = api.nvim_eval_statusline(
  vim.wo[win].winbar,
  { winid = win, use_winbar = true, highlights = true }
)
check(rendered.str:find("next%{bad} name", 1, true), "native winbar evaluates escaped names safely")
check(#rendered.highlights > 1, "native winbar has semantic highlights")
local requested = #calls
for row = 1, 6 do
  api.nvim_win_set_cursor(win, { row, 0 })
  api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
  text()
end
check(#calls == requested, "cursor movement and rendering never request symbols")
check(text() == "", "outside scopes clears the breadcrumb")
api.nvim_win_set_cursor(win, { 4, 0 })
check(text() == "impl Circuit", "end-exclusive child range returns to parent")
vim.cmd("vsplit")
local split = api.nvim_get_current_win()
api.nvim_win_set_cursor(split, { 2, 4 })
flush()
check(#calls == requested, "splits share one document request/cache")
check(
  text(split):find("next", 1, true) and text(win) == "impl Circuit",
  "each split uses its own cursor"
)
vim.g.statusline_winid = win
check(
  tools.breadcrumbs({ icons = false, color = false }) == "impl Circuit",
  "statusline target wins over focused window"
)
vim.g.statusline_winid = nil
vim.wo[split].winbar = "another provider"
breadcrumbs.disable()
check(vim.wo[win].winbar == "", "disable restores owned winbar")
check(vim.wo[split].winbar == "another provider", "disable preserves newer winbar owner")
check(text() == "", "disable clears cache")
vim.wo[split].winbar = ""
setup({ winbar = true })
reply()
breadcrumbs.disable()
check(
  vim.wo[split].winbar == "" and vim.wo[win].winbar == "",
  "disable restores inherited split winbars"
)
api.nvim_win_close(split, true)
api.nvim_set_current_win(win)
setup()
check(vim.wo[win].winbar == "", "component mode leaves winbar untouched")
reply()
api.nvim_buf_set_lines(buf, 3, 4, false, { "edited" })
check(text() == "", "changedtick hides stale scope before TextChanged")
api.nvim_exec_autocmds("TextChanged", { buffer = buf })
flush(30)
local stale = calls[#calls]
api.nvim_buf_set_lines(buf, 3, 4, false, { "edited again" })
api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
check(stale.cancelled, "edits cancel pending requests")
stale.callback(nil, symbols)
flush(30)
check(text() == "", "obsolete replies cannot restore stale scopes")
reply()
api.nvim_win_set_cursor(win, { 2, 4 })
check(text():find("next", 1, true), "latest reply repopulates path")
api.nvim_exec_autocmds("LspDetach", { buffer = buf, data = { client_id = 1 } })
clients = { second }
check(text() == "", "detach hides old provider immediately")
flush(30)
check(calls[#calls].client == second, "detach selects remaining provider")
reply()
api.nvim_exec_autocmds("TextChanged", { buffer = buf })
flush(30)
local timed = calls[#calls]
flush(110)
check(timed.cancelled and text() == "", "timeout cancels request and clears path")
timed.callback(nil, symbols)
flush()
check(text() == "", "late timeout result is ignored")
setup({ client_name = "missing" })
check(text() == "", "filtered/unsupported providers render empty")
setup({ client_name = second.name })
calls[#calls].callback({ message = "failed" })
flush()
check(text() == "", "server errors render empty")
setup()
local pending = calls[#calls]
api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".rs")
pending.callback(nil, symbols)
flush()
check(pending.cancelled and text() == "", "URI changes cancel and reject old reply")
flush(30)
reply({
  {
    name = "flat",
    kind = 12,
    location = { uri = vim.uri_from_bufnr(buf), range = range(1, 0, 3, 0) },
    containerName = "invented",
  },
})
check(text() == "flat", "flat SymbolInformation does not invent parent path")
setup({ mode = "auto", icons = { Namespace = "§" } })
vim.bo[buf].filetype = "tex"
reply({
  {
    name = "Alpha",
    detail = "section",
    kind = 3,
    range = range(0, 0, 5, 0),
    children = {
      { name = "macro", kind = 12, range = range(1, 0, 3, 0) },
    },
  },
})
check(text() == "Alpha", "auto mode follows enclosing LaTeX sections")
check(
  tools.breadcrumbs({ winid = win }):find("§ Alpha", 1, true),
  "icons accept partial string overrides"
)
local float =
  api.nvim_open_win(buf, false, { relative = "editor", row = 2, col = 2, width = 20, height = 3 })
check(text(float) == "", "floating windows have no breadcrumbs")
api.nvim_win_close(float, true)
vim.bo[buf].buftype = "nofile"
check(text() == "", "special buffers have no breadcrumbs")
vim.bo[buf].buftype = ""
setup()
pending = calls[#calls]
tools.setup({
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
})
pending.callback(nil, symbols)
flush(30)
check(pending.cancelled and text() == "", "disable cancels work and rejects late replies")
setup()
pending = calls[#calls]
vim.cmd("enew!")
flush()
check(pending.cancelled, "hiding the last source window cancels its document request")
pending.callback(nil, symbols)
flush()
api.nvim_win_set_buf(win, buf)
flush()
check(calls[#calls] ~= pending, "returning to a hidden document requests a fresh snapshot")
reply(symbols)
api.nvim_win_set_cursor(win, { 2, 4 })
check(text():find("next", 1, true), "a late hidden-buffer reply does not corrupt the new cache")
check(not pcall(setup, { request_timeout = 0 }), "invalid timeout rejected")
check(not pcall(setup, { mode = "bad" }), "invalid mode rejected")
print(("lsp-tools breadcrumbs: %d assertions passed"):format(count))
vim.cmd("qa!")
