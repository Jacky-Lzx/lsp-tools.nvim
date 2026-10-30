vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api, results = vim.api, require("lsp-tools.results")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_name(buf, root .. "/preview.lua")
local code = { "-- unsaved context 😀", 'local value = "😀hello"', "return value" }
api.nvim_buf_set_lines(buf, 0, -1, false, code)
vim.bo[buf].filetype = "lua"
local tick = api.nvim_buf_get_changedtick(buf)
results.setup({ auto_preview = false })
local ft_events, reads, count = 0, 0, 0
api.nvim_create_autocmd("FileType", {
  pattern = { "lua", "python" },
  callback = function()
    ft_events = ft_events + 1
  end,
})
api.nvim_create_autocmd("BufReadPost", {
  callback = function()
    reads = reads + 1
  end,
})
local item = {
  id = "target",
  bufnr = buf,
  pos = { 2, 6 },
  end_pos = { 2, 11 },
  text = 'local false "diagnostic"',
  severity = 1,
}
local v = results.open({ item }, { focus = true })
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function preview()
  results.select(v, "target")
  results.preview(v)
  return v.preview
end
local function marks(p, name)
  return api.nvim_buf_get_extmarks(
    p.buf,
    api.nvim_create_namespace(name),
    0,
    -1,
    { details = true }
  )
end
local p = preview()
check(
  p.filetype == "lua" and p.highlight_backend == "treesitter",
  "loaded Lua uses Tree-sitter highlighting"
)
check(
  vim.bo[p.buf].filetype == "lsp-tools-results" and not vim.bo[p.buf].modifiable,
  "preview keeps its read-only widget filetype"
)
local keyword, str = false, false
for _, mark in ipairs(marks(p, "lsp-tools.results.preview.syntax")) do
  check(mark[2] >= p.code_start - 1, "syntax captures stay within the source excerpt")
  local hl = mark[4].hl_group
  keyword = keyword or hl:find("@keyword", 1, true) ~= nil
  str = str or hl:find("@string", 1, true) ~= nil
end
check(keyword and str, "actual Lua keyword and string captures are rendered")
local range, line, path, message
for _, mark in ipairs(marks(p, "lsp-tools.results.preview")) do
  local detail = mark[4]
  if detail.hl_group == "LspToolsResultsPreviewRange" then
    range = mark
  end
  if detail.line_hl_group == "LspToolsResultsPreviewLine" then
    line = mark
  end
  if detail.hl_group == "LspToolsResultsPreviewPath" then
    path = mark
  end
  if detail.hl_group == "DiagnosticError" then
    message = mark
  end
end
check(
  path and message and line,
  "path, diagnostic severity and target line have independent highlights"
)
local selected =
  api.nvim_buf_get_text(p.buf, range[2], range[3], range[4].end_row, range[4].end_col, {})
check(table.concat(selected, "\n") == "value", "target highlight uses exact UTF8 byte positions")
check(
  api.nvim_buf_get_changedtick(buf) == tick
    and vim.deep_equal(code, api.nvim_buf_get_lines(buf, 0, -1, false)),
  "syntax preview preserves unsaved source contents"
)
local old_buf = p.buf
local original = vim.treesitter.get_string_parser
vim.treesitter.get_string_parser = function()
  return nil
end
p = preview()
vim.treesitter.get_string_parser = original
check(
  not api.nvim_buf_is_valid(old_buf),
  "replacing a preview releases its old buffer and highlights"
)
check(p.highlight_backend == "syntax", "missing Tree-sitter parser falls back to native syntax")
local function syntax(row, col)
  return api.nvim_buf_call(p.buf, function()
    return vim.fn.synIDattr(vim.fn.synID(row, col, true), "name")
  end)
end
check(
  syntax(p.code_start + 1, 1):find("lua", 1, true),
  "fallback highlights actual Lua source keywords"
)
check(syntax(3, 1) == "", "fallback does not parse diagnostic text as Lua")
item.pos, item.end_pos = { 2, assert(code[2]:find("😀", 1, true)) - 1 }, nil
results.set_items(v, { item })
p = preview()
for _, mark in ipairs(marks(p, "lsp-tools.results.preview")) do
  if mark[4].hl_group == "LspToolsResultsPreviewRange" then
    range = mark
  end
