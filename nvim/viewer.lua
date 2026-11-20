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
-- project worth naming. Returns the name and the directory it is relative
-- to ("" for ~/...).
local function display_name(path, project)
  if project == vim.env.HOME or project == "/" then project = "" end
  for _, base in ipairs({ project or "", root }) do
    if base ~= "" and base ~= "/" and path ~= base and under(path, base) then
      return path:sub(#base + 2), base
    end
  end
  return vim.fn.fnamemodify(path, ":~"), ""
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
-- sessions belongs to both); per_pane: the latest edit of each path per tmux
-- pane (the list of one tmux window).
local function empty_log() return { offset = 0, head = "", latest = {}, per_session = {}, per_pane = {} } end
local log_cache = empty_log()

local function read_log()
  local c = log_cache
  local st = vim.uv.fs_stat(log_file)
  if not st then
    log_cache = empty_log()
    return log_cache
  end
  if st.size == c.offset and c.mtime and st.mtime.sec == c.mtime.sec and st.mtime.nsec == c.mtime.nsec then
    return c
  end
  local fh = io.open(log_file, "r")
  if not fh then return c end
  local head = fh:read(64) or ""
  if st.size < c.offset or head:sub(1, #c.head) ~= c.head then
    c = empty_log()
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
      -- outside: the agent ran outside tmux (lines older than the pane
      -- column don't say).
      local e = {
        ts = ts, agent = f[2], path = path,
        project = f[4] or "", session = f[5] or "-", via = f[6] or "tool", pane = f[7] or "-",
        outside = f[7] == "-",
      }
      e.rel, e.base = display_name(path, f[4])
      if not c.latest[path] or c.latest[path].ts <= ts then c.latest[path] = e end
      local key = e.session .. "\0" .. path
      if not c.per_session[key] or c.per_session[key].ts <= ts then c.per_session[key] = e end
      key = e.pane .. "\0" .. path
      if e.pane ~= "-" and (not c.per_pane[key] or c.per_pane[key].ts <= ts) then c.per_pane[key] = e end
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

local home = vim.env.HOME

-- "This project": the file is under `dir` (default: the viewer's directory),
-- or the session that edited it was started in that directory, below it, or
-- above it (except $HOME and /, which are not projects).
local function in_project(e, dir)
  dir = dir or root
  if under(e.path, dir) then return true end
  local project = e.project or ""
  if project == "" then return false end
  if under(project, dir) then return true end
  return under(dir, project) and project ~= home and project ~= "/"
end

-- An edit by an agent running outside tmux, such as a Claude Code background
-- agent (they run without the tmux environment), belongs to every window
-- with a pane in its project.
local function near_tab(e)
  if not e.outside then return false end
  for _, dir in ipairs(M.tab.dirs or {}) do
    if in_project(e, dir) then return true end
  end
  return false
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
  local shown, sessions = latest, log.per_session
  -- One tmux window: only the edits made from its panes, and those of the
  -- agents outside tmux working in its projects.
  local panes = M.tab_only and M.tab and M.tab.panes
  if panes then
    shown, sessions = {}, {}
    for _, e in pairs(log.per_pane) do
      if panes[e.pane] and (not shown[e.path] or shown[e.path].ts < e.ts) then shown[e.path] = e end
    end
    for key, e in pairs(log.per_session) do
      local outside = near_tab(e)
      if outside and (not shown[e.path] or shown[e.path].ts < e.ts) then shown[e.path] = e end
      if panes[e.pane] or outside then sessions[key] = e end
    end
  end
  -- Reviewed until anyone edits the file again.
  for _, t in ipairs({ shown, sessions }) do
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
      -- The session created the file: the hook found nothing to save before it.
      if e.created == nil then
        local base = baseline_file(e)
        e.created = base ~= nil and vim.uv.fs_stat(base .. ".new") ~= nil
      end
      if not e.deleted or e.has_baseline then out[#out + 1] = e end
    end
    return sort_entries(out)
  end
  return listed(shown), listed(sessions)
end

-- Filters ------------------------------------------------------------------
-- a: one agent; s: the session of the selected file; p: this project only.

M.filters = { agent = nil, session = nil, project = false }

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
  if M.tab_only and M.tab then out[#out + 1] = M.tab.label end
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

-- Session groups and the folder tree -------------------------------------------
-- t toggles the session view: one header per agent session, its files below.
-- f toggles the folder tree (on by default). Folders and sessions fold.

-- folded: what was folded or unfolded by hand; any other folder or session
-- follows fold_default (zM / zR set it). Everything starts folded.
M.grouped, M.folders, M.folded, M.fold_default = false, true, {}, true
local list_ns = vim.api.nvim_create_namespace("agent-edits-list")

local function is_folded(key)
  if M.folded[key] == nil then return M.fold_default end
  return M.folded[key]
end

local function group_key(e)
  return e.session ~= "-" and e.session or (e.agent .. "|" .. e.project)
end

-- items: the subfolders ({ folder = f }) and files ({ entry = e }) in list
-- order; files: every file below the folder.
local function new_folder(key, label, path)
  return { key = key, label = label, path = path, items = {}, subs = {}, files = {} }
end

-- A folder with nothing but one subfolder becomes one row: "src/api/".
-- deleted: the folder is gone from the disk (its files are all deleted).
local function compact(f)
  while not f.project and #f.items == 1 and f.items[1].folder do
    local sub = f.items[1].folder
    f.label, f.key, f.path, f.items = f.label .. "/" .. sub.label, sub.key, sub.path, sub.items
  end
  f.deleted = f.path ~= "" and vim.uv.fs_stat(f.path) == nil
  for _, item in ipairs(f.items) do
    if item.folder then compact(item.folder) end
  end
end

-- The folder tree of `files` (already sorted). A folder comes where its first
-- file would, so the newest edits and the files still to review stay on top.
-- When the files come from several projects, each project is a folder.
local function folder_tree(files, scope)
  local top = new_folder(scope, "", "")
  local bases, projects = {}, 0
  for _, e in ipairs(files) do
    if not bases[e.base] then bases[e.base], projects = true, projects + 1 end
  end
  for _, e in ipairs(files) do
    local node = top
    local function enter(key, label, path)
      if not node.subs[key] then
        node.subs[key] = new_folder(scope .. "\0" .. key, label, path)
        node.items[#node.items + 1] = { folder = node.subs[key] }
      end
      node = node.subs[key]
      table.insert(node.files, e)
    end
    table.insert(top.files, e)
    if projects > 1 then
      enter("project\0" .. e.base, e.base ~= "" and vim.fn.fnamemodify(e.base, ":~") or "elsewhere", e.base)
      node.project = true
    end
    local parts = vim.split(e.rel, "/", { plain = true })
    local dir = e.base
    for i = 1, #parts - 1 do
      -- ~/... and /... names: the first part is "~" or "" (the root).
      dir = dir == "" and (parts[i] == "" and "/" or vim.fs.normalize(parts[i]))
        or (dir:sub(-1) == "/" and dir or dir .. "/") .. parts[i]
      enter(e.base .. "\0" .. dir, parts[i], dir)
    end
    node.items[#node.items + 1] = { entry = e }
  end
  for _, item in ipairs(top.items) do
    if item.folder then compact(item.folder) end
  end
  return top
end

local function tree_rows(rows, f, depth)
  for _, item in ipairs(f.items) do
    if item.entry then
      rows[#rows + 1] = { entry = item.entry, depth = depth, short = true }
    else
      rows[#rows + 1] = { folder = item.folder, depth = depth }
      if not is_folded(item.folder.key) then tree_rows(rows, item.folder, depth + 1) end
    end
  end
end

local function file_rows(rows, files, depth, scope)
  if M.folders then return tree_rows(rows, folder_tree(files, scope), depth) end
  for _, e in ipairs(files) do rows[#rows + 1] = { entry = e, depth = depth } end
end

local function build_rows(entries, per_session)
  local rows = {}
  if not M.grouped then
    file_rows(rows, entries, 0, "")
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
    rows[#rows + 1] = { group = g, depth = 0 }
    if not is_folded(g.key) then file_rows(rows, g.files, 1, g.key) end
  end
  return rows
end

-- One list line of exactly `width` cells. `left` and `right` are lists of
-- { text, hl } chunks; `right` is aligned to the right edge. When the line is
-- too long, the chunks marked `cut` are shortened from the start, in order.
-- Returns the text and the highlights as { start byte, end byte, hl, keep }.
local function compose(left, right, width)
  local function cells(chunks)
    local n = 0
    for _, c in ipairs(chunks) do n = n + vim.fn.strdisplaywidth(c[1]) end
    return n
  end
  local over = cells(left) + cells(right) - width
  for _, c in ipairs(left) do
    if over <= 0 then break end
    local w = vim.fn.strdisplaywidth(c[1])
    if c.cut and w > 0 then
      if w - over >= 1 then
        c[1] = "…" .. vim.fn.strcharpart(c[1], vim.fn.strchars(c[1]) - (w - over - 1))
        over = 0
      else
        c[1], over = "", over - w
      end
    end
  end
  local chunks = vim.list_extend({}, left)
  chunks[#chunks + 1] = { string.rep(" ", math.max(width - cells(left) - cells(right), 0)) }
  vim.list_extend(chunks, right)
  local text, spans = "", {}
  for _, c in ipairs(chunks) do
    if c[2] and c[1] ~= "" then spans[#spans + 1] = { #text, #text + #c[1], c[2], c.keep } end
    text = text .. c[1]
  end
  return text, spans
end

local function agent_hl(agent)
  return vim.fn.hlexists("AgentEdits" .. agent) == 1 and ("AgentEdits" .. agent) or "AgentEditsAgent"
end

-- The chunks of one row (see compose), and the highlight of the whole line.
local function row_chunks(row)
  local indent = { string.rep(" ", 1 + 2 * row.depth) }
  if row.group then
    local g = row.group
    local where = g.project ~= "" and vim.fn.fnamemodify(g.project, ":~") or "?"
    return { indent, { (is_folded(g.key) and "▸" or "▾") .. " ", "AgentEditsFoldMark" },
      { g.agent, agent_hl(g.agent) }, { " " .. where, cut = true } },
      { { string.format(" %d %3s", #g.files, ago(g.ts)), "AgentEditsMeta" } }, "Title"
  end
  if row.folder then
    local f, todo = row.folder, 0
    for _, e in ipairs(f.files) do
      if not e.reviewed then todo = todo + 1 end
    end
    local right = { { " " } }
    if f.deleted then right[#right + 1] = { "✗ ", "Removed", keep = true } end
    right[#right + 1] = { tostring(#f.files), "AgentEditsMeta" }
    return { indent, { (is_folded(f.key) and "▸" or "▾") .. " ", "AgentEditsFoldMark" },
      { f.label .. "/", f.project and "Title" or "AgentEditsFolder", cut = true } },
      right, f.deleted and "AgentEditsDeleted" or (todo == 0 and "Comment" or nil)
  end
  local e = row.entry
  local left = { indent }
  local dir, base = e.rel:match("^(.*/)([^/]*)$")
  if row.short then
    left[2] = { e.rel:match("[^/]*$"), cut = true }
  elseif dir then
    -- The folder dimmed, the file name in the normal colour.
    left[2], left[3] = { dir, "AgentEditsMeta", cut = true }, { base, cut = true }
  else
    left[2] = { e.rel, cut = true }
  end
  local right = { { " " } }
  if e.reviewed then right[#right + 1] = { "✓ ", "AgentEditsReviewedMark", keep = true } end
  if e.deleted then
    right[#right + 1] = { "✗ ", "Removed", keep = true }
  elseif e.created then
    right[#right + 1] = { "+ ", "Added", keep = true }
  end
  -- In the session view the header names the agent.
  if not M.grouped then right[#right + 1] = { e.agent, agent_hl(e.agent) } end
  right[#right + 1] = { e.via == "shell" and "$" or " ", "AgentEditsMeta" }
  right[#right + 1] = { string.format(" %3s", ago(e.ts)), "AgentEditsMeta" }
  local line_hl = e.deleted and "AgentEditsDeleted" or (e.reviewed and "Comment" or nil)
  return left, right, line_hl
end

local function render()
  local lines, spans, line_hls = {}, {}, {}
  local width = vim.api.nvim_win_get_width(M.list_win) - 1
  local only_tab = M.tab_only and M.tab and #filter_labels() == 1
  if #M.rows == 0 and only_tab then
    lines = { "", "  No files edited by the agents", "  in this tmux window yet.", "",
      "  w shows every window." }
  elseif #M.rows == 0 and #filter_labels() > 0 then
    lines = { "", "  No files match the filters:", "  " .. table.concat(filter_labels(), " "),
      "", "  F clears them, w shows every window." }
  elseif #M.rows == 0 then
    lines = { "", "  No files edited by agents yet." }
  else
    for i, row in ipairs(M.rows) do
      local left, right, line_hl = row_chunks(row)
      local row_spans
      lines[i], row_spans = compose(left, right, width)
      -- A dimmed or struck-through line keeps only its marks coloured.
      local plain = line_hl == "Comment" or line_hl == "AgentEditsDeleted"
      for _, s in ipairs(row_spans) do
        if s[4] or not plain then spans[#spans + 1] = { i, s[1], s[2], s[3] } end
      end
      if line_hl then line_hls[#line_hls + 1] = { i, line_hl } end
    end
  end
  vim.bo[M.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.list_buf, 0, -1, false, lines)
  vim.bo[M.list_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.list_buf, list_ns, 0, -1)
  for _, l in ipairs(line_hls) do
    vim.api.nvim_buf_set_extmark(M.list_buf, list_ns, l[1] - 1, 0,
      { line_hl_group = l[2], priority = l[2] == "AgentEditsDeleted" and 11 or 10 })
  end
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(M.list_buf, list_ns, s[1] - 1, s[2], { end_col = s[3], hl_group = s[4], priority = 20 })
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

-- One tmux window -----------------------------------------------------------------
-- The list shows only what the agents in the popup's tmux window (its "tab")
-- edited: the hook logs the pane each agent runs in. w shows every window.

M.tab_only = true

local function inner_option(name)
  local out = vim.fn.system({ "tmux", "show-options", "-qv", name })
  return vim.v.shell_error == 0 and vim.trim(out) or ""
end

-- The popup's tmux window: { panes = set of "<server pid>:<pane id>",
-- dirs = the panes' directories (not $HOME or /), label }, nil outside the
-- popup, or { gone = true } once the window is closed. Tests replace it.
function M.current_tab()
  if vim.env.AGENT_EDITS_POPUP ~= "1" or not vim.env.TMUX then return nil end
  local socket = inner_option("@ae_socket")
  local window = inner_option("@ae_window")
  if window == "" then window = inner_option("@ae_pane") end
  if socket == "" or window == "" then return nil end
  local out = vim.fn.systemlist({ "tmux", "-S", socket, "list-panes", "-t", window,
    "-F", "#{pid}\t#{pane_id}\t#{window_index}\t#{pane_current_path}\t#{window_name}" })
  if vim.v.shell_error ~= 0 then return { gone = true } end
  local tab = { panes = {}, dirs = {} }
  for _, l in ipairs(out) do
    local pid, pane, index, dir, name = l:match("^(%d+)\t(%%%d+)\t(%d+)\t([^\t]*)\t?(.*)$")
    if pid then
      tab.panes[pid .. ":" .. pane] = true
      if dir ~= "" and dir ~= home and dir ~= "/" and not vim.tbl_contains(tab.dirs, dir) then
        tab.dirs[#tab.dirs + 1] = dir
      end
      -- Agents set long window titles: keep the start.
      if vim.fn.strchars(name) > 16 then name = vim.fn.strcharpart(name, 0, 15) .. "…" end
      tab.label = tab.label or ("window " .. index .. (name ~= "" and (" " .. name) or ""))
    end
  end
  return tab.label and tab or nil
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
  M.tab = M.current_tab()
  if M.tab and M.tab.gone then
    -- The viewer's tmux window was closed: nothing left to show.
    vim.cmd("qa!")
    return
  end
  local all, per_session = read_entries()
  local git_sig = ""
  if M.hide_committed then
    update_committed(all, refresh)
    git_sig = M.git.sig
  end
  local entries = apply_filters(all)
  M.total, M.all = #all, all
  local tab = M.tab_only and M.tab
  local sig = { git_sig, M.reviewed_raw, tab and (tab.label .. "\0" .. table.concat(tab.dirs or {}, "\0")) or "" }
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

local function toggle_tab()
  if not M.tab then
    vim.notify("agent-edits: not opened from a tmux window")
    return
  end
  M.tab_only = not M.tab_only
  refresh(true)
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
  elseif delta == 0 then
    -- Stay, or go to the nearest file row below (else above) a header.
    for _, step in ipairs({ 1, -1 }) do
      local i = cur
      while rows[i] and not rows[i].entry do i = i + step end
      if rows[i] then target = i break end
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

local function toggle_folders()
  M.folders = not M.folders
  refresh(true)
end

local function header_key(row)
  local h = row and (row.group or row.folder)
  return h and h.key
end

-- The files a row stands for: its file, or every file in its folder or session.
local function row_files(row)
  if not row then return {} end
  if row.entry then return { row.entry } end
  return (row.group or row.folder).files
end

local function cursor_row() return vim.api.nvim_win_get_cursor(M.list_win)[1] end

-- The header that holds row `i`: the nearest one above, one level up.
local function parent_row(i)
  local depth = M.rows[i] and M.rows[i].depth or 0
  for j = i - 1, 1, -1 do
    if M.rows[j].depth < depth and header_key(M.rows[j]) then return j end
  end
end

-- Row `i` when it is a header, else the header that holds it.
local function own_header(i)
  if header_key(M.rows[i]) then return i end
  return parent_row(i)
end

-- Folds (true), unfolds (false) or toggles (nil) the header on row `i`, and
-- leaves the cursor on it.
local function set_fold(i, folded)
  local key = i and header_key(M.rows[i])
  if not key then return end
  if folded == nil then folded = not is_folded(key) end
  if is_folded(key) == folded then
    vim.api.nvim_win_set_cursor(M.list_win, { i, 0 })
    return
  end
  M.folded[key] = folded
  refresh(true)
  for j, r in ipairs(M.rows) do
    if header_key(r) == key then
      vim.api.nvim_win_set_cursor(M.list_win, { j, 0 })
      break
    end
  end
end

-- zM folds every folder and session, zR unfolds them all.
local function fold_all(folded)
  M.folded, M.fold_default = {}, folded
  refresh(true)
  if folded and #M.rows > 0 then vim.api.nvim_win_set_cursor(M.list_win, { 1, 0 }) end
end

-- Enter: folds / unfolds a header, jumps into the code from a file.
local function list_enter()
  local i = cursor_row()
  if header_key(M.rows[i]) then
    set_fold(i)
  elseif M.rows[i] then
    vim.api.nvim_set_current_win(M.code_win)
  end
end

-- l: opens a folded header, goes into an open one, jumps into the code from a file.
local function list_right()
  local i = cursor_row()
  local key = header_key(M.rows[i])
  if not key then
    if M.rows[i] then vim.api.nvim_set_current_win(M.code_win) end
  elseif is_folded(key) then
    set_fold(i, false)
  elseif M.rows[i + 1] and M.rows[i + 1].depth > M.rows[i].depth then
    vim.api.nvim_win_set_cursor(M.list_win, { i + 1, 0 })
  end
end

-- h: folds an open header, else folds the one that holds the row.
local function list_left()
  local i = cursor_row()
  local key = header_key(M.rows[i])
  if key and not is_folded(key) then
    set_fold(i, true)
  else
    set_fold(parent_row(i), true)
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
-- What the agent changed since its starting point (or HEAD), shown in the
-- code like a GitHub diff: added and changed lines on a green background,
-- the lines they replaced or that were deleted in red above them (virtual
-- lines, with their old numbers), the changed words brighter, and the
-- unchanged stretches folded but for CONTEXT lines around each change.
-- I turns that off and leaves signs in the margin. ]c / [c jump between the
-- changes either way.

local ns = vim.api.nvim_create_namespace("agent-edits")
local MAX_DIFF_BYTES = 2000000
local CONTEXT, MIN_FOLD = 3, 4
local diff_fn = (vim.text and vim.text.diff) or vim.diff
M.hunks, M.stats, M.inline = {}, {}, true

-- Words, runs of blanks and single other characters, as { first, last, text }.
local function tokens(s)
  local out, i = {}, 1
  while i <= #s do
    local _, j = s:find("^[%w_\128-\255]+", i)
    if not j then _, j = s:find("^%s+", i) end
    j = j or i
    out[#out + 1] = { i, j, s:sub(i, j) }
    i = j + 1
  end
  return out
end

-- The byte ranges ({ first, last }) where `old` and `new` differ, word by
-- word. Nil when the lines have no word in common: all of it changed, and
-- brighter words would only add noise.
local function word_diff(old, new)
  if old == "" or new == "" or #old > 1000 or #new > 1000 then return nil end
  local a, b = tokens(old), tokens(new)
  local function text(t)
    local out = {}
    for i, tk in ipairs(t) do out[i] = tk[3] end
    return table.concat(out, "\n") .. "\n"
  end
  local ok, hunks = pcall(diff_fn, text(a), text(b), { result_type = "indices" })
  if not ok or type(hunks) ~= "table" or #hunks == 0 then return nil end
  local ranges_a, ranges_b, changed = {}, {}, {}
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = unpack(h)
    if count_a > 0 then
      ranges_a[#ranges_a + 1] = { a[start_a][1], a[start_a + count_a - 1][2] }
      for i = start_a, start_a + count_a - 1 do changed[i] = true end
    end
    if count_b > 0 then ranges_b[#ranges_b + 1] = { b[start_b][1], b[start_b + count_b - 1][2] } end
  end
  for i, tk in ipairs(a) do
    if not changed[i] and tk[3]:find("%S") then return ranges_a, ranges_b end
  end
  return nil
end

-- Virtual text chunks of an old line: tabs expanded to `ts`, the byte
-- `ranges` in `word_hl` and the rest in `hl`, padded to `width` cells so the
-- background covers the window.
local function old_chunks(line, ranges, hl, word_hl, ts, width)
  local chunks, col = {}, 0
  local function add(s, group)
    local parts = {}
    for piece, tab in s:gmatch("([^\t]*)(\t?)") do
      parts[#parts + 1] = piece
      col = col + vim.api.nvim_strwidth(piece)
      if tab ~= "" then
        parts[#parts + 1] = string.rep(" ", ts - col % ts)
        col = col + ts - col % ts
      end
    end
    local text = table.concat(parts)
    if text ~= "" then chunks[#chunks + 1] = { text, group } end
  end
  local pos = 1
  for _, r in ipairs(ranges or {}) do
    add(line:sub(pos, r[1] - 1), hl)
    add(line:sub(r[1], r[2]), word_hl)
    pos = r[2] + 1
  end
  add(line:sub(pos), hl)
  chunks[#chunks + 1] = { string.rep(" ", math.max(width - col, 0)), hl }
  return chunks
end

-- Draws the changes of `e` in `buf`: the inline diff, or signs. Fills
-- M.hunks and M.stats, and returns the unchanged stretches to fold.
local function draw_changes(e, buf, inline)
  local base = base_for(e, "agent")
  if not base then return {} end
  -- A deleted file's buffer still has one empty line: compare with nothing.
  local lines = e.deleted and {} or vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local old = #base == 0 and "" or (table.concat(base, "\n") .. "\n")
  local new = #lines == 0 and "" or (table.concat(lines, "\n") .. "\n")
  if #old > MAX_DIFF_BYTES or #new > MAX_DIFF_BYTES then return {} end
  local ok, hunks = pcall(diff_fn, old, new, { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then return {} end

  local last = vim.api.nvim_buf_line_count(buf)
  local function mark(line, col, opts)
    line = math.max(1, math.min(line, last))
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, line - 1, col, opts)
  end
  -- The margin of a virtual line: "-" in the sign column, the old line
  -- number in the number column.
  local wo = vim.wo[M.code_win]
  local numw = (wo.number or wo.relativenumber) and math.max(wo.numberwidth, #tostring(last) + 1) or 0
  local margin = string.rep(" ", tonumber(wo.foldcolumn) or 0) .. "- "
  local ts, width = vim.bo[buf].tabstop, vim.o.columns
  local st, starts, spans = M.stats[e.path], M.hunks[e.path], {}
  -- Virtual lines above the first line: the window has to be told to show them.
  local top = 0
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = unpack(h)
    if count_b == 0 then
      -- Deleted lines: they were after line start_b.
      st.delete = st.delete + count_a
      starts[#starts + 1] = math.max(start_b, 1)
      spans[#spans + 1] = { math.max(start_b, 1), math.max(start_b, 1) }
    else
      local kind = count_a > 0 and "change" or "add"
      st[kind] = st[kind] + count_b
      starts[#starts + 1] = start_b
      spans[#spans + 1] = { start_b, start_b + count_b - 1 }
    end
    if not inline then
      if count_b == 0 then
        mark(start_b == 0 and 1 or start_b, 0,
          { sign_text = start_b == 0 and "▔" or "▁", sign_hl_group = "Removed", priority = 20 })
      else
        local hl = count_a > 0 and "Changed" or "Added"
        for l = start_b, start_b + count_b - 1 do mark(l, 0, { sign_text = "▎", sign_hl_group = hl, priority = 20 }) end
      end
    else
      -- Old and new lines side by side in a change get their words compared.
      local words_a, words_b = {}, {}
      for k = 0, math.min(count_a, count_b) - 1 do
        words_a[k], words_b[k] = word_diff(base[start_a + k], lines[start_b + k])
      end
      if count_a > 0 then
        local virt = {}
        for k = 0, count_a - 1 do
          local number = numw > 0 and string.format("%" .. (numw - 1) .. "d ", start_a + k) or ""
          local chunks = { { margin .. number, "AgentEditsDelNr" } }
          virt[k + 1] = vim.list_extend(chunks,
            old_chunks(base[start_a + k], words_a[k], "AgentEditsDelLine", "AgentEditsDelText", ts, width))
        end
        -- Above the lines that replaced them, else below the line they followed.
        local above = count_b > 0 or start_b == 0
        mark(math.max(start_b, 1), 0, { virt_lines = virt, virt_lines_above = above, virt_lines_leftcol = true })
        if above and start_b <= 1 then top = count_a end
      end
      for k = 0, count_b - 1 do
        local l = start_b + k
        -- The background as a range to the next line: line_hl_group would
        -- cover the brighter words. The sign on its own, or it would show
        -- on the next line too.
        mark(l, 0, { end_row = l, end_col = 0, strict = false, hl_eol = true, hl_group = "AgentEditsAddLine", priority = 20 })
        mark(l, 0, { number_hl_group = "AgentEditsAddNr", sign_text = "+", sign_hl_group = "AgentEditsAddNr", priority = 20 })
        for _, r in ipairs(words_b[k] or {}) do
          mark(l, r[1] - 1, { end_col = r[2], hl_group = "AgentEditsAddText", priority = 21 })
        end
      end
    end
  end

  local folds, shown = {}, 0
  for _, span in ipairs(spans) do
    local from, to = shown == 0 and 1 or shown + CONTEXT + 1, span[1] - CONTEXT - 1
    if to - from + 1 >= MIN_FOLD then folds[#folds + 1] = { from, to } end
    shown = math.max(shown, span[2])
  end
  if shown > 0 and last - shown - CONTEXT >= MIN_FOLD then folds[#folds + 1] = { shown + CONTEXT + 1, last } end
  return folds, top
end

function M.fold_text()
  return string.format("  ⋯ %d unchanged lines", vim.v.foldend - vim.v.foldstart + 1)
end

-- Folds the unchanged stretches in `win` (nil: removes the folds). With
-- `first`, the cursor goes to that line (the first change) unless it was
-- moved from the top already; otherwise its line stays unfolded.
local function set_folds(win, folds, first)
  vim.api.nvim_win_call(win, function()
    local wo = vim.wo[win]
    if folds then
      local fill = vim.o.fillchars:gsub("fold:[^,]*,?", ""):gsub(",$", "")
      wo.fillchars = (fill ~= "" and fill .. "," or "") .. "fold: "
      wo.foldtext = "v:lua.require'agent-edits'.fold_text()"
      wo.foldmethod = "manual"
    end
    vim.cmd("silent! normal! zE")
    M.folds_set = folds ~= nil
    if not folds then
      wo.foldtext = vim.go.foldtext
      return
    end
    for _, f in ipairs(folds) do vim.cmd(string.format("silent! %d,%dfold", f[1], f[2])) end
    wo.foldenable, wo.foldlevel = true, 0
    if first and vim.api.nvim_win_get_cursor(win)[1] == 1 then
      pcall(vim.api.nvim_win_set_cursor, win, { first, 0 })
    else
      vim.cmd("silent! normal! zv")
    end
  end)
end

function M.update_markers(e)
  if not (e and vim.api.nvim_win_is_valid(M.code_win)) then return end
  local buf = vim.api.nvim_win_get_buf(M.code_win)
  if vim.api.nvim_buf_get_name(buf) ~= e.path then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.wo[M.code_win].signcolumn = "yes:1"
  M.hunks[e.path], M.stats[e.path] = {}, { add = 0, change = 0, delete = 0 }
  -- The side-by-side diff (D) has colours and folds of its own.
  local inline = M.inline and not M.diff_win
  local folds, top = draw_changes(e, buf, inline)
  -- A file shown for the first time opens at its first change.
  local key = e.path .. "\0" .. e.session
  local first = M.marked ~= key and M.hunks[e.path][1] or nil
  M.marked = key
  if not M.diff_win and (inline or M.folds_set) then
    set_folds(M.code_win, inline and folds or nil, first)
  end
  if inline and (top or 0) > 0 then
    vim.api.nvim_win_call(M.code_win, function()
      local view = vim.fn.winsaveview()
      if view.topline == 1 then
        view.topfill = top
        vim.fn.winrestview(view)
      end
    end)
  end
end

-- I: the inline diff, or only signs in the margin.
local function toggle_inline()
  M.inline = not M.inline
  M.update_markers(selected())
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
    if same then
      M.update_markers(e)
      return
    end
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
  M.update_markers(e)
end

-- Revert ------------------------------------------------------------------------
-- R puts back what the file held before the agent's session: the change under
-- the cursor (code or diff window), or whole files (list, also on a visual
-- selection of rows). Every revert first saves what it replaces in
-- reverted/<id>/, and :AgentEditsUndoRevert puts the last one back.

local reverted_dir = state_dir .. "/reverted"
local REVERT_KEEP = 7 * 86400

-- Asks before a revert changes files. Tests replace it.
function M.confirm(question)
  local answer = vim.fn.confirm(question, "&Yes\n&No", 2)
  vim.cmd("redraw")
  return answer == 1
end

local function warn(msg) vim.notify("agent-edits: " .. msg, vim.log.levels.WARN) end

local function read_raw(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end

-- Writes through a temporary file and a rename, so the agent never reads a
-- half-written file. Keeps the file's permissions.
local function write_raw(path, text)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local st = vim.uv.fs_stat(path)
  local tmp = dir .. "/.agent-edits-revert-" .. vim.fn.fnamemodify(path, ":t")
  local fh, err = io.open(tmp, "wb")
  if not fh then return nil, err end
  fh:write(text)
  fh:close()
  -- The type bits sit above 4096; what is left is the permissions.
  if st then vim.uv.fs_chmod(tmp, st.mode % 4096) end
  local ok, rename_err = vim.uv.fs_rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, rename_err
  end
  return true
end

-- Size and mtime: how a file looked right after a revert ("absent" if gone).
local function stamp(path)
  local st = vim.uv.fs_stat(path)
  return st and string.format("%d.%d.%d", st.mtime.sec, st.mtime.nsec, st.size) or "absent"
end

-- What a revert of `e` puts back: { kind = "file", text = ... }, or
-- { kind = "new" } for a file the session created. Nil and a reason when the
-- session's starting point is unknown.
local function revert_base(e)
  local base = baseline_file(e)
  if base then
    if vim.uv.fs_stat(base) then return { kind = "file", text = read_raw(base) or "" } end
    if vim.uv.fs_stat(base .. ".new") then return { kind = "new" } end
    if vim.uv.fs_stat(base .. ".skip") then
      return nil, e.rel .. " was over 2 MB, so no snapshot was kept"
    end
  end
  return nil, "no snapshot of " .. e.rel .. " before the agent's session (shell edit or older entry)"
end

-- Saves what `paths` hold now in a new reverted/<id>/, and returns the
-- function that completes the record once the files are written:
-- index.tsv holds "<path>\t<saved copy or absent>\t<stamp after the revert>".
local function start_undo(paths)
  if vim.uv.fs_stat(reverted_dir) then
    local cutoff = os.time() - REVERT_KEEP
    for name in vim.fs.dir(reverted_dir) do
      if (tonumber(name:sub(1, 10)) or 0) < cutoff then vim.fn.delete(reverted_dir .. "/" .. name, "rf") end
    end
  end
  local sec, usec = vim.uv.gettimeofday()
  local dir = string.format("%s/%d%06d", reverted_dir, sec, usec)
  vim.fn.mkdir(dir, "p")
  local saved = {}
  for i, path in ipairs(paths) do
    local text = read_raw(path)
    if text then
      local fh = assert(io.open(dir .. "/" .. i, "wb"))
      fh:write(text)
      fh:close()
    end
    saved[i] = text and tostring(i) or "absent"
  end
  return function()
    local index = {}
    for i, path in ipairs(paths) do
      index[i] = table.concat({ path, saved[i], stamp(path) }, "\t")
    end
    vim.fn.writefile(index, dir .. "/index.tsv")
  end
end

-- After files changed under the viewer: reload the previewed one and the list.
local function after_change(paths)
  diff_off()
  local e = selected()
  if e and vim.tbl_contains(paths, e.path) and vim.api.nvim_win_is_valid(M.code_win) then
    vim.api.nvim_win_call(M.code_win, function()
      vim.cmd("silent! edit!")
      vim.bo.modifiable = false
    end)
  end
  refresh(true)
  e = selected()
  if e then
    M.update_markers(e)
    set_code_winbar(e)
  end
end

-- Lines of a text, and whether it ends with a newline.
local function split_lines(text)
  if text == "" then return {}, false end
  local eol = text:sub(-1) == "\n"
  if eol then text = text:sub(1, -2) end
  return vim.split(text, "\n", { plain = true }), eol
end

local function join_lines(lines, eol)
  if #lines == 0 then return "" end
  return table.concat(lines, "\n") .. (eol and "\n" or "")
end

-- R in the code window (or the diff window): the change under the cursor.
local function revert_hunk()
  local e = selected()
  if not e then return end
  local win = vim.api.nvim_get_current_win()
  local in_diff = win == M.diff_win
  local base, why = revert_base(e)
  if not base then return warn(why) end
  local current = read_raw(e.path)
  if not current then return warn("the file was deleted: R in the list restores it") end
  local old = base.text or ""
  if old:find("\0", 1, true) or current:find("\0", 1, true) then
    return warn("binary file: R in the list reverts the whole file")
  end
  local a = split_lines(old)
  local b, eol = split_lines(current)
  -- The cursor must point at the lines on disk: the buffer has to be up to date.
  local shown = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(M.code_win), 0, -1, false)
  if not vim.deep_equal(shown, #b == 0 and { "" } or b) then
    vim.cmd("silent! checktime")
    return warn("the file changed, try again")
  end
  local ok, hunks = pcall(diff_fn, join_lines(a, true), join_lines(b, true), { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then return warn("could not compare the file") end

  -- In the code window the cursor is on the new lines; in the diff window on
  -- the old ones. A count of 0 means "after line start": its marker is there.
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local pick
  for _, h in ipairs(hunks) do
    local start, count = h[3], h[4]
    if in_diff then start, count = h[1], h[2] end
    if count > 0 and line >= start and line < start + count then
      pick = h
      break
    end
    if count == 0 and math.max(start, 1) == line then pick = pick or h end
  end
  if not pick then return warn("no change under the cursor") end
  if not M.confirm(string.format("Revert this change in %s?", e.rel)) then return end

  local start_a, count_a, start_b, count_b = unpack(pick)
  if count_b == 0 then start_b = start_b + 1 end
  local out = {}
  for i = 1, start_b - 1 do out[#out + 1] = b[i] end
  for i = start_a, start_a + count_a - 1 do out[#out + 1] = a[i] end
  for i = start_b + count_b, #b do out[#out + 1] = b[i] end
  if #b == 0 then eol = old:sub(-1) == "\n" end

  local finish = start_undo({ e.path })
  local written, err = write_raw(e.path, join_lines(out, eol))
  if not written then return warn("could not write " .. e.rel .. ": " .. tostring(err)) end
  finish()
  after_change({ e.path })
  vim.notify("agent-edits: reverted the change (:AgentEditsUndoRevert puts it back)")
end

-- R in the list: whole files back to before their session. A file the session
-- created is deleted, a deleted one is written back. The files count as
-- reviewed: the reviewer just decided on them.
local function revert_files(first, last)
  local todo, skipped, seen = {}, {}, {}
  for row = first, last do
    for _, e in ipairs(row_files(M.rows[row])) do
      if not seen[e.path] then
        seen[e.path] = true
        local base, why = revert_base(e)
        if base then
          todo[#todo + 1] = { e = e, base = base }
        else
          skipped[#skipped + 1] = why
        end
      end
    end
  end
  if #todo == 0 then
    if #skipped > 0 then warn(table.concat(skipped, "; ")) end
    return
  end
  local question
  if #todo == 1 then
    local t = todo[1]
    question = string.format("Revert %s to before %s's session?%s", t.e.rel, t.e.agent,
      t.base.kind == "new" and " The session created it: it will be deleted." or "")
  else
    question = string.format("Revert %d files to before their agent's session?", #todo)
  end
  if #skipped > 0 then question = question .. "\n(skipped: " .. table.concat(skipped, "; ") .. ")" end
  if not M.confirm(question) then return end

  local paths = {}
  for _, t in ipairs(todo) do paths[#paths + 1] = t.e.path end
  local finish = start_undo(paths)
  local failed = {}
  for _, t in ipairs(todo) do
    if t.base.kind == "new" then
      if vim.uv.fs_stat(t.e.path) and not os.remove(t.e.path) then failed[#failed + 1] = t.e.rel end
    elseif not write_raw(t.e.path, t.base.text) then
      failed[#failed + 1] = t.e.rel
    end
  end
  finish()
  local ts = 0
  for _, e in ipairs(M.all or {}) do
    if seen[e.path] then ts = math.max(ts, e.ts) end
  end
  vim.fn.system(vim.list_extend({ log_cmd, "--reviewed", tostring(ts) }, paths))
  after_change(paths)
  if #failed > 0 then
    warn("could not revert " .. table.concat(failed, ", "))
  else
    vim.notify(string.format("agent-edits: reverted %d file%s (:AgentEditsUndoRevert puts %s back)",
      #todo, #todo == 1 and "" or "s", #todo == 1 and "it" or "them"))
  end
end

local function revert_here()
  if vim.api.nvim_get_current_win() == M.list_win then
    local row = vim.api.nvim_win_get_cursor(M.list_win)[1]
    revert_files(row, row)
  else
    revert_hunk()
  end
end

-- Puts back what the last revert replaced. Refuses when a file changed since
-- the revert (the agent may have edited it again), unless `force`.
local function undo_revert(force)
  local ids = {}
  if vim.uv.fs_stat(reverted_dir) then
    for name, kind in vim.fs.dir(reverted_dir) do
      if kind == "directory" and vim.uv.fs_stat(reverted_dir .. "/" .. name .. "/index.tsv") then
        ids[#ids + 1] = name
      end
    end
  end
  table.sort(ids)
  if #ids == 0 then
    vim.notify("agent-edits: nothing to undo")
    return
  end
  local dir = reverted_dir .. "/" .. ids[#ids]
  local rows, changed, paths = {}, {}, {}
  for _, l in ipairs(vim.fn.readfile(dir .. "/index.tsv")) do
    local path, saved, after = unpack(vim.split(l, "\t", { plain = true }))
    rows[#rows + 1] = { path = path, saved = saved }
    paths[#paths + 1] = path
    if stamp(path) ~= after then changed[#changed + 1] = vim.fn.fnamemodify(path, ":~:.") end
  end
  if #changed > 0 and not force then
    return warn("changed since the revert: " .. table.concat(changed, ", ")
      .. ". :AgentEditsUndoRevert! puts the old content back anyway")
  end
  for _, r in ipairs(rows) do
    if r.saved == "absent" then
      os.remove(r.path)
    else
      write_raw(r.path, read_raw(dir .. "/" .. r.saved) or "")
    end
  end
  vim.fn.delete(dir, "rf")
  after_change(paths)
  vim.notify(string.format("agent-edits: undid the revert of %d file%s", #rows, #rows == 1 and "" or "s"))
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
-- agent's prompt. Claude Code and Codex read them as file references. A
-- folder row sends the folder, a session row its files.
local function send_references(first, last)
  local target, refs = agent_target(), {}
  for row = first, last do
    local r = M.rows[row]
    if r and r.folder and r.folder.path ~= "" then
      refs[#refs + 1] = "@" .. agent_path(r.folder.path, target, true) .. "/"
    else
      for _, e in ipairs(row_files(r)) do refs[#refs + 1] = "@" .. agent_path(e.path, target, true) end
    end
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
  local header = first == last and header_key(M.rows[first])
  for row = first, last do
    for _, e in ipairs(row_files(M.rows[row])) do
      if not vim.tbl_contains(paths, e.path) then
        paths[#paths + 1] = e.path
        -- The first file decides: reviewed ones get unmarked, others marked.
        -- In a folder the files to review come first.
        if unmark == nil then unmark = e.reviewed end
      end
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
  if header then
    -- Stay on the folder or session, wherever it moved.
    for i, r in ipairs(M.rows) do
      if header_key(r) == header then vim.api.nvim_win_set_cursor(M.list_win, { i, 0 }) break end
    end
  elseif unmark then
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

-- :AgentEditsPatch: everything the selected file's session changed, as a
-- unified diff (agent-edits-log --patch), in a new tab. With a file name, it
-- is written there instead; with !, saved under the state folder and pasted
-- into the agent's prompt as an @reference. Only this project's files while
-- p is on.
local function session_patch(opts)
  local e = selected() or M.current
  if not e or e.session == "-" then
    warn("select a file edited in an agent session")
    return
  end
  local args = { log_cmd, "--patch", e.session }
  if M.filters.project then vim.list_extend(args, { "--root", root }) end
  local out = vim.system(args):wait()
  local text = out.stdout or ""
  if out.code ~= 0 or text == "" then
    warn(out.code ~= 0 and "could not build the patch" or "the session left nothing changed")
    return
  end
  local short = e.session:sub(1, 8)
  if opts.bang or opts.args ~= "" then
    local file = opts.args ~= "" and vim.fn.fnamemodify(vim.fn.expand(opts.args), ":p")
      or (state_dir .. "/patches/" .. e.session .. ".patch")
    if not write_raw(file, text) then
      warn("could not write " .. file)
      return
    end
    if opts.bang then
      local target = agent_target()
      send_text("@" .. agent_path(file, target, true) .. " ", false, "the patch of session " .. short, target)
    else
      vim.notify("agent-edits: wrote " .. vim.fn.fnamemodify(file, ":~"))
    end
    return
  end
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, (split_lines(text)))
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, "agent-edits://patch/" .. e.session)
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, nowait = true, silent = true })
end

local HELP = {
  " agent-edits  ·  :AgentEditsHelp or g?",
  "",
  " File list",
  "   j / k, gg / G     move (the preview follows the file)",
  "   Enter             jump into the code; on a folder, fold / unfold it",
  "   l / h             open / close a folder (l on a file: into the code)",
  "   za  zo  zc        toggle / open / close the folder under the cursor",
  "   zR / zM           open / close every folder (all start closed)",
  "   f                 folder tree (toggle, on by default)",
  "   t                 group by agent session (toggle)",
  "   w                 only this tmux window's agents / every window",
  "   r                 reload the list now",
  "   a                 filter by agent: all, Claude, Codex, Grok",
  "   s                 only the session of the selected file (toggle)",
  "   p                 only this project (toggle)",
  "   x                 mark / unmark as reviewed (also on a folder or a",
  "                     visual selection); a new edit brings the file back",
  "   X                 hide reviewed files (toggle)",
  "   H                 hide files with nothing left to commit (toggle)",
  "   F                 clear the filters",
  "   @                 paste @path into the agent's prompt (also on a",
  "                     visual selection of rows)",
  "",
  " Anywhere",
  "   ]f / [f           next / previous edited file",
  "   Ctrl-h / Ctrl-l   move between list and code",
  "   I                 what the agent changed, inline in the code like a",
  "                     GitHub diff (toggle, on by default): added lines in",
  "                     green, removed ones in red, unchanged ones folded",
  "                     (zo / zR open them); off, only signs in the margin",
  "   D                 diff: what the agent changed, side by side (toggle)",
  "   gD                diff against HEAD (toggle)",
  "   ]c / [c           next / previous change",
  "   o                 open in $EDITOR, new tmux window, at this line",
  "   O                 same, in a split next to the agent",
  "   R                 revert to before the agent's session: in the code,",
  "                     the change under the cursor; in the list, the whole",
  "                     file (also on a visual selection of rows)",
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
  "   :AgentEditsUndoRevert  undo the last R (! even if the file changed since)",
  "   :AgentEditsPatch [file]  the session of the selected file as one",
  "                     patch, in a new tab (q closes it) or written to file;",
  "                     ! pastes @patch into the agent's prompt. Only this",
  "                     project's files while p is on",
  "   :AgentEditsHelp   this help",
  "",
  " Claude$ (a $ after the agent): the edit was inferred from a shell",
  " command; files changed meanwhile by something else may show up too.",
  " + (green): the agent's session created the file.",
  " ✗ (struck through): the file was deleted; D shows what it held.",
  " On a folder: the folder was deleted, with every file in it.",
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

-- `fg` over `bg` (0xRRGGBB) at opacity `alpha`.
local function blend(fg, bg, alpha)
  local out = 0
  for _, unit in ipairs({ 65536, 256, 1 }) do
    local f, b = math.floor(fg / unit) % 256, math.floor(bg / unit) % 256
    out = out + math.floor(b + (f - b) * alpha + 0.5) * unit
  end
  return out
end

-- The list's colours, linked to standard groups so they follow the
-- colorscheme. Deleted files: struck through, in the colour of removed lines.
local function set_highlights()
  local removed = vim.api.nvim_get_hl(0, { name = "Removed", link = false })
  vim.api.nvim_set_hl(0, "AgentEditsDeleted", { fg = removed.fg, ctermfg = removed.ctermfg, strikethrough = true })
  local links = {
    AgentEditsClaude = "DiagnosticWarn", AgentEditsCodex = "DiagnosticInfo", AgentEditsGrok = "DiagnosticHint",
    AgentEditsAgent = "Special", AgentEditsFolder = "Directory", AgentEditsFoldMark = "NonText",
    AgentEditsMeta = "Comment", AgentEditsReviewedMark = "DiagnosticOk",
  }
  for name, to in pairs(links) do vim.api.nvim_set_hl(0, name, { link = to, default = true }) end

  -- The inline diff: the colorscheme's diff backgrounds for whole lines (or
  -- its added / removed colour over the background), stronger for the
  -- changed words, and the margin in the added / removed colour.
  local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
  local normal = hl("Normal")
  local bg = normal.bg or (vim.o.background == "light" and 0xffffff or 0x000000)
  local added = hl("Added")
  local green, red = added.fg or 0x2ea043, removed.fg or 0xf85149
  local add_line = hl("DiffAdd").bg or blend(green, bg, 0.2)
  local delete = hl("DiffDelete")
  local del_line = delete.bg or blend(red, bg, 0.2)
  local text_cterm = hl("DiffText").ctermbg
  local groups = {
    AgentEditsAddLine = { bg = add_line, ctermbg = hl("DiffAdd").ctermbg },
    AgentEditsAddText = { bg = blend(green, add_line, 0.3), ctermbg = text_cterm },
    AgentEditsAddNr = { fg = green, bg = add_line, ctermfg = added.ctermfg },
    AgentEditsDelLine = { bg = del_line, ctermbg = delete.ctermbg, ctermfg = not delete.ctermbg and removed.ctermfg or nil },
    AgentEditsDelText = { bg = blend(red, del_line, 0.3), ctermbg = text_cterm },
    AgentEditsDelNr = { fg = red, bg = del_line, ctermfg = removed.ctermfg },
  }
  for name, spec in pairs(groups) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

-- 30% of the screen, between 40 and 60 columns.
local function list_width()
  return math.min(60, math.max(40, math.floor(vim.o.columns * 0.3)))
end

local function setup()
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })
  M.code_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vnew")
  M.list_win = vim.api.nvim_get_current_win()
  M.list_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_width(M.list_win, list_width())
  local bo, wo = vim.bo[M.list_buf], vim.wo[M.list_win]
  bo.buftype, bo.bufhidden, bo.swapfile, bo.filetype = "nofile", "hide", false, "agent-edits"
  wo.number, wo.relativenumber, wo.cursorline, wo.wrap, wo.winfixwidth = false, false, true, false, true

  local function map(lhs, rhs, opts)
    vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", { silent = true, nowait = true }, opts or {}))
  end
  local lb = { buffer = M.list_buf }
  -- j / k / gg / G are the plain motions: they stop on folders too.
  map("<CR>", list_enter, lb)
  map("l", list_right, lb)
  map("h", list_left, lb)
  map("za", function() set_fold(own_header(cursor_row())) end, lb)
  map("zo", function() set_fold(own_header(cursor_row()), false) end, lb)
  map("zc", function()
    local i = cursor_row()
    local key = header_key(M.rows[i])
    set_fold((key and not is_folded(key)) and i or parent_row(i), true)
  end, lb)
  map("zM", function() fold_all(true) end, lb)
  map("zR", function() fold_all(false) end, lb)
  map("t", toggle_grouped, lb)
  map("w", toggle_tab, lb)
  map("f", toggle_folders, lb)
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
  map("I", toggle_inline)
  map("gD", function() toggle_diff("head") end)
  map("o", function() open_in_editor(false) end)
  map("O", function() open_in_editor(true) end)
  map("R", revert_here)
  vim.keymap.set("x", "R", function() revert_files(visual_range()) end,
    { buffer = M.list_buf, silent = true, nowait = true })
  vim.api.nvim_create_user_command("AgentEditsPatch", session_patch, {
    bang = true, nargs = "?", complete = "file",
    desc = "agent-edits: the selected file's session as a patch (file to write it, ! to send it)",
  })
  vim.api.nvim_create_user_command("AgentEditsUndoRevert", function(o) undo_revert(o.bang) end,
    { bang = true, desc = "agent-edits: undo the last revert (! even if the files changed since)" })
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
            M.update_markers(selected())
          end
        end)
      elseif win == M.list_win or win == M.code_win then
        vim.schedule(function() vim.cmd("qa!") end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      if vim.api.nvim_win_is_valid(M.list_win) then
        vim.api.nvim_win_set_width(M.list_win, list_width())
        refresh(true)
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
