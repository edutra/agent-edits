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
-- session = "s1", via = "tool", project = root }.
local function line(r)
  return table.concat({ NOW - r[1], r[2], abs(r[3]), r.project or root, r.session or "s1", r.via or "tool" }, "\t") .. "\n"
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
  V().grouped, V().folded = false, {}
  V().confirm = function() return true end
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
  has(lines()[1], "Codex", "first row")
end)

test("one row per file, from its latest edit", function()
  file("a.txt")
  log({ { 30, "Claude", "a.txt" }, { 10, "Codex", "a.txt" } })
  eq(names(), { "a.txt" }, "rows")
  eq(V().rows[1].entry.agent, "Codex", "agent")
end)

test("old log lines with three columns", function()
  file("old.txt")
  write(log_file, "")
  refresh()
  write(log_file, (NOW - 5) .. "\tClaude\t" .. abs("old.txt") .. "\n")
  refresh()
  eq(names(), { "old.txt" }, "rows")
  eq(V().rows[1].entry.session, "-", "session")
end)

test("shell edits are marked with $", function()
  file("s.txt")
  log({ { 5, "Claude", "s.txt", via = "shell" } })
  has(lines()[1], "Claude$", "row")
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
  local e = V().rows[1].entry
  eq(e.deleted, true, "deleted")
  has(lines()[1], "✗", "row")
  select("gone.txt")
  eq(V().stats[e.path], { add = 0, change = 0, delete = 2 }, "stats")
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
    if row.entry.path == other .. "/out.txt" then error("out.txt is not in the project") end
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
  has(lines()[2], "✓", "reviewed row")
  keys("X")
  eq(names(), { "b.txt" }, "X hides reviewed")
  keys("X")
  append(line({ 0, "Claude", "a.txt" }))
  refresh()
  eq(names(), { "a.txt", "b.txt" }, "edited again")
  eq(V().rows[1].entry.reviewed, false, "reviewed")
end)

test("t groups by session", function()
  file("a.txt") file("b.txt") file("c.txt")
  log({ { 10, "Claude", "a.txt", session = "one" }, { 20, "Codex", "b.txt", session = "two" },
    { 30, "Claude", "c.txt", session = "one" } })
  keys("t")
  local kinds = {}
  for _, row in ipairs(V().rows) do kinds[#kinds + 1] = row.group and ("[" .. row.group.agent .. "]") or row.entry.rel end
  eq(kinds, { "[Claude]", "a.txt", "c.txt", "[Codex]", "b.txt" }, "rows")
  keys("t")
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
