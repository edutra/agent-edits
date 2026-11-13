# 6. Group by agent session

Branch: `feature/session-groups` (needs tasks 1 and 3)

## Goal

Show which session produced which edits. "Claude in ~/Projects/app" with its files
below is easier to read than one flat list when several agents work at the same time.

## Design

- `t` toggles between the flat list (default) and the grouped list.
- Grouped list:

  ```
  ▾ Claude  ~/Projects/app  2m        ← header: agent, project, last edit
     src/api.ts            2m
     README.md             9m
  ▾ Codex   ~/Projects/web  1h
     index.html            1h
  ```

  - Groups are sorted by their newest edit. Files inside a group are sorted
    newest first.
  - A file edited by two sessions appears in both groups.
- Header rows can't be selected: `j` / `k` skip them, and `]f` / `[f` too.
- `Enter` / `za` on a header folds or unfolds the group.
- Internally the list becomes a list of rows (`{kind = "header" | "file", entry}`),
  so the cursor-to-entry mapping no longer assumes one row per file.
- Filters from task 3 apply before grouping.

## Verification

- Two sessions with overlapping files: the right headers, the right files under each,
  and the right order.
- `j` / `k` never stop on a header; `t` keeps the selected file selected.
- Folding a group hides its files; a refresh keeps it folded.
