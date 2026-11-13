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

1. The `agent-edits-log` hook runs around each file-editing tool call:
   - **before** the call (`PreToolUse`), it saves a copy of each file the tool is about to change.
     It does this once per agent session, in `~/.local/state/agent-edits/baselines/`. `D` uses
     this copy to show exactly what the session changed.
   - for **shell commands** (`Bash` and the equivalents in Codex and Grok), it records the files
     that changed under the command's directory while the command ran (see Limitations).
   - **after** the call (`PostToolUse`), it appends `timestamp  agent  path  project  session  via`
     to `~/.local/state/agent-edits/edits.tsv`. `project` is the directory the agent session was
     started in.
   - **Claude Code**: `Edit`, `Write`, `MultiEdit`, `NotebookEdit` (in `~/.claude/settings.json`).
   - **Grok**: Grok also loads the hooks in `~/.claude/settings.json`, so the same entry covers it.
     Edits are tagged `Grok`.
   - **Codex**: `apply_patch` (in `~/.codex/hooks.json`). File names are read from the patch.
     Codex runs the hook only after you trust it with `/hooks` (see Troubleshooting).
2. The tmux binding runs `agent-edits-popup --open` through `run-shell`, because `display-popup`
   does not expand `#{formats}` in its command. That opens a `display-popup` running `agent-edits-popup`. That script keeps one
   viewer per directory alive in a private tmux server (`tmux -L agent-edits`). The first press
   starts the viewer, and later presses re-attach to it, so hiding the popup keeps its state.
3. `agent-edits-view` starts Neovim with `nvim/viewer.lua` in that directory. Every logged file
   is listed, and you can filter the list by agent, session or project. A path is shown relative
   to the editing session's project, or to the directory, or as `~/...`.
   The list refreshes every 2 seconds.
4. The binding also passes the pane's id to the viewer. Selected code is pasted into that pane
   with `tmux paste-buffer -p` (bracketed paste), so the newlines don't submit the prompt.

The hook never blocks or fails an agent. It always exits with code 0.

## Requirements

- Linux or macOS
- `python3` (3.8 or newer)
- Neovim 0.10 or newer
- tmux 3.3 or newer (for `display-popup`)
- git (optional, for `gD` and as a fallback for `D`)

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

Running `./install.sh` again is safe: it never adds an entry twice, and it updates an existing
entry in place, so upgrading is `git pull && ./install.sh`. It backs a file up only when it changes the file.

Environment overrides: `AGENT_EDITS_BIN_DIR`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`,
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`.

## Usage

Press `prefix + e` inside the pane where the agent is running. If a viewer for that directory
is already running in the background, the same key brings it back as you left it.

| Key | Where | Action |
|-----|-------|--------|
| `j` / `k`, `gg` / `G` | list | Select a file (the preview updates) |
| `Enter` / `l` | list | Jump into the code |
| `t` | list | Group the list by agent session (toggle). Each group has a header with the agent, the project, the number of files and the last edit. A file edited by two sessions appears in both groups. |
| `za` | list | Fold / unfold the session group under the cursor |
| `r` | list | Reload the list now |
| `a` | list | Filter by agent: all, Claude, Codex, Grok (only the agents in the log) |
| `s` | list | Show only the session that edited the selected file (toggle) |
| `p` | list | Show only this project (toggle): files under the directory, or edited by a session started in it, above it or below it |
| `x` | list | Mark the file as reviewed, or remove the mark. This also works on a visual selection. Reviewed files are dimmed, marked `✓` and moved below the others, and the cursor moves on to the next file to review. A new edit brings the file back as unreviewed. Marks are kept in `reviewed.tsv` and survive restarts. |
| `X` | list | Hide reviewed files (toggle) |
| `H` | list | Hide files with nothing left to commit: tracked by git and unchanged since `HEAD` (toggle). Untracked, ignored and non-git files stay visible. The list updates when you commit. |
| `F` | list | Clear the filters |
| `@` | list | Paste `@path` into the agent's prompt (a file reference for Claude Code and Codex). Works on a visual selection of rows too. The viewer stays open. |
| `]f` / `[f` | anywhere | Next / previous edited file |
| `Ctrl-h` / `Ctrl-l` | anywhere | Move between the list and the code |
| `D` | anywhere | Toggle a side-by-side diff of what the agent changed: the file before the session's first edit, next to the file now |
| `gD` | anywhere | Toggle a side-by-side diff against `HEAD` |
| `]c` / `[c` | anywhere | Next / previous change. Changed lines are marked in the margin (`▎` added or changed, `▁` deleted below), and the code winbar shows `+added ~changed -deleted`. |
| `o` | anywhere | Open the file in `$VISUAL` / `$EDITOR` (default `nvim`) in a new tmux window next to the agent's. From the code window it opens at the cursor line, from the list at the first change. The popup hides itself. |
| `O` | anywhere | Same, but in a split next to the agent pane |
| `Ctrl-z` or `prefix + e` | anywhere | Hide the popup. The viewer keeps running. |
| `:q`, `:qa`, `ZZ`, `ZQ` | list or code | Quit the viewer, as in plain Neovim |
| `y` | visual selection | Paste the selected lines into the agent's prompt and keep the viewer open |
| `d` / `Enter` | visual selection | Paste into the agent's prompt and hide the popup |
| `c` | visual selection | Ask for a comment, then paste the code followed by the comment. The viewer stays open, so you can queue several comments before you switch to the agent. `Esc` or an empty comment sends nothing. |
| `:AgentEditsHelp` / `g?` | anywhere | Show these key bindings |
| `:AgentEditsClear` | command | Forget this project's edits, after asking for confirmation. This uses the same project rule as `p`. `:AgentEditsClear!` forgets every edit. Snapshots that are no longer used are deleted. |

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

