-- Decorate native hover previews without replacing their requests or focus lifecycle.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("lsp-tools.hover.float")
local installed

local function navigation(buf, hidden)
  if not next(hidden) then
    return
  end
  for key, motion in pairs({
    j = "j",
    k = "k",
    gj = "gj",
    gk = "gk",
    ["<Down>"] = "j",
    ["<Up>"] = "k",
    ["<C-n>"] = "j",
    ["<C-p>"] = "k",
  }) do
    vim.keymap.set({ "n", "x" }, key, function()
      -- Count visible steps, keeping native columns, wrapping and Visual selection.
      for _ = 1, vim.v.count1 do
        local pos
        repeat
          local before = api.nvim_win_get_cursor(0)
          vim.cmd.normal({ motion, bang = true })
          pos = api.nvim_win_get_cursor(0)
          if pos[1] == before[1] and pos[2] == before[2] then
            return
          end
        until not hidden[pos[1]] or vim.wo.conceallevel == 0
      end
    end, { buffer = buf, silent = true, desc = "Move across visible hover lines" })
  end
end

local function definition(name)
  local seen = {}
  while name and not seen[name] do
    seen[name] = true
    local value = api.nvim_get_hl(0, { name = name, link = true, create = false })
    if not value.link then
      return value
    end
    name = value.link
  end
  return {}
end

local function highlights(c)
  local normal, editor = definition("NormalFloat"), definition("Normal")
  local bg = c and c.ui.float_bg or normal.bg or "NONE"
  local groups = {
    Normal = { fg = c and c.ui.float_fg or normal.fg or editor.fg, bg = bg },
    Border = { fg = c and c.ui.border or definition("FloatBorder").fg, bg = bg },
    Title = c and { fg = c.ui.accent, bold = true } or { link = "Title" },
  }
  for suffix, value in pairs(groups) do
    local public, target = "LspToolsHover" .. suffix, "LspToolsDefaultHover" .. suffix
    api.nvim_set_hl(0, target, value)
    local empty = vim.tbl_isempty(api.nvim_get_hl(0, { name = public, create = false }))
    api.nvim_set_hl(0, public, { link = target, default = not empty })
  end
end

local function render(buf, win, markdown, opts)
  for name, value in pairs({
    list = false,
    spell = false,
    conceallevel = 2,
    concealcursor = "nvic",
    winblend = 0,
    winfixbuf = true,
    winhighlight = "Normal:LspToolsHoverNormal,NormalFloat:LspToolsHoverNormal,FloatBorder:LspToolsHoverBorder",
  }) do
    vim.wo[win][name] = value
  end
  if markdown then
    vim.bo[buf].filetype = "markdown"
    if not pcall(vim.treesitter.start, buf, "markdown") then
      vim.bo[buf].syntax = "markdown"
    end
    -- Hide entire fence rows even with older/missing Tree-sitter conceal queries.
    -- Keep the original Markdown and language annotations for highlighting/yanking.
    local fence
    local hidden = {}
    for row, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local marker, rest = line:match("^%s*([`~]+)(.*)$")
      if marker and #marker >= 3 and (marker:match("^`+$") or marker:match("^~+$")) then
        local opening = not fence and not (marker:sub(1, 1) == "`" and rest:find("`", 1, true))
        local closing = fence
          and marker:sub(1, 1) == fence:sub(1, 1)
          and #marker >= #fence
          and rest:match("^%s*$")
        if opening or closing then
          fence = opening and marker or nil
          hidden[row] = true
          api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { conceal_lines = "" })
        end
      elseif not fence then
        local heading = line:match("^%s*#+%s+")
        if heading then
          api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_col = #heading, conceal = "" })
        elseif line:match("^%s*%-%-%-+%s*$") then
          api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
            virt_text = {
              {
                string.rep("─", math.max(1, api.nvim_win_get_width(win) - 1)),
                "LspToolsHoverBorder",
              },
            },
            virt_text_pos = "overlay",
          })
        end
      end
    end
    navigation(buf, hidden)
  end
  if not opts.height then
    local height = api.nvim_win_text_height(win, {}).all
    api.nvim_win_set_height(win, math.max(1, math.min(height, opts.max_height)))
  end
end

function M.disable()
  if not installed then
    return
  end
  installed.enabled = false
  if installed.stop then
    installed.stop()
  end
  if vim.lsp.util.open_floating_preview == installed.wrapper then
    vim.lsp.util.open_floating_preview = installed.original
  end
  api.nvim_del_augroup_by_id(installed.group)
  installed = nil
end

function M.setup(opts)
  M.disable()
  if opts == false then
    return
  end
  opts = opts or {}
  local state = { enabled = true, original = vim.lsp.util.open_floating_preview }
  state.wrapper = function(contents, syntax, options)
    if not state.enabled or not options or options.focus_id ~= "textDocument/hover" then
      return state.original(contents, syntax, options)
    end
    local styled = vim.tbl_extend("force", {
      border = opts.border or "rounded",
      title = { { " Documentation ", "LspToolsHoverTitle" } },
      title_pos = "left",
      max_width = opts.max_width or 80,
      max_height = opts.max_height or 20,
    }, options)
    styled.max_width = math.max(1, math.min(styled.max_width, vim.o.columns - 4))
    styled.max_height = math.max(1, math.min(styled.max_height, vim.o.lines - 4))
    if styled.border == "none" or styled.border == "" then
      styled.title, styled.title_pos = nil, nil
    end
    local markdown = syntax == "markdown"
    local padded = { " " }
    for _, line in ipairs(contents) do
      padded[#padded + 1] = " " .. line:gsub("\r$", "") .. " "
    end
    padded[#padded + 1] = " "
    -- Native Markdown styling depends on g:syntax_on and can fail without a parser.
    -- Start highlighting explicitly after opening, independent of legacy syntax.
    local buf, win = state.original(padded, markdown and "plaintext" or syntax, styled)
    if not vim.b[buf].lsp_tools_hover_float then
      vim.b[buf].lsp_tools_hover_float = true
      render(buf, win, markdown, styled)
      if opts.on_render then
        local ok, err =
          pcall(opts.on_render, { buf = buf, win = win, contents = contents, syntax = syntax })
        if not ok then
          vim.notify("lsp-tools hover.float.on_render: " .. tostring(err), vim.log.levels.ERROR)
        end
      end
    end
    return buf, win
  end
  state.group = api.nvim_create_augroup("LspToolsHoverFloat", { clear = true })
  local function attach()
    local themes = package.loaded.theme_tools
    if not state.stop and type(themes) == "table" and type(themes.on_change) == "function" then
      state.stop = themes.on_change("lsp-tools:hover-float", highlights)
    end
    return state.stop ~= nil
  end
  api.nvim_create_autocmd("ColorScheme", {
    group = state.group,
    callback = function()
      if not attach() then
        highlights()
      end
    end,
  })
  api.nvim_create_autocmd(
    "User",
    { group = state.group, pattern = "ThemeToolsReady", callback = attach }
  )
  if not attach() then
    highlights()
  end
  vim.lsp.util.open_floating_preview = state.wrapper
  installed = state
end

return M
