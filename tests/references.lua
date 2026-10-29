vim.opt.rtp:prepend(vim.env.LSP_TOOLS_ROOT)
local tools = require("lsp-tools")
local references = require("lsp-tools.references")
local namespace = vim.api.nvim_create_namespace("lsp-tools.references")
local other_namespace = vim.api.nvim_create_namespace("other-reference-provider")
local count, requests, notices = 0, {}, {}
local clients = {}
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "😀foo foo", "foo", "tail" })
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function cursor(row, col)
  vim.api.nvim_win_set_cursor(0, { row, col })
end
local function at(row, col)
  return vim.deep_equal(vim.api.nvim_win_get_cursor(0), { row, col })
end
local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
end
local function flush()
  vim.wait(5, function()
    return false
  end, 1)
end
local function make_client(id, encoding)
  local client = { id = id, offset_encoding = encoding }
  function client:request(method, params, callback)
    check(method == "textDocument/documentHighlight", "use document highlights")
    local call = { params = params, callback = callback, client = id }
    requests[#requests + 1] = call
    call.id = #requests
    return true, call.id
  end
  function client:cancel_request(id)
    requests[id].cancelled = true
  end
  return client
end
clients = { make_client(1, "utf-16") }
vim.lsp.get_clients = function(opts)
  check(opts.method == "textDocument/documentHighlight", "query method-capable clients")
  return clients
end
vim.notify = function(message)
  notices[#notices + 1] = message
end
local function highlight(row, col, length, kind)
  return {
    range = {
      start = { line = row, character = col },
      ["end"] = { line = row, character = col + length },
    },
    kind = kind,
  }
end
local utf16 = { highlight(1, 0, 3, 2), highlight(0, 6, 3, 3), highlight(0, 2, 3, 1) }
local function setup(opts)
  references.disable()
  cursor(1, 4)
  tools.setup({
    code_actions = false,
    references = vim.tbl_extend("force", {
      debounce = 50,
      request_timeout = 40,
      notify_end = true,
    }, opts or {}),
  })
end
setup()
check(tools.jump_reference(1), "cold jump queues a request before auto highlights")
local pending = requests[#requests]
check(pending.params.position.character == 2, "UTF-16 request position uses server encoding")
pending.callback(nil, utf16)
check(at(1, 8), "unsorted results are sorted and Unicode byte columns are correct")
check(#marks() == 3, "all current symbol locations are highlighted")
local n = #requests
tools.jump_reference(-1)
check(at(1, 4) and #requests == n, "backward jump reuses current semantic results")
tools.jump_reference(2)
check(at(2, 0), "counts skip multiple references")
tools.jump_reference(1)
check(at(2, 0) and notices[#notices] == "No more references", "end does not wrap by default")
tools.jump_reference(1, { wrap = true })
check(at(1, 4), "wrap can be requested explicitly")
tools.jump_reference(-1, { wrap = true })
check(at(2, 0), "backward wrap")
check(vim.fn.getpos("''")[2] == 1, "jumps record the previous source location")
local groups = {}
for _, mark in ipairs(marks()) do
  groups[#groups + 1] = mark[4].hl_group
end
check(
  vim.deep_equal(groups, { "LspReferenceText", "LspReferenceWrite", "LspReferenceRead" }),
  "preserve highlight kinds"
)
cursor(1, 7) -- Exclusive end of first range, before the next symbol.
tools.jump_reference(1)
check(#requests == n + 1, "exclusive range ends do not reuse the previous symbol")
pending = requests[#requests]
cursor(3, 0)
pending.callback(nil, utf16)
check(#marks() == 0 and pending.cancelled, "cursor movement rejects and cancels stale responses")

setup()
tools.jump_reference(1)
pending = requests[#requests]
tools.jump_reference(1)
check(requests[#requests] == pending, "rapid repeated keys share one request")
pending.callback(nil, utf16)
check(at(2, 0), "rapid counts accumulate while resolving")
setup()
tools.jump_reference(1)
pending = requests[#requests]
vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "changed" })
pending.callback(nil, utf16)
check(at(1, 4) and #marks() == 0, "edited buffers reject stale results")

setup()
tools.jump_reference(1)
pending = requests[#requests]
local original_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
pending.callback(nil, utf16)
check(at(1, 4) and #marks() == 0, "other windows cannot receive the pending jump")
vim.cmd("close")
check(vim.api.nvim_get_current_win() == original_win, "test returns to original window")

clients = { make_client(1, "utf-16"), make_client(2, "utf-8") }
setup()
tools.jump_reference(1)
local one, two = requests[#requests - 1], requests[#requests]
check(two.params.position.character == 4, "each client gets its own position encoding")
two.callback(nil, { highlight(0, 4, 3, 2), highlight(0, 8, 3, 1), highlight(1, 0, 3, 2) })
one.callback(nil, utf16)
check(#marks() == 3 and at(1, 8), "multi-client duplicates count as a single reference")

setup()
tools.jump_reference(1)
one, two = requests[#requests - 1], requests[#requests]
one.callback(nil, utf16)
vim.wait(100, function()
  return at(1, 8)
end, 1)
check(at(1, 8) and two.cancelled, "timeout cancels slow clients and uses available results")
two.callback(nil, { highlight(2, 0, 3) })
check(#marks() == 3, "late timed-out responses cannot change highlights")

clients = { make_client(1, "utf-32") }
setup()
tools.jump_reference(1)
pending = requests[#requests]
check(pending.params.position.character == 1, "UTF-32 request position")
pending.callback(nil, { highlight(0, 5, 3), highlight(0, 1, 3), { range = {} } })
check(at(1, 8) and #marks() == 2, "UTF-32 results and malformed range isolation")

setup({ debounce = 1 })
check(
  vim.wait(50, function()
    return #requests > pending.id
  end, 1),
  "auto highlighting requests after debounce"
)
requests[#requests].callback(nil, { highlight(0, 1, 3), highlight(0, 5, 3) })
check(at(1, 4) and #marks() == 2, "auto highlighting does not move the cursor")
vim.api.nvim_buf_set_extmark(buf, other_namespace, 0, 0, { end_col = 4, hl_group = "Search" })
tools.setup({ code_actions = false, references = false })
check(#marks() == 0, "disable clears owned highlights")
check(
  #vim.api.nvim_buf_get_extmarks(buf, other_namespace, 0, -1, {}) == 1,
  "disable preserves other providers' marks"
)
check(not tools.jump_reference(1), "disabled module does not move or request")

clients = { make_client(1, "utf-16") }
local deferred, original_defer = {}, vim.defer_fn
vim.defer_fn = function(callback, delay)
  deferred[delay] = callback
  return vim.uv.new_timer()
end
setup()
n = #requests
tools.jump_reference(1)
deferred[50]() -- A debounce callback may already be scheduled when its timer is stopped.
check(#requests == n + 1, "an already queued debounce cannot duplicate an immediate jump request")
pending = requests[#requests]
tools.setup({ code_actions = false, references = false })
pending.callback(nil, utf16)
check(
  pending.cancelled and #marks() == 0 and at(1, 4),
  "disable cancels pending jumps and discards late results"
)
vim.defer_fn = original_defer

setup()
tools.jump_reference(1)
requests[#requests].callback(nil, {
  { range = { start = { line = 0, character = 2 }, ["end"] = { line = 1, character = 3 } } },
  highlight(2, 0, 3),
})
check(at(3, 0), "multiline highlights use lexical position comparisons")
cursor(2, 1)
tools.jump_reference(1)
check(at(3, 0), "later lines inside a multiline highlight are recognized")

setup()
tools.jump_reference(1)
pending = requests[#requests]
pending.callback({ message = "server failure" })
check(at(1, 4) and #marks() == 0, "server errors do not fabricate navigation targets")
setup()
tools.jump_reference(1)
pending = requests[#requests]
local get_mode = vim.api.nvim_get_mode
vim.api.nvim_get_mode = function()
  return { mode = "no" }
end
pending.callback(nil, utf16)
check(at(1, 4) and #marks() == 0, "entering operator-pending mode rejects a queued jump")
vim.api.nvim_get_mode = get_mode
clients = {}
setup()
n = #requests
tools.jump_reference(1)
check(#requests == n and at(1, 4), "unsupported buffers stay in place")
check(
  notices[#notices]:find("No language server"),
  "unsupported capability is explained on explicit jump"
)
check(
  not package.loaded["snacks"] and not package.loaded["snacks.words"],
  "reference navigation needs no Snacks"
)
references.disable()
print(("lsp-tools references: %d assertions passed"):format(count))
vim.cmd("qa!")
