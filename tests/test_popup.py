"""Smoke test for bin/agent-edits-popup: the first call starts a viewer in the
private tmux server, a second call re-attaches to it.

Runs in tmux servers of its own (TMUX_TMPDIR), never the one you work in.
"""
import hashlib
import os
import shutil
import subprocess
import tempfile
import time
import unittest

from helpers import REPO


def has_tmux():
    return shutil.which("tmux") is not None and shutil.which("nvim") is not None


@unittest.skipUnless(has_tmux(), "tmux and nvim are needed")
class PopupTests(unittest.TestCase):
    def setUp(self):
        # Short path: tmux sockets have a length limit (104 bytes on macOS).
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="ae-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.dir = os.path.join(self.tmp, "project")
        os.makedirs(self.dir)
        for sub in ("tmux", "config", "state"):
            os.makedirs(os.path.join(self.tmp, sub))
        self.env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
        self.env.update(TMUX_TMPDIR=os.path.join(self.tmp, "tmux"),
                        XDG_CONFIG_HOME=os.path.join(self.tmp, "config"),
                        XDG_STATE_HOME=os.path.join(self.tmp, "state"),
                        AGENT_EDITS_VIEWER=os.path.join(REPO, "nvim", "viewer.lua"))
        self.addCleanup(self.tmux, "-L", "agent-edits", "kill-server")
        self.addCleanup(self.tmux, "-L", "outer", "kill-server")
        # Same name as agent-edits-popup computes with md5sum (or md5 on macOS).
        self.session = "ae-" + hashlib.md5(self.dir.encode()).hexdigest()[:12]

    def tmux(self, *args):
        return subprocess.run(["tmux"] + list(args), env=self.env, capture_output=True, text=True)

    def open_popup(self, name):
        popup = os.path.join(REPO, "bin", "agent-edits-popup")
        result = self.tmux("-L", "outer", "new-session", "-d", "-s", name, "-x", "120", "-y", "30",
                           "-c", self.dir, popup + " e '' ''")
        self.assertEqual(result.returncode, 0, result.stderr)

    def wait_for(self, check, what, seconds=15):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if check():
                return
            time.sleep(0.2)
        self.fail("timed out waiting for " + what)

    def inner_sessions(self):
        out = self.tmux("-L", "agent-edits", "list-sessions", "-F", "#{session_name}").stdout
        return out.split()

    def viewer_screen(self):
        return self.tmux("-L", "agent-edits", "capture-pane", "-p", "-t", self.session + ":").stdout

    def test_starts_once_and_reattaches(self):
        self.open_popup("first")
        self.wait_for(lambda: self.session in self.inner_sessions(), "the viewer session")
        self.wait_for(lambda: "Edits (0)" in self.viewer_screen(), "the viewer to draw")
        self.assertEqual(self.inner_sessions(), [self.session])

        # Closing the popup leaves the viewer running; opening it again re-attaches.
        self.tmux("-L", "outer", "kill-session", "-t", "first")
        time.sleep(0.3)
        self.assertEqual(self.inner_sessions(), [self.session])
        self.open_popup("second")
        self.wait_for(lambda: self.tmux("-L", "agent-edits", "list-clients").stdout.strip() != "",
                      "the popup to attach")
        self.assertEqual(self.inner_sessions(), [self.session])


if __name__ == "__main__":
    unittest.main()
