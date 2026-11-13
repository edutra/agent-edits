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

-- Every logged file is listed, from any project. Files under the directory
-- the viewer was opened in show a relative path; the rest show ~/...
local function display_name(path)
  if root ~= "/" and path ~= root and under(path, root) then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

local function read_entries()
  local latest = {}
  local fh = io.open(log_file, "r")
  if fh then
    for line in fh:lines() do
      -- <epoch> <agent> <path> [<project>]; old lines have no project column.
      local ts, agent, path = line:match("^(%d+)\t([^\t]*)\t([^\t]+)")
      if ts then
        ts = tonumber(ts)
        if not latest[path] or latest[path].ts <= ts then
          latest[path] = { ts = ts, agent = agent, path = path, rel = display_name(path) }
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

local function selected()
  if not (M.list_win and vim.api.nvim_win_is_valid(M.list_win)) then return nil end
  local row = vim.api.nvim_win_get_cursor(M.list_win)[1]
  return M.entries[row]
end

local function diff_off()
  if not M.diff_win then return end
  if vim.api.nvim_win_is_valid(M.diff_win) then
    vim.api.nvim_win_close(M.diff_win, true)
  end
  M.diff_win = nil
  if vim.api.nvim_win_is_valid(M.code_win) then
    vim.api.nvim_win_call(M.code_win, function() vim.cmd("diffoff") end)
  end
end

local function set_code_winbar(e)
  local text = e and string.format(" %s  %%#Comment#(%s, %s ago)", e.rel, e.agent, ago(e.ts)) or ""
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
  set_code_winbar(e)
end

local function render()
  local lines = {}
  if #M.entries == 0 then
    lines = { "", "  No files edited by agents", "  under this directory yet." }
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
  vim.wo[M.list_win].winbar = string.format(" Agent edits (%d)  %%#Comment#%s", #M.entries,
    vim.fn.fnamemodify(root, ":t"))
end

local function refresh(force)
  local entries = read_entries()
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

local function toggle_diff()
  local e = selected()
  if not e then return end
  if M.diff_win then
    diff_off()
    return
  end
  -- Ask the repository that holds the file, wherever it is.
  local dir, name = vim.fn.fnamemodify(e.path, ":h"), vim.fn.fnamemodify(e.path, ":t")
  local out = vim.fn.systemlist({ "git", "-C", dir, "show", "HEAD:./" .. name })
  if vim.v.shell_error ~= 0 then
    vim.notify("agent-edits: no committed version (new file, no commits yet or not in git)",
      vim.log.levels.WARN)
    return
  end
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
  vim.wo[M.diff_win].winbar = " HEAD:" .. e.rel
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

local HELP = {
  " agent-edits  ·  :AgentEditsHelp or g?",
  "",
  " File list",
  "   j / k, gg / G     select a file (the preview follows)",
  "   Enter / l         jump into the code",
  "   r                 reload the list now",
  "",
  " Anywhere",
  "   ]f / [f           next / previous edited file",
  "   Ctrl-h / Ctrl-l   move between list and code",
  "   D                 toggle diff against HEAD",
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

  -- Global keys (every window, including the code and diff windows).
  map("]f", function() move(1) end)
  map("[f", function() move(-1) end)
  map("D", toggle_diff)
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
