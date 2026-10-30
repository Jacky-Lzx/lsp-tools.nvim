local M = {}
local api = vim.api
local model = require("lsp-tools.results.model")
local ns = api.nvim_create_namespace("lsp-tools.results.preview")
local syntax_ns = api.nvim_create_namespace("lsp-tools.results.preview.syntax")
local function source(item)
  local first = math.max(1, item.pos[1] - 3)
  local buf = item.bufnr or (item.uri and vim.uri_to_bufnr(item.uri))
  if buf and api.nvim_buf_is_loaded(buf) then
    return api.nvim_buf_get_lines(
      buf,
      first - 1,
      math.min(api.nvim_buf_line_count(buf), item.pos[1] + 6),
      false
    ),
      first,
      vim.bo[buf].filetype
  end
  if item.filename then
    local stat = vim.uv.fs_stat(item.filename)
    if stat and stat.size <= 1024 * 1024 then
      local ok, lines = pcall(vim.fn.readfile, item.filename, "", item.pos[1] + 6)
      if ok then
        return vim.list_slice(lines, first, item.pos[1] + 6), first
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
function M.open(item)
  local path = model.clean(item.filename or item.uri or "[no source]")
  local lines =
    { path .. ":" .. item.pos[1] .. ":" .. (item.column_unknown and "?" or item.pos[2] + 1), "" }
  local message_first = #lines
  if item.text ~= "" then
    vim.list_extend(lines, vim.split(item.text, "\n", { plain = true }))
    lines[#lines + 1] = ""
  end
  local code, first, ft = source(item)
  local offset, message_last = #lines, #lines - 1
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
  api.nvim_buf_set_extmark(
    buf,
    ns,
    0,
    #path,
    { end_col = #lines[1], hl_group = "LspToolsResultsPosition" }
  )
  local severity = ({ "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint" })[item.severity]
    or "LspToolsResultsText"
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
  local width, height =
    math.max(1, math.floor(vim.o.columns * 0.6)),
    math.max(1, math.min(#lines, math.floor((vim.o.lines - 4) * 0.5)))
  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    title = " Preview ",
    style = "minimal",
    focusable = false,
  })
  vim.wo[win].wrap, vim.wo[win].foldenable = true, false
  vim.wo[win].scrolloff, vim.wo[win].sidescrolloff = 0, 0
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
