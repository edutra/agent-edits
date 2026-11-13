-- agent-edits viewer: a read-only Neovim layout listing the files AI agents
-- edited under $AGENT_EDITS_ROOT, with a live preview of the selected file.

-- Keep the user's own config (colorscheme, options, plugins).
local user_init = vim.fn.stdpath("config") .. "/init.lua"
if vim.fn.filereadable(user_init) == 1 then
  pcall(dofile, user_init)
end

local root = (vim.env.AGENT_EDITS_ROOT or vim.fn.getcwd()):gsub("(.)/$", "%1")
local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-edits"
local log_file = state_dir .. "/edits.tsv"
local baselines_dir = state_dir .. "/baselines"
local reviewed_file = state_dir .. "/reviewed.tsv"
-- The hook script next to this file (nvim/viewer.lua -> bin/agent-edits-log).
local this_file = vim.fn.resolve(debug.getinfo(1, "S").source:sub(2))
local log_cmd = vim.fn.fnamemodify(this_file, ":h:h") .. "/bin/agent-edits-log"
if vim.fn.executable(log_cmd) == 0 then log_cmd = vim.fn.exepath("agent-edits-log") end
local LIST_WIDTH = 40

vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.autoread = true
vim.o.number = true
vim.o.signcolumn = "no"

local M = { entries = {}, signature = "", list_buf = nil, list_win = nil, code_win = nil, current = nil }
-- The viewer's state, for tests/viewer.
package.loaded["agent-edits"] = M

local function ago(ts)
  local d = os.time() - ts
  if d < 60 then return d .. "s" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  return math.floor(d / 86400) .. "d"
end

-- True when `path` is `dir` or lies below it.
local function under(path, dir)
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

