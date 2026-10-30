local M = {}
local request = require("lsp-tools.request")
local panel = require("lsp-tools.panel")
local config = { width = 0.4, request_timeout = 3000, debounce = 200, follow_cursor = false }
local enabled = false
local sessions = {}
local refresh

local function cancel(s)
  if s.pending then
    s.pending.cancel()
    s.pending = nil
  end
  if s.timer then
    s.timer:stop()
    s.timer:close()
    s.timer = nil
  end
end

local function source_context(s)
  if not vim.api.nvim_win_is_valid(s.ctx.win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(s.ctx.win)
  if vim.bo[buf].buftype ~= "" then
    return
  end
  return vim.api.nvim_win_call(s.ctx.win, request.context)
end

local function write(s, content, status)
  local ctx = s.ctx
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(ctx.buf), ":~:.")
  local lines = {
    "# Pinned LSP documentation",
    "",
    ("Source: %s:%d:%d"):format(name, ctx.pos[1], ctx.pos[2] + 1),
    "r refresh · f toggle follow · y copy · gx open link · b source · q close",
    "Follow cursor: " .. (s.follow and "on" or "off"),
    "",
  }
  if status then
    lines[#lines + 1] = status
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, content or {})
  panel.write(s, lines)
end

refresh = function(s)
  cancel(s)
  local ctx = source_context(s)
  if not ctx or not panel.alive(s) then
    return false
  end
  s.ctx = ctx
  write(s, s.content, "Loading…")
  s.pending = request.start({
    buf = ctx.buf,
    method = "textDocument/hover",
    timeout = config.request_timeout,
    params = function(client)
      return request.position(ctx, client)
    end,
  }, function(results)
    if not panel.alive(s) then
      return
    end
    if not request.valid(ctx, s.follow, true) then
      write(s, s.content, "Source changed; press r to refresh")
      return
    end
    local lines = {}
    table.sort(results, function(a, b)
      return a.client.id < b.client.id
    end)
    for _, response in ipairs(results) do
      local result = response.result
      if not response.error and result and result.contents then
        local ok, content = pcall(vim.lsp.util.convert_input_to_markdown_lines, result.contents)
        if ok and #content > 0 then
          lines[#lines + 1] = "## " .. (response.client.name or tostring(response.client.id))
          lines[#lines + 1] = ""
          vim.list_extend(lines, content)
          lines[#lines + 1] = ""
        end
      end
    end
    s.content = lines
    write(
      s,
      lines,
      #lines == 0
          and "No hover documentation (inspect clients for capabilities or request failures)"
        or nil
    )
  end)
  return true
end

function M.open(opts)
  if not enabled then
    return false
  end
  opts = opts or {}
  local existing = panel.get("hover")
  if existing and vim.api.nvim_get_current_win() == existing.win then
    return existing
  end
  if vim.bo.buftype ~= "" then
    return false
  end
  local s = panel.open(
    "hover",
    request.context(),
    { width = config.width, filetype = "markdown", focus = opts.focus ~= false }
  )
  s.follow = opts.follow_cursor == nil and config.follow_cursor or opts.follow_cursor
  sessions[s] = true
  s.on_close = function()
    cancel(s)
    sessions[s] = nil
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = s.out, desc = desc })
  end
  map("r", function()
    refresh(s)
  end, "Refresh pinned documentation")
  map("f", function()
    s.follow = not s.follow
    if s.follow then
      refresh(s)
    else
      cancel(s)
      write(s, s.content)
    end
  end, "Toggle documentation following")
  map("b", function()
    panel.source(s, true)
  end, "Return to documentation source")
  map("y", function()
    vim.fn.setreg('"', table.concat(s.content or {}, "\n"))
    vim.notify("Documentation copied to unnamed register")
  end, "Copy pinned documentation")
  map("gx", function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(s.win)[2] + 1
    local links = {}
    for first, url, last in line:gmatch("()%b[]%((.-)%)()") do
      links[#links + 1] = { first, last, url }
    end
    for first, url, last in line:gmatch("()(https?://[^%s<>%)]+)()") do
      links[#links + 1] = { first, last, url }
    end
    for _, link in ipairs(links) do
      if col >= link[1] and col < link[2] then
        vim.ui.open(link[3])
        return
      end
    end
    vim.notify("No documentation link at the cursor", vim.log.levels.INFO)
  end, "Open documentation link")
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "BufEnter" },
    {
      group = s.group,
      callback = function()
        if
          not s.follow
          or not panel.alive(s)
          or vim.api.nvim_get_current_win() ~= s.ctx.win
          or vim.bo.buftype ~= ""
        then
          return
        end
        cancel(s)
        s.timer = assert(vim.uv.new_timer())
        s.timer:start(
          config.debounce,
          0,
          vim.schedule_wrap(function()
            if panel.alive(s) and s.follow then
              refresh(s)
            end
          end)
        )
      end,
    }
  )
  vim.api.nvim_create_autocmd("LspDetach", {
    group = s.group,
    callback = function(ev)
      if ev.buf == s.ctx.buf then
        cancel(s)
        write(s, s.content, "Language server detached; press r to refresh")
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = s.group,
    callback = function(ev)
      if ev.buf == s.ctx.buf and s.pending and s.pending.active then
        cancel(s)
        write(s, s.content, "Source hidden; press r to refresh")
      end
    end,
  })
  refresh(s)
  return s
end

function M.disable()
  enabled = false
  for s in pairs(vim.tbl_extend("force", {}, sessions)) do
    panel.close(s)
  end
end

function M.setup(opts)
  local next_config = vim.tbl_extend("force", config, opts or {})
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  assert(
    type(next_config.debounce) == "number" and next_config.debounce >= 0,
    "debounce must be nonnegative"
  )
  M.disable()
  config, enabled = next_config, true
end

return M
