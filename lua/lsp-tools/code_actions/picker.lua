local M = {}
local active = {}
local function notify(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "Code Actions" })
end

function M.open(actions, opts, on_choice, config, on_applied)
  local closed, generation, confirming = false, 0, false
  local picker
  local stop_render = function() end
  local items, pending = {}, {}
  for i, entry in ipairs(actions) do
    local buf = entry.ctx.bufnr
    items[i] = {
      text = opts.format_item(entry),
      entry = entry,
      root = require("lsp-tools.code_actions.preview").root(
        buf,
        vim.lsp.get_client_by_id(entry.ctx.client_id)
      ),
      tick = vim.api.nvim_buf_get_changedtick(buf),
    }
  end

  local function resolve(item, callback)
    if item.resolved then
      return callback(item.resolved)
    end
    if item.waiters then
      table.insert(item.waiters, callback)
      return
    end
    local entry = item.entry
    local client = vim.lsp.get_client_by_id(entry.ctx.client_id)
    if not client then
      return callback(nil, "Language server disconnected")
    end
    local action = entry.action
    if action.disabled then
      return callback(nil, action.disabled.reason)
    end
    if
      type(action.command) == "string"
      or (action.edit and action.command)
      or not client:supports_method("codeAction/resolve")
    then
      item.resolved = action
      return callback(action)
    end
    item.waiters = { callback }
    local done = false
    local request_id
    local function finish(err, result)
      if done then
        return
      end
      done = true
      pending[item] = nil
      local waiters = item.waiters
      item.waiters = nil
      if closed then
        return
      end
      -- Like native code_action, preserve an executable original action if
      -- optional resolution fails. Actions without an edit/command stay open.
      local fallback = err and (action.edit or action.command)
      item.resolved = (not err or fallback) and (result or action) or nil
      for _, waiter in ipairs(waiters) do
        waiter(item.resolved, not item.resolved and err and (err.message or tostring(err)))
      end
    end
    local sent
    sent, request_id =
      client:request("codeAction/resolve", vim.deepcopy(action), finish, entry.ctx.bufnr)
    if not sent then
      finish({ message = "Could not send codeAction/resolve" })
      return
    end
    if not done then
      pending[item] = { client = client, id = request_id }
      vim.defer_fn(function()
        if not done then
          client:cancel_request(request_id)
          finish({ message = "Code action resolution timed out" })
        end
      end, config.resolve_timeout)
    end
  end

  local function close()
    closed = true
    active[close] = nil
    generation = generation + 1
    stop_render()
    for _, request in pairs(pending) do
      request.client:cancel_request(request.id)
    end
    pending = {}
  end

  local options = vim.tbl_deep_extend("force", {
    title = "Code Actions",
    items = items,
    format = "text",
    layout = { preset = "default", preview = true },
    win = {
      input = {
        keys = {
          ["<CR>"] = { "confirm", mode = { "n", "i" } },
          ["<Esc>"] = { "close", mode = { "n", "i" } },
        },
      },
      list = { keys = { ["<CR>"] = "confirm", ["<Esc>"] = "close" } },
    },
  }, config.picker)
  options.preview = function(ctx)
    generation = generation + 1
    stop_render()
    local current = generation
    local item = ctx.item
    if not item then
      return
    end
    ctx.preview:reset()
    ctx.preview:set_title("Preview")
    ctx.preview:set_lines({ "Resolving code action…" })
    resolve(item, function(action, err)
      vim.schedule(function()
        if closed or current ~= generation or ctx.picker:current() ~= item then
          return
        end
        local ok, lines = pcall(
          require("lsp-tools.code_actions.preview").lines,
          action or {},
          (vim.lsp.get_client_by_id(item.entry.ctx.client_id) or {}).offset_encoding or "utf-16",
          item.root
        )
        stop_render = require("lsp-tools.code_actions.render").start(
          ctx,
          err and { err } or ok and lines or { "Preview unavailable: " .. tostring(lines) },
          config,
          function()
            return not closed and current == generation and ctx.picker:current() == item
          end
        )
      end)
    end)
  end
  options.confirm = function(picker, item)
    if not item or confirming then
      return
    end
    confirming = true
    resolve(item, function(action, err)
      vim.schedule(function()
        confirming = false
        if closed then
          return
        end
        if err then
          notify(err)
          return
        end
        local entry = item.entry
        local client = vim.lsp.get_client_by_id(entry.ctx.client_id)
        if not client or not vim.api.nvim_buf_is_valid(entry.ctx.bufnr) then
          notify("The language server or original buffer is no longer available")
          return
        end
        if vim.api.nvim_buf_get_changedtick(entry.ctx.bufnr) ~= item.tick then
          notify("The buffer changed. Request code actions again before applying.")
          return
        end
        close()
        picker:close()
        -- Apply the cached resolved action, avoiding a second resolve request.
        -- Native code_action still owns requests, ranges, diagnostics and filters.
        local ok, problem = pcall(function()
          if action.disabled then
            error(action.disabled.reason)
          end
          if action.edit then
            vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
          end
          if action.command then
            client:exec_cmd(type(action.command) == "table" and action.command or action, entry.ctx)
          end
        end)
        if not ok then
          notify(tostring(problem))
        elseif on_applied then
          on_applied(action, entry.ctx)
        end
      end)
    end)
  end
  options.on_close = function()
    if not closed then
      close()
      on_choice(nil)
    end
  end
  picker = require("snacks.picker").pick(options)
  if not closed then
    active[close] = function()
      picker:close()
    end
  end
  return picker
end

function M.disable()
  for _, stop in ipairs(vim.tbl_values(active)) do
    stop()
  end
end

return M
