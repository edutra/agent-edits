# 15. Export a session as a patch

Branch: `feature/session-patch` (needs task 1 for baselines)

## Goal

Get everything one agent session changed as a single unified diff: to save it, apply it
elsewhere, paste it into a pull request, or hand it to another agent for review. It must
work outside git too, where `git diff` can't help.

## Design

- `agent-edits-log --patch SESSION [--root DIR]` prints the patch on stdout. For each file
  the session edited (optionally only those in the project, same rule as `p`), it diffs the
  baseline with the current file using `difflib.unified_diff`, with `a/` and `b/` paths
  relative to the session's project, so `git apply -p1` and `patch -p1` both take it.
  - Created file: `--- /dev/null`. Deleted file: `+++ /dev/null`.
  - No baseline (shell edit, old entry): the diff against `HEAD` when in git, otherwise a
    comment line `# <path>: no snapshot, skipped`.
  - Skipped baselines (`.skip`, over 2 MB) and binary files: `Binary files differ`.
- Viewer:
  - `:AgentEditsPatch [file]` with the session of the selected file. Without a file, opens
    the patch in a new tab (`filetype=diff`, read-only). With a file, writes it there.
  - `:AgentEditsPatch!` sends `@<file>` of a temporary patch file to the agent (task 4),
    for "review this change" prompts.
- `g?` and the README document both.

## Edge cases

- A file edited by two sessions: each session's patch starts from its own baseline, so the
  two patches overlap. Documented.
- Files outside the session's project (absolute edits elsewhere): use absolute paths with a
  comment, since `-p1` can't apply them.

## Verification

- A session that edits, creates and deletes a file in a git repository: the patch applies
  with `git apply` on a clean checkout of the starting point and gives the current tree.
- The same outside git, with `patch -p1`.

## Implementation notes

- Paths are relative to the git work tree of `--root` (or of the session's project), or to that
  directory outside git: `git apply` takes paths from the top of the work tree.
- `--root` keeps the files the viewer's `p` keeps (`in_project`, the same rule), so a session
  started in the project also brings its files outside it, with `a/` + their absolute path and
  a `# ... apply from /` comment.
- Binary files and `.skip` baselines are a `#` comment instead of `Binary files differ`: git
  refuses a binary patch without its full index line, and the rest of the patch must apply.
- Created or deleted empty files can't be expressed as a plain unified diff: also a comment.
- Lines end only at `\n` (not `str.splitlines`, which also splits on `\r`, `\f`...), and a
  missing final newline gets `\ No newline at end of file`.
- `:AgentEditsPatch!` writes `patches/<session>.patch` in the state folder and pastes its
  absolute path, since it is outside the agent's directory.
- Tests: `tests/test_patch.py` (applies with `git apply` on a clone of the starting point and
  with `patch -p1` outside git, then compares the trees) and three viewer tests.
