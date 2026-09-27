#!/usr/bin/env python3
"""Record the README demos as asciicast v2 files, then render them to GIF with agg.

Neovim runs in a pseudo-terminal of a fixed size; keys are typed from a script, and
waits for the LLM ask Neovim itself over its --listen socket, so every recording is
reproducible and nothing on the real screen is touched.

    python3 docs/demo/record.py translate explain visualize
    .deps/agg --idle-time-limit 1 ... docs/demo/translate.cast docs/demo/translate.gif

Requires a working transplit setup (LLM backend, d2 for `visualize`).
"""
import codecs
import fcntl
import json
import os
import pty
import shutil
import select
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

COLS, ROWS = 170, 34
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")


class Session:
    def __init__(self, cast_path, cwd, args):
        self.cast_path = cast_path
        self.sock = os.path.join(tempfile.mkdtemp(), "nvim.sock")
        self.events = []
        self.start = time.monotonic()
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(cwd)
            env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor")
            os.execvpe("nvim", ["nvim", "--listen", self.sock, *args], env)
        self.pid, self.fd = pid, fd
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.alive = True
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        # a multibyte character (Korean is 3 bytes) can be split across reads
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        while self.alive:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if not r:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                break
            if not data:
                break
            text = decoder.decode(data)
            if text:
                self.events.append([round(time.monotonic() - self.start, 4), "o", text])

    def keys(self, text, pause=0.6):
        """Send keys at once (a slow <leader> sequence would pop up which-key)."""
        os.write(self.fd, text.encode())
        time.sleep(pause)

    def type(self, text, delay=0.06, pause=0.4):
        for ch in text:
            os.write(self.fd, ch.encode())
            time.sleep(delay)
        time.sleep(pause)

    def lua(self, expr):
        """Evaluate a Lua expression in the recorded Neovim."""
        res = subprocess.run(
            ["nvim", "--server", self.sock, "--remote-expr", f"luaeval({json.dumps(expr)})"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return res.stdout.strip()

    def wait(self, expr, timeout=180, poll=0.5):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.lua(expr) in ("true", "1"):
                return True
            time.sleep(poll)
        print(f"  timed out waiting for: {expr}", file=sys.stderr)
        return False

    def wait_stable(self, expr, seconds=3, timeout=180):
        """Wait until `expr` stops changing (e.g. a streamed answer is complete)."""
        end, last, since = time.monotonic() + timeout, None, time.monotonic()
        while time.monotonic() < end:
            v = self.lua(expr)
            if v != last:
                last, since = v, time.monotonic()
            elif time.monotonic() - since >= seconds:
                return True
            time.sleep(0.5)
        return False

    def close(self):
        self.keys("\x1b:qa!\r", pause=0.5)
        self.alive = False
        with open(self.cast_path, "w") as f:
            header = {"version": 2, "width": COLS, "height": ROWS, "env": {"TERM": "xterm-256color"}}
            f.write(json.dumps(header) + "\n")
            for ev in self.events:
                f.write(json.dumps(ev, ensure_ascii=False) + "\n")


NO_HOURGLASS = """(function()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins < 2 then return false end
  for _, w in ipairs(wins) do
    if (vim.wo[w].winbar or ""):find("\\xe2\\x8f\\xb3") then return false end
  end
  return true
end)()"""


def translate(s):
    s.wait("vim.fn.exists(':TransSplit') == 2 or true")
    time.sleep(1.5)
    s.type(":TransClearCache\r", pause=0.8)  # show a live translation, not a cached one
    s.keys(" tk", pause=1)
    s.wait(NO_HOURGLASS)
    time.sleep(2)
    for _ in range(2):  # scroll: the pane follows and translates what comes into view
        s.keys("\x04", pause=1.2)
        s.wait(NO_HOURGLASS)
        time.sleep(1.5)
    s.keys("gg", pause=2)


def explain(s):
    time.sleep(1.5)
    s.type("/upstream timed out\r", pause=0.3)
    s.keys("\x1b0", pause=0.8)
    s.keys(" te", pause=1)
    buf = "vim.fn.bufnr('transplit://explain')"
    s.wait(f"{buf} ~= -1 and vim.api.nvim_buf_line_count({buf}) > 12")
    s.wait_stable(f"vim.api.nvim_buf_line_count({buf})", seconds=4)
    s.keys("\x17l", pause=0.8)  # into the explanation window
    for _ in range(3):
        s.keys("\x04", pause=1.5)
    s.keys("gg", pause=1.5)


def visualize(s):
    time.sleep(1.5)
    s.keys(" tv", pause=1)
    s.wait(
        "(function() local d = require('transplit.visual').last_doc"
        " return d ~= nil and not d.busy and d.version >= 1 and d.status == '' end)()",
        timeout=300,
    )
    time.sleep(1.5)
    s.keys("\x17l", pause=0.8)
    for _ in range(4):
        s.keys("\x04", pause=1.6)
    s.keys("gg", pause=1.5)


# The data is copied into a server-like layout, so the model sees the paths a real
# setup would have (and doesn't comment on "docs/demo/data").
ROOT = os.path.join(tempfile.gettempdir(), "transplit-demo")
SCENARIOS = {
    "translate": ("var/log/nginx", ["error.log"], translate),
    "explain": ("var/log/nginx", ["error.log"], explain),
    "visualize": ("srv/stack", ["compose.yaml"], visualize),
}


def prepare():
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.join(ROOT, "var/log/nginx"))
    shutil.copy(os.path.join(DATA, "error.log"), os.path.join(ROOT, "var/log/nginx"))
    shutil.copytree(os.path.join(DATA, "stack"), os.path.join(ROOT, "srv/stack"))

if __name__ == "__main__":
    prepare()
    for name in sys.argv[1:] or list(SCENARIOS):
        rel, args, run = SCENARIOS[name]
        cwd = os.path.join(ROOT, rel)
        cast = os.path.join(HERE, f"{name}.cast")
        print(f"recording {name} -> {cast}")
        s = Session(cast, cwd, args)
        try:
            run(s)
        finally:
            s.close()
        print(f"  {len(s.events)} events, {s.events[-1][0] if s.events else 0:.0f}s")
