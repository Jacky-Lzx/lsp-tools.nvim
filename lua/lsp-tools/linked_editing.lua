local M = {}
local sessions = {}
local method = "textDocument/linkedEditingRange"
local request = require("lsp-tools.request")
local enabled, setup_group = false, nil
local config = { request_timeout = 1500 }

-- A repeated character class covers common HTML/XML and TeX providers. Other
-- ECMAScript expressions need an explicit validator, not a lossy regex guess.
local function validator(pattern)
  if config.validate then
    return function(text)
      return config.validate(text, pattern)
    end
  end
  if not pattern then
    return function(text)
      return not text:find("[^%w_%-]")
    end
  end
  local body = pattern:gsub("^%^", ""):gsub("%$$", "")
  if not body:match("^%[.*%][*+]$") then
    return nil
  end
  local class = body:sub(2, -3)
  if class:find("%]") or class:find("\\[pPuUxXbB]") then
    return nil
  end
  class = class:gsub("\\s", "[:space:]"):gsub("\\w", "[:alnum:]_"):gsub("\\d", "[:digit:]")
  local ok, regex = pcall(vim.regex, "\\m^[" .. class .. "]*$")
  if not ok then
    return nil
  end
  return function(text)
    return regex:match_str(text) ~= nil
  end
end

