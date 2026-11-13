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
local LIST_WIDTH = 40

vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.autoread = true
vim.o.number = true
vim.o.signcolumn = "no"

local M = { entries = {}, signature = "", list_buf = nil, list_win = nil, code_win = nil, current = nil }

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

local function read_entries()
  local latest = {}
  local fh = io.open(log_file, "r")
  if fh then
    for line in fh:lines() do
      -- <epoch> <agent> <path> [<project> [<session> ...]]; older lines have fewer columns.
      local f = vim.split(line, "\t", { plain = true })
      local ts, path = tonumber(f[1]), f[3]
      if ts and path and path ~= "" then
        if not latest[path] or latest[path].ts <= ts then
          latest[path] = {
            ts = ts, agent = f[2], path = path, rel = display_name(path, f[4]),
            project = f[4] or "", session = f[5] or "-",
          }
        end
      end
    end
    fh:close()
  end
  local list = {}
  for _, e in pairs(latest) do
    if vim.fn.filereadable(e.path) == 1 then
      table.insert(list, e)
    end
  end
  table.sort(list, function(a, b)
    if a.ts == b.ts then return a.rel < b.rel end
    return a.ts > b.ts
  end)
  return list
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

local function apply_filters(all)
  local f, out = M.filters, {}
  for _, e in ipairs(all) do
    if (not f.agent or e.agent == f.agent)
      and (not f.session or e.session == f.session)
      and (not f.project or in_project(e)) then
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
  return out
end

local function selected()
  if not (M.list_win and vim.api.nvim_win_is_valid(M.list_win)) then return nil end
  local row = vim.api.nvim_win_get_cursor(M.list_win)[1]
  return M.entries[row]
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
  local st = e and M.stats and M.stats[e.path]
  if st and (st.add + st.change + st.delete) > 0 then
    text = text .. string.format("  %%#Added#+%d %%#Changed#~%d %%#Removed#-%d", st.add, st.change, st.delete)
  end
  vim.wo[M.code_win].winbar = text
end

local function preview(e, force)
  if not e or not vim.api.nvim_win_is_valid(M.code_win) then return end
  if not force and M.current == e.path then
    set_code_winbar(e)
    return
  end
  diff_off()
  M.current = e.path
  vim.api.nvim_win_call(M.code_win, function()
    vim.cmd("silent! keepalt edit " .. vim.fn.fnameescape(e.path))
    vim.bo.modifiable = false
  end)
  if M.update_markers then M.update_markers(e) end
  set_code_winbar(e)
end

