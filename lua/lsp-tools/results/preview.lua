local M = {}
local api = vim.api
local model = require("lsp-tools.results.model")
local ns = api.nvim_create_namespace("lsp-tools.results.preview")
local syntax_ns = api.nvim_create_namespace("lsp-tools.results.preview.syntax")
local function source(item, opts)
  local first = math.max(1, item.pos[1] - (opts.before or 3))
  local buf = item.bufnr or (item.uri and vim.uri_to_bufnr(item.uri))
  if buf and api.nvim_buf_is_loaded(buf) then
    return api.nvim_buf_get_lines(
      buf,
      first - 1,
      math.min(api.nvim_buf_line_count(buf), item.pos[1] + (opts.after or 6)),
      false
    ),
      first,
      vim.bo[buf].filetype
  end
  if item.filename then
    local stat = vim.uv.fs_stat(item.filename)
    if stat and stat.size <= 1024 * 1024 then
      local ok, lines = pcall(vim.fn.readfile, item.filename, "", item.pos[1] + (opts.after or 6))
      if ok then
        return vim.list_slice(lines, first, item.pos[1] + (opts.after or 6)), first
      end
    end
  end
end
local function treesitter(buf, lines, offset, ft)
  local lang = vim.treesitter.language.get_lang(ft)
  if not lang then
    return false
  end
  local text = table.concat(lines, "\n")
  local painted = false
  local ok = pcall(function()
    local parser = assert(vim.treesitter.get_string_parser(text, lang))
    parser:parse()
    parser:for_each_tree(function(tree, language)
      local query = vim.treesitter.query.get(language:lang(), "highlights")
      if not query then
        return
      end
      for capture, node, metadata in query:iter_captures(tree:root(), text, 0, -1) do
        local name = query.captures[capture]
        if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" then
          local range = vim.treesitter.get_range(node, text, metadata[capture])
          api.nvim_buf_set_extmark(buf, syntax_ns, offset + range[1], range[2], {
            end_row = offset + range[4],
            end_col = range[5],
            hl_group = "@" .. name .. "." .. language:lang(),
            priority = tonumber((metadata[capture] or {}).priority or metadata.priority) or 100,
            strict = false,
          })
          painted = true
        end
      end
    end)
  end)
  if not ok or not painted then
    api.nvim_buf_clear_namespace(buf, syntax_ns, 0, -1)
    return false
  end
  return true
end
local function legacy(buf, offset, count, ft)
  if
    not ft:match("^[%w_]+$") or #api.nvim_get_runtime_file("syntax/" .. ft .. ".vim", false) == 0
  then
    return false
  end
  return pcall(api.nvim_buf_call, buf, function()
    vim.cmd("syntax include @LspToolsPreviewCode syntax/" .. ft .. ".vim")
    vim.cmd(
      ("syntax region LspToolsPreviewCode start=/\\%%%dl/ end=/\\%%%dl/ contains=@LspToolsPreviewCode keepend"):format(
        offset + 1,
        offset + count + 1
      )
    )
    vim.cmd("syntax sync fromstart")
  end)
