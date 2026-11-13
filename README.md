# agent-edits

See every file your AI coding agents edited, in a tmux popup with full Vim motions.

Press `prefix + e` in any tmux pane, and a floating Neovim window opens with every file that
**Claude Code**, **Codex** or **Grok** edited, in any project. Git is not required. The newest
edits are at the top. Moving through the list previews each file read-only, and the preview
follows the agent live while it works. Select lines and press `y` or `d` to paste them into the
agent's prompt.

```
┌ Agent edits (3)  my-project ─────────┬ src/api/routes.ts  (Claude, 2m ago) ───────────────┐
│ src/api/routes.ts         Claude 2m  │  1 import { Router } from "express";               │
│ README.md                  Codex 9m  │  2 import { auth } from "./auth";                  │
│ tests/routes.test.ts        Grok 1h  │  3                                                 │
│                                      │  4 export const router = Router();                 │
└──────────────────────────────────────┴────────────────────────────────────────────────────┘
```

## How it works

1. A `PostToolUse` hook (`agent-edits-log`) runs after each file-editing tool call and appends
   `timestamp  agent  absolute-path  project` to `~/.local/state/agent-edits/edits.tsv`.
   `project` is the directory the agent session was started in.
   - **Claude Code**: `Edit`, `Write`, `MultiEdit`, `NotebookEdit` (in `~/.claude/settings.json`).
   - **Grok**: Grok also loads the hooks in `~/.claude/settings.json`, so the same entry covers it.
     Edits are tagged `Grok`.
   - **Codex**: `apply_patch` (in `~/.codex/hooks.json`). File names are read from the patch.
2. The tmux binding runs `agent-edits-popup --open` through `run-shell`, because `display-popup`
   does not expand `#{formats}` in its command. That opens a `display-popup` running `agent-edits-popup`. That script keeps one
   viewer per directory alive in a private tmux server (`tmux -L agent-edits`). The first press
   starts the viewer, and later presses re-attach to it, so hiding the popup keeps its state.
3. `agent-edits-view` starts Neovim with `nvim/viewer.lua` in that directory. Every logged file
   is listed. Files under the directory show a relative path, and all others show a `~/...` path.
   The list refreshes every 2 seconds.
4. The binding also passes the pane's id to the viewer. Selected code is pasted into that pane
   with `tmux paste-buffer -p` (bracketed paste), so the newlines don't submit the prompt.

The hook never blocks or fails an agent. It always exits with code 0.

## Requirements

- Linux or macOS
- `python3` (3.8 or newer)
- Neovim 0.9 or newer
- tmux 3.3 or newer (for `display-popup`)
- git (optional, only for the `D` diff view)

## Installation

```sh
git clone https://github.com/edutra/agent-edits.git ~/Projects/agent-edits
cd ~/Projects/agent-edits
./install.sh
```

Then restart any running agents so they load the new hook.

Options:

| Flag | Effect |
|------|--------|
| `--key KEY` | tmux key pressed after the prefix (default `e`) |
| `--no-claude` | Skip the Claude Code / Grok hook |
| `--no-codex` | Skip the Codex hook |
| `--no-tmux` | Skip the tmux binding. You can run `agent-edits-view [dir]` yourself. |

The installer:

- symlinks the scripts in `bin/` into `~/.local/bin`, and `nvim/viewer.lua` and
  `tmux/inner.conf` into `~/.config/agent-edits/`. Because these are symlinks, a `git pull` updates the install.
- adds the hook entries to `~/.claude/settings.json` and `~/.codex/hooks.json`, and keeps every other hook.
- appends a marked block to `~/.config/tmux/tmux.conf` (or `~/.tmux.conf`) and reloads tmux:
  ```tmux
  # >>> agent-edits >>>
  bind e run-shell -b "~/.local/bin/agent-edits-popup --open e #{q:client_name} #{q:socket_path} #{q:pane_id} #{q:pane_current_path}"
  # <<< agent-edits <<<
  ```
