vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT or vim.fn.getcwd())
local config = require("lsp-tools.config")
for _, tool in ipairs({ "rename", "code_actions" }) do
  config.tool(tool, { backend = "native", native = { file_header = false, ft = "lua" } })
  config.tool(tool, { backend = "delta" })
  config.tool(tool, { backend = "vim" })
  for _, invalid in ipairs({
    { backend = "unknown" },
    { backend = "native", native = false },
    { backend = "native", native = { syntax = "true" } },
    { backend = "native", native = { ft = 1 } },
  }) do
    assert(not pcall(config.tool, tool, invalid), "Invalid diff options must be rejected")
  end
end
print(
  "LSP native diff configuration: rename/code actions accept native options and reject invalid values"
)
vim.cmd("qa!")
