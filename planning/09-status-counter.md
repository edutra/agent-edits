# 9. tmux status counter and notifications

Branch: `feature/status-counter` (needs task 8 for review marks)

## Goal

Know without opening the popup that agents changed files you haven't reviewed, and notice
when an agent touches many files at once.

## Design

- `agent-edits-log --count DIR` prints the number of files to review for the project in DIR
  (same project rule as `p`, same reviewed rule as `x`, deleted files with a baseline
  included). It reads only the log and `reviewed.tsv`, and caches the answer in
  `count-<sha256(DIR)>` keyed on their sizes and mtimes, so a status refresh costs one
  `stat` when nothing changed.
- tmux: the installer adds a user option and a format, without touching `status-right`:
  ```tmux
  set -g @agent_edits_count "#(~/.local/bin/agent-edits-log --count '#{pane_current_path}')"
  ```
  The README shows how to put `#{E:@agent_edits_count}` in `status-right`, and prints
  nothing when the count is 0, so an unused project shows no segment.
- Notifications, optional (`install.sh --notify`): after logging, the hook counts the files
  the same session edited in the last 60 s. When the count crosses 10, it runs
  `tmux display-message` in the agent's tmux (`$TMUX` from the hook's environment):
  `agent-edits: Claude edited 12 files in my-project`. Once per session per 10 minutes, stamped
  in `notified/<session>`.

## Edge cases

- `#()` commands run on every status refresh (`status-interval`, 15 s by default). The cache
  keeps it cheap; the command must never print an error into the status line.
- The hook may run outside tmux (agent started in another terminal): no notification.

## Verification

- With three unreviewed files in a project, the count shows 3; `x` on one shows 2 within one
  status refresh.
- 1 000 status calls with an unchanged log take under 2 ms each.
- A shell command that changes 15 files shows one notification.
