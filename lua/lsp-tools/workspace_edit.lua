local M = {}
local preview = require("lsp-tools.code_actions.preview")

local function canonical(uri)
  if uri:match("^file:") then
    local path = vim.uri_to_fname(uri)
    return vim.uri_from_fname(vim.uv.fs_realpath(path) or vim.fs.normalize(path))
  end
  return uri
end

local function loaded(uri)
  uri = canonical(uri)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and canonical(vim.uri_from_bufnr(buf)) == uri then
      return buf
    end
  end
end

---Capture loaded buffer versions immediately before sending an edit request.
function M.baseline()
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      buffers[canonical(vim.uri_from_bufnr(buf))] =
        { buf = buf, tick = vim.api.nvim_buf_get_changedtick(buf) }
    end
  end
  return buffers
end

local function disk(uri)
  if not uri:match("^file:") then
    return {}
  end
  local path = vim.uri_to_fname(uri)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}
  end
  return {
    stat = {
      type = stat.type,
      dev = stat.dev,
      ino = stat.ino,
      size = stat.size,
      mtime = stat.mtime,
      ctime = stat.ctime,
    },
    bytes = stat.type == "file" and vim.fn.readfile(path, "b") or nil,
  }
end

local function version(uri, expected)
  if expected == nil or expected == vim.NIL then
    return
  end
  local buf = loaded(uri)
  if buf then
    assert(vim.lsp.util.buf_versions[buf] == expected, "Document version changed: " .. uri)
  end
end

---Build immutable, per-file previews and guards for the entire workspace edit.
function M.capture(edit, encoding, root, baseline)
  edit = vim.deepcopy(edit)
  local snapshots, versions, edits, operations = {}, {}, 0, 0
  local function capture(uri)
    if snapshots[uri] then
      return
    end
    local buf = loaded(uri)
    local original = baseline and baseline[canonical(uri)]
    if original then
      assert(
        buf == original.buf and vim.api.nvim_buf_get_changedtick(buf) == original.tick,
        "Buffer changed while requesting rename: " .. uri
      )
    end
    local disk_snapshot = disk(uri)
    snapshots[uri] = {
      buf = buf,
      tick = buf and vim.api.nvim_buf_get_changedtick(buf),
      lines = buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        or disk_snapshot.bytes and preview.read(uri)
        or nil,
      disk = disk_snapshot,
    }
    if buf then
      assert(vim.bo[buf].modifiable, "Buffer is not modifiable: " .. uri)
    end
  end
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument then
        local doc = change.textDocument
        capture(doc.uri)
        version(doc.uri, doc.version)
        versions[#versions + 1] = doc
        edits = edits + #change.edits
      else
        assert(
          change.kind == "create" or change.kind == "rename" or change.kind == "delete",
          "Unsupported resource operation"
        )
        if change.kind == "rename" then
          capture(change.oldUri)
          capture(change.newUri)
        else
          capture(change.uri)
        end
        operations = operations + 1
      end
    end
  else
    for uri, changes in pairs(edit.changes or {}) do
      capture(uri)
      edits = edits + #changes
    end
  end
  local function read(uri)
    local snapshot = assert(snapshots[uri], "Unknown edit URI: " .. uri)
    if snapshot.lines then
      return vim.deepcopy(snapshot.lines)
    end
    error("File does not exist: " .. uri)
  end
  local _, items = preview.lines({ edit = edit }, encoding, root, read)
  for _, item in ipairs(items) do
    if #item.lines == 0 then
      item.lines = { "No text changes to preview." }
    end
    local annotations = {}
    local function describe(changes)
      for _, change in ipairs(changes) do
        local id = change.annotationId
        if id and not annotations[id] then
          local annotation = assert(
            edit.changeAnnotations and edit.changeAnnotations[id],
            "Missing change annotation: " .. id
          )
          annotations[id] = true
          table.insert(
            item.lines,
            1,
            "Annotation: "
              .. annotation.label
              .. (annotation.description and " — " .. annotation.description or "")
          )
        end
      end
    end
    if edit.documentChanges then
      for _, change in ipairs(edit.documentChanges) do
        if change.textDocument and change.textDocument.uri == item.uri then
          describe(change.edits)
        elseif (change.uri or change.newUri) == item.uri then
          describe({ change })
        end
      end
    else
      describe(edit.changes[item.uri])
    end
    item.root = root
    item.text = item.text
      .. (
        item.edits > 0 and (" · %d %s"):format(item.edits, item.edits == 1 and "edit" or "edits")
        or " · file operation"
      )
  end
  local result = {
    edit = edit,
    items = items,
    edits = edits,
    files = vim.tbl_count(snapshots),
    operations = operations,
  }
  function result.validate()
    for uri, snapshot in pairs(snapshots) do
      local buf = loaded(uri)
      if snapshot.buf then
        assert(
          buf == snapshot.buf and vim.api.nvim_buf_get_changedtick(buf) == snapshot.tick,
          "Buffer changed since preview: " .. uri
        )
      elseif buf then
        local lines = read(uri)
        assert(
          vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines),
          "Buffer differs from preview: " .. uri
        )
      end
      if buf then
        assert(vim.bo[buf].modifiable, "Buffer is not modifiable: " .. uri)
      end
      assert(vim.deep_equal(disk(uri), snapshot.disk), "File changed since preview: " .. uri)
    end
    for _, doc in ipairs(versions) do
      version(doc.uri, doc.version)
    end
    return true
  end
  return result
end

return M
