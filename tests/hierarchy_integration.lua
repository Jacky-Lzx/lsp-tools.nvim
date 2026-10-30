local function run()
  vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
  local tui = vim.env.LSP_TOOLS_TUI == "1"
  local function wait(test, message)
    if not tui then
      assert(vim.wait(15000, test, 10), message)
      return
    end
    local start = vim.uv.hrtime()
    while not test() do
      assert((vim.uv.hrtime() - start) / 1e6 < 15000, message)
      coroutine.yield()
    end
  end
  local directory = assert(vim.env.LSP_TOOLS_TEST_TMP)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_name(buf, directory .. "/hierarchy.cpp")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "int leaf() { return 1; }",
    "int middle() { return leaf(); }",
    "int top() { return middle(); }",
    "int main() { return top(); }",
    "struct Base {};",
    "struct Derived : Base {};",
  })
  vim.bo[buf].filetype = "cpp"
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
  local id = assert(vim.lsp.start({
    name = "hierarchy-real-clangd",
    cmd = { "clangd", "--background-index=false", "--log=error" },
    root_dir = directory,
    capabilities = capabilities,
  }))
  local client = vim.lsp.get_client_by_id(id)
  wait(function()
    return client.initialized
  end, "clangd initializes")
  assert(client:supports_method("textDocument/prepareCallHierarchy", buf))
  vim.api.nvim_win_set_cursor(win, { 1, 5 })
  local ready, pending = false, false
  wait(function()
    if not pending and not ready then
      pending = true
      client:request(
        "textDocument/prepareCallHierarchy",
        vim.lsp.util.make_position_params(win, client.offset_encoding),
        function(err, result)
          if err or not result or not result[1] then
            pending = false
            return
          end
          client:request(
            "callHierarchy/incomingCalls",
            { item = result[1] },
            function(problem, calls)
              ready = not problem and calls and #calls > 0
              pending = false
            end,
            buf
          )
        end,
        buf
      )
    end
    return ready
  end, "real incoming calls indexed")
  local hierarchy = require("lsp-tools.hierarchy")
  hierarchy.setup()
  local s = assert(hierarchy.open("call"))
  wait(function()
    return s.trees.incoming and s.trees.incoming[1] and s.trees.incoming[1].children
  end, "first level expands")
  local root = s.trees.incoming[1]
  assert(root.item.name == "leaf" and root.children[1].item.name == "middle")
  local function key(lhs, row)
    vim.api.nvim_set_current_win(s.win)
    if row then
      vim.api.nvim_win_set_cursor(s.win, { row, 0 })
    end
    if tui then
      vim.api.nvim_input(lhs)
    else
      vim.fn.maparg(lhs, "n", false, true).callback()
    end
  end
  key("l", 6)
  wait(function()
    return root.children[1].children
  end, "second level expands lazily")
  assert(root.children[1].children[1].item.name == "top")
  key("p", 6)
  wait(function()
    return s.preview and vim.api.nvim_win_is_valid(s.preview)
  end, "callsite preview opens")
  local preview = table.concat(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(s.preview), 0, -1, false),
    "\n"
  )
  assert(preview:find("return leaf()", 1, true), "preview contains concrete caller source")
  key("g", 6)
  wait(function()
    return vim.api.nvim_get_current_win() == win
  end, "callsite jump returns source focus")
  assert(
    vim.api.nvim_win_get_cursor(win)[1] == 2,
    "callsite is invocation, not function definition"
  )
  if tui then
    key("q")
    wait(function()
      return not vim.api.nvim_win_is_valid(s.win)
    end, "terminal q closes hierarchy")
  else
    hierarchy.disable()
  end
  vim.api.nvim_set_current_win(win)
  if client:supports_method("textDocument/prepareTypeHierarchy", buf) then
    hierarchy.setup()
    vim.api.nvim_win_set_cursor(win, { 6, 8 })
    local types = assert(hierarchy.open("type"))
    wait(function()
      return types.trees.supertypes
        and types.trees.supertypes[1]
        and types.trees.supertypes[1].children
    end, "real type supertypes ready")
    assert(types.trees.supertypes[1].children[1].item.name == "Base", "Derived has Base supertype")
    hierarchy.disable()
    hierarchy.setup()
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 5, 8 })
    types = assert(hierarchy.open("type", { direction = "subtypes" }))
    wait(function()
      return types.trees.subtypes and types.trees.subtypes[1] and types.trees.subtypes[1].children
    end, "real type subtypes ready")
    assert(types.trees.subtypes[1].children[1].item.name == "Derived", "Base has Derived subtype")
    hierarchy.disable()
    print("hierarchy integration: real clangd supertype/subtype checks passed")
  else
    print(
      "hierarchy integration: installed clangd has no typeHierarchy capability; protocol directions covered by unit fixtures"
    )
  end
  client:stop(true)
  print(
    "hierarchy integration: real clangd two-level incoming calls, source preview and callsite jump passed"
  )
end
if vim.env.LSP_TOOLS_TUI == "1" then
  local thread = coroutine.create(run)
  local function step()
    local ok, err = coroutine.resume(thread)
    if not ok then
      vim.fn.writefile(
        { tostring(err), debug.traceback(thread) },
        vim.env.LSP_TOOLS_TEST_TMP .. "/result"
      )
      vim.cmd("cquit 1")
    elseif coroutine.status(thread) == "dead" then
      vim.fn.writefile({ "hierarchy terminal passed" }, vim.env.LSP_TOOLS_TEST_TMP .. "/result")
      vim.cmd("qa!")
    else
      vim.defer_fn(step, 10)
    end
  end
  vim.defer_fn(step, 50)
else
  run()
  vim.cmd("qa!")
end
