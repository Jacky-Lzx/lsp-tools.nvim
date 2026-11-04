local M = {}
local entries, owned = {}, {}

-- Prepare every supplied entry before changing tool state or registering overrides.
-- Native resolution preserves runtimepath/after/lsp config ordering and hooks.
function M.prepare(opts)
  assert(opts == false or type(opts) == "table", "servers must be a table or false")
  local pending = {}
  if opts == false then
    for name in pairs(entries) do
      pending[name] = false
    end
    return pending
  end
  local validation = require("lsp-tools.servers.config")
  for name, value in pairs(opts) do
    validation.name(name)
    assert(
      type(value) == "boolean" or type(value) == "table",
      "servers." .. name .. " must be a boolean or table"
    )
    if type(value) == "table" then
      validation.validate(name, value)
    end
  end
  for name, value in pairs(opts) do
    if value ~= false then
      local base = vim.lsp.config[name]
      assert(
        base or type(value) == "table" and value.cmd ~= nil,
        "No LSP config for " .. name .. "; load nvim-lspconfig first or supply a custom cmd"
      )
      validation.validate(
        name,
        vim.tbl_deep_extend("force", {}, base or {}, type(value) == "table" and value or {}),
        true
      )
    end
    pending[name] = vim.deepcopy(value)
  end
  return pending
end

function M.apply(pending)
  local start, stop = {}, {}
  for _, name in ipairs(vim.tbl_keys(pending)) do
    local value = pending[name]
    if type(value) == "table" then
      vim.lsp.config(name, value)
    end
    if value == false then
      if owned[name] then
        stop[#stop + 1] = name
      end
    elseif not vim.lsp.is_enabled(name) then
      start[#start + 1] = name
    end
  end
  table.sort(start)
  table.sort(stop)
  if #stop > 0 then
    vim.lsp.enable(stop, false)
  end
  if #start > 0 then
    vim.lsp.enable(start)
  end
  for _, name in ipairs(stop) do
    owned[name] = nil
  end
  for _, name in ipairs(start) do
    owned[name] = true
  end
  for name, value in pairs(pending) do
    if type(value) == "table" and type(entries[name]) == "table" then
      entries[name] = vim.tbl_deep_extend("force", entries[name], value)
    else
      entries[name] = value
    end
  end
end

function M.configuration()
  return vim.deepcopy(entries), vim.deepcopy(owned)
end

return M
