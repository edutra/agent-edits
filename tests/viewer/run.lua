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

-- Back to a clean slate between tests.
local function reset()
  keys("F")
  V().grouped, V().folded = false, {}
  vim.fn.delete(state .. "/baselines", "rf")
  write(state .. "/reviewed.tsv", "")
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
