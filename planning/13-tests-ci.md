# 13. Automated tests and CI

Branch: `chore/tests`

## Goal

Every task so far was verified by hand in an isolated tmux server. Nothing catches a
regression, and nothing runs on macOS, which the README supports (the `md5sum` bug fixed in
task 12 went unnoticed). Turn those manual checks into tests that run on every pull request.

## Design

No new dependencies: Python's `unittest`, Neovim in headless mode, plain bash.

- `tests/hook/`: `unittest` tests for `bin/agent-edits-log`.
  - Fixtures: one JSON event per agent and event (`fixtures/claude-edit-pre.json`,
    `codex-apply-patch-post.json`, `grok-write-post.json`, ...), taken from real payloads
    captured with `AGENT_EDITS_DEBUG=1`.
  - Each test gets a temporary `XDG_STATE_HOME` (and a temporary git repository when needed)
    and runs the script with `subprocess`, the way the agents do.
  - Covers: paths from each agent, baselines (`.new`, `.skip`, once per session), shell edits
    inside and outside git, shell deletions, prune, `--clear`, `--clear-all`, `--reviewed`,
    and "never exits non-zero" on garbage input.
- `tests/viewer/`: `nvim --headless -u nvim/viewer.lua` with a prepared log, and a small Lua
  runner (`tests/viewer/run.lua`) that calls the viewer's functions and asserts on the list
  buffer's lines and extmarks. The viewer exposes its module table on
  `package.loaded["agent-edits"]` so tests can reach `refresh`, `move`, and the filters.
  - Covers: sorting, filters (`a`, `s`, `p`, `X`, `H`), groups, reviewed marks, deleted
    files, incremental log reads (append, partial line, shrink), markers and stats.
- `tests/install/`: run `install.sh` and `uninstall.sh` against a temporary `HOME`, compare
  the resulting `settings.json`, `hooks.json` and `tmux.conf` with expected files, run
  install twice (idempotent) and check backups.
- `tests/run.sh` runs all of them; `make test` is not needed.
- `.github/workflows/test.yml`: matrix `ubuntu-latest` and `macos-latest`, Neovim from the
  official release tarball (0.10 and stable), `python3` 3.8 and latest, `shellcheck` on
  `bin/*`, `install.sh`, `uninstall.sh`.

## Edge cases

- macOS: `/tmp` is a symlink to `/private/tmp`; tests compare resolved paths.
- tmux is not needed except for one smoke test of `agent-edits-popup` (start, detach,
  re-attach), skipped when tmux is missing.

## Verification

- `tests/run.sh` passes locally and in CI on both systems.
- Reverting the `md5sum` fix makes the macOS job fail.