function M.attach(client, bufnr)
  if not enabled or not client:supports_method(method, bufnr) then
    return
  end
  if vim.lsp.linked_editing_range then
    vim.lsp.linked_editing_range.enable(false, { client_id = client.id, bufnr = bufnr })
  end
  if sessions[bufnr] then
    if sessions[bufnr].client == client then
      return
    end
    sessions[bufnr].detach()
  end

  local ns = vim.api.nvim_create_namespace("lsp-tools.linked_editing:" .. client.id .. ":" .. bufnr)
  local group = vim.api.nvim_create_augroup("LspToolsLinkedEditing" .. bufnr, { clear = true })
  local state = { client = client, ids = {}, generation = 0 }
  sessions[bufnr] = state

  local function clear()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
    state.ids = {}
  end

  local function range(id)
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
    if #mark == 0 then
      return
    end
    return { mark[1], mark[2], mark[3].end_row, mark[3].end_col }
  end

  local function refresh()
    state.generation = state.generation + 1
    local generation = state.generation
    if state.pending then
      state.pending.cancel()
      state.pending = nil
    end
    if vim.api.nvim_get_current_buf() ~= bufnr then
      clear()
      return
    end
    local ctx = request.context()
    state.pending = request.start({
      buf = bufnr,
      method = method,
      clients = { client },
      timeout = config.request_timeout,
      params = function()
        return request.position(ctx, client)
      end,
    }, function(results)
      if
        sessions[bufnr] ~= state
        or generation ~= state.generation
        or not request.valid(ctx, true)
      then
        return
      end
      state.pending = nil
      local response = results[1]
      local result = response and not response.error and response.result
      clear()
      if not result or result == vim.NIL or not result.ranges then
        return
      end
      state.validate = validator(result.wordPattern)
      if not state.validate then
        if not state.warned then
          state.warned = true
          vim.notify(
            "Unsupported linked-editing wordPattern; configure linked_editing.validate",
            vim.log.levels.WARN
          )
        end
        return
      end
      local ok, ranges = pcall(function()
        local sorted = {}
        for _, item in ipairs(result.ranges) do
          local first = request.byte(bufnr, item.start, client.offset_encoding)
          local last = request.byte(bufnr, item["end"], client.offset_encoding)
          assert(first[1] == last[1] and first[2] <= last[2], "Linked ranges must be single-line")
          sorted[#sorted + 1] = { first[1], first[2], last[1], last[2] }
        end
        table.sort(sorted, function(a, b)
          return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
        end)
        local previous, text
        for _, r in ipairs(sorted) do
          assert(
            not previous or previous[3] < r[1] or previous[3] == r[1] and previous[4] < r[2],
            "Overlapping linked ranges"
          )
          local current =
            table.concat(vim.api.nvim_buf_get_text(bufnr, r[1], r[2], r[3], r[4], {}), "\n")
          assert(not text or text == current, "Linked ranges must have identical text")
          previous, text = r, current
        end
        return sorted
      end)
      if not ok or #ranges < 2 then
        return
      end
      for i, r in ipairs(ranges) do
        state.ids[i] = vim.api.nvim_buf_set_extmark(bufnr, ns, r[1], r[2], {
          end_row = r[3],
          end_col = r[4],
          right_gravity = false,
          end_right_gravity = true,
          hl_group = "LspReferenceTarget",
        })
      end
    end)
  end

  local function update()
    if #state.ids < 2 or vim.api.nvim_get_current_buf() ~= bufnr then
      return
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]
    local active
    for i, id in ipairs(state.ids) do
      local current = range(id)
      if
        current
        and (row > current[1] or row == current[1] and col >= current[2])
        and (row < current[3] or row == current[3] and col <= current[4])
      then
        active = i
        break
      end
    end
    if not active then
      return
    end
    local edited = range(state.ids[active])
    if not edited then
      clear()
      return
    end
    local replacement =
      vim.api.nvim_buf_get_text(bufnr, edited[1], edited[2], edited[3], edited[4], {})
    if #replacement ~= 1 or not state.validate(replacement[1]) then
      clear()
      return
    end
    for i, id in ipairs(state.ids) do
      if i ~= active then
        local target = range(id)
        if target then
          local text =
            vim.api.nvim_buf_get_text(bufnr, target[1], target[2], target[3], target[4], {})
          if not vim.deep_equal(text, replacement) then
            -- An undo must restore its own complete edit without being mirrored.
            if not pcall(vim.cmd.undojoin) then
              return
            end
            vim.api.nvim_buf_set_text(
              bufnr,
              target[1],
              target[2],
              target[3],
              target[4],
              replacement
            )
          end
        end
      end
    end
  end

  state.detach = function()
    state.generation = state.generation + 1
    if state.pending then
      state.pending.cancel()
    end
    clear()
    vim.api.nvim_del_augroup_by_id(group)
    sessions[bufnr] = nil
  end
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      update()
      refresh()
    end,
  })
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "BufEnter" },
    { group = group, buffer = bufnr, callback = refresh }
  )
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    buffer = bufnr,
    callback = function(event)
      if event.data.client_id == client.id then
        state.detach()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      state.generation = state.generation + 1
      if state.pending then
        state.pending.cancel()
        state.pending = nil
      end
      clear()
    end,
  })
  vim.api.nvim_create_autocmd(
    "BufWipeout",
    { group = group, buffer = bufnr, callback = state.detach }
  )
  refresh()
end

function M.disable()
  enabled = false
  for _, state in pairs(vim.tbl_extend("force", {}, sessions)) do
    state.detach()
  end
  if setup_group then
    vim.api.nvim_del_augroup_by_id(setup_group)
    setup_group = nil
  end
end

function M.setup(opts)
  local next_config = vim.tbl_extend("force", config, opts or {})
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  assert(
    next_config.validate == nil or type(next_config.validate) == "function",
    "validate must be a function"
  )
  M.disable()
  config, enabled = next_config, true
  local function attach(buf)
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
      return
    end
    local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
    table.sort(clients, function(a, b)
      return a.id < b.id
    end)
    if clients[1] then
      M.attach(clients[1], buf)
    end
  end
  setup_group = vim.api.nvim_create_augroup("LspToolsLinkedEditingAttach", { clear = true })
  vim.api.nvim_create_autocmd({ "LspAttach", "BufEnter" }, {
    group = setup_group,
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = setup_group,
    callback = function(ev)
      vim.schedule(function()
        if enabled then
          attach(ev.buf)
        end
      end)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    attach(buf)
  end
end

return M
