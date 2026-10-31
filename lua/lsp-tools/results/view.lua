local M = {}
local api = vim.api
local prefix = "LspToolsResults"
local severity = { "Error", "Warn", "Info", "Hint" }
local signs = { "", "", "", "󰌵" }
local links = {
  Text = "Normal",
  File = "Normal",
  Directory = "Directory",
  Count = "Number",
  Guide = "NonText",
  Meta = "Comment",
  Position = "LineNr",
  Title = "Title",
  CursorLine = "CursorLine",
  Folded = "Normal",
  PreviewPath = "Directory",
  PreviewFile = "Title",
  PreviewNormal = "NormalFloat",
  PreviewBorder = "FloatBorder",
  PreviewMeta = "Comment",
  PreviewDivider = "Comment",
  PreviewLine = "CursorLine",
  PreviewRange = "Visual",
  WinBar = "WinBar",
  WinBarNC = "WinBarNC",
}
local function highlights()
  for name, link in pairs(links) do
    api.nvim_set_hl(0, prefix .. name, { default = true, link = link })
  end
end
function M.setup()
  highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup(prefix .. "Highlights", { clear = true }),
    callback = highlights,
  })
end
function M.disable()
  pcall(api.nvim_del_augroup_by_name, prefix .. "Highlights")
end
local function clean(value)
  return (tostring(value or ""):gsub("%s*[\r\n]+%s*", " "):gsub("[%z\1-\31\127]", " "))
end
function M.key_label(lhs)
  lhs = lhs
    :gsub("<[Ll]ocal[Ll]eader>", function()
      return vim.g.maplocalleader or "\\"
    end)
    :gsub("<[Ll]eader>", function()
      return vim.g.mapleader or "\\"
    end)
  return vim.fn.keytrans(vim.keycode(lhs))
