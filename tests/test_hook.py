"""Tests for bin/agent-edits-log, the hook the agents run.

The events in tests/fixtures/ carry the fields the hook reads from each agent's
payload. Replace them with payloads captured with AGENT_EDITS_DEBUG=1 when an
agent changes its format.
"""
import os
import shutil
import time
import unittest

from helpers import StateTest, event


class EditToolTests(StateTest):
    def test_edit_is_logged_with_its_baseline(self):
        path = self.write("a.txt", "one\n")
        self.edit("claude-edit", path, lambda: self.write("a.txt", "two\n"))
        rows = self.log()
        self.assertEqual(len(rows), 1)
        ts, agent, logged, project, session, via = rows[0]
        self.assertAlmostEqual(int(ts), time.time(), delta=60)
        self.assertEqual((agent, logged, project, session, via),
                         ("Claude", path, self.work, "claude-session-1", "tool"))
        self.assertEqual(self.read(self.baseline("claude-session-1", path)), "one\n")

    def test_baseline_is_taken_before_the_first_edit_only(self):
        path = self.write("a.txt", "one\n")
        self.edit("claude-edit", path, lambda: self.write("a.txt", "two\n"))
        self.edit("claude-edit", path, lambda: self.write("a.txt", "three\n"))
        self.assertEqual(self.read(self.baseline("claude-session-1", path)), "one\n")
        self.assertEqual(len(self.log()), 2)

    def test_new_file_gets_an_empty_baseline_marker(self):
        path = self.path("new.txt")
        self.edit("claude-write", path, lambda: self.write("new.txt"))
        self.assertTrue(os.path.exists(self.baseline("claude-session-1", path, ".new")))
        self.assertFalse(os.path.exists(self.baseline("claude-session-1", path)))

    def test_large_file_is_not_copied(self):
        path = self.write("big.bin", "x" * 2_000_001)
        self.edit("claude-edit", path, lambda: None)
        self.assertTrue(os.path.exists(self.baseline("claude-session-1", path, ".skip")))
        self.assertFalse(os.path.exists(self.baseline("claude-session-1", path)))

    def test_relative_and_file_url_paths_are_made_absolute(self):
        self.hook(event("claude-edit", file="sub/../rel.txt", cwd=self.work))
        self.hook(event("claude-edit", file="file://" + self.path("url.txt"), cwd=self.work))
        self.assertEqual(self.logged_paths(), [self.path("rel.txt"), self.path("url.txt")])

    def test_notebook_path(self):
        path = self.write("nb.ipynb", "{}")
        self.edit("claude-notebook", path, lambda: None)
        self.assertEqual(self.logged_paths(), [path])
        self.assertTrue(os.path.exists(self.baseline("claude-session-1", path)))

    def test_project_is_claude_project_dir_when_set(self):
        project = os.path.join(self.tmp, "project")
        self.hook(event("claude-edit", file=self.path("a.txt"), cwd=self.work),
                  env={"CLAUDE_PROJECT_DIR": project})
        self.assertEqual(self.log()[0][3], project)

    def test_session_id_is_made_safe_for_a_folder_name(self):
        payload = event("claude-edit", file=self.path("a.txt"), cwd=self.work)
        payload["session_id"] = "../a b/c"
        self.hook(payload)
        self.assertEqual(self.log()[0][4], ".._a_b_c")

    def test_no_session_id(self):
        payload = event("claude-edit", "PreToolUse", file=self.write("a.txt"), cwd=self.work)
        del payload["session_id"]
        self.hook(payload)
        self.hook(dict(payload, hook_event_name="PostToolUse"))
        self.assertEqual(self.log()[0][4], "-")
        self.assertFalse(os.path.exists(os.path.join(self.state, "baselines")))

    def test_event_without_a_path_logs_nothing(self):
        payload = event("claude-edit", file="", cwd=self.work)
        self.hook(payload)
        self.assertEqual(self.log(), [])


class CodexTests(StateTest):
    PATCHED = ["added.txt", "sub/updated.txt", "deleted.txt", "moved.txt", "renamed.txt"]

    def test_paths_are_read_from_the_patch(self):
        self.hook(event("codex-apply-patch", cwd=self.work), agent="Codex")
        self.assertEqual(self.logged_paths(), [self.path(p) for p in self.PATCHED])
        self.assertEqual({row[1] for row in self.log()}, {"Codex"})
        self.assertEqual({row[4] for row in self.log()}, {"codex-session-1"})

    def test_baselines_before_the_patch(self):
        self.write("deleted.txt", "gone\n")
        self.hook(event("codex-apply-patch", "PreToolUse", cwd=self.work), agent="Codex")
        self.assertEqual(self.read(self.baseline("codex-session-1", self.path("deleted.txt"))), "gone\n")
        self.assertTrue(os.path.exists(self.baseline("codex-session-1", self.path("added.txt"), ".new")))


