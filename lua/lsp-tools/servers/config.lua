local M = {}

local function strings(value, field, nonempty)
  assert(type(value) == "table" and vim.islist(value), field .. " must be a list")
  assert(not nonempty or #value > 0, field .. " must not be empty")
  for _, item in ipairs(value) do
    assert(type(item) == "string" and item ~= "", field .. " must contain nonempty strings")
  end
end

function M.name(name)
  assert(
    type(name) == "string" and name:match("^[%w_][%w_.%-]*$") and name ~= "_configs",
    "servers keys must be nonempty LSP config names without paths or wildcards"
  )
end

-- Validate native fields without running commands, root callbacks or client hooks.
-- Unknown fields are passed through for server-specific extensions.
function M.validate(name, config, complete)
  local prefix = "servers." .. name .. "."
  if complete or config.cmd ~= nil then
    if type(config.cmd) ~= "function" then
      strings(config.cmd, prefix .. "cmd", true)
    end
  end
  if config.filetypes ~= nil then
    strings(config.filetypes, prefix .. "filetypes")
  end
  if config.root_markers ~= nil then
    assert(
      type(config.root_markers) == "table" and vim.islist(config.root_markers),
      prefix .. "root_markers must be a list"
    )
    for _, marker in ipairs(config.root_markers) do
      if type(marker) == "table" then
        strings(marker, prefix .. "root_markers group", true)
      else
        assert(type(marker) == "string" and marker ~= "", prefix .. "invalid root marker")
      end
    end
  end
  if config.root_dir ~= nil then
    assert(
      type(config.root_dir) == "string" or type(config.root_dir) == "function",
      prefix .. "root_dir must be a string or function"
    )
  end
  if config.workspace_required ~= nil then
    assert(
      type(config.workspace_required) == "boolean",
      prefix .. "workspace_required must be boolean"
    )
  end
  for _, field in ipairs({ "settings", "capabilities" }) do
    if config[field] ~= nil then
      assert(type(config[field]) == "table", prefix .. field .. " must be a table")
    end
  end
end

return M
