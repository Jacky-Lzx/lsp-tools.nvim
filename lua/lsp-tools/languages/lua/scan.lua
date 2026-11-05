local M = {}

-- A small lexer avoids finding require calls inside strings or ordinary comments.
-- It does not evaluate Lua, execute plugin code or require a Tree-sitter parser.
function M.modules(text)
  local modules, tokens = {}, {}
  local i, length = 1, #text
  local function long_end(at)
    local equals = text:sub(at):match("^%[(=*)%[")
    if equals then
      local _, last = text:find("]" .. equals .. "]", at + #equals + 2, true)
      return last and last + 1 or length + 1
    end
  end
  while i <= length do
    local char = text:sub(i, i)
    if text:sub(i, i + 1) == "--" then
      local ending = long_end(i + 2)
      if not ending then
        ending = text:find("\n", i + 2, true) or length + 1
        local mod = text:sub(i, ending - 1):match("^%-%-%-%s*@module%s+['\"]([%w_./%-]+)['\"]")
        if mod then
          modules[mod] = true
        end
      end
      i = ending
    elseif char == "'" or char == '"' then
      local at = i + 1
      while at <= length do
        local c = text:sub(at, at)
        if c == "\\" then
          at = at + 2
        elseif c == char then
          break
        else
          at = at + 1
        end
      end
      tokens[#tokens + 1] = { value = text:sub(i + 1, at - 1), string = true }
      i = at + 1
    elseif char == "[" and long_end(i) then
      i = long_end(i)
      tokens[#tokens + 1] = { value = "long-string", string = true }
    elseif char:match("[%a_]") then
      local word = text:sub(i):match("^[%w_]+")
      tokens[#tokens + 1] = { value = word }
      i = i + #word
    else
      if not char:match("%s") then
        tokens[#tokens + 1] = { value = char }
      end
      i = i + 1
    end
  end
  for n, token in ipairs(tokens) do
    if
      token.value == "require"
      and not token.string
      and not (tokens[n - 1] and (tokens[n - 1].value == "." or tokens[n - 1].value == ":"))
    then
      local next_token = tokens[n + 1]
      local offset = next_token and (next_token.value == "(" or next_token.value == ",") and 2 or 1
      local value = tokens[n + offset]
      if value and value.string and value.value:match("^[%w_][%w_./%-]*$") then
        modules[value.value] = true
      end
    end
  end
  return modules
end
return M
