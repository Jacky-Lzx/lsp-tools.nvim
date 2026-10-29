vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api = vim.api
local model = require("lsp-tools.outline.model")
local tools = require("lsp-tools")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function flush()
  vim.wait(10, function()
    return false
  end, 1)
end
local function range(row, col, last, finish)
  return { start = { line = row, character = col }, ["end"] = { line = last, character = finish } }
end
local uri = "file:///outline.tex"
local symbols = {
  {
    name = "Chapter",
    detail = "section",
    kind = 3,
    range = range(0, 0, 4, 0),
    selectionRange = range(0, 2, 0, 5),
    children = {
      { name = "macro", kind = 12, range = range(1, 0, 1, 3) },
      { name = "Child", detail = "subsection", kind = 3, range = range(2, 0, 4, 0) },
    },
  },
}
local lines = { "😀abc", "foo", "child", "tail" }
local roots = model.normalize(symbols, lines, "utf-16", uri)
check(roots[1].position[2] == 4, "selectionRange converts UTF-16 emoji to byte column")
check(#model.rows(roots, {}, false) == 3, "nested all-symbol tree")
check(#model.rows(roots, {}, true) == 2, "section filter excludes macros")
check(model.current(roots, { 3, 0 }, true).name == "Child", "deepest enclosing section")
check(model.current(roots, { 5, 0 }, true) == nil, "end-exclusive range")
local utf32 = vim.deepcopy(symbols)
utf32[1].selectionRange = range(0, 1, 0, 3)
check(
  model.normalize(utf32, lines, "utf-32", uri)[1].position[2] == 4,
  "UTF-32 positions use code points"
)
local utf8 = vim.deepcopy(symbols)
utf8[1].selectionRange = range(0, 4, 0, 7)
check(model.normalize(utf8, lines, "utf-8", uri)[1].position[2] == 4, "UTF-8 positions use bytes")
local moved = vim.deepcopy(symbols)
moved[1].selectionRange = range(0, 3, 0, 5)
check(
  model.normalize(moved, lines, "utf-16", uri)[1].key == roots[1].key,
  "fold keys survive movement"
)
local flat = model.normalize({
  { name = "a", kind = 3, location = { uri = uri, range = range(0, 0, 0, 2) } },
  {
    name = "b",
    kind = 12,
    containerName = "a",
    location = { uri = uri, range = range(1, 0, 1, 3) },
  },
  { name = "foreign", kind = 12, location = { uri = "file:///other", range = range(1, 0, 1, 3) } },
}, lines, "utf-16", uri)
check(
  #flat == 2 and not flat[2].parent,
  "SymbolInformation stays flat and foreign locations excluded"
)
check(
  #model.normalize({ { name = "invalid", range = range(99, 0, 100, 0) } }, lines, "utf-16", uri)
    == 0,
  "invalid positions are skipped"
)
local calls, clients = {}, {}
local c = { id = 1, name = "fixture", offset_encoding = "utf-16" }
function c:request(method, params, callback)
  calls[#calls + 1] = { callback = callback, params = params, method = method }
  return true, #calls
end
function c:cancel_request(id)
  calls[id].cancelled = true
end
clients = { c }
vim.lsp.get_clients = function()
  return clients
end
vim.lsp.get_client_by_id = function(id)
  return id == 1 and clients[1]
end
function c:stop() end
vim.lsp.buf_is_attached = function()
  return #clients > 0
end
local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".tex")
api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.bo[buf].filetype = "tex"
tools.setup({
  breadcrumbs = false,
  code_actions = false,
  references = false,
  rename = false,
  outline = {
    debounce = 20,
    request_timeout = 70,
    icons = { Key = { icon = "󰌆", hl = "Type" } },
  },
})
local outwin = tools.open_outline()
local out = api.nvim_win_get_buf(outwin)
check(api.nvim_get_current_win() == win, "opening keeps source focus")
check(vim.bo[out].filetype == "lsp-tools-outline" and not vim.bo[out].modifiable, "scratch sidebar")
check(calls[1].method == "textDocument/documentSymbol", "requests document symbols")
calls[1].callback(nil, symbols)
flush()
check(api.nvim_buf_line_count(out) == 2, "LaTeX defaults to sections")
check(not vim.wo[outwin].winbar:find("Invalid"), "successful result has no error status")
check(api.nvim_buf_get_lines(out, 0, 1, false)[1]:find("Chapter"), "renders names")
check(
  api.nvim_buf_get_lines(out, 0, 1, false)[1]:find("󰅪 Chapter", 1, true),
  "LaTeX namespaces use default icons even with partial icon overrides"
)
local function name_highlight(row, name, group)
  local line = api.nvim_buf_get_lines(out, row, row + 1, false)[1]
  local first, last = line:find(name, 1, true)
  for _, mark in
    ipairs(
      api.nvim_buf_get_extmarks(
        out,
        api.nvim_create_namespace("lsp-tools.outline"),
        { row, 0 },
        { row, -1 },
        { details = true }
      )
    )
  do
    if mark[3] <= first - 1 and mark[4].end_col == last and mark[4].hl_group == group then
      return true
    end
  end
end
check(
  name_highlight(0, "Chapter", "Include"),
  "chapter name receives Namespace color without coloring its detail"
)
local function feed(keys)
  api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  flush()
end
api.nvim_set_current_win(outwin)
feed("m")
check(api.nvim_buf_line_count(out) == 3, "toggle all symbols")
check(name_highlight(1, "macro", "Function"), "function names receive their own semantic color")
feed("za")
check(api.nvim_buf_line_count(out) == 1, "fold parent")
feed("zR")
check(api.nvim_buf_line_count(out) == 3, "expand all")
api.nvim_win_set_cursor(outwin, { 3, 0 })
feed("<CR>")
check(
  api.nvim_get_current_win() == win and api.nvim_win_get_cursor(win)[1] == 3,
  "Enter jumps to source"
)
local requests = #calls
api.nvim_win_set_cursor(win, { 4, 0 })
api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
check(#calls == requests, "cursor movement never requests symbols")
local marks =
  api.nvim_buf_get_extmarks(out, api.nvim_create_namespace("lsp-tools.outline.current"), 0, -1, {})
check(#marks == 1 and marks[1][2] == 2, "highlights enclosing symbol")
api.nvim_set_current_win(outwin)
api.nvim_win_set_cursor(outwin, { 1, 0 })
feed("za")
feed("r")
calls[#calls].callback(nil, symbols)
flush()
check(api.nvim_buf_line_count(out) == 1, "manual folds survive refresh")
feed("zR")
feed("r")
local stale = calls[#calls]
api.nvim_buf_set_lines(buf, 3, 4, false, { "edited" })
stale.callback(nil, { { name = "STALE", kind = 12, range = range(0, 0, 0, 2) } })
flush()
check(
  not table.concat(api.nvim_buf_get_lines(out, 0, -1, false)):find("STALE"),
  "changedtick rejects old response"
)
local old_cursor = api.nvim_win_get_cursor(win)
feed("<CR>")
check(
  api.nvim_get_current_win() == outwin and vim.deep_equal(old_cursor, api.nvim_win_get_cursor(win)),
  "stale tree cannot jump"
)
calls[#calls].callback(nil, symbols)
flush()
-- Switch sources with an old request in flight.
feed("r")
local obsolete = calls[#calls]
api.nvim_set_current_win(win)
vim.cmd("enew!")
local other = api.nvim_get_current_buf()
api.nvim_buf_set_name(other, vim.fn.tempname() .. ".lua")
api.nvim_buf_set_lines(other, 0, -1, false, { "function f() end" })
api.nvim_exec_autocmds("BufEnter", { buffer = other })
obsolete.callback(nil, symbols)
vim.wait(40, function()
  return false
end, 1)
local last = calls[#calls]
last.callback(nil, { { name = "f", kind = 12, range = range(0, 0, 0, 16) } })
flush()
check(api.nvim_buf_get_lines(out, 0, 1, false)[1]:find("f"), "new source wins over old result")
api.nvim_set_current_win(outwin)
feed("r")
check(
  vim.wait(200, function()
    return vim.wo[outwin].winbar:find("timed out") ~= nil
  end, 5),
  "request timeout is visible"
)
check(calls[#calls].cancelled, "timeout cancels request")
feed("r")
local late = calls[#calls]
tools.close_outline()
late.callback(nil, symbols)
flush()
check(not api.nvim_win_is_valid(outwin), "late reply after close does not reopen sidebar")
clients = {}
local unsupported = tools.open_outline()
check(
  vim.wo[unsupported].winbar:find("No documentSymbol provider"),
  "unsupported server explains missing capability"
)
api.nvim_win_close(unsupported, true)
flush()
check(tools.open_outline(), "external close allows reopening")
tools.close_outline()
clients = { c }
local first_tab = api.nvim_get_current_tabpage()
local first_source = api.nvim_get_current_win()
local first = tools.open_outline()
calls[#calls].callback(nil, { { name = "first", kind = 12, range = range(0, 0, 0, 5) } })
flush()
vim.cmd("tabnew")
api.nvim_buf_set_name(0, vim.fn.tempname() .. ".lua")
api.nvim_buf_set_lines(0, 0, -1, false, { "second" })
local second = tools.open_outline()
calls[#calls].callback(nil, { { name = "second", kind = 12, range = range(0, 0, 0, 6) } })
flush()
check(first ~= second and api.nvim_win_is_valid(first), "each tab owns a separate sidebar")
tools.close_outline()
check(api.nvim_win_is_valid(first), "closing another tab sidebar preserves first tab")
vim.cmd("tabclose!")
api.nvim_set_current_tabpage(first_tab)
check(
  api.nvim_buf_get_lines(api.nvim_win_get_buf(first), 0, 1, false)[1]:find("first"),
  "tab retains its own tree"
)
-- Enter can recover a source window which was closed while the sidebar remained.
api.nvim_set_current_win(first)
api.nvim_win_close(first_source, true)
feed("<CR>")
check(
  api.nvim_get_current_win() ~= first and api.nvim_win_get_buf(0) == other,
  "jump recreates closed source window"
)
local recovered = api.nvim_get_current_win()
api.nvim_set_current_win(first)
api.nvim_win_close(recovered, true)
feed("q")
check(vim.bo.filetype ~= "lsp-tools-outline", "closing the last sidebar restores a normal buffer")
check(
  not api.nvim_buf_is_valid(api.nvim_win_get_buf(first)) or api.nvim_win_get_buf(first) == other,
  "last-window close preserves source buffer"
)
tools.setup({
  breadcrumbs = false,
  code_actions = false,
  references = false,
  rename = false,
  outline = { icons = { Namespace = "§" } },
})
local custom = tools.open_outline()
calls[#calls].callback(nil, { { name = "custom", kind = 3, range = range(0, 0, 0, 5) } })
flush()
check(
  api.nvim_buf_get_lines(api.nvim_win_get_buf(custom), 0, 1, false)[1]:find("§ custom", 1, true),
  "a user icon override replaces the default"
)
tools.setup({
  breadcrumbs = false,
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
})
check(not tools.open_outline(), "disabled outline stays closed")
print(("lsp-tools outline: %d assertions passed"):format(count))
vim.cmd("qa!")
