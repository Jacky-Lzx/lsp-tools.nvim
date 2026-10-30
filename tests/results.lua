vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local results = require("lsp-tools.results")
local model = require("lsp-tools.results.model")
vim.o.columns, vim.o.lines = 160, 45
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo", "bar", "tail" })
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local items = {
  {
    id = "first",
    bufnr = buf,
    pos = { 1, 4 },
    text = "first\nfull message",
    source = "test",
    severity = 1,
    code = "E1",
  },
  { id = "second", bufnr = buf, pos = { 2, 0 }, text = "second", severity = 2 },
  { id = "third", filename = "/tmp/other.lua", pos = { 3, 0 }, text = "third", severity = 1 },
}
results.setup({ focus = false, auto_preview = false })
local v =
  results.open(items, { id = "fixture", title = "Fixture", group_by = { "file" }, focus = false })
check(vim.api.nvim_get_current_win() ~= v.win, "opening does not steal source focus")
check(#v.items == 3 and #v.rows == 5, "groups and counts include every location")
local function key(lhs)
  vim.api.nvim_set_current_win(v.win)
  vim.fn.maparg(lhs, "n", false, true).callback()
end
results.filter(v, { text = "second" })
check(#v.filtered == 1 and v.filtered[1].id == "second", "literal filtering")
results.filter(v, { text = "" })
key("e")
check(#v.filtered == 2, "error filter")
key("e")
check(#v.filtered == 3, "error filter toggles off")
local second_row
for row, entry in ipairs(v.rows) do
  if entry.item and entry.item.id == "second" then
    second_row = row + 3
  end
end
vim.api.nvim_win_set_cursor(v.win, { second_row, 0 })
results.set_items(v, { items[3], items[1], items[2] })
check(results.selected(v).id == "second", "updates preserve selected identity")
key("p")
check(v.preview and vim.api.nvim_win_is_valid(v.preview.win), "source preview opens")
local preview = table.concat(vim.api.nvim_buf_get_lines(v.preview.buf, 0, -1, false), "\n")
check(preview:find("bar", 1, true), "preview includes source text")
key("o")
check(
  vim.api.nvim_win_get_cursor(v.ctx.win)[1] == 2 and vim.api.nvim_get_current_win() == v.win,
  "jump can keep list focus"
)
results.export(v)
check(
  #vim.fn.getqflist() == 3 and vim.fn.getqflist()[2].col == 1,
  "export uses native quickfix positions"
)
local group_row
for i, row in ipairs(v.rows) do
  if row.key then
    group_row = i + 3
    break
  end
end
vim.api.nvim_win_set_cursor(v.win, { group_row, 0 })
key("za")
check(#v.rows < 5, "groups fold")
key("zR")
check(#v.rows == 5, "expand all restores nested groups")
results.close("fixture")
check(not vim.api.nvim_win_is_valid(v.win), "close releases list window")
v = results.open(nil, { id = "fixture" })
check(#v.items == 3, "snapshots can reopen")
local before = vim.api.nvim_buf_line_count(v.out)
vim.api.nvim_buf_delete(buf, { force = true })
check(
  vim.api.nvim_win_is_valid(v.win) and vim.api.nvim_buf_line_count(v.out) == before,
  "global list outlives source buffer"
)
results.close("fixture")
check(not vim.api.nvim_win_is_valid(v.win), "orphaned source list closes safely")
check(not model.matches(model.normalize(items, 5)[1], { source = "other" }), "source filter")
results.disable()
results.setup({ auto_preview = true, debounce = 1 })
local fresh = vim.api.nvim_get_current_buf()
v = results.open({ { bufnr = fresh, text = "focus race" } }, { id = "preview-race" })
vim.api.nvim_set_current_win(v.win)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = v.out })
vim.api.nvim_set_current_win(v.ctx.win)
vim.wait(20, function()
  return false
end, 1)
check(not v.preview, "queued preview cannot reopen over the source after focus leaves the list")
results.disable()
print(("results: %d assertions passed"):format(count))
vim.cmd("qa!")
