local M = {}
local entries, owned = {}, {}
local activation, waiting, group = "eager", {}, nil

local function watch()
  if group and (activation ~= "filetype" or not next(waiting)) then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
  if not group and activation == "filetype" and next(waiting) then
    group = vim.api.nvim_create_augroup("LspToolsServers", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      callback = function(ev)
        M.activate(ev.buf)
      end,
    })
  end
end

local function enable(names)
  if #names > 0 then
    table.sort(names)
    vim.lsp.enable(names)
    for _, name in ipairs(names) do
      owned[name], waiting[name] = true, nil
    end
  end
  watch()
end

function M.activate(buf)
  local ft, bt = vim.bo[buf].filetype, vim.bo[buf].buftype
  if ft == "" or bt ~= "" and bt ~= "help" then
    return
  end
  local names = {}
  for name, config in pairs(waiting) do
    if vim.lsp.is_enabled(name) then
      waiting[name] = nil -- External activation does not transfer ownership.
    elseif config.filetypes == nil or vim.tbl_contains(config.filetypes, ft) then
      names[#names + 1] = name
    end
  end
  enable(names)
end

-- Prepare every supplied entry before changing tool state or registering overrides.
-- Native resolution preserves runtimepath/after/lsp config ordering and hooks.
function M.prepare(opts, mode)
  assert(opts == false or type(opts) == "table", "servers must be a table or false")
  if mode == nil then
    mode = activation
  end
  assert(mode == "eager" or mode == "filetype", "server_activation must be 'eager' or 'filetype'")
  local pending = { updates = {}, matches = {}, activation = mode }
  if opts == false then
    for name in pairs(entries) do
      pending.updates[name] = false
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
      local resolved = type(value) == "table"
          and vim.tbl_deep_extend("force", {}, base or {}, value)
        or base
      validation.validate(name, resolved, true)
      pending.matches[name] = { filetypes = vim.deepcopy(resolved.filetypes) }
    end
    pending.updates[name] = vim.deepcopy(value)
  end
  return pending
end

function M.apply(pending)
  local stop = {}
  for name, value in pairs(pending.updates) do
    if type(value) == "table" then
      vim.lsp.config(name, value)
    end
    if value == false then
      waiting[name] = nil
      if owned[name] then
        stop[#stop + 1] = name
      end
    elseif not vim.lsp.is_enabled(name) then
      waiting[name] = pending.matches[name]
    else
      waiting[name] = nil
    end
  end
  table.sort(stop)
  if #stop > 0 then
    vim.lsp.enable(stop, false)
    -- Some 0.12 builds only stop initialized clients in enable(false).
    -- Include in-flight clients so a disabled server cannot attach afterwards.
    for _, name in ipairs(stop) do
      for _, client in ipairs(vim.lsp.get_clients({ name = name, _uninitialized = true })) do
        if not client.initialized and not client:is_stopped() then
          client:stop(true)
        end
      end
    end
  end
  for _, name in ipairs(stop) do
    owned[name] = nil
  end
  for name, value in pairs(pending.updates) do
    if type(value) == "table" and type(entries[name]) == "table" then
      entries[name] = vim.tbl_deep_extend("force", entries[name], value)
    else
      entries[name] = value
    end
  end
  activation = pending.activation
  if activation == "eager" then
    enable(vim.tbl_keys(waiting))
  else
    watch()
    -- setup can run after FileType, including explicit commands and key loads.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if not next(waiting) then
        break
      end
      if vim.api.nvim_buf_is_loaded(buf) then
        M.activate(buf)
      end
    end
  end
end

function M.configuration()
  return vim.deepcopy(entries), vim.deepcopy(owned), activation, vim.deepcopy(waiting)
end

return M