-- Every logged file is listed, from any project. A file shows a path relative
-- to the project of the session that edited it, else to the directory the
-- viewer was opened in, else ~/... A session started in $HOME or / has no
-- project worth naming.
local function display_name(path, project)
  if project == vim.env.HOME or project == "/" then project = "" end
  for _, base in ipairs({ project or "", root }) do
    if base ~= "" and base ~= "/" and path ~= base and under(path, base) then
      return path:sub(#base + 2)
    end
  end
  return vim.fn.fnamemodify(path, ":~")
end

-- Files still to review first, then the reviewed ones; newest first within each.
local function sort_entries(list)
  table.sort(list, function(a, b)
    if a.reviewed ~= b.reviewed then return not a.reviewed end
    if a.ts == b.ts then return a.rel < b.rel end
    return a.ts > b.ts
  end)
  return list
end

-- reviewed.tsv: "<path>\t<edit time reviewed>". Returns the map and the raw
-- text (part of the refresh signature, so marks made elsewhere show up).
local function read_reviewed()
  local marks, raw = {}, ""
  local fh = io.open(reviewed_file, "r")
  if fh then
    raw = fh:read("*a")
    fh:close()
    for path, ts in raw:gmatch("([^\t\n]+)\t(%d+)") do marks[path] = tonumber(ts) end
  end
  return marks, raw
end

-- The parsed log, kept between refreshes: only the lines appended since the
-- last read are parsed. When the log shrank or its first bytes changed (the
-- hook pruned it, or :AgentEditsClear), it is parsed again from the start.
-- latest: the latest edit of each path (flat list); per_session: the latest
-- edit of each path per session (grouped list, where a file edited by two
-- sessions belongs to both).
local log_cache = { offset = 0, head = "", latest = {}, per_session = {} }

local function read_log()
  local c = log_cache
  local st = vim.uv.fs_stat(log_file)
  if not st then
    log_cache = { offset = 0, head = "", latest = {}, per_session = {} }
    return log_cache
  end
  if st.size == c.offset and c.mtime and st.mtime.sec == c.mtime.sec and st.mtime.nsec == c.mtime.nsec then
    return c
  end
  local fh = io.open(log_file, "r")
  if not fh then return c end
  local head = fh:read(64) or ""
  if st.size < c.offset or head:sub(1, #c.head) ~= c.head then
    c = { offset = 0, head = "", latest = {}, per_session = {} }
    log_cache = c
  end
  fh:seek("set", c.offset)
  local text = fh:read("*a") or ""
  fh:close()
  -- The hook may be halfway through a line: leave it for the next read.
  local cut = text:match(".*\n()")
  text = cut and text:sub(1, cut - 1) or ""
  c.offset, c.head, c.mtime = c.offset + #text, head, st.mtime
  for line in text:gmatch("[^\n]+") do
    -- <epoch> <agent> <path> [<project> [<session> ...]]; older lines have fewer columns.
    local f = vim.split(line, "\t", { plain = true })
    local ts, path = tonumber(f[1]), f[3]
    if ts and path and path ~= "" then
      local e = {
        ts = ts, agent = f[2], path = path, rel = display_name(path, f[4]),
        project = f[4] or "", session = f[5] or "-", via = f[6] or "tool",
      }
      if not c.latest[path] or c.latest[path].ts <= ts then c.latest[path] = e end
      local key = e.session .. "\0" .. path
      if not c.per_session[key] or c.per_session[key].ts <= ts then c.per_session[key] = e end
    end
  end
  return c
end

-- The baseline the hook saved for `e` (the file before its session touched
-- it), or nil when there is none.
local function baseline_file(e)
  if not e.session or e.session == "-" then return nil end
  return baselines_dir .. "/" .. e.session .. "/" .. vim.fn.sha256(e.path)
end

-- The logged files to list, newest first, in both shapes (see read_log).
-- A file that no longer exists stays listed, marked deleted, when there is a
-- baseline to show what it held: the agent deleted it, or it was deleted
-- after the agent edited it. Files a session created and then removed again
-- (scratch files) have no baseline and are left out.
local function read_entries()
  local marks
  marks, M.reviewed_raw = read_reviewed()
  local log = read_log()
  local latest = log.latest
  -- Reviewed until anyone edits the file again.
  for _, t in ipairs({ latest, log.per_session }) do
    for _, e in pairs(t) do
      local mark = marks[e.path]
      e.reviewed = mark ~= nil and latest[e.path] ~= nil and mark >= latest[e.path].ts
    end
  end
  local exists = {}
  local function listed(t)
    local out = {}
    for _, e in pairs(t) do
      if exists[e.path] == nil then exists[e.path] = vim.uv.fs_stat(e.path) ~= nil end
      e.deleted = not exists[e.path]
      if e.deleted and e.has_baseline == nil then
        local base = baseline_file(e)
        e.has_baseline = base ~= nil and vim.uv.fs_stat(base) ~= nil
      end
      if not e.deleted or e.has_baseline then out[#out + 1] = e end
    end
    return sort_entries(out)
  end
  return listed(latest), listed(log.per_session)
end

-- Filters ------------------------------------------------------------------
-- a: one agent; s: the session of the selected file; p: this project only.

local home = vim.env.HOME
M.filters = { agent = nil, session = nil, project = false }

-- "This project": the file is under the viewer's directory, or the session
-- that edited it was started in that directory, below it, or above it
-- (except $HOME and /, which are not projects).
local function in_project(e)
  if under(e.path, root) then return true end
  local project = e.project or ""
  if project == "" then return false end
  if under(project, root) then return true end
  return under(root, project) and project ~= home and project ~= "/"
end

-- Hide committed files (H) ----------------------------------------------------
-- A file is "committed" when it is in a git repository and git status reports
-- nothing for it: tracked, unchanged since HEAD. Untracked, ignored and
-- non-git files always stay visible.

M.hide_committed = false
-- Clean files and a signature of the git state (so a commit refreshes the
-- list), filled in the background: git status is slow in big repositories
-- and must not freeze the viewer every 2 seconds.
M.git = { clean = {}, sig = "", busy = false, done_at = 0, tops = {} }

-- The work tree that holds `dir`, or false. Looked up once per directory,
-- without running git.
local function git_top(dir)
  local tops = M.git.tops
  if tops[dir] == nil then
    local found = vim.fs.root(dir, ".git")
    tops[dir] = found and found:gsub("(.)/$", "%1") or false
  end
  return tops[dir]
end

-- Starts git status in each work tree holding one of `entries`; when every
-- one is done, stores the clean set and refreshes the list. Runs at most
-- every 2 seconds, one round at a time.
local function update_committed(entries, refresh)
  local g = M.git
  if g.busy or vim.uv.now() - g.done_at < 1500 then return end
  local members, tops = {}, {}
  for _, e in ipairs(entries) do
    local top = git_top(vim.fn.fnamemodify(e.path, ":h"))
    if top then
      if not members[top] then members[top] = {} tops[#tops + 1] = top end
      table.insert(members[top], e.path)
    end
  end
  table.sort(tops)
  local results, pending = {}, #tops
  local function finish()
    g.busy, g.done_at = false, vim.uv.now()
    local clean, sig = {}, {}
    for _, top in ipairs(tops) do
      local out = results[top]
      if out then
        -- Entries are "XY path", with directories ending in "/" (collapsed).
        local dirty, dirty_dirs = {}, {}
        for item in out:gmatch("[^%z]+") do
          local path = top .. "/" .. item:sub(4)
          if path:sub(-1) == "/" then dirty_dirs[#dirty_dirs + 1] = path:sub(1, -2) else dirty[path] = true end
        end
        for _, path in ipairs(members[top]) do
          local is_clean = not dirty[path]
          for _, d in ipairs(dirty_dirs) do
            if not is_clean then break end
            if under(path, d) then is_clean = false end
          end
          if is_clean then clean[path] = true end
        end
        sig[#sig + 1] = top .. "\n" .. out
      end
    end
    g.clean, g.sig = clean, table.concat(sig, "\n")
    if M.hide_committed then refresh(false) end
  end
  if pending == 0 then
    g.clean, g.sig = {}, ""
    return
  end
  g.busy = true
  for _, top in ipairs(tops) do
    local ok = pcall(vim.system, { "git", "-C", top, "status", "--porcelain", "-z", "--ignored=matching" },
      { text = true }, function(obj)
        vim.schedule(function()
          results[top] = obj.code == 0 and obj.stdout or false
          pending = pending - 1
          if pending == 0 then finish() end
        end)
      end)
    if not ok then
      -- git is missing: nothing counts as committed.
      pending = pending - 1
      if pending == 0 then finish() end
    end
  end
end

local function apply_filters(all)
  local f, out = M.filters, {}
  for _, e in ipairs(all) do
    if (not f.agent or e.agent == f.agent)
      and (not f.session or e.session == f.session)
      and (not f.project or in_project(e))
      and not (M.hide_committed and M.git.clean[e.path])
      and not (M.hide_reviewed and e.reviewed) then
      out[#out + 1] = e
    end
  end
  return out
end

local function filter_labels()
  local f, out = M.filters, {}
  if f.agent then out[#out + 1] = f.agent end
  if f.session then out[#out + 1] = "sess:" .. f.session:sub(1, 6) end
  if f.project then out[#out + 1] = "project" end
  if M.hide_committed then out[#out + 1] = "uncommitted" end
  if M.hide_reviewed then out[#out + 1] = "to review" end
  return out
end

-- The list is a sequence of rows: { entry = e } for a file, { group = g }
-- for a session header in the grouped view.
local function selected()
  if not (M.list_win and vim.api.nvim_win_is_valid(M.list_win)) then return nil end
  local row = (M.rows or {})[vim.api.nvim_win_get_cursor(M.list_win)[1]]
  return row and row.entry
end

local function diff_off()
  if not M.diff_win then return end
  -- Forget the window before closing it, so the WinClosed handler (meant for
  -- a :q on the diff window) doesn't schedule a diffoff over a new diff.
  local win = M.diff_win
  M.diff_win = nil
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  if vim.api.nvim_win_is_valid(M.code_win) then
    vim.api.nvim_win_call(M.code_win, function() vim.cmd("diffoff") end)
  end
end

local function set_code_winbar(e)
  local text = e and string.format(" %s  %%#Comment#(%s, %s ago)", e.rel, e.agent, ago(e.ts)) or ""
  if e and e.deleted then text = text .. "  %#Removed#deleted" end
  local st = e and M.stats and M.stats[e.path]
  if st and (st.add + st.change + st.delete) > 0 then
    text = text .. string.format("  %%#Added#+%d %%#Changed#~%d %%#Removed#-%d", st.add, st.change, st.delete)
  end
  vim.wo[M.code_win].winbar = text
end

local function preview(e, force)
  if not e or not vim.api.nvim_win_is_valid(M.code_win) then return end
  if not force and M.current == e.path then
    -- Same file under another session (grouped view): other baseline.
    if M.current_session ~= e.session then
      M.current_session = e.session
      diff_off()
      if M.update_markers then M.update_markers(e) end
    end
    set_code_winbar(e)
    return
  end
  diff_off()
  M.current, M.current_session = e.path, e.session
  vim.api.nvim_win_call(M.code_win, function()
    vim.cmd("silent! keepalt edit " .. vim.fn.fnameescape(e.path))
    vim.bo.modifiable = false
  end)
  if M.update_markers then M.update_markers(e) end
  set_code_winbar(e)
end

-- Session groups ------------------------------------------------------------
-- t toggles the grouped view: one header per agent session, its files below.

M.grouped, M.folded = false, {}
local list_ns = vim.api.nvim_create_namespace("agent-edits-list")

local function group_key(e)
  return e.session ~= "-" and e.session or (e.agent .. "|" .. e.project)
end

local function build_rows(entries, per_session)
  local rows = {}
  if not M.grouped then
    for _, e in ipairs(entries) do rows[#rows + 1] = { entry = e } end
    return rows
  end
  -- per_session is sorted newest first, so groups come out newest first too.
  local groups, order = {}, {}
  for _, e in ipairs(per_session) do
    local key = group_key(e)
    if not groups[key] then
      groups[key] = { key = key, agent = e.agent, project = e.project, ts = e.ts, files = {} }
      order[#order + 1] = groups[key]
    end
    table.insert(groups[key].files, e)
  end
  for _, g in ipairs(order) do
    rows[#rows + 1] = { group = g }
    if not M.folded[g.key] then
      for _, e in ipairs(g.files) do rows[#rows + 1] = { entry = e } end
    end
  end
  return rows
end

-- "<left><padding><right>" in exactly `width` cells, cutting `left` from the start.
local function fit(left, right, width)
  local room = width - vim.fn.strdisplaywidth(right)
  if vim.fn.strdisplaywidth(left) > room then
    left = "…" .. vim.fn.strcharpart(left, vim.fn.strchars(left) - (room - 1))
  end
  return left .. string.rep(" ", room - vim.fn.strdisplaywidth(left)) .. right
end

local function render()
  local lines, headers, dimmed, deleted = {}, {}, {}, {}
  if #M.rows == 0 and #filter_labels() > 0 then
    lines = { "", "  No files match the filters:", "  " .. table.concat(filter_labels(), " "),
      "", "  F clears them." }
  elseif #M.rows == 0 then
    lines = { "", "  No files edited by agents yet." }
  else
    for i, row in ipairs(M.rows) do
      if row.group then
        local g = row.group
        local where = g.project ~= "" and vim.fn.fnamemodify(g.project, ":~") or "?"
        local mark = M.folded[g.key] and "▸" or "▾"
        lines[i] = fit(string.format(" %s %s %s", mark, g.agent, where),
          string.format(" %d %s", #g.files, ago(g.ts)), LIST_WIDTH - 1)
        headers[#headers + 1] = i
      elseif M.grouped then
        local e = row.entry
        lines[i] = fit("   " .. e.rel, (e.reviewed and " ✓ " or " ") .. (e.deleted and "✗ " or "")
          .. (e.via == "shell" and "$ " or "") .. ago(e.ts), LIST_WIDTH - 1)
      else
        local e = row.entry
        lines[i] = fit(" " .. e.rel, string.format(" %s%s%s%s %s", e.reviewed and "✓ " or "",
          e.deleted and "✗ " or "", e.agent, e.via == "shell" and "$" or "", ago(e.ts)), LIST_WIDTH - 1)
      end
      if row.entry and row.entry.reviewed then dimmed[#dimmed + 1] = i end
      if row.entry and row.entry.deleted then deleted[#deleted + 1] = i end
    end
  end
  vim.bo[M.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.list_buf, 0, -1, false, lines)
  vim.bo[M.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.list_buf, list_ns, 0, -1)
  for _, i in ipairs(headers) do
    vim.api.nvim_buf_set_extmark(M.list_buf, list_ns, i - 1, 0,
      { line_hl_group = "Title", priority = 10 })
  end
  for _, i in ipairs(dimmed) do
    vim.api.nvim_buf_set_extmark(M.list_buf, list_ns, i - 1, 0,
      { line_hl_group = "Comment", priority = 10 })
  end
  for _, i in ipairs(deleted) do
    vim.api.nvim_buf_set_extmark(M.list_buf, list_ns, i - 1, 0,
      { line_hl_group = "AgentEditsDeleted", priority = 11 })
  end
  local count = #M.entries == M.total and tostring(M.total) or (#M.entries .. "/" .. M.total)
  local to_review = 0
  for _, e in ipairs(M.entries) do
    if not e.reviewed then to_review = to_review + 1 end
  end
  if to_review < #M.entries then
    count = string.format("%d to review / %s", to_review, count)
  end
  local labels = filter_labels()
  if M.grouped then table.insert(labels, 1, "by session") end
  labels = table.concat(labels, " ")
  vim.wo[M.list_win].winbar = string.format(" Edits (%s)  %%#Comment#%s", count,
    labels ~= "" and labels or vim.fn.fnamemodify(root, ":t"))
end

-- Put the cursor on the row of `path` (preferring `session`), else on the
-- first file row, and preview it.
local function select_path(path, session)
  local row
  for i, r in ipairs(M.rows) do
    if r.entry and r.entry.path == path then
      if r.entry.session == session then row = i break end
      row = row or i
    end
  end
  if not row then
    for i, r in ipairs(M.rows) do
      if r.entry then row = i break end
    end
  end
  if row then
    vim.api.nvim_win_set_cursor(M.list_win, { row, 0 })
    preview(M.rows[row].entry)
  end
end

local function refresh(force)
  local all, per_session = read_entries()
  local git_sig = ""
  if M.hide_committed then
    update_committed(all, refresh)
    git_sig = M.git.sig
  end
  local entries = apply_filters(all)
  M.total, M.all = #all, all
  local sig = { git_sig, M.reviewed_raw }
  for _, e in ipairs(per_session) do
    sig[#sig + 1] = e.ts .. e.session .. e.path .. (e.deleted and "\tdeleted" or "")
  end
  sig = table.concat(sig, "\n")
  if not force and sig == M.signature then
    -- Only the "x ago" labels change; refresh them once a minute.
    if os.time() - (M.rendered_at or 0) < 60 then return end
  end
  local keep = selected()
  M.entries, M.signature, M.rendered_at = entries, sig, os.time()
  M.rows = build_rows(entries, apply_filters(per_session))
  render()
  if keep then
    select_path(keep.path, keep.session)
  else
    select_path(M.current)
  end
end

-- Move the selection `delta` file rows (headers are skipped); math.huge and
-- -math.huge go to the last / first file.
local function move(delta)
  local rows = M.rows or {}
  local cur = vim.api.nvim_win_get_cursor(M.list_win)[1]
  local target
  if math.abs(delta) == math.huge then
    local from, to, step = 1, #rows, 1
    if delta > 0 then from, to, step = #rows, 1, -1 end
    for i = from, to, step do
      if rows[i].entry then target = i break end
    end
  else
    local step, i = delta > 0 and 1 or -1, cur
    for _ = 1, math.abs(delta) do
      local j = i + step
      while rows[j] and not rows[j].entry do j = j + step end
      if not rows[j] then break end
      i = j
    end
    if rows[i] and rows[i].entry then target = i end
  end
  if target then
    vim.api.nvim_win_set_cursor(M.list_win, { target, 0 })
    preview(rows[target].entry)
  end
end

local function toggle_grouped()
  M.grouped = not M.grouped
  refresh(true)
end

-- Enter on a header folds or unfolds its group, Enter on a file jumps into
-- the code. za folds / unfolds the group of the header or file under the cursor.
local function list_enter(fold_only)
  local cur = vim.api.nvim_win_get_cursor(M.list_win)[1]
  local row = M.rows[cur]
  if row and row.entry and fold_only and M.grouped then
    for i = cur, 1, -1 do
      if M.rows[i].group then row = M.rows[i] break end
    end
  end
  if row and row.group then
    local key = row.group.key
    M.folded[key] = not M.folded[key]
    refresh(true)
    for i, r in ipairs(M.rows) do
      if r.group and r.group.key == key then
        vim.api.nvim_win_set_cursor(M.list_win, { i, 0 })
        break
      end
    end
  elseif row and not fold_only then
    vim.api.nvim_set_current_win(M.code_win)
  end
end

-- The file as committed in HEAD, from the repository that holds it.
local function head_lines(path)
  local dir, name = vim.fn.fnamemodify(path, ":h"), vim.fn.fnamemodify(path, ":t")
  local out = vim.fn.systemlist({ "git", "-C", dir, "show", "HEAD:./" .. name })
  if vim.v.shell_error ~= 0 then return nil end
  return out
end

-- The file as it was before the session that last edited it touched it, saved
-- by the hook. Returns lines (empty for a file the session created) and a
-- label, or nil when there is no usable baseline.
local function baseline_lines(e)
  local base = baseline_file(e)
  if not base then return nil end
  local label = string.format("before %s (%s)", e.agent, e.session:sub(1, 8))
  if vim.uv.fs_stat(base .. ".new") then return {}, label .. ", new file" end
  if not vim.uv.fs_stat(base) then return nil end
  return vim.fn.readfile(base), label
end

-- Lines to compare the file with. kind "agent": the session's baseline, else
-- HEAD; kind "head": HEAD only. Returns lines and a label, or nil and a reason.
local function base_for(e, kind)
  if kind == "agent" then
    local lines, label = baseline_lines(e)
    if lines then return lines, label end
  end
  local lines = head_lines(e.path)
  if lines then
    return lines, kind == "agent" and "HEAD (no snapshot of the agent's starting point)" or "HEAD"
  end
  if kind == "agent" then
    return nil, "no snapshot of the agent's starting point and no committed version"
  end
  return nil, "no committed version (new file, no commits yet or not in git)"
end

-- Change markers ----------------------------------------------------------
-- Signs on the lines that differ from the agent's starting point (or HEAD),
-- and ]c / [c to jump between those changes without opening the diff.

local ns = vim.api.nvim_create_namespace("agent-edits")
local MAX_DIFF_BYTES = 2000000
local diff_fn = (vim.text and vim.text.diff) or vim.diff
M.hunks, M.stats = {}, {}

function M.update_markers(e)
  if not (e and vim.api.nvim_win_is_valid(M.code_win)) then return end
  local buf = vim.api.nvim_win_get_buf(M.code_win)
  if vim.api.nvim_buf_get_name(buf) ~= e.path then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.wo[M.code_win].signcolumn = "yes:1"
  M.hunks[e.path], M.stats[e.path] = {}, { add = 0, change = 0, delete = 0 }

  local base = base_for(e, "agent")
  if not base then return end
  local old = table.concat(base, "\n") .. "\n"
  -- A deleted file's buffer still has one empty line: compare with nothing.
  local new = e.deleted and "" or (table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n")
  if #old > MAX_DIFF_BYTES or #new > MAX_DIFF_BYTES then return end
  local ok, hunks = pcall(diff_fn, old, new, { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then return end

  local last = vim.api.nvim_buf_line_count(buf)
  local function sign(line, text, hl)
    line = math.max(1, math.min(line, last))
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, 0,
      { sign_text = text, sign_hl_group = hl, priority = 20 })
  end
  local st = M.stats[e.path]
  for _, h in ipairs(hunks) do
    local _, count_a, start_b, count_b = unpack(h)
    if count_b == 0 then
      -- Deleted lines: mark the line after which they were.
      st.delete = st.delete + count_a
      sign(start_b == 0 and 1 or start_b, start_b == 0 and "▔" or "▁", "Removed")
      table.insert(M.hunks[e.path], math.max(start_b, 1))
    else
      local kind, hl = "add", "Added"
      if count_a > 0 then kind, hl = "change", "Changed" end
      st[kind] = st[kind] + count_b
      for l = start_b, start_b + count_b - 1 do sign(l, "▎", hl) end
      table.insert(M.hunks[e.path], start_b)
    end
  end
end

-- Jump to the next (dir 1) or previous (dir -1) change in the code window.
local function jump_change(dir)
  if vim.wo.diff then
    vim.cmd("normal! " .. (dir > 0 and "]c" or "[c"))
    return
  end
  local starts = M.current and M.hunks[M.current] or {}
  if #starts == 0 then
    vim.notify("agent-edits: no changes in this file")
    return
  end
  vim.api.nvim_set_current_win(M.code_win)
  local cur = vim.api.nvim_win_get_cursor(M.code_win)[1]
  local target, index
  if dir > 0 then
    for i, l in ipairs(starts) do
      if l > cur then target, index = l, i break end
    end
    target, index = target or starts[1], index or 1
  else
    for i = #starts, 1, -1 do
      if starts[i] < cur then target, index = starts[i], i break end
    end
    target, index = target or starts[#starts], index or #starts
  end
  vim.api.nvim_win_set_cursor(M.code_win, { target, 0 })
  vim.cmd("normal! zz")
  vim.api.nvim_echo({ { string.format("change %d/%d", index, #starts) } }, false, {})
end

local function toggle_diff(kind)
  local e = selected()
  if not e then return end
  if M.diff_win then
    local same = M.diff_kind == kind
    diff_off()
    if same then return end
  end
  local out, label = base_for(e, kind)
  if not out then
    vim.notify("agent-edits: " .. label, vim.log.levels.WARN)
    return
  end
  M.diff_kind = kind
  local ft = vim.bo[vim.api.nvim_win_get_buf(M.code_win)].filetype
  vim.api.nvim_set_current_win(M.code_win)
  vim.cmd("diffthis")
  vim.cmd("leftabove vnew")
  M.diff_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = ft
  vim.wo[M.diff_win].winbar = " %#Comment#" .. label:gsub("%%", "%%%%")
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(M.code_win)
end

local function inner_option(name)
  local out = vim.fn.system({ "tmux", "show-options", "-qv", name })
  return vim.v.shell_error == 0 and vim.trim(out) or ""
end

local function hide_popup()
  if vim.env.AGENT_EDITS_POPUP == "1" and vim.env.TMUX then
    vim.fn.jobstart({ "tmux", "detach-client" })
  end
end

-- Sending to the agent -----------------------------------------------------

-- The agent pane the popup was opened from, in the outer tmux server.
local function agent_target()
  local socket, pane = inner_option("@ae_socket"), inner_option("@ae_pane")
  if socket == "" or pane == "" then return nil end
  return { tmux = { "tmux", "-S", socket }, pane = pane }
end

local function outer(target, args)
  return vim.list_extend(vim.deepcopy(target.tmux), args)
end

-- A path as the agent should see it: relative to the agent pane's directory
-- when inside it, absolute otherwise (agents don't expand ~ in @references).
local function agent_path(path, target, absolute_fallback)
  local base = root
  if target then
    local dir = vim.trim(vim.fn.system(outer(target,
      { "display-message", "-p", "-t", target.pane, "#{pane_current_path}" })))
    if vim.v.shell_error == 0 and dir ~= "" then base = dir end
  end
  if base ~= "/" and path ~= base and under(path, base) then return path:sub(#base + 2) end
  return absolute_fallback and path or vim.fn.fnamemodify(path, ":~")
end

-- Paste text into the agent's prompt with bracketed paste, so newlines don't
-- submit it. Falls back to the clipboard. Hides the popup when `hide`, else
-- shows `what` as confirmation.
local function send_text(text, hide, what, target)
  target = target or agent_target()
  if not target then
    vim.fn.setreg("+", text)
    vim.notify("agent-edits: no agent pane known, copied to the clipboard instead")
    return false
  end
  vim.fn.system(outer(target, { "load-buffer", "-b", "agent-edits", "-" }), text)
  vim.fn.system(outer(target, { "paste-buffer", "-p", "-d", "-b", "agent-edits", "-t", target.pane }))
  if vim.v.shell_error ~= 0 then
    vim.fn.setreg("+", text)
    vim.notify("agent-edits: agent pane is gone, copied to the clipboard instead", vim.log.levels.WARN)
    return false
  end
  if hide then
    hide_popup()
  else
    vim.notify("agent-edits: sent " .. what)
  end
  return true
end

-- The visual line range, leaving visual mode.
local function visual_range()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then first, last = last, first end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return first, last
end

-- Paste the visually selected lines into the agent's prompt, as a fenced
-- block headed by "path:first-last". With `ask_comment`, first ask for a
-- comment and send it below the block (an empty comment cancels).
local function send_selection(hide, ask_comment)
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  local first, last = visual_range()
  if vim.bo[buf].buftype ~= "" or path == "" then
    vim.notify("agent-edits: select code in the file window", vim.log.levels.WARN)
    return
  end
  local target = agent_target()
  local where = agent_path(path, target) .. ":" .. (first == last and first or (first .. "-" .. last))
  local block = {
    where,
    "```" .. vim.bo[buf].filetype,
    table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n"),
    "```",
  }
  if not ask_comment then
    send_text(table.concat(block, "\n") .. "\n", hide, where, target)
    return
  end
  vim.ui.input({ prompt = "Comment on " .. where .. ": " }, function(comment)
    if not comment or vim.trim(comment) == "" then
      vim.notify("agent-edits: nothing sent")
      return
    end
    block[#block + 1] = comment
    send_text(table.concat(block, "\n") .. "\n", hide, where .. " with a comment", target)
  end)
end

-- Paste "@path " references to the selected files (list rows) into the
-- agent's prompt. Claude Code and Codex read them as file references.
local function send_references(first, last)
  local target, refs = agent_target(), {}
  for row = first, last do
    local r = M.rows[row]
    if r and r.entry then refs[#refs + 1] = "@" .. agent_path(r.entry.path, target, true) end
  end
  if #refs == 0 then return end
  local text = table.concat(refs, " ") .. " "
  send_text(text, false, vim.trim(text), target)
end

-- Open in an editor ----------------------------------------------------------
-- o: new tmux window in the agent's tmux; O: split next to the agent pane.
-- Both run $EDITOR (default nvim) at the line you are looking at.

local function open_in_editor(split)
  local e = selected()
  if not e then return end
  if e.deleted then
    vim.notify("agent-edits: the file was deleted (D shows what it held)", vim.log.levels.WARN)
    return
  end
  -- The cursor line in the code window; from elsewhere, the first change.
  local line = 1
  if vim.api.nvim_get_current_win() == M.code_win then
    line = vim.api.nvim_win_get_cursor(M.code_win)[1]
  elseif M.hunks[e.path] and M.hunks[e.path][1] then
    line = M.hunks[e.path][1]
  end

  local target = agent_target()
  if not target then
    -- Started outside the popup: open an editable tab in this Neovim.
    vim.cmd("tabedit " .. vim.fn.fnameescape(e.path))
    vim.bo.modifiable, vim.bo.readonly = true, false
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    return
  end
  local editor = vim.split(vim.env.VISUAL or vim.env.EDITOR or "nvim", "%s+", { trimempty = true })
  local dir = vim.fn.fnamemodify(e.path, ":h")
  local args = { "split-window", "-h", "-t", target.pane, "-c", dir }
  if not split then
    -- new-window takes a window, not a pane: the one holding the agent.
    local window = vim.trim(vim.fn.system(outer(target,
      { "display-message", "-p", "-t", target.pane, "#{window_id}" })))
    args = { "new-window", "-a", "-t", window, "-c", dir }
  end
  vim.list_extend(args, editor)
  vim.list_extend(args, { "+" .. line, e.path })
  local out = vim.fn.system(outer(target, args))
  if vim.v.shell_error ~= 0 then
    vim.notify("agent-edits: could not open the editor: " .. vim.trim(out), vim.log.levels.ERROR)
    return
  end
  hide_popup()
end

local AGENT_ORDER = { Claude = 1, Codex = 2, Grok = 3 }

local function cycle_agent()
  local seen, agents = {}, {}
  for _, e in ipairs(M.all or {}) do
    if not seen[e.agent] then seen[e.agent] = true agents[#agents + 1] = e.agent end
  end
  table.sort(agents, function(x, y)
    local ox, oy = AGENT_ORDER[x] or 99, AGENT_ORDER[y] or 99
    if ox == oy then return x < y end
    return ox < oy
  end)
  local nxt = agents[1]
  for i, a in ipairs(agents) do
    if a == M.filters.agent then nxt = agents[i + 1] break end
  end
  M.filters.agent = nxt
  refresh(true)
end

local function toggle_session()
  if M.filters.session then
    M.filters.session = nil
  else
    local e = selected()
    if not e or e.session == "-" then
      vim.notify("agent-edits: no session recorded for this file")
      return
    end
    M.filters.session = e.session
  end
  refresh(true)
end

local function toggle_project()
  M.filters.project = not M.filters.project
  refresh(true)
end

local function clear_filters()
  M.filters = { agent = nil, session = nil, project = false }
  M.hide_committed, M.hide_reviewed = false, false
  refresh(true)
end

-- x marks the file(s) as reviewed, or removes the mark. The mark stores the
-- time of the latest edit, so a newer edit brings the file back.
local function toggle_reviewed(first, last)
  local paths, unmark = {}, nil
  for row = first, last do
    local r = M.rows[row]
    if r and r.entry and not vim.tbl_contains(paths, r.entry.path) then
      paths[#paths + 1] = r.entry.path
      -- The first file decides: reviewed ones get unmarked, others marked.
      if unmark == nil then unmark = r.entry.reviewed end
    end
  end
  if #paths == 0 then return end
  local ts = 0
  if not unmark then
    for _, e in ipairs(M.all or {}) do
      if vim.tbl_contains(paths, e.path) then ts = math.max(ts, e.ts) end
    end
  end
  vim.fn.system(vim.list_extend({ log_cmd, "--reviewed", tostring(ts) }, paths))
  local keep = selected()
  refresh(true)
  if unmark then
    if keep then select_path(keep.path, keep.session) end
  else
    -- Inbox style: the reviewed files sink, so stay on the same row, which
    -- now holds the next file to review.
    vim.api.nvim_win_set_cursor(M.list_win, { math.min(first, math.max(#M.rows, 1)), 0 })
    move(0)
  end
end

local function toggle_hide_reviewed()
  M.hide_reviewed = not M.hide_reviewed
  refresh(true)
end

local function toggle_hide_committed()
  M.hide_committed = not M.hide_committed
  -- Don't wait for the throttle: the result shows up once git is done.
  M.git.done_at = 0
  refresh(true)
end

-- :AgentEditsClear forgets this project's edits, :AgentEditsClear! all of
-- them. The hook script rewrites the log under the lock the hook uses.
local function clear_history(all)
  local args = all and { log_cmd, "--clear-all" } or { log_cmd, "--clear", root }
  local count = tonumber(vim.trim(vim.fn.system(vim.list_extend(vim.deepcopy(args), { "--dry-run" }))))
  if not count then
    vim.notify("agent-edits: could not read the history (" .. log_cmd .. ")", vim.log.levels.ERROR)
    return
  end
  if count == 0 then
    vim.notify("agent-edits: nothing to clear")
    return
  end
  local what = all and "ALL agent edits" or ("the edits of " .. vim.fn.fnamemodify(root, ":~"))
  local answer = vim.fn.confirm(string.format("Forget %s (%d log entries)?", what, count), "&Yes\n&No", 2)
  vim.cmd("redraw")
  if answer ~= 1 then return end
  vim.fn.system(args)
  refresh(true)
  vim.notify(string.format("agent-edits: cleared %d entries", count))
end

local HELP = {
  " agent-edits  ·  :AgentEditsHelp or g?",
  "",
  " File list",
  "   j / k, gg / G     select a file (the preview follows)",
  "   Enter / l         jump into the code",
  "   t                 group by agent session (toggle)",
  "   za                fold / unfold the session group",
  "   r                 reload the list now",
  "   a                 filter by agent: all, Claude, Codex, Grok",
  "   s                 only the session of the selected file (toggle)",
  "   p                 only this project (toggle)",
  "   x                 mark / unmark as reviewed (also on a visual",
  "                     selection); a new edit brings the file back",
  "   X                 hide reviewed files (toggle)",
  "   H                 hide files with nothing left to commit (toggle)",
  "   F                 clear the filters",
  "   @                 paste @path into the agent's prompt (also on a",
  "                     visual selection of rows)",
  "",
  " Anywhere",
  "   ]f / [f           next / previous edited file",
  "   Ctrl-h / Ctrl-l   move between list and code",
  "   D                 diff: what the agent changed (toggle)",
  "   gD                diff against HEAD (toggle)",
  "   ]c / [c           next / previous change (signs in the margin)",
  "   o                 open in $EDITOR, new tmux window, at this line",
  "   O                 same, in a split next to the agent",
  "   Ctrl-z            hide the popup (prefix + e brings it back)",
  "   :q  ZZ  ZQ        quit the viewer",
  "",
  " Visual selection in the code",
  "   y                 paste into the agent's prompt, keep the popup open",
  "   d / Enter         paste into the agent's prompt and hide the popup",
  "   c                 write a comment, then paste the code and the comment",
  "                     (popup stays open, so you can queue several)",
  "",
  " Commands",
  "   :AgentEditsClear  forget this project's edits (! for all of them)",
  "   :AgentEditsHelp   this help",
  "",
  " Claude$ (a $ after the agent): the edit was inferred from a shell",
  " command; files changed meanwhile by something else may show up too.",
  " ✗ (struck through): the file was deleted; D shows what it held.",
  "",
  " All other Vim motions work as usual; buffers are read-only.",
  " Close this help with q or Esc.",
}

local function show_help()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, HELP)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, line in ipairs(HELP) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#HELP, vim.o.lines - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    title = " help ", title_pos = "center",
  })
  vim.wo[win].cursorline = false
  for _, key in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", key, "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end
end

-- Deleted files in the list: struck through, in the colour of removed lines.
local function set_highlights()
  local removed = vim.api.nvim_get_hl(0, { name = "Removed", link = false })
  vim.api.nvim_set_hl(0, "AgentEditsDeleted", { fg = removed.fg, ctermfg = removed.ctermfg, strikethrough = true })
end

local function setup()
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })
  M.code_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vnew")
  M.list_win = vim.api.nvim_get_current_win()
  M.list_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_width(M.list_win, LIST_WIDTH)
  local bo, wo = vim.bo[M.list_buf], vim.wo[M.list_win]
  bo.buftype, bo.bufhidden, bo.swapfile, bo.filetype = "nofile", "hide", false, "agent-edits"
  wo.number, wo.relativenumber, wo.cursorline, wo.wrap, wo.winfixwidth = false, false, true, false, true

  local function map(lhs, rhs, opts)
    vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", { silent = true, nowait = true }, opts or {}))
  end
  local lb = { buffer = M.list_buf }
  map("j", function() move(1) end, lb)
  map("k", function() move(-1) end, lb)
  map("<Down>", function() move(1) end, lb)
  map("<Up>", function() move(-1) end, lb)
  map("gg", function() move(-math.huge) end, lb)
  map("G", function() move(math.huge) end, lb)
  map("<CR>", function() list_enter(false) end, lb)
  map("za", function() list_enter(true) end, lb)
  map("t", toggle_grouped, lb)
  map("l", function() vim.api.nvim_set_current_win(M.code_win) end, lb)
  map("r", function() refresh(true) end, lb)
  map("a", cycle_agent, lb)
  map("s", toggle_session, lb)
  map("p", toggle_project, lb)
  map("F", clear_filters, lb)
  map("H", toggle_hide_committed, lb)
  map("x", function()
    local row = vim.api.nvim_win_get_cursor(M.list_win)[1]
    toggle_reviewed(row, row)
  end, lb)
  vim.keymap.set("x", "x", function() toggle_reviewed(visual_range()) end,
    { buffer = M.list_buf, silent = true, nowait = true })
  map("X", toggle_hide_reviewed, lb)
  vim.api.nvim_create_user_command("AgentEditsClear", function(o) clear_history(o.bang) end,
    { bang = true, desc = "agent-edits: forget this project's edits (! for all)" })
  map("@", function()
    local row = vim.api.nvim_win_get_cursor(M.list_win)[1]
    send_references(row, row)
  end, lb)
  vim.keymap.set("x", "@", function() send_references(visual_range()) end,
    { buffer = M.list_buf, silent = true, nowait = true })

  -- Global keys (every window, including the code and diff windows).
  map("]f", function() move(1) end)
  map("[f", function() move(-1) end)
  map("D", function() toggle_diff("agent") end)
  map("gD", function() toggle_diff("head") end)
  map("o", function() open_in_editor(false) end)
  map("O", function() open_in_editor(true) end)
  map("]c", function() jump_change(1) end)
  map("[c", function() jump_change(-1) end)
  map("<C-h>", "<cmd>wincmd h<cr>")
  map("<C-l>", "<cmd>wincmd l<cr>")

  -- Ctrl-z hides the popup instead of suspending; the viewer keeps running in
  -- its tmux server and the key binding brings it back as it was.
  if vim.env.AGENT_EDITS_POPUP == "1" and vim.env.TMUX then
    vim.keymap.set({ "n", "x" }, "<C-z>", hide_popup, { silent = true })
  end

  -- Visual selection -> agent prompt. y sends and stays; d / <CR> send and hide.
  vim.keymap.set("x", "y", function() send_selection(false) end, { silent = true })
  vim.keymap.set("x", "d", function() send_selection(true) end, { silent = true })
  vim.keymap.set("x", "<CR>", function() send_selection(true) end, { silent = true })
  vim.keymap.set("x", "c", function() send_selection(false, true) end, { silent = true })

  vim.api.nvim_create_user_command("AgentEditsHelp", show_help, { desc = "agent-edits key bindings" })
  map("g?", show_help)

  -- Keep the markers in step when checktime reloads a file the agent changed.
  vim.api.nvim_create_autocmd("BufReadPost", {
    callback = function(args)
      local e = selected()
      if e and args.file ~= "" and vim.fn.fnamemodify(args.file, ":p") == e.path then
        vim.schedule(function()
          M.update_markers(e)
          set_code_winbar(e)
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = M.list_buf,
    nested = true, -- let :edit fire BufRead/FileType for the preview
    callback = function() preview(selected()) end,
  })

  -- Quit like plain Neovim: :q / ZZ / ZQ in the list or the code window
  -- closes the whole viewer (it makes no sense with half the layout gone);
  -- closing the diff window only ends the diff.
  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function(args)
      local win = tonumber(args.match)
      if win == M.diff_win then
        M.diff_win = nil
        vim.schedule(function()
          if vim.api.nvim_win_is_valid(M.code_win) then
            vim.api.nvim_win_call(M.code_win, function() vim.cmd("diffoff") end)
          end
        end)
      elseif win == M.list_win or win == M.code_win then
        vim.schedule(function() vim.cmd("qa!") end)
      end
    end,
  })

  refresh(true)
  vim.api.nvim_set_current_win(M.list_win)

  -- Follow the agent live: reload changed files and pick up newly edited ones.
  local timer = vim.uv.new_timer()
  timer:start(2000, 2000, vim.schedule_wrap(function()
    vim.cmd("silent! checktime")
    refresh(false)
  end))
end

vim.api.nvim_create_autocmd("VimEnter", { once = true, nested = true, callback = setup })
