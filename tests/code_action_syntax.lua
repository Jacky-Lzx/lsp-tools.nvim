local root = vim.env.LSP_TOOLS_ROOT or vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(vim.env.GIT_TOOLS_DIR or root .. "/../git-tools.nvim")
vim.opt.rtp:prepend(vim.env.SELECTION_TOOLS_DIR or root .. "/../selection-tools.nvim")
vim.opt.rtp:prepend(root .. "/../pairs.nvim")
local api = vim.api
local function run()
  require("pairs").setup({
    rainbow = { highlights = { "RainbowOne", "RainbowTwo", "RainbowThree" } },
  })
  api.nvim_set_hl(0, "RainbowOne", { fg = "#ff0000" })
  api.nvim_set_hl(0, "RainbowTwo", { fg = "#00ff00" })
  api.nvim_set_hl(0, "RainbowThree", { fg = "#0000ff" })
  if pcall(vim.treesitter.language.add, "lua") then
    vim.treesitter.query.set(
      "lua",
      "highlights",
      [[
      (function_declaration ["function" "end"] @keyword.function)
      (comment) @comment
      ["(" ")" "{" "}"] @punctuation.bracket
    ]]
    )
  end
  local function wait(predicate, message)
    local start = vim.uv.hrtime()
    while not predicate() do
      assert((vim.uv.hrtime() - start) / 1e6 < 5000, message)
      if vim.env.LSP_TOOLS_TUI == "1" then
        coroutine.yield()
      else
        vim.wait(10)
      end
    end
  end
  local before = { "local function outer()", "  local items = {", "    { true },", "  }" }
  for i = 1, 18 do
    before[#before + 1] = "  -- padding " .. i
  end
  before[#before + 1] = "  return items"
  before[#before + 1] = "end"
  vim.cmd.enew()
  local source, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
  api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
  vim.bo[source].filetype = "lua"
  api.nvim_buf_set_lines(source, 0, -1, false, before)
  local uri = vim.uri_from_bufnr(source)
  local function edit(row, col, text)
    return {
      range = { start = { line = row, character = col }, ["end"] = { line = row, character = col } },
      newText = text,
    }
  end
  local action = {
    title = "Full document syntax",
    edit = {
      changes = { [uri] = { edit(0, 21, " -- opening"), edit(#before - 1, 3, " -- closing") } },
    },
  }
  local preview = require("lsp-tools.code_actions.preview")
  local lines, groups, sources = preview.lines(action, "utf-8")
  assert(#sources == 1 and #groups[1].sources == 1 and vim.deep_equal(sources[1].before, before))
  local repeated = {
    edit = {
      documentChanges = {
        { textDocument = { uri = uri }, edits = { edit(0, 21, " -- first") } },
        { textDocument = { uri = uri }, edits = { edit(#before - 1, 3, " -- second") } },
      },
    },
  }
  local _, repeated_groups, repeated_sources = preview.lines(repeated, "utf-8")
  assert(#repeated_sources == 2 and #repeated_groups[1].sources == 2)
  assert(
    vim.deep_equal(repeated_sources[1].after, repeated_sources[2].before),
    "Sequential edits require distinct snapshots of the same path"
  )
  local workspace =
    require("lsp-tools.workspace_edit").capture(repeated.edit, "utf-8", vim.fn.getcwd())
  assert(
    #workspace.items[1].sources == 2 and workspace.validate(),
    "Rename keeps per-file snapshot order"
  )

  local old_client = vim.lsp.get_client_by_id
  vim.lsp.get_client_by_id = function(id)
    if id == 98765 then
      return {
        offset_encoding = "utf-8",
        supports_method = function()
          return false
        end,
      }
    end
    return old_client(id)
  end
  local actions = require("lsp-tools.code_actions")
  actions.setup({ backend = "native", native = { file_header = false } })
  actions.pick({ { action = action, ctx = { bufnr = source, client_id = 98765 } } })
  local function picker()
    return require("lsp-tools.selection").current()
  end
  local function frame()
    local p = picker()
    return p and api.nvim_win_get_buf(p.preview_win)
  end
  wait(function()
    return frame() and vim.b[frame()].git_tools_diff
  end, "Native code action frame did not publish")
  local function check()
    local buf = frame()
    local rows = api.nvim_buf_get_lines(buf, 0, -1, false)
    local marks = api.nvim_buf_get_extmarks(
      buf,
      api.nvim_create_namespace("GitToolsDiffSyntax"),
      0,
      -1,
      { details = true }
    )
    local ends, colors = 0, 0
    for _, mark in ipairs(marks) do
      local text, hl = rows[mark[2] + 1], mark[4].hl_group
      if text:match("^end") and hl == "@keyword.function.lua" then
        ends = ends + 1
      end
      if hl:match("^Rainbow") then
        colors = colors + 1
      end
    end
    if pcall(vim.treesitter.language.add, "lua") then
      assert(ends == 2, "Separated function ends lost context")
    end
    assert(colors > 0, "Loaded rainbow provider must decorate the full snapshots")
    assert(api.nvim_get_current_win() == picker().input_win, "Preview stole picker focus")
    assert(vim.deep_equal(api.nvim_buf_get_lines(source, 0, -1, false), before))
    if vim.env.LSP_TOOLS_TUI == "1" then
      vim.cmd.redraw()
      local top, left = unpack(api.nvim_win_get_position(picker().preview_win))
      local screen = {}
      for row = 1, api.nvim_win_get_height(picker().preview_win) do
        local cells = {}
        for col = 1, api.nvim_win_get_width(picker().preview_win) do
          cells[#cells + 1] = vim.fn.screenstring(top + row, left + col)
        end
        screen[#screen + 1] = table.concat(cells)
      end
      assert(
        table.concat(screen, "\n"):find("outer", 1, true),
        "Real terminal frame must display code"
      )
    end
  end
  check()
  local first = frame()
  picker():set_query("no-such-action")
  wait(function()
    return #picker().matches == 0
  end, "Zero matches did not filter")
  picker():set_query("")
  wait(function()
    return frame() and vim.b[frame()].git_tools_diff and frame() ~= first
  end, "Clearing filter did not reconstruct source highlights")
  check()
  picker():close()
  wait(function()
    return picker() == nil
  end, "Code action did not close")
  assert(api.nvim_get_current_win() == origin)
  for _, buf in ipairs(api.nvim_list_bufs()) do
    assert(not vim.b[buf].git_tools_diff, "Closing leaked a native frame")
  end
  vim.lsp.get_client_by_id = old_client
  local report =
    "Code action full syntax: sequential snapshots, rename reuse, multi-hunk ends, optional rainbow, filter recovery, focus and cleanup passed"
  if vim.env.LSP_TOOLS_TEST_TMP then
    vim.fn.writefile({ report }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
  end
  print(report)
  vim.cmd("qa!")
end
if vim.env.LSP_TOOLS_TUI == "1" then
  local thread = coroutine.create(run)
  local function step()
    local ok, err = coroutine.resume(thread)
    if not ok then
      if vim.env.LSP_TOOLS_TEST_TMP then
        vim.fn.writefile(
          { tostring(err), debug.traceback(thread) },
          vim.env.LSP_TOOLS_TEST_TMP .. "/result"
        )
      end
      vim.cmd("cquit 1")
    elseif coroutine.status(thread) ~= "dead" then
      vim.defer_fn(step, 10)
    end
  end
  vim.schedule(step)
else
  run()
end
