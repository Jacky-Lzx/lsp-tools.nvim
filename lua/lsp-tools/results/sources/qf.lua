local M = {}
local api = vim.api
local severities = { E = 1, W = 2, I = 3, H = 4, N = 4 }
local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end
local function version(list)
  return table.concat({ list.id or 0, list.changedtick or 0, list.idx or 0, list.title or "" }, ":")
end
function M.open(results, opts, local_list)
  local ctx = opts.context or require("lsp-tools.request").context()
  local owner = opts.winid or ctx.win
  if local_list and opts.winid and api.nvim_win_is_valid(owner) then
    ctx = api.nvim_win_call(owner, require("lsp-tools.request").context)
  end
  assert(
    opts.poll_interval == nil or type(opts.poll_interval) == "number" and opts.poll_interval > 0,
    "poll_interval must be positive"
  )
  local id = opts.id or (local_list and "loclist" or "qflist")
  local function read()
    if local_list and not api.nvim_win_is_valid(owner) then
      return nil
    end
    local ok, value = pcall(function()
      return local_list and vim.fn.getloclist(owner, { all = true })
        or vim.fn.getqflist({ all = true })
    end)
    return ok and value or nil
  end
  local function project(entry)
    local col = math.max(0, (entry.col or 1) - 1)
    if
      entry.vcol == 1
      and entry.bufnr
      and api.nvim_buf_is_loaded(entry.bufnr)
      and entry.lnum > 0
    then
      local line = api.nvim_buf_get_lines(entry.bufnr, entry.lnum - 1, entry.lnum, false)[1] or ""
      local visual, byte = 0, 0
      for char in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local width = char == "\t"
            and (vim.bo[entry.bufnr].tabstop - visual % vim.bo[entry.bufnr].tabstop)
          or vim.fn.strdisplaywidth(char)
        if visual + width > col then
          break
        end
        visual, byte = visual + width, byte + #char
      end
      col = byte
    end
    return col
  end
  local function refresh(v)
    local list = read()
    if not list then
      v.status = "Source window closed; location-list snapshot retained"
      results.render(v)
      return
    end
    local first = v.native_list == nil
    v.native_list, v.native_version = list, version(list)
    v.title = (local_list and "Location List" or "Quickfix")
      .. (list.title and list.title ~= "" and " · " .. list.title or "")
    v.status = nil
    local items = {}
    for index, entry in ipairs(list.items or {}) do
      local valid = entry.valid == 1
      items[#items + 1] = {
        id = (local_list and "loc:" or "qf:")
          .. (list.id or 0)
          .. ":"
          .. index
          .. ":"
          .. (entry.text or ""),
        bufnr = valid and entry.bufnr ~= 0 and entry.bufnr or nil,
        filename = valid and entry.filename or nil,
        pos = { math.max(1, entry.lnum or 1), project(entry) },
        end_pos = {
          math.max(1, entry.end_lnum or entry.lnum or 1),
          math.max(0, (entry.end_col or entry.col or 1) - 1),
        },
        text = entry.text or "",
        severity = severities[entry.type],
        source = local_list and "loclist" or "quickfix",
        data = {
          native_index = index,
          entry = entry,
          valid = valid,
          list_id = list.id,
          changedtick = list.changedtick,
        },
      }
    end
    results.set_items(v, items)
    if (first or opts.follow) and items[list.idx] then
      results.select(v, items[list.idx].id)
    end
  end
  local options = vim.tbl_deep_extend(
    "force",
    { id = id, title = local_list and "Location List" or "Quickfix", group_by = {}, sort = "none" },
    opts
  )
  options.context, options.refresh = ctx, refresh
  options.validate = function(item)
    local list = read()
    return item.data.valid
      and list
      and list.id == item.data.list_id
      and list.changedtick == item.data.changedtick
  end
  options.on_jump = function(item, v, destination)
    local command = local_list and "ll" or "cc"
    if local_list and destination == "current" then
      api.nvim_set_current_win(owner)
    end
    -- A split inherits a copy of its owner's location list. Let the native jump
    -- resolve visual columns and search patterns in that destination window.
    local switchbuf = vim.o.switchbuf
    if destination ~= "current" then
      vim.o.switchbuf = ""
    end
    local ok, err = pcall(function()
      vim.cmd[command]({ args = { tostring(item.data.native_index) } })
    end)
    vim.o.switchbuf = switchbuf
    if not ok then
      error(err)
    end
    if local_list and destination ~= "current" then
      vim.fn.setloclist(owner, {}, "a", { id = item.data.list_id, idx = item.data.native_index })
      refresh(v)
    end
    return true
  end
  options.watch = function(v)
    local timer = assert(vim.uv.new_timer())
    timer:start(
      opts.poll_interval or 150,
      opts.poll_interval or 150,
      vim.schedule_wrap(function()
        if not require("lsp-tools.panel").alive(v) or v.pinned then
          return
        end
        local list = read()
        if list and version(list) ~= v.native_version then
          results.schedule(v)
        end
      end)
    )
    api.nvim_create_autocmd({ "QuickFixCmdPost", "CmdlineLeave", "BufEnter" }, {
      group = v.group,
      callback = function()
        results.schedule(v)
      end,
    })
    if local_list then
      api.nvim_create_autocmd("WinClosed", {
        group = v.group,
        pattern = tostring(owner),
        callback = function()
          stop(timer)
          v.status = "Source window closed; location-list snapshot retained"
          results.render(v)
        end,
      })
    end
    return function()
      stop(timer)
    end
  end
  local v = results.open({}, options)
  if v then
    refresh(v)
  end
  return v
end
return M
