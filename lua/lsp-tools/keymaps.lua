local M = {}
local api = vim.api
local defaults = { key_prefix = "<LocalLeader>", keymaps = {} }
local shared = vim.deepcopy(defaults)
function M.validate(opts)
  assert(type(opts) == "table", "UI options must be a table")
  if opts.key_prefix ~= nil then
    assert(
      type(opts.key_prefix) == "string" and opts.key_prefix ~= "",
      "key_prefix must be a nonempty string"
    )
  end
  if opts.keymaps ~= nil then
    assert(type(opts.keymaps) == "table", "keymaps must be an action table")
    for action, keys in pairs(opts.keymaps) do
      assert(type(action) == "string", "keymap action names must be strings")
      assert(
        keys == false or type(keys) == "string" or type(keys) == "table" and vim.islist(keys),
        "action keys must be a string, list, or false"
      )
      if type(keys) == "table" then
        for _, key in ipairs(keys) do
          assert(type(key) == "string", "action keys must contain strings")
        end
      end
    end
  end
end
function M.configure(opts)
  M.validate(opts)
  shared = vim.tbl_deep_extend("force", vim.deepcopy(defaults), vim.deepcopy(opts))
end
function M.config()
  return vim.deepcopy(shared)
end
function M.label(lhs)
  lhs = lhs
    :gsub("<[Ll]ocal[Ll]eader>", function()
      return vim.g.maplocalleader or "\\"
    end)
    :gsub("<[Ll]eader>", function()
      return vim.g.mapleader or "\\"
    end)
  return vim.fn.keytrans(vim.keycode(lhs))
end
function M.new(buf, opts)
  opts = opts or {}
  local self = { buf = buf, entries = {}, actions = {}, options = opts }
  function self:resolve(action, default)
    local value = (self.options.keymaps or {})[action]
    if value == nil then
      value = shared.keymaps[action]
    end
    if value == nil then
      value = default
    end
    if value == false then
      return {}
    end
    if type(value) == "string" then
      value = { value }
    end
    return vim.tbl_map(function(key)
      return (
        key:gsub("<prefix>", function()
          return self.options.key_prefix or shared.key_prefix
        end)
      )
    end, value or {})
  end
  function self:map(action, default, callback, desc)
    for _, lhs in ipairs(self.actions[action] or {}) do
      local label = M.label(lhs)
      if self.entries[label] and self.entries[label].action == action then
        pcall(vim.keymap.del, "n", lhs, { buffer = self.buf })
        self.entries[label] = nil
      end
    end
    local keys = self:resolve(action, default)
    self.actions[action] = keys
    for _, lhs in ipairs(keys) do
      local label = M.label(lhs)
      local previous = self.entries[label]
      if previous and previous.action ~= action then
        self.actions[previous.action] = vim.tbl_filter(function(key)
          return M.label(key) ~= label
        end, self.actions[previous.action] or {})
      end
      vim.keymap.set(
        "n",
        lhs,
        callback,
        { buffer = self.buf, silent = true, desc = desc or action }
      )
      self.entries[label] = { lhs = label, desc = desc or action, action = action }
    end
    return keys
  end
  function self:legacy(lhs, callback, desc, kind)
    local action = ({
      r = "refresh",
      f = "follow",
      b = "return_source",
      y = "copy",
      gx = "open_link",
      a = "fix",
      A = "fix_next",
      p = "preview",
      g = "callsite",
      d = "direction",
      h = "collapse",
      l = "expand",
      ["<Tab>"] = "expand",
      ["<CR>"] = "jump",
      ["]d"] = "next",
      ["[d"] = "previous",
    })[lhs] or lhs
    if lhs == "l" and kind == "inspect" then
      action = "log"
    end
    local default = lhs:match("^%a$") and "<prefix>" .. lhs or lhs
    if action == "expand" then
      default = { "<Tab>", "<prefix>l" }
    end
    return self:map(action, default, callback, desc or action:gsub("_", " "))
  end
  function self:hint()
    local key = (self.actions.help or {})[1]
    return key and (M.label(key) .. " key bindings") or ""
  end
  function self:close_help()
    if self.help and api.nvim_win_is_valid(self.help) then
      api.nvim_win_close(self.help, true)
    end
    self.help = nil
  end
  function self:show_help(win)
    self:close_help()
    local entries = vim.tbl_values(self.entries)
    table.sort(entries, function(a, b)
      return a.lhs < b.lhs
    end)
    local lines = {}
    for _, entry in ipairs(entries) do
      lines[#lines + 1] = ("  %-18s %s"):format(entry.lhs, entry.desc)
    end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
    vim.bo[buf].filetype = "lsp-tools-results"
    local width, height =
      math.max(1, math.min(76, vim.o.columns - 4)), math.max(1, math.min(#lines, vim.o.lines - 6))
    self.help = api.nvim_open_win(buf, true, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " Tool keys ",
    })
    vim.wo[self.help].winfixbuf = true
    vim.keymap.set("n", "<Esc>", function()
      self:close_help()
      if api.nvim_win_is_valid(win) then
        api.nvim_set_current_win(win)
      end
    end, { buffer = buf, nowait = true })
  end
  return self
end
return M
