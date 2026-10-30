vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local count, global_calls, api_calls = 0, 0, 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local input = require("lsp-tools.input")
check(not package.loaded["input-tools"], "resolving the bridge must not load input-tools")
local original_global = vim.ui.input
local opts = { prompt = "Filter: ", default = "value" }
local callback = function() end
vim.ui.input = function(options, confirm)
  global_calls = global_calls + 1
  check(options == opts and confirm == callback, "global fallback preserves arguments")
end
-- No input-tools checkout is on this standalone test's runtimepath.
input.input(opts, callback)
check(global_calls == 1, "missing plugin falls back to global input")
package.preload["input-tools"] = function()
  return {
    input = function(options, confirm)
      api_calls = api_calls + 1
      check(options == opts and confirm == callback, "general API preserves arguments")
    end,
  }
end
input.input(opts, callback)
check(
  api_calls == 1 and global_calls == 1,
  "late available API is called without global replacement"
)
package.loaded["input-tools"].input = function()
  error("API failure")
end
check(
  not pcall(input.input, opts, callback),
  "API errors propagate instead of opening a second prompt"
)
check(global_calls == 1, "API error does not invoke global input")
package.loaded["input-tools"] = {}
input.input(opts, callback)
check(global_calls == 2, "old plugin without the general API uses fallback")
package.loaded["input-tools"], package.preload["input-tools"] = nil, nil
vim.ui.input = original_global
print(("general input: %d assertions passed"):format(count))
