vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local results, api = require("lsp-tools.results"), vim.api
results.setup({ auto_preview = false })
local source, owner = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
api.nvim_buf_set_lines(source, 0, -1, false, { "😀foo", "bar" })
local v = results.open(
  { { bufnr = source, pos = { 1, 4 }, text = "target" } },
  { id = "jumps", group_by = {} }
)
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
for _, destination in ipairs({ "split", "vsplit", "tab" }) do
  api.nvim_set_current_win(v.win)
  local windows, tabs = #api.nvim_list_wins(), #api.nvim_list_tabpages()
  local key = ({ split = "<LocalLeader>-", vsplit = "<LocalLeader>|", tab = "<LocalLeader>t" })[destination]
  vim.fn.maparg(key, "n", false, true).callback()
  local target = api.nvim_get_current_win()
  check(
    target ~= owner and target ~= v.win and api.nvim_win_get_buf(target) == source,
    destination .. " opens source"
  )
  check(
    api.nvim_win_get_cursor(target)[2] == 4 and #api.nvim_list_wins() == windows + 1,
    destination .. " preserves byte position"
  )
  check(
    #api.nvim_list_tabpages() == tabs + (destination == "tab" and 1 or 0),
    destination .. " preserves tab scope"
  )
  check(
    api.nvim_win_is_valid(v.win) and vim.bo[v.out].filetype == "lsp-tools-results",
    "list remains open"
  )
  api.nvim_win_close(target, true)
end
api.nvim_set_current_win(v.win)
v.options.validate = function()
  return false
end
local windows = #api.nvim_list_wins()
check(
  not results.jump(v, false, "tab") and #api.nvim_list_wins() == windows,
  "stale validation precedes window creation"
)
v.options.validate = nil
v.options.on_jump = function()
  error("unavailable target")
end
check(
  not results.jump(v, false, "tab")
    and #api.nvim_list_wins() == windows
    and v.status:find("unavailable target", 1, true),
  "failed jumps release newly created destinations"
)
results.close("jumps")
print(("result jump destinations: %d assertions passed"):format(count))
vim.cmd("qa!")
