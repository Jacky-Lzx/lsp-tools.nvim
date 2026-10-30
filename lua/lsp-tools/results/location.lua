local M = {}
local api = vim.api
function M.stat(filename)
  if not filename then
    return nil
  end
  local stat = vim.uv.fs_stat(filename)
  return stat and { size = stat.size, mtime = stat.mtime } or false
end
function M.lsp(location, client, cache)
  local uri = assert(location.targetUri or location.uri)
  local range = assert(location.targetSelectionRange or location.range or location.targetRange)
  assert(type(uri) == "string" and range.start.line >= 0 and range.start.character >= 0)
  local path = uri:sub(1, 7) == "file://" and vim.uri_to_fname(uri) or nil
  local buf = path and vim.fn.bufnr(path) or vim.uri_to_bufnr(uri)
  local loaded = buf and buf > 0 and api.nvim_buf_is_loaded(buf)
  local lines
  if loaded then
    lines = nil
  elseif path then
    if cache[path] == nil then
      local stat = vim.uv.fs_stat(path)
      local ok, text = false, nil
      if stat and stat.size <= 1024 * 1024 then
        ok, text = pcall(vim.fn.readfile, path)
      end
      cache[path] = ok and text or false
    end
    lines = cache[path] or nil
  end
  local line = loaded
      and api.nvim_buf_get_lines(buf, range.start.line, range.start.line + 1, false)[1]
    or lines and lines[range.start.line + 1]
  local col = line and vim.str_byteindex(line, client.offset_encoding, range.start.character, true)
    or 0
  local last = loaded
      and api.nvim_buf_get_lines(buf, range["end"].line, range["end"].line + 1, false)[1]
    or lines and lines[range["end"].line + 1]
  local finish = last
      and vim.str_byteindex(last, client.offset_encoding, range["end"].character, true)
    or col
  return {
    uri = uri,
    filename = path,
    bufnr = loaded and buf or nil,
    pos = { range.start.line + 1, col },
    end_pos = { range["end"].line + 1, finish },
    text = line and line:gsub("^%s+", "") or "LSP location",
    column_unknown = line == nil,
    data = {
      location = { uri = uri, range = range },
      encoding = client.offset_encoding,
      client_ids = { client.id },
      tick = loaded and api.nvim_buf_get_changedtick(buf) or nil,
      stat = M.stat(path),
    },
  }
end
return M
