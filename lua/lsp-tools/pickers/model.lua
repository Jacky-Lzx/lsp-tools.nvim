local M = {}
local api = vim.api
local location = require("lsp-tools.results.location")

function M.location(value, client, cache)
  local range = value.targetSelectionRange or value.range or value.targetRange
  assert(type(range) == "table", "Missing location range")
  for _, key in ipairs({ "start", "end" }) do
    local pos = range[key]
    assert(type(pos) == "table", "Missing location position")
    for _, key in ipairs({ "line", "character" }) do
      assert(type(pos[key]) == "number" and pos[key] >= 0 and pos[key] % 1 == 0, "Invalid position")
    end
  end
  assert(
    range["end"].line > range.start.line
      or range["end"].line == range.start.line and range["end"].character >= range.start.character,
    "Invalid range"
  )
  local item = location.lsp(value, client, cache)
  item.file = item.filename
  local lines = item.bufnr
    and api.nvim_buf_get_lines(item.bufnr, item.pos[1] - 1, item.pos[1], false)
  local disk = item.file and cache[item.file]
  item.code = lines and lines[1] or type(disk) == "table" and disk[item.pos[1]] or item.text
  item.line_matches = item.pos[1] == item.end_pos[1] and { { item.pos[2], item.end_pos[2] } } or nil
  return item
end

function M.key(item)
  return table.concat({
    item.uri,
    item.pos[1],
    item.pos[2],
    item.end_pos[1],
    item.end_pos[2],
    item.column_unknown and item.data.encoding or "",
    item.name or "",
    item.kind or "",
    -- Resolve data is server-specific, even for equal names and URI-only locations.
    item.data.unresolved and item.data.client_ids[1] or "",
  }, "\31")
end

function M.format(item)
  local file = item.file and vim.fn.fnamemodify(item.file, ":~:.") or item.uri or "[No Name]"
  local label = item.name and string.rep("  ", item.depth or 0) .. item.name
    or item.code
    or item.text
  local extra = item.kind
      and " [" .. (vim.lsp.protocol.SymbolKind[item.kind] or tostring(item.kind)) .. "]"
    or ""
  if item.severity then
    extra = " ["
      .. (vim.diagnostic.severity[item.severity] or "OTHER")
      .. "]"
      .. (item.source ~= "" and " " .. item.source or "")
      .. (item.diagnostic_code and " (" .. tostring(item.diagnostic_code) .. ")" or "")
  end
  local prefix = ("%s:%d:%d: "):format(file, item.pos[1], item.pos[2] + 1)
  item.display_file, item.display_code = file, label .. extra
  item.content_offset, item.display_indent = #prefix, item.name ~= nil
  return prefix .. item.display_code
end

