vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
tools.setup({
  results = { debounce = 1, auto_preview = false },
  code_actions = false,
  references = false,
  breadcrumbs = false,
  outline = false,
})
local results = require("lsp-tools.results")
local api = vim.api
local a, owner = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(a, vim.fn.tempname() .. "-a.lua")
api.nvim_buf_set_lines(a, 0, -1, false, { "\t😀foo", "second", "third" })
local b = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(b, vim.fn.tempname() .. "-b.lua")
api.nvim_buf_set_lines(b, 0, -1, false, { "first", "second", "third" })
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
vim.fn.setqflist({}, " ", {
  title = "Native build",
  context = { token = 42 },
  items = {
    { bufnr = b, lnum = 2, col = 1, text = "B first", type = "W" },
    { bufnr = a, lnum = 1, col = 11, vcol = 1, text = "A second", type = "E" },
    { bufnr = b, lnum = 3, col = 1, text = "B third" },
    { text = "unlocated build output", valid = 0 },
  },
})
local original = vim.fn.getqflist({ all = true })
vim.fn.setqflist({}, "a", { id = original.id, idx = 3 })
original = vim.fn.getqflist({ all = true })
local v = tools.quickfix({ focus = false, poll_interval = 5 })
check(
  #v.items == 4 and v.items[1].text == "B first" and v.items[2].text == "A second",
  "native order and invalid log rows preserved"
)
check(
  v.native_list.id == original.id and vim.deep_equal(v.native_list.context, original.context),
  "native list identity and context retained"
)
check(
  vim.deep_equal(vim.fn.getqflist({ all = true }), original),
  "opening does not change canonical list"
)
check(results.selected(v).data.native_index == 3, "initial selection follows native current index")
results.select(v, v.items[2].id)
vim.api.nvim_set_current_win(v.win)
results.jump(v, true)
check(
  vim.fn.getqflist({ idx = 0 }).idx == 2 and api.nvim_win_get_buf(owner) == a,
  "jump synchronizes canonical current index"
)
check(
  api.nvim_win_get_cursor(owner)[2] == 5,
  "native jump honors visual columns after tab and Unicode"
)
check(results.selected(v).data.native_index == 2, "explicit jump leaves the selected result active")
local id = v.native_list.id
vim.fn.setqflist({}, "a", { id = id, items = { { bufnr = a, lnum = 2, text = "appended" } } })
check(
  vim.wait(200, function()
    return #v.items == 5
  end, 1),
  "API-only append refreshes while open"
)
results.close("qflist")
api.nvim_set_current_win(owner)
vim.cmd("vsplit")
local other = api.nvim_get_current_win()
vim.fn.setloclist(
  owner,
  {},
  " ",
  { title = "owner list", items = { { bufnr = a, lnum = 2, text = "owner entry" } } }
)
vim.fn.setloclist(
  other,
  {},
  " ",
  { title = "other list", items = { { bufnr = b, lnum = 3, text = "wrong window" } } }
)
v = tools.loclist({ winid = owner, focus = false, poll_interval = 5 })
check(v.items[1].text == "owner entry", "location list binds original source window")
vim.fn.setloclist(owner, {}, "a", { items = { { bufnr = a, lnum = 3, text = "owner append" } } })
check(
  vim.wait(200, function()
    return #v.items == 2
  end, 1),
  "location list API updates refresh"
)
api.nvim_set_current_win(other)
results.refresh(v)
check(v.items[1].text == "owner entry", "panel focus cannot switch location-list ownership")
api.nvim_win_close(owner, true)
check(
  api.nvim_win_is_valid(v.win) and v.status:find("Source window closed", 1, true),
  "closed source window leaves an explicit snapshot"
)
api.nvim_set_current_win(v.win)
check(not results.jump(v), "closed owner cannot redirect a location-list jump")
results.close("loclist")
check(not api.nvim_win_is_valid(v.win), "closing releases native-list view")
print(("native list results: %d assertions passed"):format(count))
vim.cmd("qa!")
