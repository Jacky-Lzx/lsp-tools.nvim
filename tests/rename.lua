vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local count, calls, notices, clients = 0, {}, {}, {}
local input_options, input_callback, picker_options, picker, select_callback
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".lua")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo foo" })
local uri = vim.uri_from_bufnr(buf)
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function flush()
  vim.wait(5, function()
    return false
  end, 1)
end
vim.notify = function(message)
  notices[#notices + 1] = message
end
vim.ui.input = function(opts, callback)
  input_options, input_callback = opts, callback
end
vim.ui.select = function(_, _, callback)
  select_callback = callback
end
vim.lsp.get_clients = function(opts)
  return vim.tbl_filter(function(client)
    return not opts.name or opts.name == client.name
  end, clients)
end
vim.lsp.get_client_by_id = function(id)
  for _, client in ipairs(clients) do
    if client.id == id then
      return client
    end
  end
end
package.loaded["snacks.picker"] = {
  pick = function(opts)
    picker_options = opts
    picker = { item = opts.items[1], closed = false, closes = 0 }
    function picker:current()
      return self.item
    end
    function picker:close()
      if self.closed then
        return
      end
      self.closes = self.closes + 1
      opts.on_close()
      self.closed = true
    end
    return picker
  end,
}
local function client(id, prepare)
  local c = { id = id, name = "server" .. id, offset_encoding = "utf-16" }
  function c:supports_method()
    return prepare
  end
  function c:request(method, params, callback)
    calls[#calls + 1] = { method = method, params = params, callback = callback, client = self.id }
    return true, #calls
  end
  function c:cancel_request(id)
    calls[id].cancelled = true
  end
  return c
end
local range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 5 } }
local edit = { changes = { [uri] = { { range = range, newText = "bar" } } } }
local function setup(prepare)
  tools.cancel_rename()
  input_callback, input_options, picker_options = nil, nil, nil
  clients = { client(1, prepare) }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo foo" })
  vim.api.nvim_win_set_cursor(0, { 1, 4 })
  tools.setup({
    breadcrumbs = false,
    code_actions = false,
    references = false,
    rename = { request_timeout = 30 },
  })
