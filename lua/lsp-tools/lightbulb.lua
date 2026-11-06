local M = {}
local request = require("lsp-tools.request")
local ns = vim.api.nvim_create_namespace("lsp-tools.lightbulb")
local config =
  { debounce = 200, request_timeout = 1500, text = "", hl = "DiagnosticHint", sign = false }
local enabled, group, pending, timer, marked
local method = "textDocument/codeAction"

local function clients()
  if not enabled or vim.bo.buftype ~= "" or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "n" then
    return {}
  end
  return vim.lsp.get_clients({ bufnr = vim.api.nvim_get_current_buf(), method = method })
end

local function clear()
  if pending then
    pending.cancel()
    pending = nil
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if marked and vim.api.nvim_buf_is_valid(marked) then
    vim.api.nvim_buf_clear_namespace(marked, ns, 0, -1)
  end
  marked = nil
end

local function query()
  clear()
  local providers = clients()
  if #providers == 0 then
    return
  end
  local ctx = request.context()
  pending = request.start({
    buf = ctx.buf,
    method = method,
    clients = providers,
    timeout = config.request_timeout,
    params = function(client)
      local params = request.position(ctx, client)
      params.range = { start = params.position, ["end"] = params.position }
      params.position = nil
      local diagnostics = {}
      for namespace in pairs(request.diagnostic_namespaces(client)) do
        for _, diagnostic in
          ipairs(vim.diagnostic.get(ctx.buf, { namespace = namespace, lnum = ctx.pos[1] - 1 }))
        do
          local original = diagnostic.user_data and diagnostic.user_data.lsp
          if original then
            diagnostics[#diagnostics + 1] = original
          end
        end
      end
      params.context = { diagnostics = diagnostics, triggerKind = 2 }
      return params
    end,
  }, function(results)
    if not enabled or not request.valid(ctx, true) then
      return
    end
    for _, result in ipairs(results) do
      if not result.error and type(result.result) == "table" then
        for _, action in ipairs(result.result) do
          if not action.disabled then
            local icon, hl =
              require("lsp-tools.icons").get("ui", "lightbulb", config.text, config.hl)
            if icon == "" then
              return
            end
            local opts = config.sign and { sign_text = icon, sign_hl_group = hl, priority = 20 }
              or { virt_text = { { icon, hl } }, virt_text_pos = "eol", priority = 20 }
            vim.api.nvim_buf_set_extmark(ctx.buf, ns, ctx.pos[1] - 1, 0, opts)
            marked = ctx.buf
            return
          end
        end
      end
    end
  end)
end

local function schedule()
  clear()
  if #clients() > 0 then
    timer = assert(vim.uv.new_timer())
    timer:start(config.debounce, 0, vim.schedule_wrap(query))
  end
end

function M.disable()
  enabled = false
  clear()
  if group then
    vim.api.nvim_del_augroup_by_id(group)
    group = nil
  end
end

local setup_defaults = vim.deepcopy(config)

function M.setup(opts)
  local next_config =
    vim.tbl_extend("force", vim.deepcopy(setup_defaults), vim.deepcopy(opts or {}))
  assert(
    type(next_config.debounce) == "number" and next_config.debounce >= 0,
    "debounce must be nonnegative"
  )
  assert(
    type(next_config.request_timeout) == "number" and next_config.request_timeout > 0,
    "request_timeout must be positive"
  )
  assert(
    type(next_config.text) == "string" and next_config.text ~= "",
    "lightbulb text must not be empty"
  )
  M.disable()
  config, enabled = next_config, true
  group = vim.api.nvim_create_augroup("LspToolsLightbulb", { clear = true })
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "TextChanged", "BufEnter", "InsertLeave", "LspAttach", "DiagnosticChanged" },
    {
      group = group,
      callback = schedule,
    }
  )
  vim.api.nvim_create_autocmd(
    { "InsertEnter", "BufLeave", "WinLeave", "BufWipeout", "LspDetach" },
    { group = group, callback = clear }
  )
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "ThemeToolsIconsChanged", "ThemeToolsReady" },
    callback = schedule,
  })
  schedule()
end

return M
