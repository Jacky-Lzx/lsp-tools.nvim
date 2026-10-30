local M = {}
local saved = {}
local function project(v)
  local root = vim.api.nvim_buf_is_valid(v.ctx.buf) and vim.fs.root(v.ctx.buf, { ".git" }) or nil
  root = root
    or (
      vim.api.nvim_win_is_valid(v.ctx.win)
        and vim.fn.getcwd(
          v.ctx.win,
          vim.api.nvim_tabpage_get_number(vim.api.nvim_win_get_tabpage(v.ctx.win))
        )
      or vim.fn.getcwd()
    )
  return vim.uv.fs_realpath(root) or root
end
local function alive(v)
  return require("lsp-tools.panel").alive(v)
end
function M.presets(v)
  return vim.tbl_extend("force", {}, v.options.presets or {}, saved[project(v)] or {})
end
function M.save(v, name)
  assert(type(name) == "string" and name ~= "", "preset name must be nonempty")
  local key = project(v)
  saved[key] = saved[key] or {}
  saved[key][name] = vim.deepcopy(v.filter)
end
function M.apply(results, v, filter)
  if not alive(v) then
    return
  end
  v.filter = vim.deepcopy(filter)
  results.render(v)
end
function M.open(results, v)
  local menu = {
    "Text",
    "Severity",
    "Source",
    "Diagnostic code",
    "Namespace",
    "Load preset",
    "Save preset",
    "Reset",
  }
  vim.ui.select(menu, { prompt = "Filter results" }, function(choice)
    if not choice or not alive(v) then
      return
    end
    if choice == "Reset" then
      M.apply(results, v, {})
      return
    end
    if choice == "Text" then
      vim.ui.input({ prompt = "Filter text: ", default = v.filter.text or "" }, function(text)
        if text ~= nil and alive(v) then
          results.filter(v, { text = text })
        end
      end)
      return
    end
    if choice == "Save preset" then
      vim.ui.input({ prompt = "Session preset name: " }, function(name)
        if name and name ~= "" and alive(v) then
          M.save(v, name)
          v.status = "Saved session preset: " .. name
          results.render(v)
        end
      end)
      return
    end
    if choice == "Load preset" then
      local presets = M.presets(v)
      local names = vim.tbl_keys(presets)
      table.sort(names)
      vim.ui.select(names, { prompt = "Filter preset" }, function(name)
        if name and alive(v) then
          M.apply(results, v, presets[name])
        end
      end)
      return
    end
    local field = ({
      Severity = "severity",
      Source = "source",
      ["Diagnostic code"] = "code",
      Namespace = "namespace",
    })[choice]
    local values, seen = { { label = "All", value = false } }, {}
    if field == "severity" then
      values[#values + 1] = { label = "Errors and warnings", value = { 1, 2 } }
      for i = 1, 4 do
        values[#values + 1] = { label = vim.diagnostic.severity[i], value = i }
      end
    else
      for _, item in ipairs(v.items) do
        local value = item[field]
        if value ~= nil and value ~= "" and not seen[tostring(value)] then
          seen[tostring(value)] = true
          local label = tostring(value)
          if field == "namespace" then
            label = (vim.diagnostic.get_namespaces()[value] or {}).name or label
          end
          values[#values + 1] = { label = label, value = value }
        end
      end
      table.sort(values, function(a, b)
        if a.value == false then
          return b.value ~= false
        end
        if b.value == false then
          return false
        end
        return a.label < b.label
      end)
    end
    vim.ui.select(values, {
      prompt = "Filter " .. field,
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if item and alive(v) then
        results.filter(v, { [field] = item.value })
      end
    end)
  end)
end
return M
