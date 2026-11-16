# 18. More agents

Branch: `feature/more-agents` (needs task 13, so each agent comes with fixtures)

## Goal

Record the edits of other command-line agents that offer hooks: Gemini CLI, Cursor CLI and
opencode.

## Design

For each agent: install it, run it with `AGENT_EDITS_DEBUG=1` to capture real payloads,
add them as fixtures (task 13), then add the support. The names below come from the agents'
documentation and must be confirmed against those payloads.

- **Gemini CLI**: command hooks in `~/.gemini/settings.json`, events `BeforeTool` /
  `AfterTool`, edit tools `write_file` and `replace`, shell tool `run_shell_command`.
  - `config_patch.py`: a `gemini` target, same shape as the Claude one.
  - Hook: map `BeforeTool`/`AfterTool` to `PreToolUse`/`PostToolUse`, add
    `run_shell_command` to `SHELL_TOOLS`, read the agent name from the argument (`Gemini`).
- **Cursor CLI**: hooks in `~/.cursor/hooks.json`, with a file-edit event after each edit.
  If it has no event before an edit, there is no baseline (`D` falls back to `HEAD`);
  documented.
- **opencode**: no command hooks; plugins are JavaScript modules. Ship a small plugin
  (`opencode/agent-edits.js`) that runs `agent-edits-log OpenCode` with the event as JSON on
  `tool.execute.before` / `tool.execute.after`. The installer links it into
  `~/.config/opencode/plugin/`.
- `install.sh` / `uninstall.sh`: `--no-gemini`, `--no-cursor`, `--no-opencode`; each target
  is skipped silently when the agent's config directory doesn't exist.
- Viewer: `AGENT_ORDER` and the `a` filter list the new names; nothing else changes, since
  the log format already carries any agent name.

## Edge cases

- An agent that sends relative paths and no `cwd`: use the hook's working directory, as
  today.
- Session ids: when an agent has none, `-` (no baseline, no session group), as for old
  entries.

## Verification

- Fixture tests for each agent (pre, post, shell).
- A real edit in each agent shows in the viewer with the right name, and `D` works where a
  "before" event exists.
