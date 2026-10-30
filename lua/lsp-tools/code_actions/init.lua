local M = {}
local config = {
  resolve_timeout = 3000,
  backend = "vim",
  delta = { command = "delta", args = {}, timeout = 2000 },
  picker = {},
}
local installed, previous_select
local enabled = false
local setup_group

local function notify(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "Code Actions" })
end

local function select(actions, opts, on_choice, on_applied)
  return require("lsp-tools.code_actions.picker").open(actions, opts, on_choice, config, on_applied)
end

-- Reuse the preview/apply path for contextual workflows that already requested actions.
function M.pick(entries, on_applied, on_cancel)
  if not enabled then
    notify("Enable code_actions to preview diagnostic fixes")
    return false
  end
  return select(entries, {
    format_item = function(entry)
      return entry.action.title
    end,
  }, function()
    if on_cancel then
      on_cancel()
    end
  end, on_applied)
end

function M.setup(opts)
  local next_config = vim.tbl_deep_extend("force", config, opts or {})
  require("lsp-tools.config").diff(next_config)
  assert(
    type(next_config.resolve_timeout) == "number" and next_config.resolve_timeout > 0,
    "resolve_timeout must be positive"
  )
  config = next_config
  enabled = true
  local function install()
    if vim.ui.select == installed then
      return
    end
    local previous = vim.ui.select
    previous_select = previous
    installed = function(items, options, callback)
      options = options or {}
      -- Neovim's codeaction item shape is internal: safely delegate if it changes.
      local supported = enabled
        and options.kind == "codeaction"
        and #items > 0
        and type(options.format_item) == "function"
      for _, item in ipairs(items) do
        supported = supported
          and type(item) == "table"
          and item.action
          and item.ctx
          and item.ctx.client_id
          and item.ctx.bufnr
      end
      if supported then
        return select(items, options, callback)
      end
      return previous(items, options, callback)
    end
    vim.ui.select = installed
  end
  install()
  if vim.v.vim_did_enter == 0 then
    setup_group = vim.api.nvim_create_augroup("LspToolsCodeActionsSetup", { clear = true })
    vim.api.nvim_create_autocmd("UIEnter", {
      group = setup_group,
      once = true,
      callback = function()
        vim.schedule(function()
          if enabled then
            install()
          end
        end)
      end,
    })
  end
end

---Disable the adapter without replacing a UI provider installed by another plugin.
function M.disable()
  enabled = false
  if setup_group then
    vim.api.nvim_clear_autocmds({ group = setup_group })
  end
  local picker = package.loaded["lsp-tools.code_actions.picker"]
  if picker then
    picker.disable()
  end
  if installed and vim.ui.select == installed then
    vim.ui.select = previous_select
  end
end

function M.code_action(opts)
  return vim.lsp.buf.code_action(opts)
end

return M
