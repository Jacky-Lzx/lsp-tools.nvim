-- Optional shared icon policy. Standalone use never loads theme-tools.
local M = {}
function M.get(category, name, fallback, hl)
  local icons = package.loaded["theme_tools.icons"]
  if type(icons) == "table" and type(icons.get) == "function" then
    local icon, group, default = icons.get(category, name)
    if icon == "" then
      return icon, hl or group
    end
    local mode = icons.current()
    if
      default
      and (category == "ui" or category == "lsp")
      and fallback ~= nil
      and mode ~= "ascii"
      and mode ~= "none"
    then
      return fallback, hl or group
    end
    return icon, group
  end
  return fallback or "", hl or "Normal"
end
function M.prefix(category, name, fallback, hl)
  local icon, group = M.get(category, name, fallback, hl)
  return icon ~= "" and (icon .. " ") or "", group
end
return M
