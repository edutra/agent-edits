# Roadmap

One planning document per task. Each task is implemented in its own branch, created from
`dev`, merged back into `dev` through a pull request before the next task starts.

| # | Task | Branch | Plan |
|---|------|--------|------|
| — | Codex hook never fires | `fix/codex-hook` | [00-codex-hook.md](00-codex-hook.md) |
| 1 | Diff against what the agent changed | `feature/agent-baseline-diff` | [01-agent-baseline-diff.md](01-agent-baseline-diff.md) |
| 2 | Change markers and hunk jumps | `feature/change-markers` | [02-change-markers.md](02-change-markers.md) |
| 3 | Filter the list | `feature/list-filters` | [03-list-filters.md](03-list-filters.md) |
| 4 | Send a file reference | `feature/file-reference` | [04-file-reference.md](04-file-reference.md) |
| 5 | Comment and send | `feature/comment-snippet` | [05-comment-snippet.md](05-comment-snippet.md) |
| 6 | Group by agent session | `feature/session-groups` | [06-session-groups.md](06-session-groups.md) |
| 7 | Clear history, hide committed files | `feature/history-cleanup` | [07-history-cleanup.md](07-history-cleanup.md) |
| 8 | Mark files as reviewed | `feature/review-marks` | [08-review-marks.md](08-review-marks.md) |
| 10 | Detect edits made by shell commands | `feature/shell-edits` | [10-shell-edits.md](10-shell-edits.md) |
| 11 | Open the file in a regular editor | `feature/open-in-editor` | [11-open-in-editor.md](11-open-in-editor.md) |
| 12 | Robustness fixes (macOS, refresh cost, deleted files, baseline prune) | `fix/robustness` | [12-robustness.md](12-robustness.md) |
| 13 | Automated tests and CI | `chore/tests` | [13-tests-ci.md](13-tests-ci.md) |
| 14 | Revert to the agent's starting point | `feature/revert` | [14-revert-to-baseline.md](14-revert-to-baseline.md) |
| 15 | Export a session as a patch | `feature/session-patch` | [15-session-patch.md](15-session-patch.md) |
| 16 | Baselines for shell edits | `feature/shell-baselines` | [16-shell-baselines.md](16-shell-baselines.md) |
| 17 | Batched review comments | `feature/review-batch` | [17-review-batch.md](17-review-batch.md) |
| 9 | tmux status counter and notifications | `feature/status-counter` | [09-status-counter.md](09-status-counter.md) |
| 18 | More agents (Gemini CLI, Cursor CLI, opencode) | `feature/more-agents` | [18-more-agents.md](18-more-agents.md) |

The rows are in the planned order. Tests (13) come first among the new tasks, so every
feature after it lands with tests. A demo GIF for the README is not scheduled.

## Shared decisions

### Log format

`~/.local/state/agent-edits/edits.tsv` is the only interface between the hook and the
viewer. Every column is appended at the end, so old lines stay readable:

| Column | Since | Content |
|--------|-------|---------|
| 1 | v1 | Unix time of the edit |
| 2 | v1 | Agent: `Claude`, `Codex`, `Grok` |
| 3 | v1 | Absolute path of the edited file |
| 4 | v1 | Directory the agent session was started in |
| 5 | task 1 | Agent session id (`-` when unknown) |
| 6 | task 10 | How the edit was detected: `tool` (an edit tool) or `shell` (a shell command) |

Other state lives next to the log: `baselines/` (task 1), `reviewed.tsv` (task 8),
`pending/` (task 10), and later `reverted/` (task 14), `review.json` (task 17) and
`count-*` (task 9).

### Key map

The keys are planned together so that the features don't collide.

| Key | Where | Action | Task |
|-----|-------|--------|------|
| `D` | anywhere | diff against the agent's baseline | 1 |
| `gD` | anywhere | diff against `HEAD` (the old `D`) | 1 |
| `]c` / `[c` | code | next / previous change | 2 |
| `a` | list | cycle the agent filter: all, Claude, Codex, Grok | 3 |
| `s` | list | only the session of the selected file (toggle) | 3 |
| `p` | list | only this project (toggle) | 3 |
| `@` | list | paste `@path` into the agent's prompt | 4 |
| `c` | visual | comment, then paste snippet and comment | 5 |
| `t` | list | group by agent session (toggle) | 6 |
| `H` | list | hide files with nothing left to commit (toggle) | 7 |
| `:AgentEditsClear[!]` | command | clear this project's history (`!`: all of it) | 7 |
| `x` | list | mark / unmark the file as reviewed | 8 |
| `X` | list | hide / show reviewed files | 8 |
| `o` | anywhere | open the file in a new tmux window | 11 |
| `O` | anywhere | open the file in a split next to the agent | 11 |
| `R` | code / list | revert the hunk / the file(s) to the agent's starting point | 14 |
| `:AgentEditsUndoRevert` | command | undo the last revert | 14 |
| `:AgentEditsPatch[!] [file]` | command | the selected file's session as a patch (`!`: send it to the agent) | 15 |
| `C` | visual | add a comment to the review queue | 17 |
| `S` | anywhere | send the queued review | 17 |
| `:AgentEditsReview` | command | show and edit the review queue | 17 |

Every task updates `g?` / `:AgentEditsHelp` and the README key table.

### Hooks

`lib/config_patch.py` owns the hook entries. From the Codex fix on it can register any
event, and running `install.sh` again replaces our entries with the current ones, so
upgrading is a matter of `git pull && ./install.sh`.

### Testing

Each task is verified in an isolated tmux server (`tmux -L <name>`) with a temporary
`XDG_STATE_HOME`, driving the viewer with `send-keys` and reading it with `capture-pane`.
The hook is tested by piping sample events of the three agents into it.