end
check(range[4].end_col - range[3] == 4, "point locations highlight the full Unicode codepoint")
item.column_unknown = true
results.set_items(v, { item })
p = preview()
local ranges = 0
for _, mark in ipairs(marks(p, "lsp-tools.results.preview")) do
  if mark[4].hl_group == "LspToolsResultsPreviewRange" then
    ranges = ranges + 1
  end
end
check(
  ranges == 0 and api.nvim_buf_get_lines(p.buf, 0, 1, false)[1]:find(":?", 1, true),
  "unknown columns retain line focus without inventing a highlighted range"
)
item.column_unknown = nil
item.end_pos = { 500, 0 }
results.set_items(v, { item })
p = preview()
for _, mark in ipairs(marks(p, "lsp-tools.results.preview")) do
  if mark[4].hl_group == "LspToolsResultsPreviewRange" then
    range = mark
  end
end
check(range[4].end_col == #code[#code], "multiline ranges clip to the complete visible excerpt")
item.pos = { 50, 0 }
results.set_items(v, { item })
p = preview()
check(
  not p.target_row and not p.highlight_backend,
  "stale positions beyond the loaded buffer show a safe fallback"
)
local many = {}
for i = 1, 100 do
  many[i] = "local value" .. i .. " = " .. i
end
api.nvim_buf_set_lines(buf, 0, -1, false, many)
results.set_items(v, { { id = "target", bufnr = buf, pos = { 40, 6 }, text = "context" } })
v.preview_options = { before = 0, after = 0 }
p = preview()
check(
  p.source_first == 40 and api.nvim_buf_line_count(p.buf) == p.code_start,
  "preview context options bound the excerpt"
)
local number = api.nvim_eval_statusline(
  vim.wo[p.win].statuscolumn,
  { winid = p.win, use_statuscol_lnum = p.code_start }
).str
check(number:find("40", 1, true), "preview numbers use source-file lines")
api.nvim_set_current_win(v.win)
vim.fn.maparg("<LocalLeader>w", "n", false, true).callback()
check(api.nvim_get_current_win() == p.win, "focus action enters the preview")
vim.fn.maparg("<LocalLeader>+", "n", false, true).callback()
p = v.preview
check(
  p.source_first == 20 and api.nvim_get_current_win() == p.win,
  "context expansion retains preview focus"
)
vim.fn.maparg("<LocalLeader>s", "n", false, true).callback()
p = v.preview
check(
  api.nvim_win_get_config(p.win).relative == "" and api.nvim_get_current_win() == p.win,
  "side layout can be selected interactively"
)
vim.fn.maparg("<Esc>", "n", false, true).callback()
check(
  not v.preview and api.nvim_get_current_win() == v.win,
  "leaving preview restores the list and releases the preview"
)
local file = root .. "/disk.py"
vim.fn.writefile({ 'value = "disk"', "print(value)" }, file)
results.set_items(v, { { id = "target", filename = file, pos = { 2, 0 }, text = "disk result" } })
p = preview()
local disk_buf = vim.fn.bufnr(file)
check(
  p.filetype == "python" and p.highlight_backend,
  "unloaded files detect their language from the filename"
)
check(
  not api.nvim_buf_is_loaded(disk_buf) and reads == 0 and ft_events == 0,
  "preview starts no source-buffer read or language FileType hooks"
)
results.set_items(
  v,
  { { id = "target", filename = root .. "/missing.lua", pos = { 50, 0 }, text = "unavailable" } }
)
p = preview()
check(
  not p.highlight_backend and not p.target_row,
  "missing source retains the readable plain-text fallback"
)
results.close()
check(not api.nvim_buf_is_valid(p.buf), "closing the result view releases its preview")
vim.fn.delete(root, "rf")
print(("result preview: %d assertions passed"):format(count))
vim.cmd("qa!")