local function render()
  local lines = {}
  if #M.entries == 0 and #filter_labels() > 0 then
    lines = { "", "  No files match the filters:", "  " .. table.concat(filter_labels(), " "),
      "", "  F clears them." }
  elseif #M.entries == 0 then
    lines = { "", "  No files edited by agents yet." }
  else
    for _, e in ipairs(M.entries) do
      local suffix = string.format(" %s %s", e.agent, ago(e.ts))
      local room = LIST_WIDTH - 2 - vim.fn.strdisplaywidth(suffix)
      local name = e.rel
      if vim.fn.strdisplaywidth(name) > room then
        name = "…" .. name:sub(-(room - 1))
      end
      lines[#lines + 1] = " " .. name .. string.rep(" ", room - vim.fn.strdisplaywidth(name)) .. suffix
    end
  end
  vim.bo[M.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.list_buf, 0, -1, false, lines)
  vim.bo[M.list_buf].modifiable = false
  local count = #M.entries == M.total and tostring(M.total) or (#M.entries .. "/" .. M.total)
  local labels = table.concat(filter_labels(), " ")
  vim.wo[M.list_win].winbar = string.format(" Edits (%s)  %%#Comment#%s", count,
    labels ~= "" and labels or vim.fn.fnamemodify(root, ":t"))
end

local function refresh(force)
  local all = read_entries()
  local entries = apply_filters(all)
  M.total, M.all = #all, all
  local sig = {}
  for _, e in ipairs(entries) do sig[#sig + 1] = e.ts .. e.path end
  sig = table.concat(sig, "\n")
  if not force and sig == M.signature then
    -- Only the "x ago" labels change; refresh them once a minute.
    if os.time() - (M.rendered_at or 0) < 60 then return end
  end
  local keep = M.current
  M.entries, M.signature, M.rendered_at = entries, sig, os.time()
  render()
  local row = 1
  for i, e in ipairs(entries) do
    if e.path == keep then row = i break end
  end
  if #entries > 0 then
    vim.api.nvim_win_set_cursor(M.list_win, { row, 0 })
    preview(entries[row])
  end
end

local function move(delta)
  if #M.entries == 0 then return end
  local row = vim.api.nvim_win_get_cursor(M.list_win)[1] + delta
  row = math.max(1, math.min(#M.entries, row))
  vim.api.nvim_win_set_cursor(M.list_win, { row, 0 })
  preview(M.entries[row])
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
  if not e.session or e.session == "-" then return nil end
  local base = baselines_dir .. "/" .. e.session .. "/" .. vim.fn.sha256(e.path)
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
  local new = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
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

-- Paste the visually selected lines into the agent's prompt, as a fenced
-- block headed by "path:first-last". Bracketed paste keeps the newlines from
-- submitting the prompt.
local function send_selection(hide)
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first > last then first, last = last, first end
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  if vim.bo[buf].buftype ~= "" or path == "" then
    vim.notify("agent-edits: select code in the file window", vim.log.levels.WARN)
    return
  end

  local socket, pane = inner_option("@ae_socket"), inner_option("@ae_pane")
  local outer = socket ~= "" and { "tmux", "-S", socket } or nil
  local base = outer and vim.trim(vim.fn.system(vim.list_extend(vim.deepcopy(outer),
    { "display-message", "-p", "-t", pane, "#{pane_current_path}" }))) or root
  local name = (base ~= "" and under(path, base) and path ~= base) and path:sub(#base + 2)
    or vim.fn.fnamemodify(path, ":~")
  local range = first == last and tostring(first) or (first .. "-" .. last)
  local text = table.concat({
    name .. ":" .. range,
    "```" .. vim.bo[buf].filetype,
    table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n"),
    "```",
    "",
  }, "\n")

  if not (outer and pane ~= "") then
    vim.fn.setreg("+", text)
    vim.notify("agent-edits: no agent pane known, copied to the clipboard instead")
    return
  end
  local load = vim.list_extend(vim.deepcopy(outer), { "load-buffer", "-b", "agent-edits", "-" })
  vim.fn.system(load, text)
  local paste = vim.list_extend(vim.deepcopy(outer),
    { "paste-buffer", "-p", "-d", "-b", "agent-edits", "-t", pane })
  vim.fn.system(paste)
  if vim.v.shell_error ~= 0 then
    vim.fn.setreg("+", text)
    vim.notify("agent-edits: agent pane is gone, copied to the clipboard instead", vim.log.levels.WARN)
    return
  end
  if hide then
    hide_popup()
  else
    vim.notify(string.format("agent-edits: sent %s:%s", name, range))
  end
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
  refresh(true)
end

local HELP = {
  " agent-edits  ·  :AgentEditsHelp or g?",
  "",
  " File list",
  "   j / k, gg / G     select a file (the preview follows)",
  "   Enter / l         jump into the code",
  "   r                 reload the list now",
  "   a                 filter by agent: all, Claude, Codex, Grok",
  "   s                 only the session of the selected file (toggle)",
  "   p                 only this project (toggle)",
  "   F                 clear the filters",
  "",
  " Anywhere",
  "   ]f / [f           next / previous edited file",
  "   Ctrl-h / Ctrl-l   move between list and code",
  "   D                 diff: what the agent changed (toggle)",
  "   gD                diff against HEAD (toggle)",
  "   ]c / [c           next / previous change (signs in the margin)",
  "   Ctrl-z            hide the popup (prefix + e brings it back)",
  "   :q  ZZ  ZQ        quit the viewer",
  "",
  " Visual selection in the code",
  "   y                 paste into the agent's prompt, keep the popup open",
  "   d / Enter         paste into the agent's prompt and hide the popup",
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

local function setup()
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
  map("<CR>", function() vim.api.nvim_set_current_win(M.code_win) end, lb)
  map("l", function() vim.api.nvim_set_current_win(M.code_win) end, lb)
  map("r", function() refresh(true) end, lb)
  map("a", cycle_agent, lb)
  map("s", toggle_session, lb)
  map("p", toggle_project, lb)
  map("F", clear_filters, lb)

  -- Global keys (every window, including the code and diff windows).
  map("]f", function() move(1) end)
  map("[f", function() move(-1) end)
  map("D", function() toggle_diff("agent") end)
  map("gD", function() toggle_diff("head") end)
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
