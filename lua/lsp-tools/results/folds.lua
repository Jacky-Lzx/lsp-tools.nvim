local M = {}
local api = vim.api
local layouts = {}
local function command(line, keys)
  api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd.normal({ args = { keys }, bang = true })
end
local function close_groups(groups, states)
  for i = #groups, 1, -1 do
    local group = groups[i]
    if states[group.key] and vim.fn.foldclosed(group.first) == -1 then
      command(group.first, "zc")
    end
  end
end
-- Inspect nested native folds by temporarily opening their closed parents.
-- Restore everything synchronously, before control returns to the editor UI.
function M.capture(v)
  local layout = layouts[v.out]
  if not layout or not api.nvim_win_is_valid(v.win) or api.nvim_win_get_buf(v.win) ~= v.out then
    return
  end
  api.nvim_win_call(v.win, function()
    local saved = vim.fn.winsaveview()
    v.fold_level, v.fold_enable = vim.wo.foldlevel, vim.wo.foldenable
    vim.wo.foldenable = true
    for _, group in ipairs(layout.fold_ranges) do
      local closed = vim.fn.foldclosed(group.first) == group.first
      v.folds[group.key] = closed
      if closed then
        command(group.first, "zo")
      end
    end
    close_groups(layout.fold_ranges, v.folds)
    vim.wo.foldenable = v.fold_enable
    vim.fn.winrestview(saved)
  end)
end
function M.apply(v, layout)
  layouts[v.out] = layout
  api.nvim_buf_set_var(v.out, "lsp_tools_result_foldlevels", layout.fold_levels)
  api.nvim_win_call(v.win, function()
    local saved = vim.fn.winsaveview()
    vim.wo.foldenable = true
    vim.wo.foldlevel = v.fold_level
    vim.cmd.normal({ args = { "zX" }, bang = true })
    local states = {}
    for _, group in ipairs(layout.fold_ranges) do
      local closed = v.folds[group.key]
      if closed == nil then
        closed = group.depth > v.fold_level
      end
      states[group.key] = closed
      if vim.fn.foldclosed(group.first) == group.first then
        command(group.first, "zo")
      end
    end
    close_groups(layout.fold_ranges, states)
    vim.wo.foldenable = v.fold_enable
    vim.fn.winrestview(saved)
  end)
end
function M.reveal(v, line)
  local layout = layouts[v.out]
  api.nvim_win_call(v.win, function()
    if vim.wo.foldenable and layout then
      for _, group in ipairs(layout.fold_ranges) do
        if
          group.first <= line
          and line <= group.last
          and vim.fn.foldclosed(group.first) == group.first
        then
          command(group.first, "zo")
        end
      end
    end
    api.nvim_win_set_cursor(0, { line, 0 })
  end)
end
function M.release(v)
  layouts[v.out] = nil
end
-- Native foldtext chunks keep the same semantic colors as the open group row.
function M.text()
  local layout = layouts[api.nvim_get_current_buf()]
  local first = vim.v.foldstart
  if not layout or not layout.lines[first] then
    return vim.fn.getline(first)
  end
  local text = layout.lines[first]:gsub("", "", 1):gsub("▾", "▸", 1)
  local chunks, col = {}, 0
  for _, span in ipairs(layout.highlights[first]) do
    if span[1] > col then
      chunks[#chunks + 1] = { text:sub(col + 1, span[1]), "LspToolsResultsText" }
    end
    chunks[#chunks + 1] = { text:sub(span[1] + 1, span[2]), span[3] }
    col = span[2]
  end
  if col < #text then
    chunks[#chunks + 1] = { text:sub(col + 1), "LspToolsResultsText" }
  end
  return chunks
end
return M