- Changes made by the agents' shell commands (`sed -i`, `echo > file`, formatters, generators)
  are inferred. Before a command runs, the hook notes the time. Afterwards, it lists the files
  under the command's directory that changed since then. Inside git it uses modified and
  untracked files and skips ignored ones. Outside git it walks the directory (bounded, skipping
  `node_modules`, `.venv` and hidden directories). Such edits are marked `$` (`Claude$`). A file
  something else changed during the command (your editor, another agent) can show up too.
  `D` shows them against `HEAD`, because no snapshot is taken before a command.
  Inside git, committed files a command deletes (`rm`, `git rm`) are recorded too, with their
  `HEAD` version as the snapshot. Deleting untracked files, or files outside git, is not seen.
- Only edits made after you install the hook are recorded.
- `D` falls back to `HEAD` for edits recorded before the snapshots existed and for files over 2 MB.
- A file that no longer exists stays in the list, struck through and marked `✗`, when there is a
  snapshot of what it held: `D` shows it. Files an agent created and then removed again
  (scratch files) are hidden.
- Log entries older than 14 days are pruned once the log grows past about 1 MB. Snapshots are
  kept as long as their session is still in the log.
  `:AgentEditsClear` clears the history at any time.

## Troubleshooting

- **The list is empty.** Check `~/.local/state/agent-edits/edits.tsv`. If it is empty, restart the agent so
  it loads the hook. In Claude Code, `/hooks` lists the hooks it loaded.
- **Codex edits don't show up.** Codex only runs hooks that you trust. Open Codex, run `/hooks`
  and trust the `agent-edits-log` hooks. Codex asks again when `install.sh` changes a hook.
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
├── tests/
│   ├── run.sh              # runs every test
│   ├── test_hook.py        # the hook, fed with the events in fixtures/
│   ├── test_install.py     # install.sh and uninstall.sh against a temporary HOME
│   ├── test_popup.py       # the popup starts a viewer once and re-attaches to it
│   ├── test_viewer.py      # runs viewer/run.lua in a headless Neovim
│   └── fixtures/           # one hook event per agent and tool
├── install.sh
├── uninstall.sh
├── LICENSE
└── README.md
```

## Development

```sh
tests/run.sh          # every test, about 5 seconds
tests/run.sh -v       # one line per test
tests/run.sh -k shell # only the tests whose name contains "shell"
```

The tests need `python3`, `git` and Neovim; the tmux ones are skipped without tmux 3.3 or newer.
They never touch your configuration or your tmux server: each test gets a temporary `HOME`,
state directory and `TMUX_TMPDIR`. GitHub Actions runs them on Linux and macOS, with the
oldest supported Python and Neovim too, and runs `shellcheck` on the shell scripts.

## License

MIT