- saves a timestamped backup (`*.bak-agent-edits-YYYYmmdd-HHMMSS`) of each config file before it changes the file.

Running `./install.sh` again is safe: it never adds an entry twice.

Environment overrides: `AGENT_EDITS_BIN_DIR`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`.

## Usage

Press `prefix + e` inside the pane where the agent is running. If a viewer for that directory
is already running in the background, the same key brings it back as you left it.

| Key | Where | Action |
|-----|-------|--------|
| `j` / `k`, `gg` / `G` | list | Select a file (the preview updates) |
| `Enter` / `l` | list | Jump into the code |
| `r` | list | Reload the list now |
| `]f` / `[f` | anywhere | Next / previous edited file |
| `Ctrl-h` / `Ctrl-l` | anywhere | Move between the list and the code |
| `D` | anywhere | Toggle a side-by-side diff against `HEAD` |
| `Ctrl-z` or `prefix + e` | anywhere | Hide the popup. The viewer keeps running. |
| `:q`, `:qa`, `ZZ`, `ZQ` | list or code | Quit the viewer, as in plain Neovim |
| `y` | visual selection | Paste the selected lines into the agent's prompt and keep the viewer open |
| `d` / `Enter` | visual selection | Paste into the agent's prompt and hide the popup |
| `:AgentEditsHelp` / `g?` | anywhere | Show these key bindings |

All other Vim motions work in the code window: search, marks, `%`, `Ctrl-d`/`Ctrl-u`,
`Ctrl-f`/`Ctrl-b` and so on. The buffers are read-only. Running `:q` on the diff window ends only the diff.

A snippet is pasted as a fenced block with its location. The path is relative to the agent pane's directory:

````
src/api/routes.ts:10-24
```typescript
…the selected lines…
```
````

Snippets go to the pane you opened the popup from. Outside tmux, or when that pane has
closed, the snippet is copied to the clipboard instead.

Your own `~/.config/nvim/init.lua` is loaded first, so you keep your colorscheme and plugins.

## Limitations

- Only edits made through the agents' file-editing tools are recorded. Changes made with shell
  commands (`sed -i`, `echo > file`, code generators) are not.
- Only edits made after you install the hook are recorded.
- Files that no longer exist are hidden. Log entries older than 14 days are pruned once the log grows past about 1 MB.

## Troubleshooting

- **The list is empty.** Check `~/.local/state/agent-edits/edits.tsv`. If it is empty, restart the agent so
  it loads the hook. In Claude Code, `/hooks` lists the hooks it loaded.
- **An agent sends a payload the logger doesn't parse.** Start the agent with `AGENT_EDITS_DEBUG=1`
  set. Each raw hook event is then written to `~/.local/state/agent-edits/debug.jsonl`.
  Please open an issue with an example.

## Uninstall

```sh
./uninstall.sh          # remove hooks, tmux binding, symlinks and background viewers; keep the log
./uninstall.sh --purge  # also delete ~/.local/state/agent-edits
```

The uninstaller removes only the entries that contain `agent-edits-log` and the marked tmux block,
so the rest of your configuration stays as it is. It also unbinds the key in the running tmux server.
It keeps the backups. To roll back completely, copy a `*.bak-agent-edits-*` file over the original.

## Project structure

```
agent-edits/
├── bin/
│   ├── agent-edits-log     # PostToolUse hook: parses the event, appends to the log
│   ├── agent-edits-view    # starts Neovim with the viewer for a directory
│   └── agent-edits-popup   # runs in the popup: starts or re-attaches the background viewer
├── nvim/
│   └── viewer.lua          # list + preview UI, keymaps, live refresh, diff
├── tmux/
│   └── inner.conf          # config of the private tmux server that keeps viewers alive
├── lib/
│   └── config_patch.py     # idempotent add/remove of the hook entries and the tmux block
├── install.sh
├── uninstall.sh
├── LICENSE
└── README.md
```

## License

MIT
