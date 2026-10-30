local M = {}
local lifecycle, group = {}, nil
function M.history(buf)
  return vim.deepcopy(vim.tbl_filter(function(event)
    return not buf or event.buf == buf
  end, lifecycle))
end
function M.disable()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end
function M.setup()
  if group then
    return
  end
  group = vim.api.nvim_create_augroup("LspToolsInspect", { clear = true })
  vim.api.nvim_create_autocmd("LspRequest", {
    group = group,
    callback = function(ev)
      local data = ev.data
      if not data or not data.request then
        return
      end
      lifecycle[#lifecycle + 1] = {
        buf = data.request.bufnr,
        client_id = data.client_id,
        id = data.request_id,
        method = data.request.method,
        status = data.request.type,
      }
      if #lifecycle > 80 then
        table.remove(lifecycle, 1)
      end
    end,
  })
end
return M
