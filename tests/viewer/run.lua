-- Tests for nvim/viewer.lua, started by tests/test_viewer.py:
--   nvim --headless -u nvim/viewer.lua -c "luafile tests/viewer/run.lua"
-- with a temporary XDG_STATE_HOME and AGENT_EDITS_ROOT. Each test writes the
-- log (and the files it names), refreshes the list, and checks the rows.
-- Prints "ok <name>" or "FAIL <name>: <error>" per test, and exits non-zero
-- when a test failed.

local root = vim.env.AGENT_EDITS_ROOT
local state = vim.env.XDG_STATE_HOME .. "/agent-edits"
local log_file = state .. "/edits.tsv"
local NOW = os.time()
local tests = {}
-- The viewer's fold_default when it started, before any test changed it.
local started_folded

local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end
local function V() return package.loaded["agent-edits"] end

-- Helpers -------------------------------------------------------------------

local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fh = assert(io.open(path, "w"))
  fh:write(text or "x\n")
  fh:close()
  return path
end

local function file(rel, text) return write(root .. "/" .. rel, text) end
local function abs(rel) return rel:sub(1, 1) == "/" and rel or root .. "/" .. rel end

-- Typed keys in the list window, run to completion.
local function keys(k)
  vim.api.nvim_set_current_win(V().list_win)
  vim.api.nvim_feedkeys(vim.keycode(k), "x", false)
end

local function refresh() keys("r") end

-- One log line: { age in seconds, agent, path (relative to root or absolute),
-- session = "s1", via = "tool", project = root, pane = "-" }.
local function line(r)
  return table.concat({ NOW - r[1], r[2], abs(r[3]), r.project or root, r.session or "s1", r.via or "tool",
    r.pane or "-" }, "\t") .. "\n"
end