end
local function target(buf, item, lines, first, offset)
  local row = item.pos[1] - first
  if row < 0 or row >= #lines then
    return
  end
  api.nvim_buf_set_extmark(
    buf,
    ns,
    offset + row,
    0,
    { line_hl_group = "LspToolsResultsPreviewLine", priority = 110 }
  )
  if item.column_unknown then
    return offset + row + 1, 0
  end
  local col = math.min(item.pos[2], #lines[row + 1])
  local last_row = math.min(#lines - 1, math.max(row, (item.end_pos or item.pos)[1] - first))
  local last_col = (item.end_pos or item.pos)[1] - first >= #lines and #lines[last_row + 1]
    or math.min((item.end_pos or item.pos)[2], #lines[last_row + 1])
  if last_row == row and last_col <= col then
    local char = lines[row + 1]:sub(col + 1):match("^[%z\1-\127\194-\244][\128-\191]*") or ""
    last_col = col + #char
  end
  if last_row > row or last_col > col then
    api.nvim_buf_set_extmark(buf, ns, offset + row, col, {
      end_row = offset + last_row,
      end_col = last_col,
      hl_group = "LspToolsResultsPreviewRange",
      priority = 150,
    })
  end
  return offset + row + 1, col
end
function M.line_number()
  local info = vim.b.lsp_tools_preview
  local row = vim.v.lnum
  if info and vim.v.virtnum == 0 and row >= info.start and row <= info.finish then
    return tostring(info.first + row - info.start)
  end
  return ""
end
function M.open(item, opts, owner)
  opts = opts or {}
  local path = model.clean(item.filename or item.uri or "[no source]")
  if not path:find("://", 1, true) then
    path = vim.fn.fnamemodify(path, ":~:.")
  end
  local width =
    math.max(1, math.min(vim.o.columns - 4, math.floor(vim.o.columns * (opts.width or 0.6))))
  local level = ({ "Error", "Warning", "Information", "Hint" })[item.severity]
  local severity = ({ "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" })[item.severity]
    or "LspToolsResultsText"
  local lines =
    { path .. ":" .. item.pos[1] .. ":" .. (item.column_unknown and "?" or item.pos[2] + 1), "" }
  local metadata = {}
  for _, value in ipairs({ item.source or "", item.code or "" }) do
    if tostring(value) ~= "" then
      metadata[#metadata + 1] = model.clean(value)
    end
  end
  if #metadata > 0 then
    lines[2] = table.concat(metadata, "  ·  ")
    lines[#lines + 1] = ""
  end
  local message_first = #lines
  if item.text ~= "" then
    vim.list_extend(lines, vim.split(item.text, "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  local code, first, ft = source(item, opts)
  local message_last = #lines - 1
  local divider = #lines
  local label = "── Source "
  lines[#lines + 1] = label
    .. string.rep("─", math.max(0, width - 8 - vim.fn.strdisplaywidth(label)))
  lines[#lines + 1] = ""
  local offset = #lines
  vim.list_extend(
    lines,
    code and #code > 0 and code
      or { "Source unavailable or larger than preview limit; Enter opens the location." }
  )
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden, vim.bo[buf].modifiable = "wipe", false
  vim.bo[buf].filetype = "lsp-tools-results"
  api.nvim_buf_set_extmark(
    buf,
    ns,
    0,
    0,
    { end_col = #path, hl_group = "LspToolsResultsPreviewPath" }
  )
  local filename = path:match("[^/]+$") or path
  api.nvim_buf_set_extmark(buf, ns, 0, #path - #filename, {
    end_col = #path,
    hl_group = "LspToolsResultsPreviewFile",
    priority = 110,
  })
  api.nvim_buf_set_extmark(
    buf,
    ns,
    0,
    #path,
    { end_col = #lines[1], hl_group = "LspToolsResultsPosition" }
  )
  if #metadata > 0 then
    api.nvim_buf_set_extmark(
      buf,
      ns,
      1,
      0,
      { end_col = #lines[2], hl_group = "LspToolsResultsPreviewMeta" }
    )
  end
  api.nvim_buf_set_extmark(buf, ns, divider, 0, {
    end_col = #lines[divider + 1],
    hl_group = "LspToolsResultsPreviewDivider",
  })
  for row = message_first, message_last - 1 do
    api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #lines[row + 1], hl_group = severity })
  end
  local backend, target_row, target_col
  if code and #code > 0 then
    ft = ft ~= "" and ft or nil
    if not ft and (item.filename or first == 1) then
      ft = vim.filetype.match({ filename = item.filename, contents = first == 1 and code or nil })
    end
    if ft and ft ~= "" then
      if treesitter(buf, code, offset, ft) then
        backend = "treesitter"
      elseif legacy(buf, offset, #code, ft) then
        backend = "syntax"
      end
    end
    target_row, target_col = target(buf, item, code, first, offset)
  else
    api.nvim_buf_set_extmark(
      buf,
      ns,
      offset,
      0,
      { end_col = #lines[offset + 1], hl_group = "LspToolsResultsMeta" }
    )
  end
  local height = math.max(1, math.min(#lines, math.floor((vim.o.lines - 4) * (opts.height or 0.5))))
  local window = {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    title = { { " " .. (level or "Source preview") .. " ", severity } },
    title_pos = "left",
    footer = code
        and #code > 0
        and (" " .. (ft ~= "" and ft or "source") .. " · " .. first .. "–" .. (first + #code - 1) .. " ")
      or " Source unavailable ",
    footer_pos = "right",
    style = "minimal",
    focusable = true,
  }
  if opts.layout == "right" or opts.layout == "bottom" then
    window = { split = opts.layout == "right" and "right" or "below", win = -1 }
    window[opts.layout == "right" and "width" or "height"] = opts.layout == "right" and width
      or height
  end
  local win = api.nvim_open_win(buf, false, window)
  vim.wo[win][0].wrap, vim.wo[win][0].foldenable = true, false
  vim.wo[win][0].scrolloff, vim.wo[win][0].sidescrolloff = 0, 0
  vim.wo[win][0].winhighlight =
    "Normal:LspToolsResultsPreviewNormal,NormalFloat:LspToolsResultsPreviewNormal,FloatBorder:LspToolsResultsPreviewBorder,FloatFooter:LspToolsResultsPreviewMeta"
  vim.b[buf].lsp_tools_preview =
    { start = offset + 1, finish = offset + (code and #code or 0), first = first or 1 }
  vim.wo[win][0].number, vim.wo[win][0].relativenumber = true, false
  vim.wo[win][0].statuscolumn =
    "  %#LineNr#%4{v:lua.require'lsp-tools.results.preview'.line_number()}  "
  if owner then
    local bindings = require("lsp-tools.keymaps").new(buf, owner.options)
    bindings:map("return_list", { "<Esc>", "<prefix>b" }, owner.return_list, "Return to results")
    bindings:map("more_context", "<prefix>+", function()
      owner.reopen({ before = (opts.before or 3) + 20, after = (opts.after or 6) + 20 })
    end, "Expand source context")
    bindings:map("preview_layout", "<prefix>s", function()
      owner.reopen({ layout = opts.layout == "right" and "float" or "right" })
    end, "Toggle side preview")
    bindings:map("help", "<prefix>?", function()
      bindings:show_help(win)
    end, "Show key bindings")
    api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        bindings:close_help()
      end,
    })
  end
  if target_row then
    api.nvim_win_set_cursor(win, { target_row, target_col })
  end
  return {
    win = win,
    buf = buf,
    code_start = offset + 1,
    source_first = first,
    filetype = ft,
    highlight_backend = backend,
    target_row = target_row,
  }
end
return M