class GrokTests(StateTest):
    def test_grok_is_recognised_and_its_project_is_the_event_cwd(self):
        path = self.write("a.txt", "one\n")
        # Grok runs Claude's hook entry (argument "Claude") and sets
        # CLAUDE_PROJECT_DIR to its workspace root.
        self.edit("grok-edit", path, lambda: self.write("a.txt", "two\n"),
                  agent="Claude", workspaceroot="unused")
        row = self.log()[0]
        self.assertEqual((row[1], row[3], row[4]), ("Grok", self.work, "grok-session-1"))
        self.assertEqual(self.read(self.baseline("grok-session-1", path)), "one\n")

    def test_grok_ignores_claude_project_dir(self):
        self.hook(event("grok-edit", file=self.path("a.txt"), cwd=self.work),
                  env={"CLAUDE_PROJECT_DIR": "/elsewhere"})
        self.assertEqual(self.log()[0][3], self.work)


class ShellTests(StateTest):
    def test_git_modified_and_untracked_files_but_not_ignored_ones(self):
        self.init_repo({"tracked.txt": "a\n", ".gitignore": "ignored.txt\n"})

        def change():
            self.write("tracked.txt", "b\n")
            self.write("new.txt")
            self.write("ignored.txt")
        self.shell("claude-bash", change)
        self.assertEqual(sorted(self.logged_paths()), [self.path("new.txt"), self.path("tracked.txt")])
        self.assertEqual({row[5] for row in self.log()}, {"shell"})

    def test_files_changed_before_the_command_are_not_logged(self):
        self.init_repo({"dirty.txt": "a\n"})
        self.write("dirty.txt", "changed earlier\n")
        time.sleep(0.05)
        self.shell("claude-bash", lambda: self.write("now.txt"))
        self.assertEqual(self.logged_paths(), [self.path("now.txt")])

    def test_outside_git_walks_the_directory_and_skips_vendored_and_hidden_dirs(self):
        def change():
            self.write("src/code.txt")
            self.write("node_modules/pkg/index.js")
            self.write(".cache/blob")
        self.shell("claude-bash", change)
        self.assertEqual(self.logged_paths(), [self.path("src/code.txt")])

    def test_only_files_under_the_command_workdir(self):
        self.init_repo({"top.txt": "a\n", "sub/inner.txt": "a\n"})

        def change():
            self.write("top.txt", "b\n")
            self.write("sub/inner.txt", "b\n")
        self.shell("codex-shell", change, agent="Codex", workdir=self.path("sub"))
        self.assertEqual(self.logged_paths(), [self.path("sub/inner.txt")])
        self.assertEqual(self.log()[0][1], "Codex")

    def test_grok_shell_tool(self):
        self.shell("grok-shell", lambda: self.write("g.txt"))
        self.assertEqual([(r[1], r[2], r[5]) for r in self.log()], [("Grok", self.path("g.txt"), "shell")])

    def test_deleted_committed_files_are_logged_with_head_as_baseline(self):
        self.init_repo({"rm.txt": "rm\n", "gitrm.txt": "gitrm\n", "dir/deep.txt": "deep\n",
                        "already.txt": "already\n"})
        os.remove(self.path("already.txt"))  # deleted before the command: not its doing

        def change():
            os.remove(self.path("rm.txt"))
            self.git("rm", "-q", "gitrm.txt")
            shutil.rmtree(self.path("dir"))
        self.shell("claude-bash", change)
        deleted = [self.path(p) for p in ("dir/deep.txt", "gitrm.txt", "rm.txt")]
        self.assertEqual(sorted(self.logged_paths()), deleted)
        for path in deleted:
            name = os.path.basename(path).split(".")[0]
            self.assertEqual(self.read(self.baseline("claude-session-1", path)), name + "\n")
        # A later command doesn't log them again.
        self.shell("claude-bash", lambda: None, call="call-2")
        self.assertEqual(len(self.log()), 3)

    def test_post_without_pre_logs_nothing(self):
        self.write("a.txt")
        self.hook(event("claude-bash", cwd=self.work, command="true", call="c"))
        self.assertEqual(self.log(), [])

    def test_pending_marker_is_removed(self):
        self.shell("claude-bash", lambda: None)
        self.assertEqual(os.listdir(os.path.join(self.state, "pending")), [])