-- Replace the log. It is emptied and read first, so the viewer parses the new
-- one from the start.
local function log(rows)
  write(log_file, "")
  refresh()
  local text = {}
  for _, r in ipairs(rows) do text[#text + 1] = line(r) end
  write(log_file, table.concat(text))
  refresh()
end

local function append(text)
  local fh = assert(io.open(log_file, "a"))
  fh:write(text)
  fh:close()
end

local function baseline(session, rel, text)
  return write(state .. "/baselines/" .. session .. "/" .. vim.fn.sha256(abs(rel)), text)
end

local function lines() return vim.api.nvim_buf_get_lines(V().list_buf, 0, -1, false) end

-- The file rows' entries, top to bottom.
-- 
local function entries()
  local out = {}
  for _, row in ipairs(V().rows) do
    if row.entry then out[#out + 1] = row.entry end
  end
  return out
end

-- The text of the file row named `rel`.
local function row_text(rel)
  for i, row in ipairs(V().rows) do
    if row.entry and row.entry.rel == rel then return lines()[i] end
  end
  error("no row for " .. rel, 2)
end

-- Every row, top to bottom: "[agent]" for a session, "dir/" for a folder,
-- the file's name for a file.
local function kinds()
  local out = {}
  for _, row in ipairs(V().rows) do
    out[#out + 1] = row.group and ("[" .. row.group.agent .. "]")
      or row.folder and (row.folder.label .. "/") or row.entry.rel
  end
  return out
end

-- The displayed name of each file row, top to bottom.
local function names()
  local out = {}
  for _, row in ipairs(V().rows) do
    if row.entry then out[#out + 1] = row.entry.rel end
  end
  return out
end

local function eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(want), vim.inspect(got)), 2)
  end
end

local function has(text, part, what)
  if not text:find(part, 1, true) then
    error(string.format("%s: %s not found in %s", what or "text", vim.inspect(part), vim.inspect(text)), 2)
  end
end

-- Cursor on the file row named `rel`.
local function select(rel)
  for i, row in ipairs(V().rows) do
    if row.entry and row.entry.rel == rel then
      vim.api.nvim_win_set_cursor(V().list_win, { i, 0 })
      keys("r")
      return
    end
  end
  error("no row for " .. rel, 2)
end

-- Keys typed in the code window, with the cursor on `row`.
local function code_keys(row, k)
  vim.api.nvim_set_current_win(V().code_win)
  vim.api.nvim_win_set_cursor(V().code_win, { row, 0 })
  vim.api.nvim_feedkeys(vim.keycode(k), "x", false)
end

local function read(rel)
  local fh = io.open(abs(rel), "rb")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end

-- Messages shown with vim.notify since the last call.
local notes = {}
vim.notify = function(msg) notes[#notes + 1] = msg end
local function notified()
  local text = table.concat(notes, "\n")
  notes = {}
  return text
end

-- Back to a clean slate between tests.
local function reset()
  keys("F")
  -- Unfolded, so the rows show; "everything starts folded" has its own test.
  V().grouped, V().folders, V().folded, V().fold_default = false, true, {}, false
  V().confirm = function() return true end
  -- Outside tmux: every window.
  V().current_tab, V().tab_only = function() return nil end, true
  vim.fn.delete(state .. "/baselines", "rf")
  vim.fn.delete(state .. "/reverted", "rf")
  write(state .. "/reviewed.tsv", "")
  notified()
end

-- Tests -----------------------------------------------------------------------

test("empty log", function()
  log({})
  has(table.concat(lines(), "\n"), "No files edited by agents yet.")
end)

test("newest first, names relative to the project", function()
  file("a.txt") file("sub/b.txt") file("c.txt")
  log({ { 30, "Claude", "a.txt" }, { 10, "Codex", "sub/b.txt" }, { 20, "Grok", "c.txt" } })
  eq(names(), { "sub/b.txt", "c.txt", "a.txt" }, "rows")
  has(row_text("sub/b.txt"), "Codex", "first row")
end)

test("one row per file, from its latest edit", function()
  file("a.txt")
  log({ { 30, "Claude", "a.txt" }, { 10, "Codex", "a.txt" } })
  eq(names(), { "a.txt" }, "rows")
  eq(entries()[1].agent, "Codex", "agent")
end)

test("old log lines with three columns", function()
  file("old.txt")
  write(log_file, "")
  refresh()
  write(log_file, (NOW - 5) .. "\tClaude\t" .. abs("old.txt") .. "\n")
  refresh()
  eq(names(), { "old.txt" }, "rows")
  eq(entries()[1].session, "-", "session")
end)

test("shell edits are marked with $", function()
  file("s.txt")
  log({ { 5, "Claude", "s.txt", via = "shell" } })
  has(row_text("s.txt"), "Claude$", "row")
end)

test("missing files without a baseline are hidden", function()
  file("here.txt")
  log({ { 5, "Claude", "here.txt" }, { 5, "Claude", "scratch.txt" } })
  eq(names(), { "here.txt" }, "rows")
end)

test("deleted files with a baseline are listed", function()
  baseline("s1", "gone.txt", "a\nb\n")
  log({ { 5, "Claude", "gone.txt" } })
  eq(names(), { "gone.txt" }, "rows")
  local e = entries()[1]
  eq(e.deleted, true, "deleted")
  has(row_text("gone.txt"), "✗", "row")
  select("gone.txt")
  eq(V().stats[e.path], { add = 0, change = 0, delete = 2 }, "stats")
end)

test("a deleted folder is marked", function()
  file("kept/a.txt")
  baseline("s1", "old/sub/b.txt", "b\n")
  baseline("s1", "kept/c.txt", "c\n")
  log({ { 5, "Claude", "kept/a.txt" }, { 10, "Claude", "old/sub/b.txt" }, { 15, "Claude", "kept/c.txt" } })
  eq(kinds(), { "kept/", "kept/a.txt", "kept/c.txt", "old/sub/", "old/sub/b.txt" }, "rows")
  -- A folder that still exists is not marked, even with a deleted file in it.
  eq(lines()[1]:find("✗", 1, true), nil, "kept/ marked: " .. lines()[1])
  has(lines()[4], "✗", "old/sub/ row")
  eq(V().rows[4].folder.deleted, true, "old/sub/ deleted")
  eq(V().rows[1].folder.deleted, false, "kept/ deleted")
end)

test("change markers count added, changed and deleted lines", function()
  baseline("s1", "m.txt", "a\nb\nc\nd\n")
  file("m.txt", "a\nB\nc\nnew\n")
  log({ { 5, "Claude", "m.txt" } })
  select("m.txt")
  eq(V().stats[abs("m.txt")], { add = 0, change = 2, delete = 0 }, "stats")
  -- A different size, so checktime sees the change within the same clock tick.
  file("m.txt", "a\nb\nc\nd\ne\nf\n")
  vim.cmd("silent! checktime")
  -- The markers follow a reload from a scheduled callback.
  local want = { add = 2, change = 0, delete = 0 }
  vim.wait(2000, function() return vim.deep_equal(V().stats[abs("m.txt")], want) end)
  eq(V().stats[abs("m.txt")], want, "stats after the agent changed it")
end)

test("a cycles the agent filter", function()
  file("a.txt") file("b.txt") file("c.txt")
  log({ { 30, "Grok", "c.txt" }, { 20, "Codex", "b.txt" }, { 10, "Claude", "a.txt" } })
  local seen = {}
  for _ = 1, 4 do
    keys("a")
    seen[#seen + 1] = table.concat(names(), ",")
  end
  eq(seen, { "a.txt", "b.txt", "c.txt", "a.txt,b.txt,c.txt" }, "rows per filter")
end)

test("s keeps the session of the selected file", function()
  file("a.txt") file("b.txt") file("c.txt")
  log({ { 10, "Claude", "a.txt", session = "one" }, { 20, "Claude", "b.txt", session = "two" },
    { 30, "Claude", "c.txt", session = "one" } })
  select("b.txt")
  keys("s")
  eq(names(), { "b.txt" }, "rows")
  keys("s")
  eq(#names(), 3, "rows after toggling off")
end)

test("p keeps this project", function()
  local other = vim.fn.fnamemodify(root, ":h") .. "/other"
  file("in.txt")
  write(other .. "/out.txt")
  write(other .. "/by-us.txt")
  log({ { 10, "Claude", "in.txt" }, { 20, "Claude", other .. "/out.txt", project = other },
    { 30, "Claude", other .. "/by-us.txt", project = root } })
  eq(#names(), 3, "rows")
  keys("p")
  eq(#names(), 2, "rows in the project")
  for _, row in ipairs(V().rows) do
    if row.entry and row.entry.path == other .. "/out.txt" then error("out.txt is not in the project") end
  end
end)

test("no match shows the filters", function()
  file("a.txt")
  log({ { 10, "Claude", "a.txt" } })
  V().filters.agent = "Nobody"
  refresh()
  has(table.concat(lines(), "\n"), "No files match the filters")
end)

test("x marks reviewed, a new edit brings the file back", function()
  file("a.txt") file("b.txt")
  log({ { 10, "Claude", "a.txt" }, { 20, "Claude", "b.txt" } })
  select("a.txt")
  keys("x")
  eq(names(), { "b.txt", "a.txt" }, "reviewed file sinks")
  has(row_text("a.txt"), "✓", "reviewed row")
  keys("X")
  eq(names(), { "b.txt" }, "X hides reviewed")
  keys("X")
  append(line({ 0, "Claude", "a.txt" }))
  refresh()
  eq(names(), { "a.txt", "b.txt" }, "edited again")
  eq(entries()[1].reviewed, false, "reviewed")
end)

test("t groups by session", function()
  file("a.txt") file("b.txt") file("c.txt")
  log({ { 10, "Claude", "a.txt", session = "one" }, { 20, "Codex", "b.txt", session = "two" },
    { 30, "Claude", "c.txt", session = "one" } })
  keys("t")
  eq(kinds(), { "[Claude]", "a.txt", "c.txt", "[Codex]", "b.txt" }, "rows")
  keys("t")
end)

test("files are grouped by folder, newest first", function()
  file("top.txt") file("src/api/a.ts") file("src/api/b.ts") file("lib/c.lua")
  log({ { 40, "Claude", "top.txt" }, { 30, "Claude", "src/api/a.ts" }, { 10, "Codex", "lib/c.lua" },
    { 20, "Claude", "src/api/b.ts" } })
  eq(kinds(), { "lib/", "lib/c.lua", "src/api/", "src/api/b.ts", "src/api/a.ts", "top.txt" }, "rows")
  -- Under its folder a file shows its name only.
  local text = row_text("src/api/b.ts")
  eq(text:find("src/api", 1, true), nil, "folder repeated in " .. text)
  has(text, "b.ts", "file row")
  has(lines()[3], "src/api/", "folder row")
  keys("f")
  eq(names(), { "lib/c.lua", "src/api/b.ts", "src/api/a.ts", "top.txt" }, "rows without folders")
  has(row_text("src/api/b.ts"), "src/api/b.ts", "full name")
end)

test("folders nest, a folder with one subfolder is one row", function()
  file("src/tui/data.rs") file("src/tui/ui.rs") file("src/commands/trip.rs") file("src/main.rs")
  log({ { 10, "Claude", "src/tui/data.rs" }, { 20, "Claude", "src/commands/trip.rs" },
    { 30, "Claude", "src/tui/ui.rs" }, { 40, "Claude", "src/main.rs" } })
  eq(kinds(), { "src/", "tui/", "src/tui/data.rs", "src/tui/ui.rs", "commands/", "src/commands/trip.rs",
    "src/main.rs" }, "rows")
  eq(V().rows[2].depth, 1, "depth of tui/")
  has(lines()[1], "4", "file count of src/")
end)

test("folders fold and unfold: za, h / l, zc / zo, zM / zR", function()
  file("x/one.txt") file("x/deep/two.txt") file("y/three.txt")
  log({ { 10, "Claude", "x/one.txt" }, { 20, "Claude", "x/deep/two.txt" }, { 30, "Claude", "y/three.txt" } })
  local function cur() return vim.api.nvim_win_get_cursor(V().list_win)[1] end
  eq(kinds(), { "x/", "x/one.txt", "deep/", "x/deep/two.txt", "y/", "y/three.txt" }, "rows")
  -- j / k stop on folders, so a folded one can be reached and opened again.
  keys("gg")
  eq(cur(), 1, "gg")
  keys("jj")
  eq(kinds()[cur()], "deep/", "j stops on a folder")
  keys("za")
  eq(kinds(), { "x/", "x/one.txt", "deep/", "y/", "y/three.txt" }, "za folds")
  has(lines()[3], "▸", "folded mark")
  keys("za")
  eq(#kinds(), 6, "za unfolds")
  -- h on a file folds its folder and leaves the cursor on it.
  keys("j")
  eq(kinds()[cur()], "x/deep/two.txt", "on the file")
  keys("h")
  eq(kinds(), { "x/", "x/one.txt", "deep/", "y/", "y/three.txt" }, "h folds the parent")
  eq(cur(), 3, "cursor on the folder")
  keys("h")
  eq(kinds(), { "x/", "y/", "y/three.txt" }, "h again folds the folder above")
  eq(cur(), 1, "cursor on x/")
  keys("l")
  eq(kinds(), { "x/", "x/one.txt", "deep/", "y/", "y/three.txt" }, "l opens, deep/ stays folded")
  keys("l")
  eq(cur(), 2, "l on an open folder goes in")
  keys("zc")
  eq(kinds(), { "x/", "y/", "y/three.txt" }, "zc on a file folds its folder")
  keys("zo")
  eq(#kinds(), 5, "zo")
  keys("zM")
  eq(kinds(), { "x/", "y/" }, "zM")
  keys("zR")
  eq(#kinds(), 6, "zR")
end)

test("everything starts folded", function()
  eq(started_folded, true, "fold_default at start")
  file("a/one.txt") file("a/b/two.txt") file("top.txt")
  log({ { 10, "Claude", "a/one.txt" }, { 20, "Claude", "a/b/two.txt" }, { 30, "Claude", "top.txt" } })
  keys("zM")
  eq(kinds(), { "a/", "top.txt" }, "folded")
  keys("gg")
  keys("l")
  eq(kinds(), { "a/", "a/one.txt", "b/", "top.txt" }, "a subfolder starts folded too")
  keys("t")
  for _, row in ipairs(V().rows) do
    if not row.group then error("a session is not folded") end
  end
  keys("t")
end)

test("x on a folder marks every file in it", function()
  file("d/a.txt") file("d/b.txt") file("e.txt")
  log({ { 10, "Claude", "d/a.txt" }, { 20, "Claude", "d/b.txt" }, { 5, "Claude", "e.txt" } })
  eq(kinds()[1], "e.txt", "newest first")
  vim.api.nvim_win_set_cursor(V().list_win, { 2, 0 })
  keys("x")
  local reviewed = {}
  for _, e in ipairs(entries()) do reviewed[e.rel] = e.reviewed end
  eq(reviewed, { ["d/a.txt"] = true, ["d/b.txt"] = true, ["e.txt"] = false }, "reviewed")
  eq(kinds()[vim.api.nvim_win_get_cursor(V().list_win)[1]], "d/", "cursor stays on the folder")
end)

test("files from several projects are grouped by project", function()
  local other = vim.fn.fnamemodify(root, ":h") .. "/other"
  file("src/in.txt")
  write(other .. "/src/out.txt")
  log({ { 10, "Claude", "src/in.txt" }, { 20, "Claude", other .. "/src/out.txt", project = other } })
  local here, there = vim.fn.fnamemodify(root, ":~"), vim.fn.fnamemodify(other, ":~")
  eq(kinds(), { here .. "/", "src/", "src/in.txt", there .. "/", "src/", "src/out.txt" }, "rows")
  keys("p")
  eq(kinds(), { "src/", "src/in.txt" }, "one project")
end)

test("long names are shortened from the start", function()
  local long = "a-very-long-directory-name/with/more/levels/than/fit/file.txt"
  file(long)
  log({ { 5, "Claude", long } })
  local width = vim.api.nvim_win_get_width(V().list_win) - 1
  for i, l in ipairs(lines()) do
    eq(vim.fn.strdisplaywidth(l), width, "width of line " .. i)
  end
  has(lines()[1], "…", "folder row")
  keys("f")
  has(row_text(long), "file.txt", "flat row keeps the file name")
end)

test("the log is read as it grows and again when it shrinks", function()
  file("a.txt") file("b.txt") file("c.txt")
  log({ { 30, "Claude", "a.txt" } })
  append(line({ 20, "Claude", "b.txt" }))
  refresh()
  eq(#names(), 2, "after an append")
  local half = line({ 10, "Claude", "c.txt" })
  append(half:sub(1, 12))
  refresh()
  eq(#names(), 2, "half-written line")
  append(half:sub(13))
  refresh()
  eq(#names(), 3, "line completed")
  write(log_file, line({ 5, "Codex", "c.txt" }))
  refresh()
  eq(names(), { "c.txt" }, "after the log shrank")
end)

test("H hides files with nothing left to commit", function()
  local repo = root .. "/repo"
  write(repo .. "/clean.txt", "a\n")
  write(repo .. "/dirty.txt", "a\n")
  vim.fn.system({ "git", "-C", repo, "init", "-q" })
  vim.fn.system({ "git", "-C", repo, "add", "-A" })
  vim.fn.system({ "git", "-C", repo, "commit", "-q", "-m", "init" })
  assert(vim.v.shell_error == 0, "git commit failed")
  write(repo .. "/dirty.txt", "b\n")
  write(repo .. "/new.txt")
  log({ { 10, "Claude", "repo/clean.txt" }, { 20, "Claude", "repo/dirty.txt" }, { 30, "Claude", "repo/new.txt" } })
  keys("H")
  -- git status runs in the background.
  assert(vim.wait(10000, function() return #names() == 2 end), "git status never finished")
  eq(names(), { "repo/dirty.txt", "repo/new.txt" }, "rows")
end)

-- One tmux window ------------------------------------------------------------------

-- The viewer as if opened from a tmux window holding `panes`.
local function in_window(panes, label)
  local set = {}
  for _, p in ipairs(panes) do set[p] = true end
  V().current_tab = function() return { panes = set, label = label or "window 1" } end
  refresh()
end

test("only the files the agents of this tmux window edited", function()
  file("mine.txt") file("theirs.txt") file("both.txt") file("old.txt")
  log({ { 10, "Claude", "mine.txt", pane = "100:%1" }, { 20, "Codex", "theirs.txt", pane = "100:%2" },
    { 30, "Claude", "both.txt", pane = "100:%1" }, { 5, "Codex", "both.txt", pane = "100:%2" },
    { 40, "Claude", "old.txt" } })
  eq(#names(), 4, "outside tmux")
  in_window({ "100:%1", "100:%3" }, "window 2 code")
  eq(names(), { "mine.txt", "both.txt" }, "this window")
  -- both.txt from this window's edit, not the newer one made elsewhere.
  eq(entries()[2].agent, "Claude", "edit of this window")
  has(vim.wo[V().list_win].winbar, "window 2 code", "winbar")
  keys("w")
  eq(#names(), 4, "w shows every window")
  keys("w")
  eq(#names(), 2, "w again")
end)

test("another tmux server, another pane", function()
  file("a.txt")
  log({ { 10, "Claude", "a.txt", pane = "999:%1" } })
  in_window({ "100:%1" })
  eq(names(), {}, "rows")
  has(table.concat(lines(), "\n"), "in this tmux window yet", "empty message")
end)

test("a closed tmux window ends the viewer", function()
  local quit
  local cmd = vim.cmd
  vim.cmd = function(c) if c == "qa!" then quit = true else cmd(c) end end
  V().current_tab = function() return { gone = true } end
  local ok, err = pcall(refresh)
  vim.cmd = cmd
  V().current_tab = function() return nil end
  assert(ok, err)
  eq(quit, true, "quit")
end)

-- Revert ------------------------------------------------------------------------

test("R in the code reverts the changed lines under the cursor", function()
  baseline("s1", "r.txt", "a\nb\nc\nd\ne\n")
  file("r.txt", "a\nB\nc\nD\ne\n")
  log({ { 5, "Claude", "r.txt" } })
  select("r.txt")
  code_keys(4, "R")
  eq(read("r.txt"), "a\nB\nc\nd\ne\n", "file")
  eq(V().stats[abs("r.txt")], { add = 0, change = 1, delete = 0 }, "stats")
end)

test("R reverts deleted and added lines", function()
  baseline("s1", "d.txt", "a\nb\nc\n")
  file("d.txt", "new\na\nc\n")
  log({ { 5, "Claude", "d.txt" } })
  select("d.txt")
  code_keys(2, "R") -- "b" was deleted below line 2
  eq(read("d.txt"), "new\na\nb\nc\n", "after the deletion")
  code_keys(1, "R")
  eq(read("d.txt"), "a\nb\nc\n", "after the addition")
end)

test("R in the diff window reverts the change under the cursor", function()
  baseline("s1", "w.txt", "a\nb\nc\n")
  file("w.txt", "a\nB\nc\nadded\n")
  log({ { 5, "Claude", "w.txt" } })
  select("w.txt")
  keys("D")
  assert(V().diff_win, "no diff window")
  vim.api.nvim_set_current_win(V().diff_win)
  vim.api.nvim_win_set_cursor(V().diff_win, { 2, 0 })
  vim.api.nvim_feedkeys("R", "x", false)
  eq(read("w.txt"), "a\nb\nc\nadded\n", "file")
  eq(V().diff_win, nil, "diff closed after the revert")
end)

test("R keeps a missing final newline and the file mode", function()
  baseline("s1", "n.sh", "a\nb")
  file("n.sh", "a\nB")
  vim.uv.fs_chmod(abs("n.sh"), tonumber("755", 8))
  log({ { 5, "Claude", "n.sh" } })
  select("n.sh")
  code_keys(2, "R")
  eq(read("n.sh"), "a\nb", "file")
  eq(vim.uv.fs_stat(abs("n.sh")).mode % 4096, tonumber("755", 8), "mode")
end)

test("R refuses when the file changed under the viewer", function()
  baseline("s1", "c.txt", "a\n")
  file("c.txt", "b\n")
  log({ { 5, "Claude", "c.txt" } })
  select("c.txt")
  file("c.txt", "agent was here\n")
  code_keys(1, "R")
  eq(read("c.txt"), "agent was here\n", "file")
  has(notified(), "the file changed", "message")
end)

test("R asks first", function()
  baseline("s1", "q.txt", "a\n")
  file("q.txt", "b\n")
  log({ { 5, "Claude", "q.txt" } })
  select("q.txt")
  local asked
  V().confirm = function(question) asked = question return false end
  code_keys(1, "R")
  has(asked, "q.txt", "question")
  eq(read("q.txt"), "b\n", "file")
  keys("R")
  eq(read("q.txt"), "b\n", "file after declining in the list")
end)

test("R without a snapshot says why", function()
  file("shell.txt", "x\n")
  log({ { 5, "Claude", "shell.txt", via = "shell" } })
  select("shell.txt")
  keys("R")
  eq(read("shell.txt"), "x\n", "file")
  has(notified(), "no snapshot", "message")
end)

test("R in the list reverts whole files, :AgentEditsUndoRevert undoes it", function()
  baseline("s1", "edited.txt", "old\n")
  file("edited.txt", "new\n")
  vim.fn.mkdir(state .. "/baselines/s1", "p")
  write(state .. "/baselines/s1/" .. vim.fn.sha256(abs("created.txt")) .. ".new", "")
  file("created.txt", "made by the agent\n")
  baseline("s1", "deleted.txt", "was here\n")
  log({ { 10, "Claude", "edited.txt" }, { 20, "Claude", "created.txt" }, { 30, "Claude", "deleted.txt" } })
  keys("gg")
  keys("VGR")
  eq({ read("edited.txt"), read("created.txt"), read("deleted.txt") }, { "old\n", nil, "was here\n" }, "files")
  has(read(state .. "/reviewed.tsv"), abs("edited.txt"), "reviewed marks")

  vim.cmd("AgentEditsUndoRevert")
  eq({ read("edited.txt"), read("created.txt"), read("deleted.txt") },
    { "new\n", "made by the agent\n", nil }, "files after the undo")
  vim.cmd("AgentEditsUndoRevert")
  has(notified(), "nothing to undo", "second undo")
end)

test("the undo refuses when the agent edited the file since", function()
  baseline("s1", "u.txt", "old\n")
  file("u.txt", "new\n")
  log({ { 5, "Claude", "u.txt" } })
  select("u.txt")
  keys("R")
  eq(read("u.txt"), "old\n", "reverted")
  file("u.txt", "agent edited it again\n")
  vim.cmd("AgentEditsUndoRevert")
  eq(read("u.txt"), "agent edited it again\n", "kept")
  has(notified(), "changed since the revert", "message")
  vim.cmd("AgentEditsUndoRevert!")
  eq(read("u.txt"), "new\n", "forced")
end)

test(":AgentEditsPatch shows the session's patch in a tab", function()
  baseline("s1", "p.txt", "old\n")
  file("p.txt", "new\n")
  baseline("s2", "other.txt", "o\n")
  file("other.txt", "O\n")
  log({ { 5, "Claude", "p.txt" }, { 4, "Codex", "other.txt", session = "s2" } })
  select("p.txt")
  vim.cmd("AgentEditsPatch")
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, "diff", "filetype")
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  has(text, "+++ b/p.txt\n@@ -1 +1 @@\n-old\n+new", "patch")
  eq(text:find("other.txt", 1, true), nil, "other session")
  vim.api.nvim_feedkeys("q", "x", false)
  eq(#vim.api.nvim_list_tabpages(), 1, "q closes the tab")
end)

test(":AgentEditsPatch FILE writes it", function()
  baseline("s1", "w.txt", "old\n")
  file("w.txt", "new\n")
  log({ { 5, "Claude", "w.txt" } })
  select("w.txt")
  local out = vim.env.XDG_STATE_HOME .. "/out.patch"
  vim.cmd("AgentEditsPatch " .. out)
  local fh = assert(io.open(out, "rb"))
  local text = fh:read("*a")
  fh:close()
  has(text, "--- a/w.txt\n+++ b/w.txt\n", "written")
  has(notified(), "wrote", "message")
  eq(#vim.api.nvim_list_tabpages(), 1, "no tab")
end)

test(":AgentEditsPatch without a session says so", function()
  file("n.txt", "x\n")
  log({ { 5, "Claude", "n.txt", session = "-" } })
  select("n.txt")
  vim.cmd("AgentEditsPatch")
  has(notified(), "agent session", "message")
  eq(#vim.api.nvim_list_tabpages(), 1, "no tab")
end)

-- Runner ------------------------------------------------------------------------

local function run()
  started_folded = V().fold_default
  local failed = 0
  for _, t in ipairs(tests) do
    reset()
    local ok, err = pcall(t.fn)
    if ok then
      io.stdout:write("ok " .. t.name .. "\n")
    else
      failed = failed + 1
      io.stdout:write("FAIL " .. t.name .. ": " .. tostring(err) .. "\n")
    end
  end
  io.stdout:write(string.format("%d passed, %d failed\n", #tests - failed, failed))
  vim.cmd(failed > 0 and "cquit 1" or "qall!")
end

-- After the viewer's own VimEnter handler has built the layout.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function() vim.schedule(run) end,
})
