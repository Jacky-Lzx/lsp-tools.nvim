local M = {}
local preview = require("lsp-tools.code_actions.preview")
local render = require("lsp-tools.code_actions.render")
local workspace = require("lsp-tools.workspace_edit")
local config = {
  request_timeout = 3000,
  backend = "vim",
  delta = { command = "delta", args = {}, timeout = 2000 },
  picker = {},
}
local enabled = false
local active, group

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "LSP Rename" })
end

local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function close(token, from_picker)
  if token.closed then
    return
  end
  token.closed = true
  if active == token then
    active = nil
  end
  if token.pending then
    local pending = token.pending
    token.pending = nil
    stop(pending.timer)
    pending.done = true
    if pending.id then
      pending.client:cancel_request(pending.id)
    end
  end
  if token.stop_render then
    token.stop_render()
  end
  if token.picker and not from_picker then
    token.picker:close()
  end
end

local function source_valid(token, position)
  return enabled
    and active == token
    and not token.closed
    and vim.api.nvim_buf_is_valid(token.buf)
    and vim.api.nvim_win_is_valid(token.win)
    and vim.api.nvim_win_get_buf(token.win) == token.buf
    and vim.api.nvim_buf_get_changedtick(token.buf) == token.tick
    and (not position or vim.deep_equal(vim.api.nvim_win_get_cursor(token.win), token.cursor))
end

local function connected(token)
  return token.client and vim.lsp.get_client_by_id(token.client.id) == token.client
end

local function fail(token, message)
  if not token.closed then
    close(token)
    notify(message)
  end
end

local function request(token, method, params, callback)
  if not source_valid(token, true) or not connected(token) then
    fail(token, "The source position, buffer, or language server changed. Request rename again.")
    return
  end
  local pending = { client = token.client }
  token.pending = pending
  local function response(err, result)
    if pending.done or token.closed then
      return
    end
    pending.done = true
    stop(pending.timer)
    token.pending = nil
    vim.schedule(function()
      if token.closed then
        return
      end
      if not source_valid(token, true) or not connected(token) then
        fail(
          token,
          "The source position, buffer, or language server changed. Request rename again."
        )
      elseif err then
        fail(
          token,
          method .. ": " .. tostring(type(err) == "table" and (err.message or err) or err)
        )
      else
        callback(result)
      end
    end)
  end
  local sent, id = token.client:request(method, params, response, token.buf)
  pending.id = id
  if not sent then
    response({ message = "Could not send request" })
  elseif not pending.done then
    pending.timer = vim.defer_fn(function()
      if not pending.done and not token.closed then
        fail(token, method .. " timed out")
      end
    end, config.request_timeout)
  end
end

