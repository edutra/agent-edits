# Fix: the Codex hook never fires

Branch: `fix/codex-hook`

## Problem

Files edited by Codex never show up. The log contains only `Claude` entries.

## Cause

Codex runs a hook only when it is **trusted**. `~/.codex/config.toml` stores a
`[hooks.state."<file>:<event>:<group>:<handler>"]` table with a `trusted_hash` for each
approved hook. `install.sh` added a `PostToolUse` group to `~/.codex/hooks.json`, but
nobody approved it, so Codex skips it without telling anyone. The hash format is
internal to Codex, so the installer must not write it. The user has to approve the
hook in Codex.

A second, smaller risk: the matcher is `apply_patch`. If a Codex version reports the
edit tool under another name, the hook stays silent even after it is approved.

## Changes

- `lib/config_patch.py`
  - `hooks-add FILE EVENT MATCHER COMMAND`: the event becomes a parameter, because
    later tasks need `PreToolUse` too.
  - Running it again **replaces** our group (identified by `agent-edits-log`) instead
    of keeping the old one. A changed matcher or command is upgraded in place.
  - `hooks-remove FILE` removes our groups from every event and drops events that end
    up empty.
- `install.sh`
  - The Codex matcher becomes `apply_patch|Edit|Write`. The logger already accepts
    any payload shape.
  - After touching `~/.codex/hooks.json`, print a clear notice: open Codex, run
    `/hooks` and trust the agent-edits hook. Without that step, Codex ignores the hook.
- README: a "Codex" troubleshooting entry explaining hook trust.

## Verification

- `config_patch` round trip: add, add again with a different matcher (one group,
  updated), remove (original file byte for byte).
- Re-run `install.sh` on the real configuration: our group is updated, and the
  notification hooks stay as they are.
- Manual (user): trust the hook in Codex, let Codex edit a file, and check that
  `edits.tsv` gets a `Codex` line.
