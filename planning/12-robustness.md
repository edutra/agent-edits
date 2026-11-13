# 12. Robustness fixes

Branch: `fix/robustness`

## Goal

Four problems found while reviewing the code:

1. On macOS the popup fails: `agent-edits-popup` hashes the directory with `md5sum`, which
   macOS doesn't have.
2. Every 2 seconds the viewer parses the whole log again. With `H` on it also runs
   `git rev-parse` and `git status` synchronously, which freezes the viewer in big
   repositories.
3. Files an agent deleted (Codex `*** Delete File`, `rm` in a shell command) disappear from
   the list, so the deletion is never reviewed.
4. `prune()` drops a session's baselines by the mtime of its folder, which only changes when a
   file is added. A session still running after 14 days loses the baselines of its first
   edits.

## Design

1. Use `md5sum` when it exists, else `md5 -q`. The session name stays the same on Linux, so
   running viewers are reused after the upgrade.
2. Viewer:
   - Keep the parsed log between refreshes and parse only the lines appended since the last
     read. Skip the read when the log's size and mtime are unchanged. Parse it again from the
     start when it shrank or its first 64 bytes changed (prune, `:AgentEditsClear`). A line
     the hook hasn't finished writing is left for the next read.
   - `H`: find each file's work tree with `vim.fs.root(dir, ".git")` (no process), cached
     per directory. Run `git status` in the background with `vim.system`, one round at a time
     and at most every 1.5 s. The list refreshes when the round ends. Until then, files count
     as not committed, so nothing is hidden by mistake.
3. Deleted files:
   - Hook, shell commands: inside git, `PreToolUse` also stores the files under the working
     directory that are in `HEAD` but missing from the disk
     (`git diff HEAD --relative --no-renames --name-only --diff-filter=D`). `PostToolUse`
     runs the same command; the files missing now but not before are logged with `via`
     `shell`, and their `HEAD` version is saved as their baseline (unless the session already
     has one). `git show` runs in the working directory, because the file's own directory may
     be gone too.
   - Viewer: a file that no longer exists stays listed when its session has a baseline. It is
     struck through in the colour of `Removed`, marked `✗`, and the code winbar says
     `deleted`. Markers and `D` compare the baseline with an empty file. `o` / `O` warn
     instead of creating the file again.
   - A file that has no baseline (created and removed again by the session, such as a scratch
     file) stays hidden, as before.
4. `prune()` keeps the baselines of every session that still has lines in the log, and drops
   the others once their folder is older than 14 days. A session whose first edit is still
   in flight (baseline written, log line not yet) is recent, so it is kept.

## Edge cases

- Shell deletions of untracked files, or outside git, are not detected: there is nothing to
  compare with. Documented in Limitations.
- A deleted file that comes back: it exists again, so it is listed normally.
- `git mv` shows up as a deletion of the old path; the new path is not detected (its mtime
  doesn't change). Same as before for the new path.

## Verification

- Hook, in a temporary repository: `rm`, `git rm` and `rm -rf` of a directory during one
  shell command are logged once, each with its `HEAD` content as baseline. A second command
  logs nothing new. An `Edit` still logs with `tool`.
- Prune: a log over 1 MB with an old session and an active session (old lines plus a recent
  one) whose baseline folders are 20 days old. The old session's folder is removed, the
  active one and a fresh folder with no log lines are kept.
- Viewer (`tmux -L` + `capture-pane`): deleted files show `✗` and `deleted -1`; `D` shows the
  baseline next to an empty file; a new log line appears within 2 s; a half-written line
  appears only once completed; `:AgentEditsClear!` empties the list and new edits show up
  after it; `H` hides committed files and a commit updates the list.
- 20 000 log lines: a forced refresh takes about half as long as before. The timer's refresh
  no longer reads the log when it hasn't changed.
