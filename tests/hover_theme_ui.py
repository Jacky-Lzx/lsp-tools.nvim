"""Validate native hover surface colors with an attached Neovim UI."""
import os
from pathlib import Path
import signal
import sys

root = Path(__file__).resolve().parents[1]
theme = Path(os.environ.get("THEME_TOOLS_DIR", root.parent / "theme-tools.nvim"))
sys.path.insert(0, str(theme / "tests"))
from rpc import Capture

signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError("Hover theme UI timed out")))
signal.alarm(20)
env = dict(os.environ, LSP_TOOLS_ROOT=str(root), THEME_TOOLS_DIR=str(theme))
ui = Capture(env, ["-u", "NONE", "-i", "NONE", "--noplugin"])


def lua(code):
    return ui.request("nvim_exec_lua", [code, []])


def check(bg):
    position = lua("vim.cmd('redraw!');return vim.api.nvim_win_get_position(win)")
    lua("return true")
    for row, col in ((position[0], position[1]), (position[0]+1, position[1]+1)):
        attrs = ui.attrs[ui.grid[row][col][1]]
        assert attrs.get("background", ui.bg) == bg, (row, col, attrs, bg)


try:
    ui.request("nvim_ui_attach", [100, 34, {"rgb": True, "ext_linegrid": True}])
    lua("""
      vim.opt.rtp:prepend(vim.env.THEME_TOOLS_DIR);vim.opt.rtp:append(vim.env.LSP_TOOLS_ROOT)
      t=require('theme_tools');opts={persist=false,catppuccin=false,dracula=false,icons={default='none'},
        default='theme-tools-dracula',themes={'theme-tools-dracula'}}
      t.setup(opts)
      vim.api.nvim_set_hl(0,'Normal',{fg='#eeeeee',bg='#334455'})
      h=require('lsp-tools.hover.float');h.setup({})
      buf,win=vim.lsp.util.open_floating_preview({'documentation'},'plaintext',{focus_id='textDocument/hover'})
      assert(not vim.api.nvim_get_hl(0,{name='LspToolsHoverNormal',link=false}).bg)
      assert(not vim.api.nvim_get_hl(0,{name='LspToolsHoverBorder',link=false}).bg)
    """)
    check(0x334455)
    lua("""
      opts.palette={overrides={ui={float_bg='#123456',float_fg='#abcdef'}}}
      t.setup(opts);vim.cmd('redraw!')
    """)
    check(0x123456)
    lua("""
      local snapshot=require('theme_tools.colors').snapshot()
      assert(require('theme_tools.colors').apply({colorscheme='theme-tools-mocha',background='dark'}))
      require('theme_tools.colors').restore(snapshot)
    """)
    check(0x123456)
    lua("vim.api.nvim_win_close(win,true);h.disable()")
finally:
    ui.close()
print("hover theme UI: transparent menu separation, shared float border/content and rollback passed")
