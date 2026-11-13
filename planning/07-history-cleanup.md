# 7. Clear history, hide committed files

Branch: `feature/history-cleanup`

## Goal

The list keeps everything for 14 days. After a task is finished and committed, its
files are noise.

## Design

### `:AgentEditsClear` / `:AgentEditsClear!`

- `:AgentEditsClear` removes the log lines of files under the viewer's directory, and
  of sessions started in it. That is "this project", the rule from task 3.
- `:AgentEditsClear!` empties the whole log.
- Both ask for confirmation (`vim.fn.confirm`) and show how many entries will go.
- The log is rewritten under the same `flock` the hook uses, so an edit logged at the
  same moment is not lost.
- Baselines of sessions that no longer have log lines are deleted.

### Hide committed files

- `H` toggles hiding files that have nothing left to commit, that is, files tracked by
  git with no difference from `HEAD`. Untracked files and files outside git always
  stay visible.
- The status comes from one `git status --porcelain` per repository per refresh,
  cached for the 2 s refresh cycle.
- The winbar shows `hide:committed` while the filter is on.

## Verification

- Clear with a log of two projects: only this project's lines go, and the other
  project's stay.
- `!` empties everything; cancelling the confirmation keeps everything.
- In a git repo, commit one of two edited files and press `H`: the committed one
  disappears, the other stays.
