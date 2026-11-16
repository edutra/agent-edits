"""Runs the viewer tests (tests/viewer/run.lua) in a headless Neovim."""
import os
import shutil
import subprocess
import unittest

from helpers import REPO, StateTest


@unittest.skipUnless(shutil.which("nvim"), "nvim is needed")
class ViewerTests(StateTest):
    def test_viewer(self):
        root = os.path.join(self.tmp, "root")
        os.makedirs(root)
        env = dict(self.env, AGENT_EDITS_ROOT=root, XDG_CONFIG_HOME=os.path.join(self.tmp, "config"),
                   XDG_DATA_HOME=os.path.join(self.tmp, "data"))
        result = subprocess.run(
            ["nvim", "--headless", "-u", os.path.join(REPO, "nvim", "viewer.lua"),
             "-c", "luafile " + os.path.join(REPO, "tests", "viewer", "run.lua")],
            cwd=root, env=env, capture_output=True, text=True, timeout=120)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, "\n" + output)
        self.assertNotIn("FAIL", output)
        self.assertIn(" passed, 0 failed", output)


if __name__ == "__main__":
    unittest.main()
