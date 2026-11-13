# 5. Comment and send

Branch: `feature/comment-snippet` (uses the helper from task 4)

## Goal

Turn the viewer into a small code review tool. Select lines, write what is wrong, and
send both to the agent.

## Design

- Visual `c` in the code window opens a prompt (`vim.ui.input`, so a UI plugin such as
  dressing or snacks styles it if one is installed) titled
  `Comment on src/a.py:10-14`.
- The text sent is the snippet followed by the comment:

  ````
  src/a.py:10-14
  ```python
  ...
  ```
  <comment>
  ````

- An empty comment or `Esc` cancels and sends nothing.
- The viewer stays open, so several comments can be queued in the prompt before you
  switch back and press Enter in the agent.
- Comment lines that start with `/` are sent as written, so you can still type an
  agent slash command. The agents only treat a leading `/` as a command, and the
  snippet header always comes first.

## Verification

- `V` over 3 lines, `c`, type `rename this`, Enter: the agent pane receives the block
  followed by `rename this`.
- `Esc` in the prompt sends nothing and leaves visual mode.
