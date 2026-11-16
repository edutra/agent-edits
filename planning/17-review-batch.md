# 17. Batched review comments

Branch: `feature/review-batch` (needs task 5)

## Goal

`c` pastes each comment into the agent's prompt at once. While reviewing a large change, the
prompt fills up with separate snippets, and an agent that is idle may be submitted half a
review. Collect the comments first and send them as one review, like a pull request review.

## Design

- `C` on a visual selection in the code: ask for a comment and add
  `{ path, first, last, lines, filetype, comment }` to a queue. Nothing is sent.
- The queue is shown:
  - in the list winbar: `3 comments`;
  - as virtual text (`💬 comment`) at the end of the commented lines, and a sign;
  - `:AgentEditsReview` opens it in a floating window, where `dd` drops a comment and `e`
    edits it.
- `S` (anywhere) sends the review: a header line (`Review of the changes in <project>:`),
  then each comment as the snippet block from task 5, numbered, then a closing line taken
  from an optional prompt (`Overall comment:`, empty to skip). Pasted with bracketed paste in
  one go, then the queue is emptied and the popup hides.
- The queue is saved in `review.json` next to the log, per viewer directory, so it survives
  hiding the popup, quitting the viewer and restarts.
- When a commented file changes again, the comment stays with its original lines, and the
  list shows `(outdated)` next to it, since the lines may have moved.
- `c` keeps its current behaviour (send now).

## Edge cases

- Very long reviews: tmux `load-buffer` has no practical limit, but some agents truncate
  pasted text. Warn above 50 000 characters.
- The agent pane is gone: copy the review to the clipboard and keep the queue.

## Verification

- Queue three comments in two files, hide and reopen the popup, quit and restart the viewer:
  the queue is still there.
- `S` pastes one block in order and empties the queue.
- An edit after a comment marks it outdated.
