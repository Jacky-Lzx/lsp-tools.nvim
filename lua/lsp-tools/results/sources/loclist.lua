local M = {}
function M.open(results, opts)
  return require("lsp-tools.results.sources.qf").open(results, opts, true)
end
return M
