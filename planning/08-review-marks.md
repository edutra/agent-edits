# 8. Mark files as reviewed

Branch: `feature/review-marks`

## Goal

Use the list as a review inbox. Once you have looked at a file, mark it, and it gets
out of the way until an agent touches it again.

## Design

- `x` on a file (or on a visual selection of rows) toggles "reviewed".
- Stored in `reviewed.tsv` next to the log as `<path>\t<edit time reviewed>`, one line
  per path, rewritten under `flock`. It lives outside the viewer's memory, so every
  viewer and later sessions agree.
- A file counts as reviewed when its stored time is at least the time of its latest
  edit. A new edit brings the file back automatically, with no extra state.
- Reviewed files are dimmed (`Comment` highlight) with a `✓` and sorted below the
  unreviewed ones.
- `X` toggles hiding reviewed files completely. The winbar shows
  `Agent edits (3 to review / 8)`.
- Pruning: entries for paths that are no longer in the log are dropped when the file
  is rewritten.

## Verification

- `x` dims the file and moves it down. `x` again restores it.
- A new log line for that file (a newer time) brings it back as unreviewed.
- `X` hides reviewed files and shows them again; the counts in the winbar are right.
- Close and reopen the viewer: the marks persist.