class MaintenanceTests(StateTest):
    def setUp(self):
        super().setUp()
        self.a, self.b = os.path.join(self.tmp, "a"), os.path.join(self.tmp, "b")
        now = int(time.time())
        self.write_log([
            (now, "Claude", self.a + "/1.txt", self.a, "sa", "tool"),
            (now, "Claude", self.a + "/2.txt", self.a, "sa", "tool"),
            (now, "Codex", self.b + "/3.txt", self.b, "sb", "tool"),
        ])
        for session in ("sa", "sb"):
            os.makedirs(os.path.join(self.state, "baselines", session))

    def test_clear_dry_run_counts_and_changes_nothing(self):
        out = self.hook(b"", args=["--clear", self.a, "--dry-run"])
        self.assertEqual(out.strip(), "2")
        self.assertEqual(len(self.log()), 3)

    def test_clear_one_project(self):
        out = self.hook(b"", args=["--clear", self.a])
        self.assertEqual(out.strip(), "2")
        self.assertEqual(self.logged_paths(), [self.b + "/3.txt"])
        self.assertEqual(os.listdir(os.path.join(self.state, "baselines")), ["sb"])

    def test_clear_all(self):
        self.assertEqual(self.hook(b"", args=["--clear-all"]).strip(), "3")
        self.assertEqual(self.log(), [])
        self.assertEqual(os.listdir(os.path.join(self.state, "baselines")), [])

    def test_reviewed_marks(self):
        reviewed = os.path.join(self.state, "reviewed.tsv")
        self.hook(b"", args=["--reviewed", "100", self.a + "/1.txt", self.b + "/3.txt"])
        self.assertEqual(self.read(reviewed), f"{self.a}/1.txt\t100\n{self.b}/3.txt\t100\n")
        self.hook(b"", args=["--reviewed", "0", self.b + "/3.txt"])
        self.assertEqual(self.read(reviewed), f"{self.a}/1.txt\t100\n")
        # Marks for files that left the log are dropped on the next write.
        self.hook(b"", args=["--clear", self.a])
        self.hook(b"", args=["--reviewed", "200", self.b + "/3.txt"])
        self.assertEqual(self.read(reviewed), f"{self.b}/3.txt\t200\n")


class PruneTests(StateTest):
    def test_old_lines_and_baselines_go_active_sessions_keep_theirs(self):
        now, old = int(time.time()), int(time.time()) - 20 * 86400
        rows = [(old, "Claude", f"/x/f{i}", "/x", "old", "tool") for i in range(30000)]
        rows += [(old, "Claude", "/x/a", "/x", "active", "tool"),
                 (now, "Claude", "/x/b", "/x", "active", "tool")]
        self.write_log(rows)  # over 1 MB
        for session in ("old", "active", "inflight"):
            os.makedirs(os.path.join(self.state, "baselines", session))
        for session in ("old", "active"):
            folder = os.path.join(self.state, "baselines", session)
            os.utime(folder, (old, old))
        self.hook(event("claude-edit", file="/x/c", cwd="/x"))
        self.assertEqual(self.logged_paths(), ["/x/b", "/x/c"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.state, "baselines"))),
                         ["active", "inflight"])

    def test_small_log_is_left_alone(self):
        old = int(time.time()) - 20 * 86400
        self.write_log([(old, "Claude", "/x/a", "/x", "s", "tool")])
        self.hook(event("claude-edit", file="/x/c", cwd="/x"))
        self.assertEqual(self.logged_paths(), ["/x/a", "/x/c"])


class RobustnessTests(StateTest):
    def test_bad_input_never_fails_the_agent(self):
        for payload in (b"", b"not json", b"[]", b"{}", b'{"tool_input": 5}', b"\xff\xfe"):
            with self.subTest(payload=payload):
                self.hook(payload)
        self.assertEqual(self.log(), [])

    def test_unwritable_state_never_fails_the_agent(self):
        os.makedirs(os.path.dirname(self.state))
        with open(self.state, "w") as fh:  # a file where the folder should be
            fh.write("")
        self.hook(event("claude-edit", file=self.path("a.txt"), cwd=self.work))

    def test_debug_writes_raw_events(self):
        payload = event("claude-edit", file=self.path("a.txt"), cwd=self.work)
        self.hook(payload, env={"AGENT_EDITS_DEBUG": "1"})
        self.assertIn('"tool_name": "Edit"', self.read(os.path.join(self.state, "debug.jsonl")))


if __name__ == "__main__":
    unittest.main()
