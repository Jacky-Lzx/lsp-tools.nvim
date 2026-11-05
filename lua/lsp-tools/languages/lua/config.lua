local M = {}
local function strings(value, field)
  assert(type(value) == "table" and vim.islist(value), field .. " must be a list")
  for _, item in ipairs(value) do
    assert(type(item) == "string" and item ~= "", field .. " must contain nonempty strings")
  end
end
function M.validate(opts)
  assert(
    opts.enabled == nil or type(opts.enabled) == "boolean" or type(opts.enabled) == "function",
    "lua.enabled must be boolean or function"
  )
  for _, key in ipairs({ "debounce", "max_bytes" }) do
    assert(
      opts[key] == nil or type(opts[key]) == "number" and opts[key] >= 0,
      "lua." .. key .. " must be nonnegative"
    )
  end
  if opts.plugin_roots ~= nil then
    strings(opts.plugin_roots, "lua.plugin_roots")
  end
  if opts.library ~= nil then
    assert(type(opts.library) == "table" and vim.islist(opts.library), "lua.library must be a list")
    for _, item in ipairs(opts.library) do
      assert(
        type(item) == "string" or type(item) == "table" and type(item.path) == "string",
        "lua.library needs a path"
      )
      assert(
        (type(item) == "string" and item or item.path) ~= "",
        "lua.library path must not be empty"
      )
      if type(item) == "table" then
        for _, key in ipairs({ "words", "mods", "files" }) do
          if item[key] then
            strings(item[key], "lua.library." .. key)
            for _, pattern in ipairs(item[key]) do
              assert(pcall(string.find, "", pattern), "invalid lua.library pattern")
            end
          end
        end
      end
    end
  end
end
return M
