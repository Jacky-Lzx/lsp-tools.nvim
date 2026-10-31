-- Thin presentation adapter: selection-tools owns all windows and preview frames.
local M = {}
local active

function M.current()
  return active and not active.closed and active or nil
end

function M.pick(options)
  local opts = vim.tbl_extend("force", {}, options)
  opts.prompt = options.title
  opts.format_item = function(item)
    return item.text
  end
  opts.resume, opts.multi = false, false
  opts.preview = { enabled = true }
  opts.previewer = options.preview
  opts.before_confirm = function(ctx)
    options.confirm(ctx.picker, ctx.item, ctx.accept, ctx.is_cancelled, ctx.reject)
    -- Completion may be asynchronous; the caller accepts or rejects explicitly.
  end
  opts.on_choice = nil
  opts.on_close = function(picker, outcome)
    if active == picker then
      active = nil
    end
    if options.on_close then
      options.on_close(picker, outcome)
    end
  end
  opts.confirm, opts.format, opts.win, opts.title = nil, nil, nil, nil
  local picker = require("selection_tools").open(opts)
  if not picker.closed then
    active = picker
  end
  return picker
end

return M
