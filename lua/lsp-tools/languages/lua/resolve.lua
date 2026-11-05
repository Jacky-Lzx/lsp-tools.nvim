local M = {}
local roots, modules
local function normalize(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end
function M.reset()
  roots, modules = nil, {}
end
local function candidates(opts)
  if roots then
    return roots
  end
  roots = {}
  local seen = {}
  local function add(path)
    path = normalize(path)
    if not seen[path] and vim.fn.isdirectory(path .. "/lua") == 1 then
      seen[path], roots[#roots + 1] = true, path
    end
  end
  for _, path in ipairs(vim.opt.rtp:get()) do
    add(path)
  end
  local lazy = package.loaded["lazy.core.config"]
  if lazy and lazy.plugins then
    local names = vim.tbl_keys(lazy.plugins)
    table.sort(names)
    for _, name in ipairs(names) do
      add(lazy.plugins[name].dir)
    end
  end
  for _, parent in ipairs(opts.plugin_roots or { vim.fn.stdpath("data") .. "/lazy" }) do
    parent = vim.fn.expand(parent)
    local scan = vim.uv.fs_scandir(parent)
    if scan then
      local children = {}
      while true do
        local name = vim.uv.fs_scandir_next(scan)
        if not name then
          break
        end
        children[#children + 1] = parent .. "/" .. name
      end
      table.sort(children)
      for _, path in ipairs(children) do
        add(path)
      end
    end
  end
  return roots
end
function M.module(name, opts)
  if not name:match("^[%w_][%w_./%-]*$") then
    return
  end
  if modules[name] then
    return modules[name]
  end
  local relative = name:gsub("%.", "/")
  for _, root in ipairs(candidates(opts)) do
    for _, suffix in ipairs({ ".lua", "/init.lua" }) do
      if vim.fn.filereadable(root .. "/lua/" .. relative .. suffix) == 1 then
        modules[name] = root .. "/lua"
        return modules[name]
      end
    end
  end
end
function M.library(path, opts)
  -- LuaLS expands this placeholder using its own installation, including Nix.
  if path:match("^%${3rd}/") then
    return path
  end
  path = vim.fn.expand(path)
  if not path:match("^/") then
    local name, suffix = path:match("^([^/]+)(.*)$")
    for _, root in ipairs(candidates(opts)) do
      if vim.fs.basename(root) == name then
        path = root .. suffix
        break
      end
    end
  end
  if vim.fn.isdirectory(path .. "/lua") == 1 then
    path = path .. "/lua"
  end
  return vim.fn.isdirectory(path) == 1 and normalize(path) or nil
end
M.reset()
return M