local function show(token, edit, baseline)
  if edit == nil or edit == vim.NIL then
    close(token)
    notify("The language server returned no rename changes")
    return
  end
  local ok, data =
    pcall(workspace.capture, edit, token.client.offset_encoding, token.root, baseline)
  if not ok then
    fail(token, "Cannot preview rename: " .. tostring(data))
    return
  end
  if #data.items == 0 then
    close(token)
    notify("The language server returned no rename changes")
    return
  end
  token.stage = "preview"
  local generation = 0
  local options = vim.tbl_deep_extend("force", {
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
  -- Collection, preview, and application are always owned by this module.
  options.title = ("Rename to %s · %d %s · %d %s%s · Enter applies all"):format(
    token.new_name,
    data.files,
    data.operations > 0 and (data.files == 1 and "path" or "paths")
      or (data.files == 1 and "file" or "files"),
    data.edits,
    data.edits == 1 and "edit" or "edits",
    data.operations > 0 and (" · %d file operations"):format(data.operations) or ""
  )
  options.items = data.items
  options.preview = function(ctx)
    generation = generation + 1
    if token.stop_render then
      token.stop_render()
    end
    if not ctx.item then
      return
    end
    local current, item = generation, ctx.item
    token.stop_render = render.start(ctx, item.lines, config, function()
      return not token.closed and generation == current and ctx.picker:current() == item
    end)
  end
  options.confirm = function(picker)
    if token.closed or not picker:current() then
      return
    end
    local valid, problem = pcall(function()
      assert(
        source_valid(token, false) and connected(token),
        "The source buffer/window or language server changed"
      )
      data.validate()
    end)
    if not valid then
      notify(tostring(problem) .. ". Request rename again before applying.")
      return
    end
    -- Enter confirms the full displayed edit, including all described annotations.
    local applied = vim.deepcopy(data.edit)
    for _, annotation in pairs(applied.changeAnnotations or {}) do
      annotation.needsConfirmation = false
    end
    local function approved(edits)
      for _, edit in ipairs(edits) do
        edit.annotationId = nil -- Already reviewed; avoid native per-file prompts/announcements.
      end
    end
    if applied.documentChanges then
      for _, change in ipairs(applied.documentChanges) do
        if change.textDocument then
          if change.textDocument.version == nil then
            change.textDocument.version = vim.NIL
          end
          approved(change.edits)
        end
      end
    else
      for _, edits in pairs(applied.changes or {}) do
        approved(edits)
      end
    end
    close(token)
    local success, err =
      pcall(vim.lsp.util.apply_workspace_edit, applied, token.client.offset_encoding)
    if not success then
      notify("Rename could not be fully applied: " .. tostring(err))
    end
  end
  options.on_close = function()
    close(token, true)
  end
  local opened, picker = pcall(function()
    return require("snacks.picker").pick(options)
  end)
  if not opened then
    fail(token, "Cannot open rename preview: " .. tostring(picker))
  elseif not token.closed then
    token.picker = picker
  end
end

local function rename(token, new_name)
  if token.closed then
    return
  end
  if new_name == nil or new_name == "" or new_name == token.original then
    close(token)
    return
  end
  if not source_valid(token, true) then
    fail(token, "The source position or buffer changed. Request rename again.")
    return
  end
  token.new_name = new_name
  token.stage = "request"
  local baseline = workspace.baseline()
  local params = vim.deepcopy(token.params)
  params.newName = new_name
  request(token, "textDocument/rename", params, function(edit)
    show(token, edit, baseline)
  end)
end

local function input(token, default, new_name)
  if new_name then
    rename(token, new_name)
  else
    token.stage = "input"
    vim.ui.input({ prompt = "Rename to: ", default = default, scope = "cursor" }, function(value)
      rename(token, value)
    end)
  end
end

local function prepare(token, new_name)
  token.root = preview.root(token.buf, token.client)
  token.params = vim.lsp.util.make_position_params(token.win, token.client.offset_encoding)
  if not token.client:supports_method("textDocument/prepareRename", token.buf) then
    input(token, token.original, new_name)
    return
  end
  request(token, "textDocument/prepareRename", token.params, function(result)
    if result == nil or result == vim.NIL then
      fail(token, "Nothing to rename at the cursor")
      return
    end
    if type(result) ~= "table" then
      fail(token, "Invalid prepareRename response")
      return
    end
    local range = result.range or result.start and result
    local default = token.original
    if range then
      local ok, text = pcall(function()
        local function byte(pos)
          local line = vim.api.nvim_buf_get_lines(token.buf, pos.line, pos.line + 1, false)[1]
          return vim.str_byteindex(line, token.client.offset_encoding, pos.character, false)
        end
        return table.concat(
          vim.api.nvim_buf_get_text(
            token.buf,
            range.start.line,
            byte(range.start),
            range["end"].line,
            byte(range["end"]),
            {}
          ),
          "\n"
        )
      end)
      if not ok then
        fail(token, "Invalid prepareRename range: " .. tostring(text))
        return
      end
      token.original = text
      default = text
    end
    if type(result.placeholder) == "string" then
      default = result.placeholder
    end
    input(token, default, new_name)
  end)
end

---Preview a symbol rename. Multiple providers are selected explicitly, never merged.
---@param new_name? string
---@param opts? {bufnr?: integer, name?: string, filter?: fun(client: table): boolean}
function M.rename(new_name, opts)
  assert(new_name == nil or type(new_name) == "string", "new_name must be a string")
  opts = opts or {}
  if not enabled then
    notify("Rename preview is disabled")
    return
  end
  M.cancel()
  local buf = opts.bufnr and opts.bufnr ~= 0 and opts.bufnr or vim.api.nvim_get_current_buf()
  if buf ~= vim.api.nvim_get_current_buf() or vim.bo[buf].buftype ~= "" then
    notify("Rename requires the current file buffer")
    return
  end
  local clients =
    vim.lsp.get_clients({ bufnr = buf, name = opts.name, method = "textDocument/rename" })
  if opts.filter then
    clients = vim.tbl_filter(opts.filter, clients)
  end
  if #clients == 0 then
    notify("No matching language server supports rename")
    return
  end
  table.sort(clients, function(a, b)
    return a.id < b.id
  end)
  local token = {
    buf = buf,
    win = vim.api.nvim_get_current_win(),
    tick = vim.api.nvim_buf_get_changedtick(buf),
    cursor = vim.api.nvim_win_get_cursor(0),
    original = vim.fn.expand("<cword>"),
    stage = "prepare",
  }
  active = token
  local function use(client)
    if token.closed then
      return
    end
    if not client then
      close(token)
      return
    end
    if not source_valid(token, true) or vim.lsp.get_client_by_id(client.id) ~= client then
      fail(token, "The source position or language server changed. Request rename again.")
      return
    end
    token.client = client
    prepare(token, new_name)
  end
  if #clients == 1 then
    use(clients[1])
  else
    vim.ui.select(clients, {
      prompt = "Rename with:",
      format_item = function(client)
        return ("%s (#%d)"):format(client.name, client.id)
      end,
    }, use)
  end
end

function M.cancel()
  if active then
    close(active)
  end
end

function M.disable()
  enabled = false
  M.cancel()
  if group then
    vim.api.nvim_clear_autocmds({ group = group })
  end
end

function M.setup(opts)
  local next_config = vim.tbl_deep_extend("force", config, opts or {})
  render.validate(next_config)
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  M.disable()
  config, enabled = next_config, true
  group = vim.api.nvim_create_augroup("LspToolsRename", { clear = true })
  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "TextChanged",
    "TextChangedI",
    "BufWipeout",
    "LspDetach",
    "WinClosed",
  }, {
    group = group,
    callback = function(event)
      local token = active
      if not token then
        return
      end
      local detached = event.event == "LspDetach"
        and token.client
        and event.data.client_id == token.client.id
      if
        detached
        or not vim.api.nvim_win_is_valid(token.win)
        or not vim.api.nvim_buf_is_valid(token.buf)
      then
        close(token)
      elseif token.stage ~= "preview" and not source_valid(token, true) then
        close(token)
      end
    end,
  })
end

return M
