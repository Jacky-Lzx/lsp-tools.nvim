vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api, results = vim.api, require("lsp-tools.results")
local root = vim.fn.tempname()
local function buffer(name)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, root .. "/" .. name)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "😀alpha", "beta", "gamma" })
  return buf
end
local a, b, c = buffer("src/中文.lua"), buffer("src/z.lua"), buffer("test/c.lua")
results.setup({ auto_preview = false })
local items = {
  { id = "alpha", bufnr = a, text = "alpha\ncontinued 😀", pos = { 1, 4 } },
  { id = "beta", bufnr = b, text = "beta", pos = { 2, 0 } },
  { id = "gamma", bufnr = c, text = "gamma", pos = { 3, 0 } },
}
local v = results.open(items, { group_by = { "directory", "file" }, focus = true })
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function group(field, value)
  for i, row in ipairs(v.rows) do
    if row.field == field and row.value == root .. "/" .. value then
      return v.row_lines[i]
    end
  end
  error("missing group: " .. value)
end
local function closed(line)
  return api.nvim_win_call(v.win, function()
    return vim.fn.foldclosed(line)
  end)
end
local function native(line, keys)
  api.nvim_set_current_win(v.win)
  api.nvim_win_set_cursor(v.win, { line, 0 })
  api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end
for _, key in ipairs({
  "za",
  "zo",
  "zc",
  "zO",
  "zC",
  "zM",
  "zR",
  "zm",
  "zr",
  "zj",
  "zk",
  "zn",
  "zN",
  "zx",
  "zX",
  "zv",
}) do
  check(vim.fn.maparg(key, "n") == "", key .. " remains a native Vim command")
end
check(vim.wo[v.win].foldmethod == "expr", "result hierarchy supplies native expression folds")
local file_a, file_b, directory =
  group("file", "src/中文.lua"), group("file", "src/z.lua"), group("directory", "src")
native(directory, "zm")
check(
  vim.wo[v.win].foldlevel == 1 and closed(directory) == -1 and closed(file_a) == file_a,
  "initial zm immediately closes one hierarchy level"
)
native(directory, "zR")
native(directory, "zj")
check(api.nvim_win_get_cursor(v.win)[1] == file_b, "native zj moves to the next fold start")
native(file_a, "zk")
check(
  v.line_rows[api.nvim_win_get_cursor(v.win)[1]].item.id == "beta",
  "native zk moves to the preceding fold end"
)
local before = api.nvim_buf_get_lines(v.out, 0, -1, false)
native(file_a, "zc")
check(closed(file_a) == file_a and closed(file_b) == -1, "zc closes only the selected file")
check(
  vim.deep_equal(before, api.nvim_buf_get_lines(v.out, 0, -1, false)),
  "native folding preserves all diagnostic lines in the buffer"
)
local finish = api.nvim_win_call(v.win, function()
  return vim.fn.foldclosedend(file_a)
end)
check(
  finish > file_a and v.line_rows[finish].item.id == "alpha",
  "native fold includes the multiline diagnostic and stops before the next file"
)
local caption = api.nvim_win_call(v.win, function()
  return vim.fn.foldtextresult(file_a)
end)
check(
  caption:find("中文.lua", 1, true) and caption:find("", 1, true),
  "native folded caption retains the Unicode file name and closed marker"
)
vim.fn.maparg("<CR>", "n", false, true).callback()
check(closed(file_a) == -1, "Enter on a group delegates to the native fold")
vim.fn.maparg("<CR>", "n", false, true).callback()
native(directory, "zc")
check(closed(directory) == directory, "directory folds nest above file folds")
local inserted = buffer("aaa/new.lua")
local updated = vim.list_extend({
  { id = "new", bufnr = inserted, text = "new" },
  { id = "alpha-more", bufnr = a, text = "more", pos = { 3, 0 } },
}, items)
results.set_items(v, updated)
directory, file_a, file_b =
  group("directory", "src"), group("file", "src/中文.lua"), group("file", "src/z.lua")
check(
  directory > 1 and closed(directory) == directory,
  "refresh preserves a closed directory after earlier lines are inserted"
)
native(directory, "zo")
check(
  closed(file_a) == file_a and closed(file_b) == -1,
  "refresh preserves closed/open child states beneath a closed parent"
)
caption = api.nvim_win_call(v.win, function()
  return vim.fn.foldtextresult(file_a)
end)
check(caption:match("2%s*$"), "a closed fold caption updates its diagnostic count")
native(directory, "zC")
check(closed(directory) == directory, "recursive native close works")
native(directory, "zO")
check(closed(file_a) == -1 and closed(file_b) == -1, "recursive native open works")
native(1, "zM")
check(vim.wo[v.win].foldlevel == 0 and closed(directory) == directory, "zM closes all native folds")
native(1, "zr")
check(
  vim.wo[v.win].foldlevel == 1 and closed(directory) == -1 and closed(file_a) == file_a,
  "zr opens just one level"
)
results.set_items(v, updated)
check(
  vim.wo[v.win].foldlevel == 1 and closed(file_a) == file_a,
  "refresh preserves foldlevel and manual fold state"
)
native(1, "zn")
results.set_items(v, updated)
check(not vim.wo[v.win].foldenable and closed(file_a) == -1, "refresh respects native zn")
native(1, "zN")
check(closed(file_a) == file_a, "zN restores the native closed folds after refresh")
native(1, "zM")
native(1, "/beta<CR>")
check(
  results.selected(v).id == "beta" and closed(file_b) == -1,
  "native search reveals a diagnostic inside closed groups"
)
results.set_items(v, updated)
check(
  closed(file_b) == -1 and closed(file_a) == file_a,
  "refresh preserves folds opened by native search"
)
native(1, "zM")
results.select(v, "beta")
check(
  results.selected(v).id == "beta" and closed(file_b) == -1 and closed(file_a) == file_a,
  "select reveals only the target ancestors"
)
native(directory, "zC")
results.close()
v = results.open(nil, { group_by = { "directory", "file" }, focus = true })
directory, file_a = group("directory", "src"), group("file", "src/中文.lua")
check(closed(directory) == directory, "reopening restores native closed groups")
native(directory, "zo")
check(closed(file_a) == file_a, "reopening also restores nested closed groups")
results.disable()
print(("native result folds: %d assertions passed"):format(count))
vim.cmd("qa!")