function M.highlights(item)
  local first = item.content_offset
  if item.kind then
    local name = vim.lsp.protocol.SymbolKind[item.kind]
    local icon = require("lsp-tools.symbols.icons")[name]
    local indent = #(string.rep("  ", item.depth or 0))
    return {
      {
        first + indent,
        first + indent + #item.name,
        hl = icon and icon.hl or "Identifier",
        priority = 100,
      },
      { first + indent + #item.name, first + #item.display_code, hl = "Comment", priority = 100 },
    }
  end
  if item.severity then
    local name = ({ "Error", "Warn", "Info", "Hint" })[item.severity] or "Info"
    return { { first, first + #item.display_code, hl = "Diagnostic" .. name, priority = 100 } }
  end
  return {}
end

function M.symbols(symbols, client, uri, cache, add, workspace, depth)
  assert(type(symbols) == "table", "Invalid symbol response")
  for _, symbol in ipairs(symbols) do
    if type(symbol.name) == "string" then
      local value = symbol.location or { uri = uri, range = symbol.selectionRange or symbol.range }
      local item
      if workspace and value.uri and not value.range then
        item = {
          uri = value.uri,
          file = value.uri:sub(1, 7) == "file://" and vim.uri_to_fname(value.uri) or nil,
          pos = { 1, 0 },
          end_pos = { 1, 0 },
          data = {
            unresolved = symbol,
            client_ids = { client.id },
            encoding = client.offset_encoding,
          },
        }
      else
        item = M.location(value, client, cache)
      end
      item.name, item.kind, item.depth = symbol.name, symbol.kind, depth or 0
      item.detail = symbol.detail or symbol.containerName or symbol.name
      add(item)
      if symbol.children then
        M.symbols(symbol.children, client, uri, cache, add, workspace, (depth or 0) + 1)
      end
    end
  end
end

function M.target_valid(item)
  local buf = item.bufnr or item.file and vim.fn.bufnr(item.file)
  if buf and buf > 0 and api.nvim_buf_is_loaded(buf) then
    if vim.uri_from_bufnr(buf) ~= item.uri then
      return false
    end
    if item.data.tick then
      if api.nvim_buf_get_changedtick(buf) ~= item.data.tick then
        return false
      end
    elseif vim.bo[buf].modified then
      return false
    end
  elseif item.data.tick then
    return false
  end
  return not item.file or vim.deep_equal(item.data.stat, location.stat(item.file))
end

function M.diagnostics(opts, origin)
  local scope = opts.scope or "all"
  assert(vim.tbl_contains({ "all", "buffer", "project" }, scope), "Invalid diagnostic scope")
  local root = opts.root or vim.fs.root(origin.buf, { ".git" }) or vim.fn.getcwd()
  root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
  local values = vim.diagnostic.get(
    scope == "buffer" and origin.buf or nil,
    { namespace = opts.namespace, severity = opts.severity }
  )
  local items = {}
  for _, diagnostic in ipairs(values) do
    local buf = diagnostic.bufnr
    if api.nvim_buf_is_valid(buf) then
      local file = api.nvim_buf_get_name(buf)
      if scope ~= "project" or file ~= "" and vim.fs.relpath(root, file) then
        local item = {
          uri = vim.uri_from_bufnr(buf),
          file = file ~= "" and file or nil,
          filename = file ~= "" and file or nil,
          bufnr = buf,
          pos = { diagnostic.lnum + 1, diagnostic.col },
          end_pos = {
            (diagnostic.end_lnum or diagnostic.lnum) + 1,
            diagnostic.end_col or diagnostic.col,
          },
          text = diagnostic.message,
          code = diagnostic.message,
          severity = diagnostic.severity,
          source = diagnostic.source or "",
          namespace = diagnostic.namespace,
          diagnostic_code = diagnostic.code,
          detail = diagnostic.message,
          data = {
            diagnostic = diagnostic,
            tick = api.nvim_buf_get_changedtick(buf),
            stat = location.stat(file ~= "" and file or nil),
          },
        }
        local candidate = vim.tbl_extend("force", {}, item)
        candidate.code = diagnostic.code
        if require("lsp-tools.results.model").matches(candidate, opts.filter) then
          items[#items + 1] = item
        end
      end
    end
  end
  table.sort(items, function(a, b)
    if a.severity ~= b.severity then
      return (a.severity or 9) < (b.severity or 9)
    end
    if a.uri ~= b.uri then
      return a.uri < b.uri
    end
    if a.pos[1] ~= b.pos[1] then
      return a.pos[1] < b.pos[1]
    end
    if a.pos[2] ~= b.pos[2] then
      return a.pos[2] < b.pos[2]
    end
    return a.text < b.text
  end)
  return items
end

function M.diagnostic_valid(item)
  if not M.target_valid(item) then
    return false
  end
  local diagnostic = item.data.diagnostic
  for _, current in ipairs(vim.diagnostic.get(item.bufnr, { namespace = diagnostic.namespace })) do
    if vim.deep_equal(current, diagnostic) then
      return true
    end
  end
  return false
end

return M
