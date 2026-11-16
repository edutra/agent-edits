"""Tests for agent-edits-log --patch: a session's changes as a unified diff
that git apply and patch -p1 take."""
import os
import shutil
import subprocess
import unittest

from helpers import StateTest

SESSION = "claude-session-1"


class PatchTests(StateTest):
    def patch(self, *args):
        return self.hook(b"", args=["--patch", SESSION] + list(args))

    def tree(self, folder):
        """{relative path: bytes} of the files under folder, .git left out."""
        files = {}
        for dirpath, dirnames, filenames in os.walk(folder):
            dirnames[:] = [d for d in dirnames if d != ".git"]
            for name in filenames:
                path = os.path.join(dirpath, name)
                with open(path, "rb") as fh:
                    files[os.path.relpath(path, folder)] = fh.read()
        return files

    def session_edits(self):
        """Edit, create, delete and change the final newline of files, with
        the edit tools and a shell command."""
        self.edit("claude-edit", self.path("a.txt"),
                  lambda: self.write("a.txt", "one\nTWO\nthree\nfour\n"))
        self.edit("claude-write", self.path("dir/new.txt"), lambda: self.write("dir/new.txt", "new\n"))
        self.edit("claude-edit", self.path("noeol.txt"), lambda: self.write("noeol.txt", "end"))
        self.edit("claude-edit", self.path("same.txt"), lambda: self.write("same.txt", "same\n"))
        # Edited, then deleted by a command: the edit took the snapshot.
        self.edit("claude-edit", self.path("gone.txt"), lambda: self.write("gone.txt", "bye!\n"))
        self.shell("claude-bash", lambda: os.remove(self.path("gone.txt")))

    START = {"a.txt": "one\ntwo\nthree\nfour\n", "noeol.txt": "end\n", "gone.txt": "bye\n",
             "same.txt": "same\n", "keep.txt": "keep\n"}

    def test_git_apply_on_the_starting_point_gives_the_current_tree(self):
        self.init_repo(self.START)
        self.session_edits()
        patch = self.patch()
        self.assertIn("--- /dev/null\n+++ b/dir/new.txt\n", patch)
        self.assertIn("--- a/gone.txt\n+++ /dev/null\n", patch)
        self.assertIn("+end\n\\ No newline at end of file\n", patch)
        self.assertNotIn("same.txt", patch)
        clone = os.path.join(self.tmp, "clone")
        self.git("clone", "-q", self.work, clone)
        subprocess.run(["git", "-C", clone, "apply", "-"], input=patch.encode(), env=self.env,
                       check=True, capture_output=True)
        self.assertEqual(self.tree(clone), self.tree(self.work))

    def test_patch_p1_outside_git(self):
        for rel, text in self.START.items():
            self.write(rel, text)
        before = os.path.join(self.tmp, "before")
        shutil.copytree(self.work, before)
        self.session_edits()
        patch = self.patch()
        if shutil.which("patch") is None:
            self.skipTest("patch not installed")
        subprocess.run(["patch", "-p1", "-s", "-E"], cwd=before, input=patch.encode(),
                       check=True, capture_output=True)
        self.assertEqual(self.tree(before), self.tree(self.work))

    def test_shell_edit_in_git_is_diffed_against_head(self):
        self.init_repo({"s.txt": "old\n"})
        self.shell("claude-bash", lambda: self.write("s.txt", "new\n"))
        patch = self.patch()
        self.assertIn("# s.txt: no snapshot, diff against HEAD\n", patch)
        self.assertIn("-old\n+new\n", patch)

    def test_what_cannot_be_diffed_is_a_comment(self):
        self.shell("claude-bash", lambda: self.write("shell.txt", "x\n"))
        self.write("bin.dat", "\0one")
        self.edit("claude-edit", self.path("bin.dat"), lambda: self.write("bin.dat", "\0two"))
        big = self.write("big.txt", "x" * 2_000_001)
        self.edit("claude-edit", big, lambda: self.write("big.txt", "small\n"))
        self.assertEqual(self.patch(), "".join([
            "# big.txt: over 2 MB, no snapshot, skipped\n",
            "# bin.dat: binary file changed, skipped\n",
            "# shell.txt: no snapshot (shell edit or older entry), skipped\n",
        ]))

    def test_root_keeps_the_project_files_and_paths_follow_it(self):
        self.write("a.txt", "a\n")
        other = os.path.join(self.tmp, "other.txt")
        with open(other, "w") as fh:
            fh.write("o\n")
        self.edit("claude-edit", self.path("a.txt"), lambda: self.write("a.txt", "A\n"))

        def change():
            with open(other, "w") as fh:
                fh.write("O\n")
        self.edit("claude-edit", other, change)
        full = self.patch()
        self.assertIn("+++ b/a.txt\n", full)
        self.assertIn(f"# {other}: outside {self.work}, apply from /\n", full)
        self.assertIn("+++ b/" + other.lstrip("/") + "\n", full)
        self.assertEqual(self.patch("--root", os.path.join(self.tmp, "elsewhere")), "")
        sub = self.patch("--root", self.tmp)
        self.assertIn("+++ b/work/a.txt\n", sub)
        self.assertIn("+++ b/other.txt\n", sub)

    def test_unknown_session_prints_nothing(self):
        self.assertEqual(self.hook(b"", args=["--patch", "nope"]), "")


if __name__ == "__main__":
    unittest.main()
