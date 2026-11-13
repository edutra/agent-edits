# 2. Change markers and hunk jumps

Branch: `feature/change-markers` (needs task 1)

## Goal

In a long file it is hard to find what the agent touched. The code window marks the
changed lines in the sign column, and `]c` / `[c` jump between the changes, without
opening the side-by-side diff.

## Design

- Compute the hunks with `vim.text.diff` (falls back to `vim.diff` on older Neovim),
  using `result_type = "indices"`, between the baseline from task 1 and the current
  buffer.
  - No baseline: fall back to the `HEAD` content (`git show`).
  - Neither: no markers.
- Signs, through extmarks in an `agent-edits` namespace:
  - added lines: `▎` in `DiffAdd` / `Added` colour.
  - changed lines: `▎` in `DiffChange` / `Changed`.
  - deleted lines: `▁` in `DiffDelete` / `Removed` on the line before the deletion.
- The code window gets `signcolumn=yes:1`.
- Recompute when a file is previewed and after `checktime` reloads it (`BufReadPost`),
  so the markers follow the agent live.
- `]c` / `[c` in the code window:
  - in diff mode, use Vim's own `]c` / `[c`.
  - otherwise, jump to the start of the next / previous hunk, wrapping around, with a
    "change 2/5" message.
- The code winbar shows a summary: `+12 ~3 -4`.

## Edge cases

- Large files: diff only when both sides are under 2 MB.
- A binary file, or a baseline that can't be read: no markers, no error.

## Verification

- A file with one added, one changed and one deleted region shows the three kinds
  of signs on the right lines.
- `]c` / `[c` cycle through the hunks and wrap. In `D` mode they behave as in Vim.
- Append to the file while the viewer is open: a new sign appears within 2 s.
