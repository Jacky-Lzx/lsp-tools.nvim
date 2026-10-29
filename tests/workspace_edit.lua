vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local workspace = require("lsp-tools.workspace_edit")
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local project = vim.fn.tempname()
vim.fn.mkdir(project, "p")
local function buffer(name, text)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, project .. "/" .. name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  return buf, vim.uri_from_bufnr(buf)
end
local function change(first, last, new)
  return {
    range = { start = { line = 0, character = first }, ["end"] = { line = 0, character = last } },
    newText = new,
  }
end
local buf, uri = buffer("中文.lua", "😀foo foo")
local other, other_uri = buffer("other.lua", "foo")
local edit = {
  changes = {
    [uri] = { change(2, 5, "bar"), change(6, 9, "bar") },
    [other_uri] = { change(0, 3, "bar") },
  },
}
local before = #vim.api.nvim_list_bufs()
local data = workspace.capture(edit, "utf-16", project, workspace.baseline())
check(data.files == 2 and data.edits == 3 and #data.items == 2, "file and edit totals")
check(#vim.api.nvim_list_bufs() == before, "snapshot preview creates no persistent source buffers")
local unicode_item = vim.tbl_filter(function(item)
  return item.uri == uri
end, data.items)[1]
check(
  table.concat(unicode_item.lines, "\n"):find("+😀bar bar", 1, true),
  "Unicode edits use unsaved text"
)
check(
  vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "😀foo foo",
  "snapshot preview never edits source"
)
check(data.validate(), "unchanged snapshots validate")
vim.api.nvim_buf_set_lines(other, 0, 1, false, { "newer" })
check(not pcall(data.validate), "another loaded file becoming stale blocks the entire edit")
local baseline = workspace.baseline()
vim.api.nvim_buf_set_lines(other, 0, 1, false, { "foo" })
check(
  not pcall(workspace.capture, edit, "utf-16", project, baseline),
  "edits during the rename request are rejected"
)

local path = project .. "/disk.lua"
vim.fn.writefile({ "foo" }, path)
local disk_uri = vim.uri_from_fname(path)
data = workspace.capture({ changes = { [disk_uri] = { change(0, 3, "bar") } } }, "utf-16", project)
vim.fn.writefile({ "other" }, path)
check(not pcall(data.validate), "external disk writes invalidate previews")
vim.fn.writefile({ "foo" }, path)
data = workspace.capture({ changes = { [disk_uri] = { change(0, 3, "bar") } } }, "utf-16", project)
local disk_buf = vim.fn.bufadd(path)
vim.fn.bufload(disk_buf)
check(data.validate(), "loading an unchanged disk snapshot is safe")
vim.api.nvim_buf_set_lines(disk_buf, 0, 1, false, { "unsaved" })
check(
  not pcall(data.validate),
  "newly loaded buffers are checked against immutable snapshot contents"
)

vim.lsp.util.buf_versions[buf] = 9
local doc_edit = {
  documentChanges = {
    { textDocument = { uri = other_uri, version = vim.NIL }, edits = { change(0, 3, "bar") } },
    { textDocument = { uri = uri, version = 8 }, edits = { change(2, 5, "bar") } },
  },
}
check(
  not pcall(workspace.capture, doc_edit, "utf-16", project),
  "every document version is checked, including later entries"
)
doc_edit.documentChanges[2].textDocument.version = 9
data = workspace.capture(doc_edit, "utf-16", project)
check(data.validate(), "matching document versions")
vim.lsp.util.buf_versions[buf] = 10
check(not pcall(data.validate), "version changes after preview are rejected")
vim.lsp.util.buf_versions[buf] = nil

local annotated = change(0, 3, "bar")
annotated.annotationId = "rename"
edit = {
  documentChanges = { { textDocument = { uri = other_uri }, edits = { annotated } } },
  changeAnnotations = {
    rename = {
      label = "Rename public API",
      description = "All call sites",
      needsConfirmation = true,
    },
  },
}
local notifications, confirms = 0, 0
local notify, confirm = vim.notify, vim.fn.confirm
vim.notify = function()
  notifications = notifications + 1
end
vim.fn.confirm = function()
  confirms = confirms + 1
  return 2
end
data = workspace.capture(edit, "utf-16", project)
check(
  confirms == 0 and notifications == 0,
  "annotation previews never prompt or claim edits were applied"
)
check(data.items[1].lines[1]:find("Rename public API", 1, true), "annotations appear in the review")
check(
  annotated.annotationId == "rename" and edit.changeAnnotations.rename.needsConfirmation,
  "server annotations remain unchanged"
)
vim.notify, vim.fn.confirm = notify, confirm

local created = vim.uri_from_fname(project .. "/new.lua")
local renamed = vim.uri_from_fname(project .. "/renamed.lua")
edit = {
  documentChanges = {
    { kind = "create", uri = created },
    { textDocument = { uri = created }, edits = { change(0, 0, "foo") } },
    { kind = "rename", oldUri = created, newUri = renamed },
    { textDocument = { uri = renamed }, edits = { change(0, 3, "bar") } },
    { kind = "delete", uri = renamed },
  },
}
data = workspace.capture(edit, "utf-16", project)
check(
  data.operations == 3 and data.edits == 2 and data.files == 2,
  "ordered resource operation totals"
)
check(
  not vim.uv.fs_stat(vim.uri_to_fname(created)) and not vim.uv.fs_stat(vim.uri_to_fname(renamed)),
  "resource previews never touch disk"
)
check(data.validate(), "absent resource paths validate")
vim.fn.writefile({ "surprise" }, vim.uri_to_fname(created))
check(not pcall(data.validate), "new conflicting resource paths block apply")
vim.fn.delete(project, "rf")
print(("lsp-tools workspace edits: %d assertions passed"):format(count))
vim.cmd("qa!")
