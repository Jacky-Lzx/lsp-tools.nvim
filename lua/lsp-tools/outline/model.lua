local M = {}
local headings = {
  part = true,
  chapter = true,
  section = true,
  subsection = true,
  subsubsection = true,
  paragraph = true,
  subparagraph = true,
}

local function before(a, b)
  return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
end

---Normalize positions once, using the selected provider's encoding and source snapshot.
---SymbolInformation remains flat: containerName does not establish a hierarchy.
function M.normalize(symbols, lines, encoding, uri)
  local function position(pos, eof)
    if
      type(pos) ~= "table"
      or type(pos.line) ~= "number"
      or type(pos.character) ~= "number"
      or pos.line < 0
      or pos.character < 0
      or pos.line % 1 ~= 0
      or pos.character % 1 ~= 0
    then
      return
    end
    if eof and pos.line == #lines and pos.character == 0 then
      return { #lines + 1, 0 }
    end
    local line = lines[pos.line + 1]
    if not line then
      return
    end
    local ok, byte = pcall(vim.str_byteindex, line, encoding, pos.character, true)
    if ok and byte <= #line then
      return { pos.line + 1, byte }
    end
  end
  local function range(value)
    if type(value) ~= "table" then
      return
    end
    local a, b = position(value.start), position(value["end"], true)
    if a and b and not before(b, a) then
      return { a, b }
    end
  end
  local function walk(items, parent)
    local nodes, duplicates = {}, {}
    for _, symbol in ipairs(items or {}) do
      local location = symbol.location
      if type(symbol.name) == "string" and (not location or location.uri == uri) then
        local extent = range(symbol.range or location and location.range)
        local selection =
          range(symbol.selectionRange or symbol.range or location and location.range)
        if extent and selection then
          local id = tostring(symbol.kind) .. ":" .. symbol.name
          duplicates[id] = (duplicates[id] or 0) + 1
          local node = {
            name = symbol.name,
            detail = symbol.detail or "",
            kind = symbol.kind,
            range = extent,
            position = selection[1],
            parent = parent,
            key = (parent and parent.key or "") .. "/" .. #id .. ":" .. id .. ":" .. duplicates[id],
          }
          node.children = walk(not location and symbol.children or nil, node)
          nodes[#nodes + 1] = node
        end
      end
    end
    return nodes
  end
  return walk(symbols)
end

function M.section(node)
  local detail = node.detail:gsub("^\\", ""):gsub("%*$", "")
  return headings[detail] or node.kind == 3 and detail == ""
end

---Filtering promotes matching descendants rather than discarding whole subtrees.
function M.rows(roots, folds, sections)
  local rows = {}
  local function walk(nodes, depth, visible_parent)
    for _, node in ipairs(nodes) do
      if not sections or M.section(node) then
        local children = false
        local function has_child(items)
          for _, child in ipairs(items) do
            if not sections or M.section(child) or has_child(child.children) then
              return true
            end
          end
          return false
        end
        children = has_child(node.children)
        rows[#rows + 1] =
          { node = node, depth = depth, parent = visible_parent, children = children }
        if not folds[node.key] then
          walk(node.children, depth + 1, node)
        end
      else
        walk(node.children, depth, visible_parent)
      end
    end
  end
  walk(roots, 0)
  return rows
end

function M.current(roots, cursor, sections)
  local found
  local function walk(nodes)
    for _, node in ipairs(nodes) do
      if not before(cursor, node.range[1]) and before(cursor, node.range[2]) then
        if not sections or M.section(node) then
          found = node
        end
        walk(node.children)
      end
    end
  end
  walk(roots)
  return found
end

return M
