# 14. Revert to the agent's starting point

Branch: `feature/revert` (needs task 1 for baselines)

## Goal

The viewer shows what the agent changed, but undoing a change means switching to an editor
or asking the agent. Let the reviewer throw away a change from the viewer: one hunk, or the
whole file.

## Design

- `R` in the code window: revert the hunk under the cursor. The hunk is found in
  `M.hunks` (task 2); its lines are replaced with the baseline's lines for that range.
- `R` in the list (also on a visual selection of rows): revert the whole file to its
  baseline. A file the session created (`.new` baseline) is deleted; a deleted file
  (task 12) is written back.
- Always asks first: `Revert this change in src/api.ts? (y/N)` or
  `Revert 3 files to before Claude's session? (y/N)`.
- Only with an agent baseline. Without one (shell edits outside git, old entries) `R` says
  so; reverting to `HEAD` is `git checkout`'s job.
- Write through a temporary file and `os.rename`, so the agent never reads a half-written
  file. Keep the file's mode.
- Before writing, save the current content to `reverted/<epoch>-<sha256(path)>` next to the
  log, so `:AgentEditsUndoRevert` can restore the last revert. Kept 7 days.
- The hook doesn't see the revert (no tool call). The viewer marks the file as reviewed at
  the latest edit time, since the reviewer just decided on it.
- Tell the agent? No: the agent may be mid-task. The README suggests `@path` (task 4) to
  point the agent at the reverted file.

## Edge cases

- The file changed since the markers were computed (the agent is still editing): compare
  the file's mtime with the one used for the markers, and refuse with "the file changed,
  try again" if it differs.
- Binary or skipped (`.skip`) baselines: whole-file revert only.
- The file is open in the user's editor: their editor will notice the change (autoread or
  a warning), as with any agent edit.

## Verification

- A file with three hunks: `R` on the second one leaves the other two; markers update.
- `R` in the list on an edited file, a created file and a deleted file.
- `:AgentEditsUndoRevert` restores the content before the revert.
- `R` while the hook appends a new edit to the same file refuses.
