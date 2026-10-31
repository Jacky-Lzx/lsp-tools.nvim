local M = {}
M.validate = require("lsp-tools.config").diff

function M.start(ctx, lines, config, valid)
  local opts = vim.tbl_extend("force", {}, config)
  opts.cwd = ctx.item and ctx.item.root or nil
  local handle = require("git_tools.diff").render(ctx, lines, opts, valid)
  return function()
    handle:close()
  end
end

return M