end
setup(true)
tools.rename()
check(calls[#calls].method == "textDocument/prepareRename", "prepare before asking for a new name")
check(calls[#calls].params.position.character == 2, "prepare uses server encoding")
calls[#calls].callback(nil, { range = range, placeholder = "foo" })
flush()
check(input_options.default == "foo", "prepare placeholder prefills input")
input_callback("bar")
check(
  calls[#calls].method == "textDocument/rename" and calls[#calls].params.newName == "bar",
  "input triggers native rename request"
)
calls[#calls].callback(nil, edit)
flush()
check(picker_options.title:find("1 file · 1 edit", 1, true), "title reports file and edit counts")
check(
  vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "😀foo foo",
  "preview never edits source"
)
check(picker_options.items[1].lines[3]:find("@@", 1, true), "per-file diff is available")
local selected = picker.item
picker.item = nil
picker_options.confirm(picker)
check(not picker.closed, "Enter with no matching files does not apply the rename")
picker.item = selected
picker_options.confirm(picker)
picker_options.confirm(picker)
check(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "😀bar foo", "confirmation applies once")

setup(true)
tools.rename("bar")
calls[#calls].callback(nil, range)
flush()
check(
  calls[#calls].method == "textDocument/rename" and not input_callback,
  "programmatic name still prepares and skips input"
)
calls[#calls].callback(nil, edit)
flush()
picker:close()
check(picker.closes == 1, "external picker closure never re-enters Snacks close")
check(
  vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "😀foo foo",
  "Escape cancels without edits"
)

setup(false)
tools.rename()
check(input_options.default == "foo", "servers without prepare use the cursor word")
local n = #calls
input_callback(nil)
check(#calls == n and not picker_options, "canceling input sends no rename")
setup(false)
tools.rename()
input_callback("")
check(#calls == n, "empty names cancel")
setup(false)
tools.rename()
input_callback("foo")
check(#calls == n, "unchanged names do not send a request")

setup(true)
tools.rename()
calls[#calls].callback(nil, { defaultBehavior = true })
flush()
check(input_options.default == "foo", "prepare defaultBehavior uses cursor word")
tools.cancel_rename()
input_callback("bar")
check(calls[#calls].method == "textDocument/prepareRename", "late input after cancel is ignored")
setup(true)
tools.rename()
calls[#calls].callback(nil, nil)
flush()
check(
  not input_callback and notices[#notices]:find("Nothing to rename"),
  "null prepare rejects location"
)
setup(true)
tools.rename()
calls[#calls].callback({ message = "not an identifier" })
flush()
check(
  not input_callback and notices[#notices]:find("not an identifier"),
  "prepare errors are reported"
)

setup(false)
tools.rename("bar")
local pending = calls[#calls]
tools.cancel_rename()
pending.callback(nil, edit)
flush()
check(pending.cancelled and not picker_options, "cancel stops request and ignores late reply")
setup(false)
tools.rename("bar")
pending = calls[#calls]
vim.api.nvim_win_set_cursor(0, { 1, 8 })
pending.callback(nil, edit)
flush()
check(not picker_options, "cursor movement rejects a stale response")
setup(false)
tools.rename("bar")
pending = calls[#calls]
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "changed" })
pending.callback(nil, edit)
flush()
check(not picker_options, "source edits reject a stale response")
setup(false)
tools.rename("bar")
pending = calls[#calls]
vim.wait(100, function()
  return pending.cancelled
end, 1)
check(
  pending.cancelled and notices[#notices]:find("timed out"),
  "requests time out and cancel asynchronously"
)

setup(false)
tools.rename("bar")
calls[#calls].callback(nil, edit)
flush()
vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "changed" })
picker_options.confirm(picker)
check(
  not picker.closed and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "changed",
  "changed preview remains reviewable but refuses apply"
)
setup(false)
tools.rename("bar")
calls[#calls].callback(nil, edit)
flush()
clients = {}
picker_options.confirm(picker)
check(
  not picker.closed and notices[#notices]:find("language server changed"),
  "disconnected server refuses apply"
)

setup(false)
clients[#clients + 1] = client(2, false)
tools.rename("bar")
n = #calls
check(select_callback ~= nil, "multiple servers require selection")
select_callback(clients[2])
check(#calls == n + 1 and calls[#calls].client == 2, "only the selected server is asked to rename")
tools.cancel_rename()
tools.rename("bar", { name = "server1" })
check(calls[#calls].client == 1, "client name filtering")
tools.cancel_rename()
tools.rename("bar", {
  filter = function(c)
    return c.id == 2
  end,
})
check(calls[#calls].client == 2, "client predicate filtering")
tools.setup({ breadcrumbs = false, code_actions = false, references = false, rename = false })
check(calls[#calls].cancelled, "disabling rename cancels pending work")
n = #calls
tools.rename("bar")
check(#calls == n, "disabled rename sends no requests")
setup(false)
clients = {}
tools.rename("bar")
check(notices[#notices]:find("No matching"), "unsupported servers are explained")
setup(false)
local path = vim.fn.tempname() .. ".lua"
local resource = vim.uri_from_fname(path)
tools.rename("bar")
calls[#calls].callback(nil, {
  documentChanges = {
    { kind = "create", uri = resource },
    {
      textDocument = { uri = resource },
      edits = {
        {
          range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 0 },
          },
          newText = "bar",
        },
      },
    },
  },
})
flush()
check(not vim.uv.fs_stat(path), "resource changes are only simulated before confirmation")
picker_options.confirm(picker)
check(
  vim.uv.fs_stat(path) ~= nil,
  "confirmed resource operations reach native workspace application"
)
check(
  vim.api.nvim_buf_get_lines(vim.uri_to_bufnr(resource), 0, 1, false)[1] == "bar",
  "text edits after a create are applied"
)
vim.fn.delete(path)
tools.cancel_rename()
print(("lsp-tools rename: %d assertions passed"):format(count))
vim.cmd("qa!")
