local M = {}
local function clean(value)
  return tostring(value or ""):gsub("[\r\n]", " ↵ ")
end
M.clean = clean
function M.normalize(items, limit)
  local result, occurrences = {}, {}
  for i, original in ipairs(items or {}) do
    if #result >= limit then
      break
    end
    if type(original) == "table" then
      local item = vim.tbl_extend("force", {}, original)
      local buf = item.bufnr or item.buf
      if buf and buf ~= 0 and vim.api.nvim_buf_is_valid(buf) then
        item.bufnr = buf
        item.uri = item.uri or vim.uri_from_bufnr(buf)
      end
      item.filename = item.filename or item.file
      if not item.uri and item.filename then
        item.uri = vim.uri_from_fname(vim.fn.fnamemodify(item.filename, ":p"))
      end
      if item.uri and item.uri:sub(1, 7) == "file://" then
        local ok, filename = pcall(vim.uri_to_fname, item.uri)
        if ok then
          item.filename = filename
        end
      end
      item.pos = item.pos or { math.max(1, item.lnum or 1), math.max(0, (item.col or 1) - 1) }
      item.pos = { math.max(1, item.pos[1] or 1), math.max(0, item.pos[2] or 0) }
      item.text = tostring(item.text or item.message or "")
      item.source = tostring(item.source or "")
      local identity = item.id
        or table.concat({ item.source, item.uri or "", item.pos[1], item.pos[2], item.text }, "\31")
      occurrences[identity] = (occurrences[identity] or 0) + 1
      item.id = tostring(identity)
        .. (occurrences[identity] > 1 and "\31" .. occurrences[identity] or "")
      item.index = i
      result[#result + 1] = item
    end
  end
  return result
end
function M.matches(item, filter)
  filter = filter or {}
  if filter.bufnr and item.bufnr ~= filter.bufnr then
    return false
  end
  if
    filter.severity
    and (
      type(filter.severity) == "table" and not vim.tbl_contains(filter.severity, item.severity)
      or type(filter.severity) ~= "table" and item.severity ~= filter.severity
    )
  then
    return false
  end
  if filter.namespace and item.namespace ~= filter.namespace then
    return false
  end
  if filter.source and item.source ~= filter.source then
    return false
  end
  if filter.code and tostring(item.code) ~= tostring(filter.code) then
    return false
  end
  if filter.root and (not item.filename or not vim.fs.relpath(filter.root, item.filename)) then
    return false
  end
  if filter.text and filter.text ~= "" then
    local text = table
      .concat({ item.text, item.filename or item.uri or "", item.source, tostring(item.code or "") }, " ")
      :lower()
    if not text:find(filter.text:lower(), 1, true) then
      return false
    end
  end
  if filter.predicate and not filter.predicate(item) then
    return false
  end
  return true
end
function M.rows(items, opts)
  local filtered = vim.tbl_filter(function(item)
    return M.matches(item, opts.filter)
  end, items)
  if opts.sort ~= "none" then
    table.sort(filtered, function(a, b)
      if a.section_order and b.section_order and a.section_order ~= b.section_order then
        return a.section_order < b.section_order
      end
      if opts.sort == "severity" and (a.severity or 9) ~= (b.severity or 9) then
        return (a.severity or 9) < (b.severity or 9)
      end
      if (a.filename or a.uri or "") ~= (b.filename or b.uri or "") then
        return (a.filename or a.uri or "") < (b.filename or b.uri or "")
      end
      if a.pos[1] ~= b.pos[1] then
        return a.pos[1] < b.pos[1]
      end
      if a.pos[2] ~= b.pos[2] then
        return a.pos[2] < b.pos[2]
      end
      return a.index < b.index
    end)
  end
  local root = { children = {}, groups = {} }
  for _, item in ipairs(filtered) do
    local parent = root
    for _, field in ipairs(opts.group_by or {}) do
      local value = field == "file" and (item.filename or item.uri or "[no location]")
        or field == "directory" and (item.filename and vim.fs.dirname(item.filename) or "[other]")
        or field == "severity" and (vim.diagnostic.severity[item.severity] or "OTHER")
        or tostring(item[field] or "[other]")
      local key = (parent.key or "") .. "\30" .. field .. ":" .. value
      local group = parent.groups[key]
      if not group then
        group = {
          key = key,
          field = field,
          value = value,
          label = field == "file" and vim.fn.fnamemodify(value, ":t") or value,
          children = {},
          groups = {},
          count = 0,
        }
        parent.groups[key] = group
        parent.children[#parent.children + 1] = group
      end
      group.count = group.count + 1
      parent = group
    end
    parent.children[#parent.children + 1] = { item = item }
  end
  local rows = {}
  local function walk(parent, depth)
    for i, child in ipairs(parent.children) do
      child.depth = depth
      child.last = i == #parent.children
      rows[#rows + 1] = child
      if not child.item then
        walk(child, depth + 1)
      end
    end
  end
  walk(root, 0)
  return rows, filtered
end
return M
