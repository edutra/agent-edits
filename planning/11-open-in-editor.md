# 11. Open the file in a regular editor

Branch: `feature/open-in-editor`

## Goal

The viewer is read-only. When you want to fix something yourself, open the file in a
normal Neovim at the line you are looking at.

## Design

- `o`: new tmux window in the agent's tmux (the outer server), in the file's directory,
  running `$EDITOR +<line> <file>`. `$EDITOR` defaults to `nvim`. The popup hides
  itself, so the new window is visible.
- `O`: same, but in a horizontal split next to the agent pane (`split-window -h -t
  <agent pane>`). That keeps the agent and the editor side by side.
- Line:
  - from the code window, the cursor line.
  - from the list, the first changed line when task 2's hunks are known, otherwise 1.
- It uses the outer socket and pane stored by `agent-edits-popup`. Without them
  (viewer started outside the popup), `o` opens the file in a new tab of the viewer
  with `modifiable` restored, so it still works.
- The editor command is built as an argument list, not a shell string, so paths
  with spaces or quotes work.

## Verification

- `o` in the code window on line 42: a new tmux window opens with Neovim at line 42,
  and the popup is hidden.
- `O`: a split appears next to the agent pane.
- `o` outside tmux opens an editable tab.