end
local function canonical(path)
  local current, tail = vim.fs.normalize(path), {}
  while current do
    local resolved = vim.uv.fs_realpath(current)
    if resolved then
      for i = #tail, 1, -1 do
        resolved = vim.fs.joinpath(resolved, tail[i])
      end
      return resolved
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      break
    end
    tail[#tail + 1] = vim.fs.basename(current)
    current = parent
  end
  return path
end
local function label(path, v)
  if path:find("://", 1, true) then
    return clean(path)
  end
  if not v.display_paths[path] then
    local real = canonical(path)
    v.display_paths[path] =
      clean(vim.fs.relpath(v.display_cwd, real) or vim.fn.fnamemodify(real, ":~"))
  end
  return v.display_paths[path]
end
local function file_icon(path, icons)
  if not icons then
    return "", prefix .. "File"
  end
  local provider = package.loaded["nvim-web-devicons"]
  if provider then
    local icon, hl =
      provider.get_icon(vim.fn.fnamemodify(path or "", ":t"), nil, { default = true })
    if icon then
      return icon .. " ", hl
    end
  end
  return " ", prefix .. "File"
end
local function sign(item, icons)
  if not severity[item.severity] then
    return icons and " " or "· ", prefix .. "Guide"
  end
  local config = vim.diagnostic.config().signs
  local configured = type(config) == "table"
    and type(config.text) == "table"
    and config.text[item.severity]
  local icon = icons and (configured or signs[item.severity])
    or ({ "E", "W", "I", "H" })[item.severity]
  return clean(icon) .. " ", "Diagnostic" .. severity[item.severity]
end
local function builder()
  local result = { text = "", spans = {} }
  function result:add(text, hl)
    text = clean(text)
    local start = #self.text
    self.text = self.text .. text
    if hl and #text > 0 then
      self.spans[#self.spans + 1] = { start, #self.text, hl }
    end
  end
  return result
end
local function indent(line, row, guides, enabled, continuation)
  line:add("  ")
  for depth = 1, row.depth - 1 do
    line:add(enabled and guides[depth] and "│ " or "  ", prefix .. "Guide")
  end
  if row.depth > 0 then
    line:add(
      row.item
          and enabled
          and (continuation and (row.last and "  " or "│ ") or (row.last and "└╴" or "├╴"))
        or "  ",
      prefix .. "Guide"
    )
  end
end
local function group(line, row, v)
  line:add(v.options.icons and " " or "▾ ", prefix .. "Guide")
  if row.field == "file" then
    local icon, hl = file_icon(row.value, v.options.icons)
    line:add(icon, hl)
    line:add(row.label, prefix .. "File")
    if v.group_by[row.depth] ~= "directory" then
      local parent = vim.fs.dirname(row.value)
      if parent and parent ~= "." then
        line:add("  " .. label(parent, v), prefix .. "Meta")
      end
    end
  elseif row.field == "directory" then
    line:add(v.options.icons and " " or "", prefix .. "Directory")
    line:add(label(row.value, v), prefix .. "Directory")
  else
    line:add(row.label, prefix .. "Title")
  end
  line:add("  " .. row.count, prefix .. "Count")
end
local function metadata(line, item, v)
  if
    item.source ~= ""
    and not ({ LSP = true, quickfix = true, loclist = true })[item.source]
    and v.title ~= "Picker · " .. item.source
  then
    line:add("  " .. item.source, prefix .. "Meta")
  end
  if item.code then
    line:add(" " .. item.code, prefix .. "Meta")
  end
  if item.uri then
    line:add(
      "  " .. item.pos[1] .. ":" .. (item.column_unknown and "?" or item.pos[2] + 1),
      prefix .. "Position"
    )
  end
end
function M.layout(v)
  v.display_cwd = canonical(
    api.nvim_win_is_valid(v.ctx.win)
        and vim.fn.getcwd(
          v.ctx.win,
          api.nvim_tabpage_get_number(api.nvim_win_get_tabpage(v.ctx.win))
        )
      or vim.fn.getcwd()
  )
  v.display_paths = {}
  local out = {
    lines = {},
    highlights = {},
    line_rows = {},
    row_lines = {},
    fold_levels = {},
    fold_ranges = {},
  }
  local guides = {}
  local groups = {}
  local function push(line, row)
    out.lines[#out.lines + 1] = line.text
    out.highlights[#out.lines] = line.spans
    out.line_rows[#out.lines] = row
    out.fold_levels[#out.lines] = row and (row.item and row.depth or ">" .. (row.depth + 1)) or 0
  end
  for index, row in ipairs(v.rows) do
    while #groups > 0 and groups[#groups].depth > row.depth do
      groups[#groups].last = #out.lines
      table.remove(groups)
    end
    row.index = index
    out.row_lines[index] = #out.lines + 1
    local line = builder()
    indent(line, row, guides, v.options.indent_guides)
    if row.item then
      local item = row.item
      if #v.group_by == 0 and (item.filename or item.uri) then
        local icon, hl = file_icon(item.filename, v.options.icons)
        line:add(icon, hl)
        line:add(label(item.filename or item.uri, v), prefix .. "File")
        line:add("  ")
      end
      local icon, hl = sign(item, v.options.icons)
      line:add(icon, hl)
      local text = item.text:gsub("\r\n", "\n"):gsub("\r", "\n")
      local parts = v.options.multiline and vim.split(text, "\n", { plain = true })
        or { clean(text) }
      line:add(parts[1], prefix .. "Text")
      metadata(line, item, v)
      push(line, row)
      for i = 2, #parts do
        line = builder()
        indent(line, row, guides, v.options.indent_guides, true)
        line:add(string.rep(" ", vim.fn.strdisplaywidth(icon)))
        line:add(parts[i], prefix .. "Text")
        push(line, row)
      end
    else
      local range = { key = row.key, first = #out.lines + 1, depth = row.depth + 1 }
      groups[#groups + 1] = range
      out.fold_ranges[#out.fold_ranges + 1] = range
      group(line, row, v)
      push(line, row)
    end
    guides[row.depth] = not row.last
  end
  for _, range in ipairs(groups) do
    range.last = #out.lines
  end
  if #out.lines == 0 then
    local line = builder()
    line:add("  No matching results", prefix .. "Meta")
    push(line)
  end
  if v.status and v.status ~= "" then
    push(builder())
    for _, message in ipairs(vim.split(v.status, " · ", { plain = true })) do
      local line = builder()
      line:add("  " .. message, prefix .. "Meta")
      push(line)
    end
  end
  return out
end
function M.winbar(v)
  local help_key = v.bindings and (v.bindings.actions.help or {})[1]
  local help = help_key and (require("lsp-tools.keymaps").label(help_key) .. " help ") or ""
  local function escape(value)
    return (clean(value):gsub("%%", "%%%%"))
  end
  local count = #v.filtered == #v.items and tostring(#v.items) or #v.filtered .. "/" .. #v.items
  local filters = {}
  if v.pinned then
    filters[#filters + 1] = "pinned"
  end
  if v.filter.text and v.filter.text ~= "" then
    filters[#filters + 1] = '"' .. v.filter.text .. '"'
  end
  if v.filter.severity then
    if type(v.filter.severity) == "table" then
      filters[#filters + 1] = table.concat(
        vim.tbl_map(function(level)
          return vim.diagnostic.severity[level] or tostring(level)
        end, v.filter.severity),
        "+"
      )
    else
      filters[#filters + 1] = vim.diagnostic.severity[v.filter.severity] or "severity"
    end
  end
  if v.filter.namespace then
    filters[#filters + 1] = (vim.diagnostic.get_namespaces()[v.filter.namespace] or {}).name
      or "namespace"
  end
  for _, field in ipairs({ "source", "code" }) do
    if v.filter[field] then
      filters[#filters + 1] = tostring(v.filter[field])
    end
  end
  if v.filter.bufnr then
    filters[#filters + 1] = "buffer"
  end
  if v.filter.root then
    filters[#filters + 1] = "project"
  end
  if v.filter.predicate then
    filters[#filters + 1] = "filtered"
  end
  return "%#"
    .. prefix
    .. "Title#  %<"
    .. escape(v.title)
    .. " %#"
    .. prefix
    .. "Count# "
    .. count
    .. "%#"
    .. prefix
    .. "Meta#  "
    .. escape(table.concat(filters, " · "))
    .. "%=%#"
    .. prefix
    .. "Meta# "
    .. escape(help)
end
return M
