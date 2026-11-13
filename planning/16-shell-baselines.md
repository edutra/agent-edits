# 16. Baselines for shell edits

Branch: `feature/shell-baselines` (needs task 10)

## Goal

Files changed by shell commands (`sed -i`, formatters, generators) have no snapshot, so `D`
falls back to `HEAD`. When the file already had uncommitted changes, from you or from an
earlier edit, the diff shows more than what the agent did.

## Design

- Inside git, `PreToolUse` on a shell tool runs `git stash create` in the working directory.
  It writes a commit holding the index and the tracked files as they are, without touching
  the work tree, the index or the stash list, and prints its hash (nothing when the tree is
  clean, in which case `HEAD` is the snapshot). The hash goes into the pending marker.
- `PreToolUse` also stores the untracked files under the directory
  (`git ls-files -o --exclude-standard`), which the stash commit doesn't hold.
- `PostToolUse`, for each file detected (task 10), unless the session already has a baseline
  for it:
  - tracked: `git show <hash or HEAD>:./<path>` becomes the baseline.
  - untracked before the command: no snapshot possible; leave it to the `HEAD` fallback, and
    note it in the README.
  - not there before: a `.new` baseline, like files created by edit tools.
- The baselines are copied at once, so the stash commit can be garbage collected later.
- Outside git: unchanged, no baseline.

## Edge cases

- Cost: `git stash create` hashes the modified files. On a tree with many large modified
  files this slows down every shell command. Measure it; skip when `git status` lists more
  than 500 entries, and allow `AGENT_EDITS_SHELL_SNAPSHOT=0` to turn it off.
- `git stash create` refreshes the index, which takes `index.lock`. Run it with
  `GIT_OPTIONAL_LOCKS=0`, and if it fails because the lock is taken (the agent's own git
  command), fall back to no baseline instead of waiting.
- Submodules and worktrees: `git -C` handles them; covered by the tests from task 13.

## Verification

- A tracked file with your own uncommitted change, then `sed -i` by the agent: `D` shows only
  the `sed` change.
- A clean tree: the baseline is `HEAD`.
- A new file written by `echo > new`: `D` shows a new file.
- The hook's added time per shell command on this repository and on a large one (logged with
  `AGENT_EDITS_DEBUG=1`).
