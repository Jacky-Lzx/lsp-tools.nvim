vim.opt.rtp:prepend(assert(vim.env.LSP_TOOLS_ROOT))
local api = vim.api
local hover = require("lsp-tools.hover.float")
local native = vim.lsp.util.open_floating_preview
api.nvim_set_hl(0, "Normal", { fg = "#eeeeee", bg = "#334455" })
api.nvim_set_hl(0, "NormalFloat", { fg = "#abcdef" })
api.nvim_set_hl(0, "Pmenu", { bg = "#123456" })
api.nvim_set_hl(0, "FloatBorder", { fg = "#abcabc", bg = "#123456" })
hover.setup({})
assert(not package.loaded.theme_tools, "hover loaded an optional theme provider")
local function hl(name)
  return api.nvim_get_hl(0, { name = name, link = false })
end
assert(not hl("LspToolsHoverNormal").bg and not hl("LspToolsHoverBorder").bg)
local root = vim.env.THEME_TOOLS_DIR or vim.env.LSP_TOOLS_ROOT .. "/../theme-tools.nvim"
if vim.fn.isdirectory(root) == 0 then
  hover.disable()
  print("hover standalone float surface passed; optional theme integration skipped")
  return
end
vim.opt.rtp:append(root)
local t = require("theme_tools")
local opts = {
  persist = false,
  catppuccin = false,
  dracula = false,
  icons = { default = "none" },
  default = "theme-tools-dracula",
  themes = {
    "theme-tools-dracula",
    { name = "solid", colorscheme = "theme-tools-dracula", transparent = false },
    "theme-tools-mocha",
  },
}
t.setup(opts)
assert(not hl("LspToolsHoverNormal").bg and not hl("LspToolsHoverBorder").bg)
local _, win = vim.lsp.util.open_floating_preview(
  { "documentation" },
  "plaintext",
  { focus_id = "textDocument/hover" }
)
assert(vim.wo[win].winhighlight:find("FloatBorder:LspToolsHoverBorder", 1, true))
assert(t.set("solid"))
assert(hl("LspToolsHoverNormal").bg == 0x282a36 and hl("LspToolsHoverBorder").bg == 0x282a36)
local snapshot = require("theme_tools.colors").snapshot()
assert(t.set("theme-tools-mocha"))
assert(not hl("LspToolsHoverNormal").bg)
require("theme_tools.colors").restore(snapshot)
assert(hl("LspToolsHoverNormal").bg == 0x282a36)
api.nvim_set_hl(0, "LspToolsHoverNormal", { fg = "#abcdef", bg = "#171720" })
t.refresh_palette()
assert(hl("LspToolsHoverNormal").bg == 0x171720)
hover.setup({})
assert(hl("LspToolsHoverNormal").bg == 0x171720)
assert(t.set("theme-tools-dracula"))
assert(not hl("LspToolsHoverNormal").bg)
opts.palette =
  { overrides = { ui = { float_bg = "#123456", float_fg = "#654321", border = "#abcdef" } } }
t.setup(opts)
assert(hl("LspToolsHoverNormal").bg == 0x123456 and hl("LspToolsHoverNormal").fg == 0x654321)
assert(hl("LspToolsHoverBorder").bg == 0x123456 and hl("LspToolsHoverBorder").fg == 0xabcdef)
hover.disable()
assert(vim.lsp.util.open_floating_preview == native)
local before = hl("LspToolsDefaultHoverNormal")
api.nvim_set_hl(0, "NormalFloat", { fg = "#111111", bg = "#222222" })
t.refresh_palette()
assert(
  vim.deep_equal(before, hl("LspToolsDefaultHoverNormal")),
  "disabled hover retained its palette subscription"
)
if api.nvim_win_is_valid(win) then
  api.nvim_win_close(win, true)
end
print(
  "hover theme: standalone transparency, optional late palette, overrides, live switching, rollback and cleanup passed"
)
