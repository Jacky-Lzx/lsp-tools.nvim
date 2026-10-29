local M = {}

-- Prefer the source buffer's repository, then its LSP workspace, then cwd.
-- The picker can change the current buffer/directory, so capture this on opening.
function M.root(buf, client)
  local git = vim.fs.root(buf, { ".git" })
  if git then
    return git
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local root
  for _, folder in ipairs(client and client.workspace_folders or {}) do
    if folder.uri:match("^file:") then
      local folder_path = vim.uri_to_fname(folder.uri)
      local candidate = vim.uv.fs_realpath(folder_path) or vim.fs.normalize(folder_path)
      if vim.fs.relpath(candidate, path) and (not root or #candidate > #root) then
        root = candidate
      end
    end
  end
  local configured = client and (client.root_dir or client.config and client.config.root_dir)
  if type(configured) == "string" then
    configured = vim.uv.fs_realpath(configured) or vim.fs.normalize(configured)
  end
  if not root and type(configured) == "string" and vim.fs.relpath(configured, path) then
    root = configured
  end
  return root or vim.fn.getcwd()
end

local function label(uri, root)
  if not uri:match("^file:") then
    return uri
  end
  local path = vim.uri_to_fname(uri)
  return vim.fs.relpath(root, path) or path
end

local function read(uri)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.uri_from_bufnr(buf) == uri then
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    end
  end
  assert(uri:match("^file:"), "Cannot read this URI: " .. uri)
  local path = vim.uri_to_fname(uri)
  assert(vim.uv.fs_stat(path), "File does not exist: " .. path)
  local lines = vim.fn.readfile(path)
  return #lines == 0 and { "" } or lines
end

M.read = read
M.label = label

local function edited(lines, edits, encoding, annotations)
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, result = pcall(function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    edits = vim.deepcopy(edits)
    for _, edit in ipairs(edits) do
      if edit.annotationId then
        assert(
          annotations and annotations[edit.annotationId],
          "Missing change annotation: " .. edit.annotationId
        )
        edit.annotationId = nil -- Simulation never prompts or announces applied annotations.
      end
    end
    vim.lsp.util.apply_text_edits(edits, buf, encoding)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, result)
  return result
end

-- Replay text edits in documentChanges order. Resource operations are shown as
-- summaries and modeled in memory, never performed while browsing the picker.
function M.lines(action, encoding, root, read_contents)
  root = root or vim.fn.getcwd()
  if not action.edit then
    return { "No text edit to preview. This action runs a command when confirmed." }
  end
  local out, files, groups, by_uri = {}, {}, {}, {}
  local function group(uri)
    if not by_uri[uri] then
      by_uri[uri] = { uri = uri, text = label(uri, root), lines = {}, edits = 0 }
      groups[#groups + 1] = by_uri[uri]
    end
    return by_uri[uri]
  end
  local function emit(uri, lines)
    vim.list_extend(out, lines)
    vim.list_extend(group(uri).lines, lines)
  end
  local function content(uri)
    if not files[uri] then
      files[uri] = (read_contents or read)(uri)
    end
    return files[uri]
  end
  local function text(uri, edits)
    local before = content(uri)
    local after = edited(before, edits, encoding, action.edit.changeAnnotations)
    group(uri).edits = group(uri).edits + #edits
    files[uri] = after
    local diff = (vim.text and vim.text.diff or vim.diff)(
      table.concat(before, "\n") .. "\n",
      table.concat(after, "\n") .. "\n",
      { result_type = "unified", ctxlen = 3 }
    )
    if diff ~= "" then
      local name = label(uri, root)
      emit(uri, { "--- " .. name, "+++ " .. name })
      emit(uri, vim.split(diff, "\n", { trimempty = true }))
    end
  end
  local edit = action.edit
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument then
        text(change.textDocument.uri, change.edits)
      elseif change.kind == "create" then
        emit(change.uri, { "Create file: " .. label(change.uri, root) })
        files[change.uri] = { "" }
      elseif change.kind == "rename" then
        emit(
          change.newUri,
          { "Rename file: " .. label(change.oldUri, root) .. " -> " .. label(change.newUri, root) }
        )
        files[change.newUri] = content(change.oldUri)
        files[change.oldUri] = nil
      elseif change.kind == "delete" then
        emit(change.uri, { "Delete file: " .. label(change.uri, root) })
        files[change.uri] = nil
      end
    end
  else
    local uris = vim.tbl_keys(edit.changes or {})
    table.sort(uris)
    for _, uri in ipairs(uris) do
      text(uri, edit.changes[uri])
    end
  end
  if #out == 0 then
    out = { "No text changes to preview." }
  end
  if action.command then
    out[#out + 1] = ""
    out[#out + 1] = "This action also runs a command; its effects are not included above."
  end
  return out, groups
end

return M
