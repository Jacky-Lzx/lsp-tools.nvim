local M = {}

---Read selected server configs without invoking dynamic cmd/root_dir callbacks.
---@param buf? integer
---@return table[]
function M.snapshot(buf)
  local manager = package.loaded["lsp-tools.servers"]
  if not manager then
    return {}
  end
  buf = buf or vim.api.nvim_get_current_buf()
  local entries, owned, _, waiting = manager.configuration()
  local result = {}
  local ft = vim.bo[buf].filetype
  for name, value in pairs(entries) do
    local ok, config = pcall(function()
      local resolved = vim.lsp.config[name]
      if resolved then
        require("lsp-tools.servers.config").validate(name, resolved, true)
      end
      return resolved
    end)
    local info = {
      name = name,
      requested = value ~= false,
      enabled = vim.lsp.is_enabled(name),
      managed = owned[name] == true,
      configured = ok and config ~= nil,
      pending = waiting[name] ~= nil and not vim.lsp.is_enabled(name),
      clients = {},
    }
    if ok and config then
      info.filetypes = vim.deepcopy(config.filetypes)
      info.matches_filetype = config.filetypes == nil or vim.tbl_contains(config.filetypes, ft)
      info.cmd = vim.deepcopy(config.cmd)
      if type(config.cmd) == "table" and type(config.cmd[1]) == "string" then
        info.executable = vim.fn.executable(config.cmd[1]) == 1
      end
      info.root = type(config.root_dir) == "string" and config.root_dir or nil
      info.dynamic_root = type(config.root_dir) == "function"
      info.root_markers = vim.deepcopy(config.root_markers)
      info.workspace_required = config.workspace_required == true
    elseif not ok then
      info.error = tostring(config)
    end
    for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
      info.clients[#info.clients + 1] = {
        id = client.id,
        initialized = client.initialized,
        attached = vim.lsp.buf_is_attached(buf, client.id),
        root = client.root_dir,
      }
    end
    table.sort(info.clients, function(a, b)
      return a.id < b.id
    end)
    result[#result + 1] = info
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

function M.describe(info)
  if info.error then
    return "Configuration error: " .. info.error
  elseif not info.requested then
    return info.enabled and "Management disabled; enabled externally" or "Disabled"
  elseif not info.enabled then
    return info.pending and "Waiting for a matching filetype"
      or "Configured; native auto-activation is disabled"
  elseif not info.configured then
    return "Configuration unavailable"
  elseif info.executable == false then
    return "Executable missing: " .. info.cmd[1]
  elseif not info.matches_filetype then
    return "Filetype does not match this buffer"
  end
  for _, client in ipairs(info.clients) do
    if client.attached then
      return client.initialized and "Attached" or "Initializing"
    end
  end
  return "Enabled; no client attached to this buffer (check root policy and LSP log)"
end

return M
