vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local api, tools = vim.api, require("lsp-tools")
local count, calls = 0, {}
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function wait(fn, message)
  check(vim.wait(2000, fn, 1), message)
end
tools.setup({
  pickers = { jump_single = false, debounce = 0 },
  code_actions = false,
  rename = false,
  references = false,
  outline = false,
  breadcrumbs = false,
})
local original_clients = vim.lsp.get_clients
local client = { id = 1, name = "preview-fixture", offset_encoding = "utf-16" }
function client:request(method, params, callback)
  calls[#calls + 1] = { method = method, params = params, callback = callback }
  return true, #calls
end
function client:cancel_request() end
function client:stop() end
vim.lsp.get_clients = function()
  return { client }
end
local source, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
api.nvim_buf_set_name(source, vim.fn.tempname() .. "-unsaved.lua")
local lines = {}
for row = 1, 300 do
  lines[row] = "-- unsaved context " .. row
end
lines[120], lines[260] = "local function alpha() end", "local function beta() end"
api.nvim_buf_set_lines(source, 0, -1, false, lines)
vim.bo[source].filetype = "lua"
api.nvim_win_set_cursor(origin, { 10, 0 })
local function range(row)
  return { start = { line = row - 1, character = 15 }, ["end"] = { line = row - 1, character = 20 } }
end
local function preview(p, row, text, context)
  wait(function()
    if not p.preview_win or not api.nvim_win_is_valid(p.preview_win) then
      return false
    end
    local buf = api.nvim_win_get_buf(p.preview_win)
    return api.nvim_buf_get_lines(buf, row - 1, row, false)[1] == text
      and api.nvim_win_get_cursor(p.preview_win)[1] == row
  end, "selected symbol previews its code at line " .. row)
  local buf = api.nvim_win_get_buf(p.preview_win)
  check(
    api.nvim_buf_get_lines(buf, row - 2, row - 1, false)[1] == context,
    "preview includes surrounding source code"
  )
  local top = api.nvim_win_call(p.preview_win, function()
    return vim.fn.line("w0")
  end)
  local bottom = api.nvim_win_call(p.preview_win, function()
    return vim.fn.line("w$")
  end)
  check(top <= row and bottom >= row and top > 1, "preview scrolls to the selected symbol")
  check(api.nvim_get_current_win() == p.input_win, "preview preserves input focus")
end
local function open(kind, result)
  local before = #calls
  local p = tools["lsp_" .. kind]()
  wait(function()
    return #calls > before
  end, kind .. " sends request")
  calls[#calls].callback(nil, result)
  wait(function()
    return not p.loading and #p.entries > 0
  end, kind .. " results arrive")
  return p
end
local p = open("symbols", {
  { name = "alpha", kind = 12, range = range(120), selectionRange = range(120) },
  { name = "beta", kind = 12, range = range(260), selectionRange = range(260) },
})
preview(p, 120, lines[120], lines[119])
p:move(1)
preview(p, 260, lines[260], lines[259])
check(
  api.nvim_win_get_cursor(origin)[1] == 10 and vim.bo[source].modified,
  "previewing unsaved symbols leaves source cursor and contents unchanged"
)
p:close()

local disk = vim.fn.tempname() .. "-workspace.lua"
local disk_lines = {}
for row = 1, 200 do
  disk_lines[row] = "-- workspace context " .. row
end
disk_lines[150] = "local function external() end"
vim.fn.writefile(disk_lines, disk)
p = open("workspace_symbols", {
  {
    name = "external",
    kind = 12,
    location = { uri = vim.uri_from_fname(disk), range = range(150) },
  },
})
preview(p, 150, disk_lines[150], disk_lines[149])
check(vim.fn.bufnr(disk) < 0, "disk preview does not open the target source buffer")
p:close()

p = open(
  "workspace_symbols",
  { { name = "unresolved", kind = 12, location = { uri = vim.uri_from_fname(disk) } } }
)
wait(function()
  return table
    .concat(api.nvim_buf_get_lines(p.preview_buf, 0, -1, false), "\n")
    :find("Confirm to resolve", 1, true) ~= nil
end, "URI-only workspace symbols explain pending location resolution")
p:close()
vim.fn.delete(disk)
vim.lsp.get_clients = original_clients
print(("symbol source preview: %d assertions passed"):format(count))
vim.cmd("qa!")
