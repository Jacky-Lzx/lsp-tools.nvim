---@type vim.lsp.Config
return {
  cmd = { "python3", vim.env.LSP_TOOLS_ROOT .. "/tests/server.py" },
  filetypes = { "lsp-tools-fixture" },
  root_markers = { { ".fixture-root", ".fixture-alt" }, ".git" },
  workspace_required = true,
  settings = { fixture = { upstream = true, precedence = "upstream" } },
  on_init = function()
    vim.g.lsp_tools_fixture_initialized = (vim.g.lsp_tools_fixture_initialized or 0) + 1
  end,
}
