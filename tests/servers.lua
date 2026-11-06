vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local runtime = vim.env.LSP_TOOLS_ROOT .. "/tests/fixtures/servers"
vim.opt.rtp:prepend(runtime)
vim.opt.rtp:append(runtime .. "/after")
local tools = require("lsp-tools")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function fails(options, needle)
  local ok, err = pcall(tools.setup, options)
  check(not ok and tostring(err):find(needle, 1, true), "validation: " .. needle)
end
tools.setup({
  code_actions = false,
  references = false,
  rename = false,
  outline = false,
  breadcrumbs = false,
})
check(not package.loaded["lsp-tools.servers"], "UI-only setup leaves server manager unloaded")
check(#tools.server_status() == 0, "no selected servers before opt-in")

for _, bad in ipairs({ true, "bad", 4 }) do
  fails({ servers = bad }, "servers must be a table or false")
end
for _, name in ipairs({ "", "*", "../bad", "_configs" }) do
  fails({ servers = { [name] = true } }, "servers keys")
end
for _, value in ipairs({ 1, "bad" }) do
  fails({ servers = { lsp_tools_fixture = value } }, "must be a boolean or table")
end
for _, config in ipairs({
  { cmd = {} },
  { cmd = { "python3", 1 } },
  { filetypes = "lua" },
  { root_dir = false },
  { root_markers = { {} } },
  { root_markers = { { "a", 3 } } },
  { workspace_required = "yes" },
  { settings = true },
  { capabilities = true },
}) do
  fails({ servers = { lsp_tools_fixture = config } }, "servers.lsp_tools_fixture.")
end
fails({ servers = { lsp_tools_missing = true } }, "No LSP config")
fails({ servers = { lsp_tools_missing = { settings = {} } } }, "No LSP config")
fails({ servers = { lsp_tools_fixture = true }, hover = { width = -1 } }, "hover.width")
check(not vim.lsp.is_enabled("lsp_tools_fixture"), "invalid UI options do not enable servers")
local before = vim.deepcopy(tools.configuration())
fails({
  servers = {
    lsp_tools_fixture = { settings = { fixture = { partial = true } } },
    lsp_tools_missing = true,
  },
}, "No LSP config")
check(vim.deep_equal(tools.configuration(), before), "invalid batch preserves plugin configuration")
check(
  not vim.lsp.config.lsp_tools_fixture.settings.fixture.partial,
  "invalid batch does not register overrides"
)

vim.lsp.config("*", { settings = { fixture = { global = true, precedence = "global" } } })
local options = { settings = { fixture = { user = true, precedence = "user" } } }
tools.setup({ servers = { lsp_tools_fixture = options } })
local config = vim.lsp.config.lsp_tools_fixture
check(vim.lsp.is_enabled("lsp_tools_fixture"), "selected runtime config enabled")
check(
  config.settings.fixture.upstream
    and config.settings.fixture.after
    and config.settings.fixture.global
    and config.settings.fixture.user,
  "native runtime, after and global fields retained"
)
check(
  config.settings.fixture.precedence == "user",
  "explicit overrides have native highest priority"
)
check(type(config.on_init) == "function", "upstream hook preserved")
check(
  vim.deep_equal(config.root_markers[1], { ".fixture-root", ".fixture-alt" }),
  "root priority groups retained"
)
options.settings.fixture.user = false
check(
  tools.configuration().servers.lsp_tools_fixture.settings.fixture.user,
  "caller tables are not retained"
)
local copied = tools.configuration()
copied.servers.lsp_tools_fixture.settings.fixture.user = false
check(
  tools.configuration().servers.lsp_tools_fixture.settings.fixture.user,
  "configuration snapshots are isolated"
)

local enable, calls = vim.lsp.enable, 0
vim.lsp.enable = function(...)
  calls = calls + 1
  return enable(...)
end
tools.setup({ servers = { lsp_tools_fixture = true } })
tools.setup({ servers = { lsp_tools_fixture = { settings = { fixture = { another = true } } } } })
tools.setup({ hover = true })
check(calls == 0, "repeated setup neither re-enables nor restarts running configs")
check(
  vim.lsp.config.lsp_tools_fixture.settings.fixture.user
    and vim.lsp.config.lsp_tools_fixture.settings.fixture.another,
  "native overrides accumulate across setup"
)
local status = tools.server_status()[1]
check(
  status.managed and status.enabled and not status.matches_filetype,
  "selected config status includes ownership and filetype match"
)
check(
  require("lsp-tools.servers.status").describe(status):find("Filetype", 1, true),
  "nonmatching filetypes explained"
)

vim.lsp.config("lsp_tools_external", { cmd = function() end, filetypes = { "lsp-tools-fixture" } })
enable("lsp_tools_external")
tools.setup({ servers = { lsp_tools_external = true } })
check(not tools.server_status()[1].managed, "pre-enabled servers remain externally managed")
tools.setup({ servers = { lsp_tools_external = false, lsp_tools_fixture = false } })
check(
  vim.lsp.is_enabled("lsp_tools_external") and not vim.lsp.is_enabled("lsp_tools_fixture"),
  "disable stops owned configs and preserves external ones"
)
check(
  vim.lsp.config.lsp_tools_fixture.settings.fixture.user,
  "disable preserves native configuration"
)
tools.setup({ servers = { lsp_tools_fixture = true } })
check(vim.lsp.is_enabled("lsp_tools_fixture"), "disabled configs can be enabled again")

local invoked = 0
tools.setup({
  servers = {
    lsp_tools_dynamic = {
      cmd = function()
        invoked = invoked + 1
      end,
      root_dir = function()
        invoked = invoked + 1
      end,
      filetypes = { "lsp-tools-fixture" },
    },
    lsp_tools_absent = {
      cmd = { "/missing/lsp-tools-server" },
      filetypes = { "lsp-tools-fixture" },
    },
  },
})
local statuses = tools.server_status()
check(invoked == 0, "setup and status never call dynamic cmd/root callbacks for unrelated buffers")
check(
  statuses[1].executable == false,
  "missing executables reported without rejecting registration"
)
check(
  statuses[2].dynamic_root and statuses[2].executable == nil,
  "dynamic command and root remain unevaluated"
)
check(
  not package.loaded["lspconfig"] and not package.loaded["lsp-tools.panel"],
  "management does not require legacy lspconfig or an interactive view"
)
vim.lsp.config("lsp_tools_dynamic", { filetypes = "invalid external update" })
local broken = tools.server_status()[2]
check(
  broken.error
    and require("lsp-tools.servers.status").describe(broken):find("Configuration error", 1, true),
  "status contains malformed external config errors"
)
tools.setup({ servers = false })
check(
  not vim.lsp.is_enabled("lsp_tools_dynamic") and not vim.lsp.is_enabled("lsp_tools_absent"),
  "bulk disable releases owned servers"
)
check(vim.lsp.is_enabled("lsp_tools_external"), "bulk disable preserves external activation")
tools.update({ servers = { lsp_tools_fixture = true } })
tools.dispose()
tools.dispose()
check(not vim.lsp.is_enabled("lsp_tools_fixture"), "disposal disables owned native servers")
check(vim.lsp.is_enabled("lsp_tools_external"), "disposal preserves external native servers")
check(
  vim.lsp.config.lsp_tools_fixture.settings.fixture.user,
  "disposal preserves native configuration overlays"
)
check(#tools.server_status() == 0, "disposal forgets managed registrations")
enable("lsp_tools_external", false)
vim.lsp.enable = enable
print(("server management: %d assertions passed"):format(count))
vim.cmd("qa!")
