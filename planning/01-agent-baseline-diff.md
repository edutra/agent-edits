# 1. Diff against what the agent changed

Branch: `feature/agent-baseline-diff`

## Goal

`D` compares the file with `HEAD`. That view mixes the agent's work with your own
uncommitted changes, and it does nothing outside git. This task makes `D` show
exactly what the agent changed: the file as it was right before the session's first
edit, next to the file now.

## Design

### Baseline snapshots (hook)

- Register the logger for `PreToolUse` as well, with the same matchers as
  `PostToolUse`. The logger reads the event name from `hook_event_name` (Claude, Codex)
  or `hookEventName` (Grok: `pre_tool_use`).
- On `PreToolUse`, for each path the tool is about to touch, if the session has no
  baseline for that path yet:
  - the file exists and is at most 2 MB: copy it to
    `baselines/<session>/<sha1(path)>`.
  - the file does not exist: write an empty `<sha1(path)>.new` marker (the agent
    creates the file).
  - it is larger than 2 MB: write a `.skip` marker, and the viewer falls back to `HEAD`.
- The baseline is kept for the whole session. Later edits in the same session never
  overwrite it, so the diff shows the session's total change.
- Session id: `session_id` (Claude, Codex) or `sessionId` (Grok), else `-`. A `-`
  session takes no snapshots.
- Pruning: when the log is pruned, session directories older than 14 days are deleted.

### Log

`PostToolUse` lines get a 5th column with the session id.

### Viewer

- `D`: diff the file against the baseline of the session that edited it last. If
  there is no baseline (old log line, file too large, unknown session), fall back to
  `HEAD` and say so. A `.new` baseline shows an empty left side, labelled "new file".
- `gD`: the previous behaviour, a diff against `HEAD`.
- The left window's winbar names the base: `before <agent> (<session prefix>)` or `HEAD`.

## Edge cases

- A file edited by two sessions: the latest session's baseline is used. The other
  session's baseline is still on disk.
- Hook payloads with relative paths are resolved against the event `cwd`, as today.
- A `PreToolUse` that the agent then denies leaves an unused baseline. That is harmless.

## Verification

- Pipe a Pre event, change the file, then pipe a Post event. The baseline holds the old
  content and the log line has the session.
- A second Pre for the same file and session does not overwrite the baseline.
- New file: `.new` marker; `D` shows an empty left side.
- In tmux: `D` shows the baseline diff, `gD` the HEAD diff, and both toggle off.
