"""Shared helpers for the tests: fixtures, a private state directory per test,
and git with a config of its own (no signing, no hooks from the user's config)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(REPO, "bin", "agent-edits-log")
FIXTURES = os.path.join(REPO, "tests", "fixtures")
GROK_EVENTS = {"PreToolUse": "pre_tool_use", "PostToolUse": "post_tool_use"}


def fill(value, table):
    if isinstance(value, dict):
        return {k: fill(v, table) for k, v in value.items()}
    if isinstance(value, list):
        return [fill(v, table) for v in value]
    if isinstance(value, str):
        for token, text in table.items():
            value = value.replace(token, text)
    return value


def event(name, phase="PostToolUse", **subs):
    """The fixture tests/fixtures/<name>.json for `phase`. Each keyword
    replaces its @UPPERCASE@ placeholder, e.g. file=... fills @FILE@."""
    with open(os.path.join(FIXTURES, name + ".json"), encoding="utf-8") as fh:
        data = json.load(fh)
    table = {"@EVENT@": phase, "@GROK_EVENT@": GROK_EVENTS[phase]}
    table.update({"@" + k.upper() + "@": v for k, v in subs.items()})
    return fill(data, table)


def baseline_key(path):
    import hashlib
    return hashlib.sha256(path.encode()).hexdigest()


class StateTest(unittest.TestCase):
    """A temporary XDG_STATE_HOME (self.state) and work directory (self.work)."""

    def setUp(self):
        # realpath: on macOS the temporary directory is behind a symlink.
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="agent-edits-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.state = os.path.join(self.tmp, "state", "agent-edits")
        self.work = os.path.join(self.tmp, "work")
        os.makedirs(self.work)
        gitconfig = os.path.join(self.tmp, "gitconfig")
        with open(gitconfig, "w") as fh:
            fh.write("[user]\n\tname = test\n\temail = test@example.com\n"
                     "[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n")
        self.env = dict(os.environ, XDG_STATE_HOME=os.path.join(self.tmp, "state"),
                        GIT_CONFIG_GLOBAL=gitconfig, GIT_CONFIG_NOSYSTEM="1")
        for name in ("CLAUDE_PROJECT_DIR", "AGENT_EDITS_DEBUG", "GIT_DIR", "GIT_WORK_TREE"):
            self.env.pop(name, None)

    # Running the hook -------------------------------------------------------

    def hook(self, payload, agent="Claude", env=None, args=None):
        """Run the hook as an agent does: the event on stdin, the agent name
        as argument. Asserts the exit code is 0 (the hook must never fail)."""
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload)
        if isinstance(payload, str):
            payload = payload.encode()
        argv = [sys.executable, HOOK] + (args if args is not None else [agent])
        run_env = dict(self.env, **(env or {}))
        result = subprocess.run(argv, input=payload, env=run_env, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout.decode()

    def edit(self, fixture, path, change, agent="Claude", **subs):
        """Pre event, change(), Post event: one edit by an edit tool."""
        subs.setdefault("cwd", self.work)
        self.hook(event(fixture, "PreToolUse", file=path, **subs), agent)
        change()
        self.hook(event(fixture, "PostToolUse", file=path, **subs), agent)

    def shell(self, fixture, change, agent="Claude", call="call-1", workdir=None):
        """Pre event, change(), Post event: one shell command."""
        subs = dict(cwd=self.work, workdir=workdir or self.work, command="true", call=call)
        self.hook(event(fixture, "PreToolUse", **subs), agent)
        # File mtimes come from a coarse clock that can lag the hook's start
        # time by a few milliseconds; a real command starts later than this.
        time.sleep(0.05)
        change()
        self.hook(event(fixture, "PostToolUse", **subs), agent)

    # State -------------------------------------------------------------------

    def log(self):
        """The log as lists of columns."""
        path = os.path.join(self.state, "edits.tsv")
        if not os.path.exists(path):
            return []
        with open(path, encoding="utf-8") as fh:
            return [line.rstrip("\n").split("\t") for line in fh]

    def logged_paths(self):
        return [row[2] for row in self.log()]

    def write_log(self, rows):
        os.makedirs(self.state, exist_ok=True)
        with open(os.path.join(self.state, "edits.tsv"), "w", encoding="utf-8") as fh:
            fh.writelines("\t".join(str(c) for c in row) + "\n" for row in rows)

    def baseline(self, session, path, ext=""):
        return os.path.join(self.state, "baselines", session, baseline_key(path) + ext)

    # Files and git -------------------------------------------------------------

    def path(self, rel):
        return os.path.join(self.work, rel)

    def write(self, rel, text="x\n"):
        path = self.path(rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return path

    def read(self, path):
        with open(path, encoding="utf-8") as fh:
            return fh.read()

    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-C", cwd or self.work] + list(args), env=self.env,
                              check=True, capture_output=True).stdout.decode()

    def init_repo(self, files):
        """A git repository in self.work holding `files` ({rel: text}), committed."""
        self.git("init", "-q")
        for rel, text in files.items():
            self.write(rel, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "init")
