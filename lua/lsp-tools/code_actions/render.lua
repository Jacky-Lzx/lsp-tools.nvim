local M = {}
M.validate = require("lsp-tools.config").diff

function M.start(ctx, lines, config, valid)
  local handle = require("selection_tools.providers.diff").render(ctx, lines, config, valid)
  return function()
    handle:close()
  end
end

return M
