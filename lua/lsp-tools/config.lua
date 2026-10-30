local M = {}

function M.diff(config)
  assert(config.backend == "vim" or config.backend == "delta", "backend must be 'vim' or 'delta'")
  assert(type(config.delta) == "table", "delta must be a table")
  assert(type(config.delta.command) == "string", "delta.command must be an executable name or path")
  assert(
    type(config.delta.args) == "table" and vim.islist(config.delta.args),
    "delta.args must be a list"
  )
  for _, arg in ipairs(config.delta.args) do
    assert(type(arg) == "string", "delta.args must contain strings")
  end
  assert(
    type(config.delta.timeout) == "number" and config.delta.timeout > 0,
    "delta.timeout must be positive"
  )
end

-- Validate supplied options without importing the implementation or its defaults.
function M.tool(name, opts)
  require("lsp-tools.keymaps").validate(opts)
  if name == "results" and opts.history ~= nil then
    assert(
      type(opts.history) == "number" and opts.history >= 0 and opts.history % 1 == 0,
      "results.history must be a nonnegative integer"
    )
  end
  if name == "results" and opts.presets then
    assert(type(opts.presets) == "table", "results.presets must be a table")
    for key, value in pairs(opts.presets) do
      assert(
        type(key) == "string" and type(value) == "table",
        "presets must map names to filter tables"
      )
    end
  end
  if name == "results" and opts.preview then
    assert(type(opts.preview) == "table", "results.preview must be a table")
    for _, key in ipairs({ "before", "after" }) do
      local value = opts.preview[key]
      assert(
        value == nil or type(value) == "number" and value >= 0 and value % 1 == 0,
        "preview context must be a nonnegative integer"
      )
    end
    assert(
      opts.preview.layout == nil
        or vim.tbl_contains({ "float", "right", "bottom" }, opts.preview.layout),
      "invalid preview layout"
    )
    for _, key in ipairs({ "width", "height" }) do
      assert(
        opts.preview[key] == nil
          or type(opts.preview[key]) == "number"
            and opts.preview[key] > 0
            and opts.preview[key] <= 1,
        "preview size must be a fraction between 0 and 1"
      )
    end
  end
  for _, key in ipairs({
    "request_timeout",
    "resolve_timeout",
    "advance_timeout",
    "width",
    "min_width",
    "max_width",
    "max_nodes",
    "max_depth",
    "height",
    "max_items",
  }) do
    if opts[key] ~= nil then
      assert(
        type(opts[key]) == "number" and opts[key] > 0,
        name .. "." .. key .. " must be positive"
      )
    end
  end
  if opts.debounce ~= nil then
    assert(
      type(opts.debounce) == "number" and opts.debounce >= 0,
      name .. ".debounce must be nonnegative"
    )
  end
  if opts.indent ~= nil then
    assert(
      type(opts.indent) == "number" and opts.indent >= 0 and opts.indent % 1 == 0,
      "outline.indent must be a nonnegative integer"
    )
  end
  if name == "outline" or name == "breadcrumbs" then
    if opts.mode ~= nil then
      assert(
        vim.tbl_contains({ "auto", "all", "sections", "structure" }, opts.mode),
        "invalid " .. name .. ".mode"
      )
    end
  end
  if name == "breadcrumbs" then
    if opts.mode ~= nil then
      assert(opts.mode ~= "structure", "invalid breadcrumbs.mode")
    end
    if opts.debounce ~= nil then
      assert(opts.debounce > 0, "breadcrumbs.debounce must be positive")
    end
    if opts.separator ~= nil then
      assert(type(opts.separator) == "string", "breadcrumbs.separator must be a string")
    end
  end
  if name == "lightbulb" and opts.text ~= nil then
    assert(type(opts.text) == "string" and opts.text ~= "", "lightbulb text must not be empty")
  end
  for _, key in ipairs({ "open", "fallback", "validate" }) do
    if opts[key] ~= nil then
      assert(type(opts[key]) == "function", name .. "." .. key .. " must be a function")
    end
  end
  if name == "rename" or name == "code_actions" then
    M.diff(
      vim.tbl_deep_extend(
        "force",
        { backend = "vim", delta = { command = "delta", args = {}, timeout = 2000 } },
        opts
      )
    )
  end
end

return M
