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

    def viewer_pid(self):
        return self.tmux("-L", "agent-edits", "list-panes", "-t", self.session + ":", "-F", "#{pane_pid}").stdout.strip()

    def test_restarts_when_the_viewer_changed(self):
        viewer = os.path.join(self.tmp, "viewer.lua")
        shutil.copy(os.path.join(REPO, "nvim", "viewer.lua"), viewer)
        self.env["AGENT_EDITS_VIEWER"] = viewer
        self.open_popup("first")
        self.wait_for(lambda: "Edits (0)" in self.viewer_screen(), "the viewer to draw")
        pid = self.viewer_pid()

        # Same code: the same viewer comes back.
        self.tmux("-L", "outer", "kill-session", "-t", "first")
        self.open_popup("second")
        self.wait_for(lambda: self.tmux("-L", "agent-edits", "list-clients").stdout.strip() != "",
                      "the popup to attach")
        self.assertEqual(self.viewer_pid(), pid)

        # Updated code (git pull): a new viewer runs it.
        self.tmux("-L", "outer", "kill-session", "-t", "second")
        with open(viewer, "a") as fh:
            fh.write("-- updated\n")
        self.open_popup("third")
        self.wait_for(lambda: self.viewer_pid() not in ("", pid), "a new viewer")
        self.wait_for(lambda: "Edits (0)" in self.viewer_screen(), "the new viewer to draw")
        self.assertEqual(self.inner_sessions(), [self.session])

    def test_one_viewer_per_tmux_window_with_its_own_files(self):
        # Two windows ("tabs") in the outer tmux, each with an "agent" pane.
        self.assertEqual(self.tmux("-L", "outer", "new-session", "-d", "-s", "work", "-x", "120", "-y", "30",
                                   "-c", self.dir, "sleep 600").returncode, 0)
        self.tmux("-L", "outer", "new-window", "-d", "-t", "work", "-c", self.dir, "sleep 600")
        socket = self.tmux("-L", "outer", "display-message", "-p", "#{socket_path}").stdout.strip()
        panes = self.tmux("-L", "outer", "list-panes", "-s", "-t", "work",
                          "-F", "#{window_id} #{pane_id}").stdout.split("\n")
        windows = [l.split() for l in panes if l.strip()]
        pid = self.tmux("-L", "outer", "display-message", "-p", "#{pid}").stdout.strip()

        # One edit made from each window.
        os.makedirs(os.path.join(self.tmp, "state", "agent-edits"), exist_ok=True)
        now = int(time.time())
        with open(os.path.join(self.tmp, "state", "agent-edits", "edits.tsv"), "w") as fh:
            for i, (_, pane) in enumerate(windows):
                path = os.path.join(self.dir, "file%d.txt" % i)
                with open(path, "w") as f:
                    f.write("x\n")
                fh.write("%d\tClaude\t%s\t%s\ts%d\ttool\t%s:%s\n" % (now, path, self.dir, i, pid, pane))

        popup = os.path.join(REPO, "bin", "agent-edits-popup")
        sessions = []
        for i, (window, pane) in enumerate(windows):
            self.tmux("-L", "outer", "new-window", "-d", "-t", "work", "-c", self.dir,
                      "%s e %s %s" % (popup, socket, pane))
            session = "ae-" + hashlib.md5(("%s %s" % (socket, window)).encode()).hexdigest()[:12]
            sessions.append(session)
            self.wait_for(lambda: session in self.inner_sessions(), "the viewer of window %d" % i)
            screen = lambda: self.tmux("-L", "agent-edits", "capture-pane", "-p", "-t", session + ":").stdout
            self.wait_for(lambda: "Edits (1)" in screen() and ("file%d.txt" % i) in screen(),
                          "the files of window %d" % i)
            self.assertNotIn("file%d.txt" % (1 - i), screen())
        self.assertEqual(sorted(self.inner_sessions()), sorted(sessions))


if __name__ == "__main__":
    unittest.main()
