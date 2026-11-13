# 10. Detect edits made by shell commands

Branch: `feature/shell-edits` (needs task 1 for the Pre hook)

## Goal

Agents also change files with shell commands (`sed -i`, `cat > file`, formatters,
generators). Those edits don't go through the edit tools, so today they are invisible.

## Design

- Add the shell tools to the hook matchers, for both `PreToolUse` and `PostToolUse`:
  - Claude: `Bash`. Grok maps `Bash` to `run_terminal_command` on its own.
  - Codex: `Bash|shell|exec_command|local_shell`. The exact name must be confirmed
    with `AGENT_EDITS_DEBUG=1`.
- `PreToolUse` on a shell tool: write a marker file
  `pending/<session>-<tool_use_id>` that holds the start time and the command's working
  directory.
- `PostToolUse` on a shell tool: find the files under the working directory modified
  after that start time:
  - inside git: `git ls-files -m -o --exclude-standard -z` (tracked-modified plus
    untracked, ignored files excluded), then keep paths whose `mtime >= start`.
  - outside git: walk the directory with `os.scandir`, skip `.git`, `node_modules`,
    `.venv`, `__pycache__` and hidden directories, and stop after 20 000 entries or
    0.5 s.
  - Log each file found with column 6 = `shell`, at most 200 files per command.
  - Delete the marker.
- Baselines: shell edits can't be snapshotted beforehand without copying the whole
  tree. The viewer falls back to `HEAD` for them (task 1 already does this when there
  is no baseline).
- The list marks shell-detected entries with `$` after the agent name, for example
  `Claude$ 2m`, and the help explains it.
- Edit-tool calls keep column 6 = `tool`.

## Edge cases

- Commands that run for a long time: the comparison uses the start time, so files
  changed at any point during the command are found.
- Files the agent's command didn't change, but that changed at the same time (your
  editor, another agent in the same directory): they are logged too. This is accepted
  and documented. The `$` marker shows that the edit was inferred.
- No `tool_use_id` (some payloads): fall back to `<session>-shell`.

## Verification

- Pre event, `sed -i` on a tracked file and `echo > new` (untracked), then Post event:
  both are logged with `shell`, and an ignored file is not.
- The same outside git, with a `node_modules` directory that is skipped.
- The viewer shows `Claude$`.
