# 13. Automated tests and CI

Branch: `chore/tests`

## Goal

Every task so far was verified by hand in an isolated tmux server. Nothing catches a
regression, and nothing runs on macOS, which the README supports (the `md5sum` bug fixed in
task 12 went unnoticed). Turn those manual checks into tests that run on every pull request.

## Design

No new dependencies: Python's `unittest`, Neovim in headless mode, plain bash. One command,
`tests/run.sh` (`python3 -m unittest discover`), runs everything.

- `tests/helpers.py`: `StateTest` gives each test a temporary `XDG_STATE_HOME` and work
  directory, a git config of its own (no signing, no user hooks), and helpers to run the hook
  the way an agent does (event on stdin, agent name as argument, exit code must be 0), one
  edit (Pre, change, Post) or one shell command.
- `tests/fixtures/`: one event per agent and tool (Claude `Edit`, `Write`, `NotebookEdit`,
  `Bash`; Codex `apply_patch`, `shell`; Grok `Edit`, `run_terminal_command`), with
  `@PLACEHOLDERS@` for paths, event names and call ids. They carry the fields the hook reads.
  No payload was captured on this machine (`debug.jsonl` was empty); replace them with real
  ones captured with `AGENT_EDITS_DEBUG=1` when an agent changes its format.
- `tests/test_hook.py` (31 tests): baselines (first edit only, `.new`, `.skip`), paths
  (relative, `file://`, notebooks, Codex patch headers), projects (`CLAUDE_PROJECT_DIR`, Grok's
  cwd), session ids, shell edits inside and outside git, workdir, deletions, `--clear`,
  `--clear-all`, `--reviewed`, prune, bad input, an unwritable state directory, debug output.
- `tests/test_install.py` (12 tests): `install.sh` and `uninstall.sh` against a temporary
  `HOME` and `TMUX_TMPDIR`, so the scripts never find or reload the tmux server you work in.
  Links, hooks, the tmux block, `~/.tmux.conf`, Codex only when installed, other settings
  kept, idempotence, update in place, backups, skip options, uninstall, `--purge`.
- `tests/test_popup.py`: starts `agent-edits-popup` in a private tmux server, waits for the
  viewer, closes the popup and opens it again: one viewer session, re-attached. The session
  name is checked against Python's md5, so the `md5sum` / `md5` fallback is covered on both
  systems.
- `tests/viewer/run.lua`, started by `tests/test_viewer.py` with
  `nvim --headless -u nvim/viewer.lua`: 16 tests that write the log, press keys in the list
  and check the rows. The viewer publishes its state table as `package.loaded["agent-edits"]`
  for them. Covers sorting, old log lines, `$`, hidden and deleted files, markers and stats,
  `a`, `s`, `p`, `x`, `X`, `t`, `H` (asynchronous git), incremental log reads.
- `.github/workflows/test.yml`: on pushes to `main` and `dev` and on pull requests.
  - `ubuntu-22.04`, Python 3.8, Neovim 0.10.4: the oldest supported versions. Its tmux is 3.2,
    so the tmux parts of the install tests are skipped there.
  - `ubuntu-latest` and `macos-latest`, current Python and Neovim stable.
  - A `shellcheck` job for the shell scripts.

## Found while writing the tests

- `install.sh` backed up `settings.json` on a fresh install: the `PreToolUse` entry created the
  file and the `PostToolUse` entry then "changed" it. Files the run itself created are no
  longer backed up.
- `shellcheck` SC2155 in `install.sh` (`local` with a command substitution).

## Edge cases

- macOS: temporary directories are behind a symlink (`/var` → `/private/var`); tests use
  resolved paths. tmux sockets have a 104-byte limit, so the popup test uses a short folder
  in `/tmp`.
- File mtimes come from a coarse clock that can lag the hook's start time by a few
  milliseconds. The shell tests wait 50 ms after the Pre event, as a real command would.

## Verification

- `tests/run.sh`: 45 tests, about 5 seconds, none skipped on this machine.
- A deliberate bug (list sorted oldest first) makes 5 viewer tests fail.
- `~/.claude/settings.json`, the tmux config and the running tmux server are untouched after
  a run.
