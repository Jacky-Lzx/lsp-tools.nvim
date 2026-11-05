"""Run an integration Lua script in a bounded, real terminal UI."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

root = Path(__file__).resolve().parent.parent
script = (root / 'tests' / sys.argv[1]).resolve()
assert script.parent == root / 'tests' and script.suffix == '.lua'
with tempfile.TemporaryDirectory(prefix='lsp-tools-terminal-') as directory:
    env = dict(os.environ, TERM='xterm-256color', LSP_TOOLS_ROOT=str(root), GIT_TOOLS_DIR=os.environ.get('GIT_TOOLS_DIR', str(root.parent / 'git-tools.nvim')), SELECTION_TOOLS_DIR=os.environ.get('SELECTION_TOOLS_DIR', str(root.parent / 'selection-tools.nvim')),
               LSP_TOOLS_TEST_TMP=directory, LSP_TOOLS_TUI='1', SNACKS_DIR=os.environ.get('SNACKS_DIR', str(Path.home() / '.local/share/nvim/lazy/snacks.nvim')),
               XDG_STATE_HOME=directory + '/state', XDG_CACHE_HOME=directory + '/cache',
               NVIM_LOG_FILE=directory + '/nvim.log', LSP_TOOLS_TERMINAL_SCRIPT=str(script),
               NVIM_SMOKE_TEST='1', NVIM_LAZY_LOCKFILE=directory + '/lazy-lock.json')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 45, 160, 0, 0))
    init = str(Path.home() / '.config/nvim/init.lua') if env.get('LSP_TOOLS_CONFIGURED') == '1' else 'NONE'
    process = subprocess.Popen(['nvim', '--cmd', 'let g:loaded_wakatime=1', '-u', init, '-i', 'NONE', '-n', '-c',
                                'lua vim.opt.rtp:prepend(vim.env.SELECTION_TOOLS_DIR); vim.opt.rtp:prepend(vim.env.GIT_TOOLS_DIR); dofile(vim.env.LSP_TOOLS_TERMINAL_SCRIPT)'],
                               env=env, stdin=slave, stdout=slave, stderr=slave,
                               start_new_session=True)
    os.close(slave)
    deadline = time.monotonic() + 40
    capture = bytearray()
    try:
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    capture.extend(chunk)
                except OSError:
                    break
        try:
            process.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise RuntimeError('Terminal check timed out: ' + script.name)
        result = Path(directory) / 'result'
        if result.exists():
            print(result.read_text(), end='')
        if process.returncode or not result.exists():
            if not result.exists():
                print(capture[-2500:].decode(errors='replace'), file=sys.stderr)
            sys.exit(process.returncode or 1)
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        os.close(master)
