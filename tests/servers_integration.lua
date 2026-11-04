vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local runtime = vim.env.LSP_TOOLS_ROOT .. "/tests/fixtures/servers"
vim.opt.rtp:prepend(runtime)
vim.opt.rtp:append(runtime .. "/after")
local project = vim.fn.tempname()
vim.fn.mkdir(project .. "/one/nested", "p")
vim.fn.mkdir(project .. "/one/nested/.git", "p")
vim.fn.mkdir(project .. "/two", "p")
vim.fn.mkdir(project .. "/standalone", "p")
vim.fn.writefile({}, project .. "/one/.fixture-root")
vim.fn.writefile({}, project .. "/two/.fixture-alt")
project = assert(vim.uv.fs_realpath(project))
local tools = require("lsp-tools")
local function wait(test, message)
  assert(vim.wait(5000, test, 10), message)
end
local function source(path)
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, project .. path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello foo" })
  vim.bo[buf].filetype = "lsp-tools-fixture"
  return buf
end
local function clients(buf)
  return vim.lsp.get_clients({ name = "lsp_tools_fixture", bufnr = buf })
end
local function attached(buf)
  wait(function()
    return #clients(buf) == 1 and clients(buf)[1].initialized
  end, "fixture attaches: " .. vim.api.nvim_buf_get_name(buf))
  return clients(buf)[1]
end
local function run()
  local first = source("/one/first.fixture")
  tools.setup({
    code_actions = false,
    references = false,
    rename = false,
    outline = false,
    breadcrumbs = false,
    inspect = true,
    server_activation = vim.env.LSP_TOOLS_SERVER_ACTIVATION or "eager",
    servers = { lsp_tools_fixture = { settings = { fixture = { user = true } } } },
  })
  local client = attached(first)
  assert(client.root_dir == project .. "/one", "native root markers choose project one")
  assert(
    client.config.settings.fixture.upstream
      and client.config.settings.fixture.after
      and client.config.settings.fixture.user,
    "native runtime, after and user configs reach real client"
  )
  assert(vim.g.lsp_tools_fixture_initialized == 1, "upstream initialization hook runs")
  assert(tools.server_status(first)[1].clients[1].attached, "status reports actual attachment")
  assert(
    require("lsp-tools.servers.status").describe(tools.server_status(first)[1]) == "Attached",
    "attached status"
  )

  local second = source("/one/nested/second.fixture")
  assert(
    attached(second).id == client.id,
    "higher-priority project marker wins over nearer .git and reuses native client"
  )
  tools.setup({ servers = { lsp_tools_fixture = { settings = { fixture = { updated = true } } } } })
  assert(
    clients(second)[1].id == client.id and vim.g.lsp_tools_fixture_initialized == 1,
    "reconfiguration does not restart client"
  )
  assert(not client.config.settings.fixture.updated, "running client retains startup settings")

  local other = source("/two/other.fixture")
  local other_client = attached(other)
  assert(
    other_client.id ~= client.id and other_client.root_dir == project .. "/two",
    "different project receives separate client"
  )
  assert(other_client.config.settings.fixture.updated, "new clients use updated configuration")
  local single = source("/standalone/single.fixture")
  vim.wait(100, function()
    return #clients(single) > 0
  end, 10)
  assert(#clients(single) == 0, "workspace-required config skips files without root markers")

  local view = tools.inspect()
  local text = table.concat(vim.api.nvim_buf_get_lines(view.out, 0, -1, false), "\n")
  assert(
    text:find("Configured servers", 1, true) and text:find("no client attached", 1, true),
    "inspection explains enabled but unattached server"
  )
  require("lsp-tools.inspect").disable()
  tools.setup({ servers = { lsp_tools_fixture = false } })
  wait(function()
    return #vim.lsp.get_clients({ name = "lsp_tools_fixture" }) == 0
  end, "disable stops clients across projects")
  assert(not vim.lsp.is_enabled("lsp_tools_fixture"), "disabled config no longer auto-activates")

  tools.setup({ servers = { lsp_tools_fixture = { workspace_required = false } } })
  local single_client = attached(single)
  assert(not single_client.root_dir, "single-file support uses native no-workspace startup")
  tools.setup({ servers = false })
  wait(function()
    return #vim.lsp.get_clients({ name = "lsp_tools_fixture" }) == 0
  end, "bulk disable stops all managed clients")
  tools.setup({
    servers = {
      lsp_tools_starting = {
        cmd = { "python3", "-c", "import time; time.sleep(30)" },
        filetypes = { "lsp-tools-fixture" },
        root_dir = project,
      },
    },
  })
  local starting = vim.lsp.get_clients({ name = "lsp_tools_starting", _uninitialized = true })
  assert(
    #starting == 1 and not starting[1].initialized,
    "client is still awaiting initialize response"
  )
  tools.setup({ servers = false })
  wait(function()
    return #vim.lsp.get_clients({ name = "lsp_tools_starting", _uninitialized = true }) == 0
  end, "disable stops a client before initialization completes")
  assert(not package.loaded["lspconfig"], "native management never loads the legacy framework")
  assert(vim.v.errmsg == "", vim.v.errmsg)
end
local ok, err = xpcall(run, debug.traceback)
for _, client in ipairs(vim.lsp.get_clients({ _uninitialized = true })) do
  client:stop(true)
end
vim.wait(1000, function()
  return #vim.lsp.get_clients() == 0
end, 10)
vim.fn.delete(project, "rf")
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
print(
  "server integration: runtime configs, hooks, native startup/reuse, project isolation, single files and disable passed"
)
vim.cmd("qa!")
