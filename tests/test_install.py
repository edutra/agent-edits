"""Tests for install.sh and uninstall.sh, against a temporary HOME.

TMUX_TMPDIR points to a private folder, so the scripts never see (or reload)
the tmux server you are working in.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

from helpers import REPO


def tmux_version():
    try:
        out = subprocess.run(["tmux", "-V"], capture_output=True, text=True).stdout
    except OSError:
        return None
    m = re.search(r"(\d+)\.(\d+)", out)
    return (int(m.group(1)), int(m.group(2))) if m else None


HAS_TMUX = (tmux_version() or (0, 0)) >= (3, 3)


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="agent-edits-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("XDG_CONFIG_HOME", "XDG_STATE_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
                                 "AGENT_EDITS_BIN_DIR", "TMUX", "TMUX_PANE")}
        self.env.update(HOME=self.home, TMUX_TMPDIR=os.path.join(self.tmp, "tmux"))
        os.makedirs(self.env["TMUX_TMPDIR"])
        self.bin = os.path.join(self.home, ".local", "bin")
        self.settings = os.path.join(self.home, ".claude", "settings.json")
        self.codex = os.path.join(self.home, ".codex", "hooks.json")
        self.tmux_conf = os.path.join(self.home, ".config", "tmux", "tmux.conf")

    def run_script(self, script, *args, ok=True):
        args = list(args)
        if script == "install.sh" and not HAS_TMUX and "--no-tmux" not in args:
            args.append("--no-tmux")
        result = subprocess.run(["bash", os.path.join(REPO, script)] + args, env=self.env,
                                capture_output=True, text=True, timeout=60)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def load(self, path):
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)

    def read(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def save(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(data if isinstance(data, str) else json.dumps(data, indent=2) + "\n")

    def ours(self, groups):
        return [g for g in groups if "agent-edits-log" in g["hooks"][0]["command"]]

    def backups(self, path):
        return glob.glob(path + ".bak-agent-edits-*")


class InstallTests(InstallTest):
    def test_fresh_install(self):
        self.run_script("install.sh")
        for name in ("agent-edits-log", "agent-edits-view", "agent-edits-popup"):
            link = os.path.join(self.bin, name)
            self.assertEqual(os.readlink(link), os.path.join(REPO, "bin", name))
        conf = os.path.join(self.home, ".config", "agent-edits")
        self.assertEqual(os.readlink(os.path.join(conf, "viewer.lua")), os.path.join(REPO, "nvim", "viewer.lua"))
        hooks = self.load(self.settings)["hooks"]
        self.assertEqual(sorted(hooks), ["PostToolUse", "PreToolUse"])
        for event in ("PreToolUse", "PostToolUse"):
            group = hooks[event][0]
            self.assertIn("Edit", group["matcher"].split("|"))
            self.assertIn("Bash", group["matcher"].split("|"))
            self.assertEqual(group["hooks"][0]["command"], os.path.join(self.bin, "agent-edits-log") + " Claude")
        # No ~/.codex: Codex is skipped.
        self.assertFalse(os.path.exists(self.codex))
        # The files didn't exist: nothing to back up, even though both
        # events changed settings.json.
        self.assertEqual(self.backups(self.settings) + self.backups(self.tmux_conf), [])

    @unittest.skipUnless(HAS_TMUX, "tmux 3.3 or newer is needed")
    def test_tmux_block(self):
        self.run_script("install.sh", "--key", "y")
        text = self.read(self.tmux_conf)
        self.assertIn("# >>> agent-edits >>>", text)
        self.assertIn("bind y run-shell -b", text)
        self.assertIn(os.path.join(self.bin, "agent-edits-popup") + " --open y", text)

    @unittest.skipUnless(HAS_TMUX, "tmux 3.3 or newer is needed")
    def test_existing_dot_tmux_conf_is_used(self):
        legacy = os.path.join(self.home, ".tmux.conf")
        self.save(legacy, "set -g mouse on\n")
        self.run_script("install.sh")
        self.assertTrue(self.read(legacy).startswith("set -g mouse on\n"))
        self.assertIn("agent-edits", self.read(legacy))
        self.assertFalse(os.path.exists(self.tmux_conf))

    def test_codex_hook_when_codex_is_installed(self):
        os.makedirs(os.path.dirname(self.codex))
        self.run_script("install.sh")
        hooks = self.load(self.codex)["hooks"]
        for event in ("PreToolUse", "PostToolUse"):
            self.assertTrue(hooks[event][0]["hooks"][0]["command"].endswith("agent-edits-log Codex"))
            self.assertIn("apply_patch", hooks[event][0]["matcher"].split("|"))

    def test_other_settings_are_kept_and_backed_up_once(self):
        other = {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-hook"}]}
        original = {"model": "opus", "hooks": {"PreToolUse": [other]}}
        self.save(self.settings, original)
        self.run_script("install.sh")
        data = self.load(self.settings)
        self.assertEqual(data["model"], "opus")
        self.assertEqual(data["hooks"]["PreToolUse"][0], other)
        self.assertEqual(len(self.ours(data["hooks"]["PreToolUse"])), 1)
        backups = self.backups(self.settings)
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.load(backups[0]), original)

    def test_running_again_changes_nothing(self):
        self.run_script("install.sh")
        before = self.read(self.settings)
        self.run_script("install.sh")
        self.assertEqual(self.read(self.settings), before)
        self.assertEqual(self.backups(self.settings), [])

    def test_an_older_entry_is_updated_in_place(self):
        old = {"matcher": "Edit", "hooks": [{"type": "command", "command": "/old/agent-edits-log Claude"}]}
        other = {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-hook"}]}
        self.save(self.settings, {"hooks": {"PostToolUse": [old, other]}})
        self.run_script("install.sh")
        groups = self.load(self.settings)["hooks"]["PostToolUse"]
        self.assertEqual(len(groups), 2)
        self.assertIn("Bash", groups[0]["matcher"])
        self.assertTrue(groups[0]["hooks"][0]["command"].startswith(self.bin))
        self.assertEqual(groups[1], other)

    def test_skip_options(self):
        os.makedirs(os.path.dirname(self.codex))
        self.run_script("install.sh", "--no-claude", "--no-codex", "--no-tmux")
        self.assertFalse(os.path.exists(self.settings))
        self.assertFalse(os.path.exists(self.codex))
        self.assertFalse(os.path.exists(self.tmux_conf))

    def test_unknown_option(self):
        result = self.run_script("install.sh", "--bogus", ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(os.path.exists(self.settings))


class UninstallTests(InstallTest):
    def setUp(self):
        super().setUp()
        self.other = {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-hook"}]}
        self.save(self.settings, {"hooks": {"PreToolUse": [self.other]}})
        if HAS_TMUX:
            self.save(self.tmux_conf, "set -g mouse on\n")
        self.run_script("install.sh")
        self.state = os.path.join(self.home, ".local", "state", "agent-edits")
        self.save(os.path.join(self.state, "edits.tsv"), "1\tClaude\t/x\t/\t-\ttool\n")

    def test_uninstall_removes_only_ours(self):
        self.run_script("uninstall.sh")
        self.assertEqual(self.load(self.settings)["hooks"], {"PreToolUse": [self.other]})
        for name in ("agent-edits-log", "agent-edits-view", "agent-edits-popup"):
            self.assertFalse(os.path.lexists(os.path.join(self.bin, name)))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config", "agent-edits")))
        if HAS_TMUX:
            self.assertEqual(self.read(self.tmux_conf), "set -g mouse on\n")
        self.assertTrue(os.path.exists(os.path.join(self.state, "edits.tsv")))

    def test_purge_deletes_the_log(self):
        self.run_script("uninstall.sh", "--purge")
        self.assertFalse(os.path.exists(self.state))

    def test_uninstall_twice(self):
        self.run_script("uninstall.sh")
        self.run_script("uninstall.sh")
        self.assertEqual(self.load(self.settings)["hooks"], {"PreToolUse": [self.other]})


if __name__ == "__main__":
    unittest.main()
