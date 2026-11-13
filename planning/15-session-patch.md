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
