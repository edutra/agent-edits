# 3. Filter the list

Branch: `feature/list-filters` (needs task 1 for the session column)

## Goal

With several agents running, the list grows fast. Narrow it down without leaving the
viewer.

## Design

Three independent filters, combined with AND, kept for the life of the viewer:

| Key | Filter | States |
|-----|--------|--------|
| `a` | agent | all → Claude → Codex → Grok → all (only agents present in the log) |
| `s` | session | off ↔ only the session that edited the selected file |
| `p` | project | off ↔ only files of this project |

- "This project" uses the rule from before the "show everything" change: the file is
  under the viewer's directory, or the session that edited it was started in it, above
  it (except `$HOME` and `/`) or below it.
- The list winbar shows the active filters, for example
  `Agent edits (4/31)  agent:Codex  project`.
- Filtering keeps the selected file selected when it is still visible.
- An empty result says which filters are on and how to clear them.
- `F` clears all filters.

## Implementation notes

- Introduce one place that turns the raw entries into the visible list: read the
  log, apply the filters, sort. Tasks 6, 7 and 8 add their steps to it.
- Entries carry `agent`, `project` and `session` from the log.

## Verification

- A log with 3 agents, 2 sessions and 2 projects: each filter and their combinations
  show the expected files, and the counter is right.
- `F` restores the full list.
