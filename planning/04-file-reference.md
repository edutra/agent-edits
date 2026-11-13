# 4. Send a file reference

Branch: `feature/file-reference`

## Goal

Sometimes you want to point the agent at a whole file instead of pasting code. Claude
Code and Codex both read `@path` in the prompt as a file reference.

## Design

- `@` in the list pastes `@<path> ` (with a trailing space) into the agent's prompt
  and keeps the viewer open, so you can add several files and then switch back.
- The path is relative to the agent pane's directory, the same rule as for snippets.
  Outside that directory it is absolute (with `~`), because the agents resolve `@`
  relative to their working directory.
- Visual `@` in the list sends every selected file, separated by spaces.
- Reuse the snippet delivery: extract a `send_text(text, hide)` helper from
  `send_selection`. It handles bracketed paste and the clipboard fallback, and both
  features use it.

## Verification

- `@` on a file under the agent's directory pastes `@src/a.py `.
- On a file elsewhere, it pastes `@~/other/x.py `.
- Visual selection of 3 rows pastes 3 references.
- With no agent pane known, the text goes to the clipboard, as for snippets.
