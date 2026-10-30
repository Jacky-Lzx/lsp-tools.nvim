vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local inspect = require("lsp-tools.inspect")
local buf = vim.api.nvim_get_current_buf()
vim.o.columns = 180
local function client(id, name, supported)
  local c = {
    id = id,
    name = name,
    offset_encoding = "utf-16",
    initialized = true,
    root_dir = "/project/" .. name,
    workspace_folders = { { uri = "file:///project" } },
    requests = { [5] = { bufnr = buf, type = "pending", method = "textDocument/hover" } },
  }
  function c:supports_method(method)
    return supported[method] or false
  end
  function c:stop() end
  return c
end
local clients = {
  client(3, "other", { ["textDocument/hover"] = true }),
  client(1, "main", { ["textDocument/rename"] = true, ["textDocument/hover"] = true }),
}
vim.lsp.get_clients = function()
  return clients
end
inspect.setup()
local snapshot = inspect.snapshot(buf)
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
check(snapshot.clients[1].id == 1 and #snapshot.clients == 2, "client list sorted by ID")
check(
  snapshot.clients[1].root == "/project/main" and #snapshot.clients[1].workspaces == 1,
  "roots and workspace folders"
)
check(
  snapshot.clients[1].methods["textDocument/rename"]
    and not snapshot.clients[2].methods["textDocument/rename"],
  "buffer capabilities differ per client"
)
local s = assert(inspect.open())
local function text()
  return table.concat(vim.api.nvim_buf_get_lines(s.out, 0, -1, false), "\n")
end
check(
  text():find("Request #5 pending", 1, true)
    and text():find("Linked editing: first capable", 1, true),
  "pending requests and selection policy"
)
for i = 1, 100 do
  vim.api.nvim_exec_autocmds("LspRequest", {
    buffer = buf,
    data = {
      client_id = 1,
      request_id = i,
      request = { bufnr = buf, method = "textDocument/hover", type = "complete" },
    },
  })
end
check(#inspect.snapshot(buf).lifecycle == 80, "bounded lifecycle recording")
vim.fn.maparg("r", "n", false, true).callback()
check(
  text():find("status only", 1, true) and text():find("request #100", 1, true),
  "refresh includes native lifecycle without claiming response success"
)
vim.fn.maparg("y", "n", false, true).callback()
check(vim.fn.getreg('"'):find("/project/main", 1, true), "copy inspection report")
inspect.disable()
check(not require("lsp-tools.panel").alive(s), "disable closes owned panel")
print(("inspection: %d assertions passed"):format(count))
vim.cmd("qa!")
