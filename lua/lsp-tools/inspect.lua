local M = {}
local panel = require("lsp-tools.panel")
local request = require("lsp-tools.request")
local enabled = false
local config = { width = 0.5 }
local sessions = {}
local recorder = require("lsp-tools.inspect.recorder")
local methods = {
  { "Hover", "textDocument/hover" },
  { "Signature", "textDocument/signatureHelp" },
  { "Definition", "textDocument/definition" },
  { "Declaration", "textDocument/declaration" },
  { "Type definition", "textDocument/typeDefinition" },
  { "Implementation", "textDocument/implementation" },
  { "References", "textDocument/references" },
  { "Document highlights", "textDocument/documentHighlight" },
  { "Document symbols", "textDocument/documentSymbol" },
  { "Workspace symbols", "workspace/symbol" },
  { "Rename", "textDocument/rename" },
  { "Prepare rename", "textDocument/prepareRename" },
  { "Code action", "textDocument/codeAction" },
  { "Resolve action", "codeAction/resolve" },
  { "Document links", "textDocument/documentLink" },
  { "Resolve link", "documentLink/resolve" },
  { "Linked editing", "textDocument/linkedEditingRange" },
  { "Pull diagnostics", "textDocument/diagnostic" },
  { "Workspace diagnostics", "workspace/diagnostic" },
  { "Call hierarchy", "textDocument/prepareCallHierarchy" },
  { "Type hierarchy", "textDocument/prepareTypeHierarchy" },
  { "Code lens", "textDocument/codeLens" },
  { "Inlay hints", "textDocument/inlayHint" },
}

function M.snapshot(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local result = { buf = buf, clients = {}, outcomes = request.history(buf), lifecycle = {} }
  local clients = vim.lsp.get_clients({ bufnr = buf })
  table.sort(clients, function(a, b)
    return a.id < b.id
  end)
  for _, client in ipairs(clients) do
    local info = {
      id = client.id,
      name = client.name,
      root = client.root_dir or (client.config or {}).root_dir,
      encoding = client.offset_encoding,
      initialized = client.initialized,
      workspaces = {},
      methods = {},
      pending = {},
    }
    if type(info.root) ~= "string" then
      info.root = nil
    end
    for _, folder in ipairs(client.workspace_folders or {}) do
      info.workspaces[#info.workspaces + 1] = folder.uri
    end
    for _, method in ipairs(methods) do
      info.methods[method[2]] = client:supports_method(method[2], buf)
    end
    for id, pending in pairs(client.requests or {}) do
      if pending.bufnr == buf then
        info.pending[#info.pending + 1] =
          { id = id, method = pending.method, status = pending.type }
      end
    end
    table.sort(info.pending, function(a, b)
      return a.id < b.id
    end)
    result.clients[#result.clients + 1] = info
  end
  result.lifecycle = recorder.history(buf)
  return result
end

local function render(s)
  if not panel.alive(s) then
    return
  end
  local data = M.snapshot(s.ctx.buf)
  local lines = {
    "LSP inspection",
    "r refresh · y copy · l LSP log · b source · q close",
    "",
    "Buffer: " .. vim.api.nvim_buf_get_name(data.buf),
    "Attached clients: " .. #data.clients,
    "",
  }
  for _, client in ipairs(data.clients) do
    lines[#lines + 1] = ("#%d %s · %s · %s"):format(
      client.id,
      client.name,
      client.encoding or "unknown encoding",
      client.initialized and "initialized" or "initializing"
    )
    lines[#lines + 1] = "  Root: " .. (client.root or "(not set)")
    for _, folder in ipairs(client.workspaces) do
      lines[#lines + 1] = "  Workspace: " .. folder
    end
    for _, pending in ipairs(client.pending) do
      lines[#lines + 1] = ("  Request #%d %s %s"):format(pending.id, pending.status, pending.method)
    end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "Feature providers (capability checks for this buffer)"
  for _, method in ipairs(methods) do
    local providers = {}
    for _, client in ipairs(data.clients) do
      if client.methods[method[2]] then
        providers[#providers + 1] = ("%s (#%d)"):format(client.name, client.id)
      end
    end
    lines[#lines + 1] = method[1]
      .. ": "
      .. (#providers > 0 and table.concat(providers, ", ") or "unsupported")
  end
  vim.list_extend(lines, {
    "",
    "Client selection",
    "Rename: choose one provider when multiple match (name/filter may narrow it).",
    "Linked editing: first capable client by ID.",
    "Outline/breadcrumbs: one provider; configured client_name/client_filter take priority.",
    "Code actions, highlights, hover and links: query capable providers; links prompt for different targets.",
    "",
    "Recent tool outcomes (new optional tools; newest last)",
  })
  if #data.outcomes == 0 then
    lines[#lines + 1] = "No completed tool requests recorded for this buffer."
  end
  for _, outcome in ipairs(data.outcomes) do
    lines[#lines + 1] = ("%s · %s · %d ms · %s"):format(
      outcome.client,
      outcome.method,
      outcome.elapsed_ms,
      outcome.error and "ERROR: " .. outcome.error or outcome.empty and "empty" or "result"
    )
  end
  vim.list_extend(lines, { "", "Native request lifecycle (status only; newest last)" })
  if #data.lifecycle == 0 then
    lines[#lines + 1] = "No lifecycle events recorded since inspection was enabled."
  end
  for _, event in ipairs(data.lifecycle) do
    lines[#lines + 1] = ("Client #%d request #%d · %s · %s"):format(
      event.client_id,
      event.id,
      event.method,
      event.status
    )
  end
  vim.list_extend(lines, {
    "",
    "Lifecycle events do not expose response contents or prove success. For other tools'",
    "response errors, use the native LSP log (l); this tool does not wrap client handlers.",
  })
  panel.write(s, lines)
end

function M.open(opts)
  if not enabled then
    return false
  end
  local existing = panel.get("inspect")
  if existing and vim.api.nvim_get_current_win() == existing.win then
    render(existing)
    return existing
  end
  if vim.bo.buftype ~= "" then
    return false
  end
  opts = opts or {}
  local s =
    panel.open("inspect", request.context(), { width = config.width, focus = opts.focus ~= false })
  sessions[s] = true
  s.on_close = function()
    sessions[s] = nil
  end
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = s.out })
  end
  map("r", function()
    render(s)
  end)
  map("b", function()
    panel.source(s, true)
  end)
  map("y", function()
    vim.fn.setreg('"', table.concat(vim.api.nvim_buf_get_lines(s.out, 0, -1, false), "\n"))
  end)
  map("l", function()
    if panel.source(s, false) then
      vim.cmd.edit(vim.fn.fnameescape(vim.lsp.log.get_filename()))
    end
  end)
  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
    group = s.group,
    buffer = s.ctx.buf,
    callback = function()
      vim.schedule(function()
        render(s)
      end)
    end,
  })
  render(s)
  return s
end

function M.disable()
  enabled = false
  recorder.disable()
  for s in pairs(vim.tbl_extend("force", {}, sessions)) do
    panel.close(s)
  end
end

function M.setup(opts)
  M.disable()
  config = vim.tbl_extend("force", config, opts or {})
  enabled = true
  recorder.setup()
end

return M
