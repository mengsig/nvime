local buffer_guard = require("nvime.buffer_guard")
local progress = require("nvime.progress")
local prompts = require("nvime.prompts")
local provider_api = require("nvime.provider")
local render = require("nvime.render")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local scroll_ns = vim.api.nvim_create_namespace("nvime.selection")
local input_ns = vim.api.nvim_create_namespace("nvime.selection.input")
local focus_group = vim.api.nvim_create_augroup("nvime.selection.focus", { clear = false })

local INPUT_PROMPT_LINE = 1
local sessions_loaded = false
local save_pending = false

local function systemlist(cmd)
  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return {}
  end
  return result or {}
end

local function git_root()
  local cwd = vim.loop.cwd()
  local result = systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    return result[1]
  end
  return nil
end

local function sessions_config()
  return (state.config or {}).sessions or {}
end

local function sessions_enabled()
  return sessions_config().enabled ~= false
end

local function sessions_path()
  local cfg = sessions_config()
  if cfg.path and cfg.path ~= "" then
    return vim.fn.fnamemodify(cfg.path, ":p")
  end

  local root = git_root()
  if root then
    return root .. "/.nvime/selection-sessions.json"
  end

  return vim.fn.stdpath("state") .. "/nvime/selection-sessions.json"
end

local function persisted_lines(session)
  if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
    return vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  end
  return session.lines or {}
end

local function persisted_selection(selection)
  local out = vim.deepcopy(selection or {})
  out.bufnr = nil
  return out
end

local function persisted_last_ask(last_ask)
  if type(last_ask) ~= "table" then
    return last_ask
  end
  local out = vim.deepcopy(last_ask)
  if type(out.selection) == "table" then
    out.selection = persisted_selection(out.selection)
  end
  return out
end

local function serializable_session(session)
  return {
    id = session.id,
    key = session.key,
    selection = persisted_selection(session.selection),
    provider = session.provider,
    mode = session.mode,
    input_start = session.input_start,
    provider_sessions = session.provider_sessions or {},
    last_ask = persisted_last_ask(session.last_ask),
    lines = persisted_lines(session),
    created_at = session.created_at,
    updated_at = session.updated_at,
  }
end

local function save_sessions_now()
  if not sessions_enabled() then
    return
  end
  local sessions = state.selection and state.selection.sessions or {}
  local max_sessions = tonumber(sessions_config().max) or 100
  local out = {}
  local sorted = vim.deepcopy(sessions)
  table.sort(sorted, function(left, right)
    return (left.updated_at or 0) > (right.updated_at or 0)
  end)
  for index, session in ipairs(sorted) do
    if index > max_sessions then
      break
    end
    out[#out + 1] = serializable_session(session)
  end

  local path = sessions_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    vim.schedule(function()
      vim.notify("nvime could not persist sessions: " .. tostring(err), vim.log.levels.WARN)
    end)
    return
  end
  fd:write(vim.json.encode({
    version = 1,
    next_session_id = state.selection.next_session_id or 1,
    sessions = out,
  }))
  fd:write("\n")
  fd:close()
end

local function schedule_save_sessions()
  if not sessions_enabled() or save_pending then
    return
  end
  save_pending = true
  vim.defer_fn(function()
    save_pending = false
    save_sessions_now()
  end, 150)
end

local function load_sessions()
  if sessions_loaded then
    return
  end
  sessions_loaded = true
  if not sessions_enabled() then
    return
  end

  local path = sessions_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.sessions) ~= "table" then
    return
  end

  state.selection.sessions = {}
  local max_id = 0
  for _, item in ipairs(decoded.sessions) do
    if type(item) == "table" and item.id and item.selection then
      item.id = tonumber(item.id)
      if item.id then
        if type(item.selection) == "table" then
          item.selection.bufnr = nil
        end
        if type(item.last_ask) == "table" and type(item.last_ask.selection) == "table" then
          item.last_ask.selection.bufnr = nil
        end
        item.provider_sessions = type(item.provider_sessions) == "table" and item.provider_sessions or {}
        item.lines = type(item.lines) == "table" and item.lines or nil
        item.pending_input = nil
        item.busy = false
        item.input_active = false
        item.bufnr = nil
        max_id = math.max(max_id, item.id)
        state.selection.sessions[#state.selection.sessions + 1] = item
      end
    end
  end
  state.selection.next_session_id = math.max(tonumber(decoded.next_session_id) or 1, max_id + 1)
end

local function provider()
  return (state.selection and state.selection.provider) or (state.config and state.config.provider) or "claude"
end

local function mode()
  return (state.selection and state.selection.mode) or "selection"
end

local function prompt_prefix()
  return "[" .. provider() .. " " .. mode() .. "]$ "
end

local function status_word()
  local session = state.selection and state.selection.active_session_id and M.get_session(state.selection.active_session_id)
  if session and session.busy then
    return "running"
  end
  if state.selection and state.selection.busy then
    return "running"
  end
  return "idle"
end

local function line_count(bufnr)
  return vim.api.nvim_buf_line_count(bufnr)
end

local function prompt_end_col(panel)
  if not panel or not panel.input_bufnr or not vim.api.nvim_buf_is_valid(panel.input_bufnr) then
    return #prompt_prefix()
  end
  local lnum = panel.input_start or 1
  local line = vim.api.nvim_buf_get_lines(panel.input_bufnr, lnum - 1, lnum, false)[1] or ""
  return #line
end

local function find_buffer_by_name(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

local function set_scratch_options(bufnr, filetype)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or "nvime"
end

local function ensure_named_buffer(name, filetype)
  local bufnr = find_buffer_by_name(name)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  set_scratch_options(bufnr, filetype)
  return bufnr
end

local function now()
  return os.time()
end

local function selection_key(selection)
  if not selection then
    return nil
  end
  return table.concat({
    selection.path or "",
    tostring(selection.line1 or ""),
    tostring(selection.line2 or ""),
  }, ":")
end

local function session_buffer_name(session)
  return "nvime://selection/" .. tostring(session.id)
end

local function ensure_sessions()
  load_sessions()
  state.selection.sessions = state.selection.sessions or {}
  state.selection.next_session_id = state.selection.next_session_id or 1
  return state.selection.sessions
end

local function touch_session(session)
  if session then
    session.updated_at = now()
    schedule_save_sessions()
  end
end

local function ensure_session_buffer(session)
  if not session then
    return nil
  end
  if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
    session.bufnr = ensure_named_buffer(session_buffer_name(session), "nvime")
    if session.lines and #session.lines > 0 then
      local modifiable = vim.bo[session.bufnr].modifiable
      local readonly = vim.bo[session.bufnr].readonly
      vim.bo[session.bufnr].readonly = false
      vim.bo[session.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, session.lines)
      vim.bo[session.bufnr].modifiable = modifiable
      vim.bo[session.bufnr].readonly = readonly
    end
  else
    set_scratch_options(session.bufnr, "nvime")
  end
  return session.bufnr
end

local function create_session(selection, key)
  local sessions = ensure_sessions()
  local id = state.selection.next_session_id
  state.selection.next_session_id = id + 1
  local session = {
    id = id,
    key = key or selection_key(selection),
    selection = M.snapshot(selection),
    provider = provider(),
    mode = "selection",
    input_start = nil,
    input_active = false,
    pending_input = nil,
    busy = false,
    provider_sessions = {},
    created_at = now(),
    updated_at = now(),
  }
  ensure_session_buffer(session)
  table.insert(sessions, session)
  schedule_save_sessions()
  return session
end

local function session_for_selection(selection, opts)
  opts = opts or {}
  if not selection then
    return nil
  end
  local key = selection_key(selection)
  if not opts.new_session then
    for _, session in ipairs(ensure_sessions()) do
      if session.key == key then
        session.selection = M.snapshot(selection)
        session.provider_sessions = session.provider_sessions or {}
        touch_session(session)
        return session
      end
    end
  end

  return create_session(selection, key)
end

local function active_session()
  return state.selection and state.selection.active_session_id and M.get_session(state.selection.active_session_id)
end

local function sync_active_panel_to_session()
  local panel = state.panels.selection
  local session = active_session()
  if not panel or not session then
    return
  end
  session.input_start = panel.input_start
  session.input_active = panel.input_active == true
  session.bufnr = panel.bufnr or session.bufnr
end

local function panel_for_session(session)
  local panel = state.panels.selection
  if panel and session and panel.session_id == session.id then
    return panel
  end
  return {
    bufnr = session and session.bufnr,
    input_bufnr = session and session.bufnr,
    input_start = session and session.input_start,
    input_active = false,
  }
end

local function delete_named_buffer(name)
  local bufnr = find_buffer_by_name(name)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

local function set_locked(bufnr, locked)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].readonly = locked
  vim.bo[bufnr].modifiable = not locked
end

local function with_writable(bufnr, fn, after, sync_panel)
  local modifiable = vim.bo[bufnr].modifiable
  local readonly = vim.bo[bufnr].readonly
  local ok, result = pcall(function()
    return buffer_guard.suspend(bufnr, function()
      vim.bo[bufnr].readonly = false
      vim.bo[bufnr].modifiable = true
      return fn()
    end)
  end)
  vim.bo[bufnr].modifiable = modifiable
  vim.bo[bufnr].readonly = readonly
  if not ok then
    error(result)
  end
  if after then
    after(bufnr)
  end
  buffer_guard.sync(bufnr, sync_panel or state.panels.selection)
  return result
end

local function dimensions()
  local cfg = (state.config or {}).ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = cfg.width or math.floor(columns * (cfg.float_width or 0.82))
  local height = cfg.height or math.floor(lines * (cfg.float_height or 0.72))

  if type(cfg.float_width) == "number" and cfg.float_width > 0 and cfg.float_width <= 1 then
    width = math.floor(columns * cfg.float_width)
  end
  if type(cfg.float_height) == "number" and cfg.float_height > 0 and cfg.float_height <= 1 then
    height = math.floor(lines * cfg.float_height)
  end

  width = math.max(56, math.min(width, columns - 4))
  height = math.max(16, math.min(height, lines - 4))

  local row = math.floor((lines - height) / 2 - 1)
  local col = math.floor((columns - width) / 2)

  return {
    width = width,
    height = height,
    row = math.max(0, row),
    col = math.max(0, col),
    border = cfg.border or "rounded",
  }
end

local function title()
  local status = status_word()
  local icon = status == "running" and ui.icon("active") or ui.icon("idle")
  return "nvime.nvim  " .. provider() .. "  " .. mode() .. "  " .. icon .. " " .. status
end

local function scroll_config()
  local dim = dimensions()
  local active = active_session()
  local footer = " i input | ? prompts | <CR> send on prompt | p provider | P choose | q close "
  if active and active.busy and active.progress and active.progress ~= "" then
    footer = " " .. render.spinner_text() .. " " .. active.progress .. " | i input | ? prompts | <CR> send | q close "
  end
  return {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " " .. title() .. " ",
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    zindex = 52,
  }
end

local function configure_scrollback_window(winid)
  vim.wo[winid].wrap = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].cursorline = false
  vim.wo[winid].spell = false
  vim.wo[winid].winblend = 0
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted"
end

local function extract_prompt_text(line)
  line = line or ""
  local modern = line:match("^%[[^%]]+%]%$%s*(.*)$")
  if modern then
    return modern
  end
  return vim.trim(line)
end

local function current_input_text()
  local panel = state.panels.selection
  local bufnr = panel and panel.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end
  local prompt_lnum = (panel.input_start or line_count(bufnr)) + INPUT_PROMPT_LINE - 1
  local line = vim.api.nvim_buf_get_lines(bufnr, prompt_lnum - 1, prompt_lnum, false)[1] or ""
  return extract_prompt_text(line)
end

local function prompt_has_submit_text(panel)
  if not panel or not panel.input_bufnr or not vim.api.nvim_buf_is_valid(panel.input_bufnr) then
    return false
  end
  if not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return false
  end
  local lnum = panel.input_start or 1
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
  if not ok or cursor[1] ~= lnum then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(panel.input_bufnr, lnum - 1, lnum, false)[1] or ""
  return vim.trim(extract_prompt_text(line)) ~= ""
end

local function decorate_scrollback(bufnr)
  render.scrollback(bufnr, scroll_ns)
end

local function decorate_input(bufnr)
  local panel = state.panels.selection
  if not panel or not panel.input_start then
    return
  end
  render.input(bufnr, input_ns, prompt_prefix(), panel.input_start)
  local session = active_session()
  if session and session.busy and session.progress and session.progress ~= "" then
    vim.api.nvim_buf_set_extmark(bufnr, input_ns, panel.input_start - 1, 0, {
      virt_text = { { render.spinner_text() .. " " .. session.progress, "NvimeStatusRunning" } },
      virt_text_pos = "right_align",
      priority = 200,
    })
  end
end

local function refresh_header(bufnr)
  decorate_scrollback(bufnr)
end

local function save_window_view(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local ok, view = pcall(vim.api.nvim_win_call, winid, vim.fn.winsaveview)
  return ok and view or nil
end

local function restore_window_view(winid, view)
  if not view or not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  pcall(vim.api.nvim_win_call, winid, function()
    vim.fn.winrestview(view)
  end)
end

local function view_is_at_bottom(panel)
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return false
  end
  local view = save_window_view(panel.winid)
  if not view then
    return false
  end
  local height = vim.api.nvim_win_get_height(panel.winid)
  return (view.topline or 1) + height >= line_count(panel.bufnr)
end

local function cursor_is_on_prompt(panel)
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return false
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
  if not ok then
    return false
  end
  return cursor[1] >= (panel.input_start or line_count(panel.bufnr))
end

local function should_auto_scroll(panel)
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return false
  end
  if panel.input_active == true then
    return true
  end
  return view_is_at_bottom(panel) and cursor_is_on_prompt(panel)
end

local function reset_input(text, opts)
  opts = opts or {}
  local panel = state.panels.selection
  local bufnr = panel and panel.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local follow = opts.force_follow == true or should_auto_scroll(panel)
  local view = follow and nil or save_window_view(panel.winid)
  with_writable(bufnr, function()
    local start = panel.input_start
    local count = line_count(bufnr)
    if not start or start < 1 or start > count then
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      if count == 1 and lines[1] == "" then
        start = 1
      else
        start = count + 1
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, start - 1, count, false, {
      prompt_prefix() .. (text or ""),
    })
    panel.input_start = vim.api.nvim_buf_line_count(bufnr)
  end, decorate_input)
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    if follow then
      local prompt_lnum = panel.input_start
      pcall(vim.api.nvim_win_set_cursor, panel.winid, { prompt_lnum, #prompt_prefix() })
      pcall(vim.api.nvim_win_call, panel.winid, function()
        vim.fn.winrestview({ topline = math.max(1, prompt_lnum - vim.api.nvim_win_get_height(panel.winid) + 2) })
      end)
    else
      restore_window_view(panel.winid, view)
    end
  end
end

local function scroll_to_bottom()
  local panel = state.panels.selection
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end
  local target = math.max(1, (panel.input_start or line_count(panel.bufnr)))
  vim.api.nvim_win_set_cursor(panel.winid, { target, 0 })
end

local function open_or_configure_window(bufnr, winid, config, configure, enter)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_config(winid, config)
    configure(winid)
    if enter then
      vim.api.nvim_set_current_win(winid)
    end
    return winid
  end
  local next_winid = vim.api.nvim_open_win(bufnr, enter == true, config)
  configure(next_winid)
  return next_winid
end

local function close_panel()
  local panel = state.panels.selection
  if not panel then
    return
  end
  local seen = {}
  for _, key in ipairs({ "input_winid", "winid" }) do
    local winid = panel[key]
    if winid and not seen[winid] and vim.api.nvim_win_is_valid(winid) then
      seen[winid] = true
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
end

local function panel_is_open(session_id)
  local panel = state.panels.selection
  return panel
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
    and (not session_id or panel.session_id == session_id)
end

local function completion_behavior()
  local ui = (state.config or {}).ui or {}
  if ui.completion == "open" or ui.completion == "popup" then
    return "open"
  end
  return "notify"
end

local function notify_finished(lane, session_id, code)
  if panel_is_open(session_id) then
    return
  end
  local session = session_id and M.get_session(session_id) or active_session()
  if session then
    state.last_session = { kind = "selection", id = session.id }
  end
  if completion_behavior() == "open" then
    M.open_session(session_id)
    return
  end
  local level = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
  local status = code == 0 and "finished" or ("failed with code " .. tostring(code))
  vim.notify("nvime " .. tostring(lane or "selection") .. " " .. status .. ". Reopen with :NvimeLast or <leader>nn.", level)
end

function M.close()
  close_panel()
end

local function in_input_window(panel)
  return panel
    and panel.input_active == true
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
    and vim.api.nvim_get_current_win() == panel.winid
end

local function focus_scrollback()
  local panel = state.panels.selection
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    panel.input_active = false
    set_locked(panel.bufnr, true)
    vim.api.nvim_set_current_win(panel.winid)
  end
end

local function prompt_lnum(panel)
  return panel.input_start or 1
end

local function attach_focus_lock(bufnr)
  pcall(vim.api.nvim_clear_autocmds, { group = focus_group, buffer = bufnr })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = focus_group,
    buffer = bufnr,
    callback = function()
      local panel = state.panels.selection
      if not panel or panel.bufnr ~= bufnr then
        return
      end
      panel.input_active = false
      set_locked(bufnr, true)
    end,
  })
end

local function attach_input_guard(bufnr)
  buffer_guard.attach({
    bufnr = bufnr,
    key = "nvime_selection_guard_attached",
    panel = function()
      return state.panels.selection
    end,
    prompt_lnum = prompt_lnum,
    prompt_prefix = prompt_prefix,
    in_input_window = in_input_window,
    set_locked = set_locked,
    decorate = function(target)
      decorate_scrollback(target)
      decorate_input(target)
    end,
  })
end

local function attach_panel(bufnr)
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "<CR>", function()
    if in_input_window(state.panels.selection) or prompt_has_submit_text(state.panels.selection) then
      require("nvime.selection").submit_current()
    else
      require("nvime.selection").focus_input()
    end
  end, opts)
  vim.keymap.set("n", "i", function()
    require("nvime.selection").focus_input()
  end, opts)
  vim.keymap.set("n", "I", function()
    require("nvime.selection").focus_input()
  end, opts)
  vim.keymap.set("n", "a", function()
    require("nvime.selection").focus_input({ cursor = "end" })
  end, opts)
  vim.keymap.set("n", "A", function()
    require("nvime.selection").focus_input({ cursor = "end" })
  end, opts)
  vim.keymap.set("n", "o", function()
    require("nvime.selection").focus_input({ cursor = "end" })
  end, opts)
  vim.keymap.set("n", "O", function()
    require("nvime.selection").focus_input({ cursor = "end" })
  end, opts)
  vim.keymap.set("n", "p", function()
    provider_api.cycle({ scope = "selection" })
  end, opts)
  vim.keymap.set("n", "<Tab>", function()
    provider_api.cycle({ scope = "selection" })
  end, opts)
  vim.keymap.set("n", "P", function()
    provider_api.choose({ scope = "selection" })
  end, opts)
  vim.keymap.set("n", "?", function()
    require("nvime.selection").choose_prompt()
  end, opts)
  vim.keymap.set("i", "<CR>", function()
    vim.cmd.stopinsert()
    require("nvime.selection").submit_current()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    focus_scrollback()
  end, opts)
  vim.keymap.set("n", "q", close_panel, opts)
end

function M.open(opts)
  opts = opts or {}
  ui.ensure_highlights()
  delete_named_buffer("nvime://selection-input")
  sync_active_panel_to_session()

  local session = nil
  if opts.session_id then
    session = M.get_session(opts.session_id)
  elseif opts.selection then
    session = session_for_selection(opts.selection, { new_session = opts.new_session == true })
  else
    session = active_session()
  end

  if not session then
    vim.notify("No nvime selection discussion is open", vim.log.levels.INFO)
    return nil
  end

  session.provider_sessions = session.provider_sessions or {}
  session.provider = opts.provider or session.provider or (state.config and state.config.provider) or "claude"
  session.mode = opts.mode or session.mode or "selection"
  if opts.selection then
    session.selection = M.snapshot(opts.selection)
    session.key = selection_key(opts.selection)
  end
  touch_session(session)

  state.selection.active_session_id = session.id
  state.last_session = { kind = "selection", id = session.id }
  state.selection.mode = session.mode
  state.selection.provider = session.provider
  state.selection.active_selection = session.selection
  state.selection.pending_input = session.pending_input

  local panel = state.panels.selection or {}
  local was_open = panel.winid and vim.api.nvim_win_is_valid(panel.winid)
  if panel.input_winid and panel.input_winid ~= panel.winid and vim.api.nvim_win_is_valid(panel.input_winid) then
    pcall(vim.api.nvim_win_close, panel.input_winid, true)
  end
  local scroll_buf = ensure_session_buffer(session)

  local scroll_win = open_or_configure_window(scroll_buf, panel.winid, scroll_config(), configure_scrollback_window, true)

  state.panels.selection = {
    bufnr = scroll_buf,
    winid = scroll_win,
    input_bufnr = scroll_buf,
    input_winid = scroll_win,
    input_start = session.input_start,
    input_active = session.input_active == true,
    session_id = session.id,
  }

  attach_panel(scroll_buf)
  attach_focus_lock(scroll_buf)
  attach_input_guard(scroll_buf)
  refresh_header(scroll_buf)
  reset_input(current_input_text(), { force_follow = not was_open })
  set_locked(scroll_buf, true)

  if opts.focus_input then
    M.focus_input()
  end

  return scroll_buf
end

function M.refresh()
  local panel = state.panels.selection
  if not panel then
    return
  end
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    vim.api.nvim_win_set_config(panel.winid, scroll_config())
    configure_scrollback_window(panel.winid)
  end
  refresh_header(panel.bufnr)
  reset_input(current_input_text())
  set_locked(panel.bufnr, true)
  sync_active_panel_to_session()
end

local spinner_timer = nil

local function stop_spinner_timer()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

local function ensure_spinner_timer()
  if spinner_timer then
    return
  end
  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    return
  end
  spinner_timer = uv.new_timer()
  spinner_timer:start(120, 120, function()
    vim.schedule(function()
      local session = active_session()
      if not session or not session.busy or not panel_is_open(session.id) then
        stop_spinner_timer()
        return
      end
      M.refresh()
    end)
  end)
end

function M.set_busy(value, session_id)
  local session = session_id and M.get_session(session_id) or active_session()
  if session then
    session.busy = value == true
    if not session.busy then
      session.progress = nil
    else
      ensure_spinner_timer()
    end
    touch_session(session)
  end
  state.selection.busy = value == true
  if not session_id or (state.selection and state.selection.active_session_id == session_id) then
    M.refresh()
  end
end

function M.set_progress(text, session_id)
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function()
      M.set_progress(text, session_id)
    end)
    return
  end
  local compact = progress.compact(text)
  if compact == "" then
    return
  end
  local session = session_id and M.get_session(session_id) or active_session()
  if not session then
    return
  end
  session.progress = compact
  touch_session(session)
  if state.selection and state.selection.active_session_id == session.id then
    M.refresh()
  end
end

function M.append(text, session_id)
  if not text or text == "" then
    return
  end
  local session = session_id and M.get_session(session_id) or active_session()
  if not session then
    return
  end

  vim.schedule(function()
    local bufnr = ensure_session_buffer(session)
    local panel = panel_for_session(session)
    if not bufnr then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local follow = should_auto_scroll(panel)
    local view = follow and nil or save_window_view(panel.winid)
    with_writable(bufnr, function()
      local parts = vim.split(text, "\n", { plain = true })
      local input_start = panel.input_start or session.input_start or (line_count(bufnr) + 1)
      local target = math.max(0, input_start - 2)
      local current = vim.api.nvim_buf_get_lines(bufnr, target, target + 1, false)[1] or ""
      vim.api.nvim_buf_set_lines(bufnr, target, target + 1, false, { current .. parts[1] })
      if #parts > 1 then
        local rest = {}
        for i = 2, #parts do
          rest[#rest + 1] = parts[i]
        end
        vim.api.nvim_buf_set_lines(bufnr, target + 1, target + 1, false, rest)
        panel.input_start = input_start + #rest
        session.input_start = panel.input_start
      end
      touch_session(session)
    end, decorate_scrollback, panel)
    set_locked(bufnr, true)
    local active_panel = state.panels.selection
    if state.selection and state.selection.active_session_id == session.id and active_panel and active_panel.session_id == session.id then
      active_panel.input_start = session.input_start
      if follow then
        scroll_to_bottom()
      else
        restore_window_view(panel.winid, view)
      end
    end
  end)
end

function M.append_user(provider_name, lane, text, session_id)
  M.append("\n\n[" .. provider_name .. " " .. lane .. "]$ " .. text .. "\n\n", session_id)
end

function M.append_response_header(provider_name, lane, session_id)
  M.append("[" .. provider_name .. " " .. lane .. " response]\n\n", session_id)
end

function M.prompt(opts)
  opts = opts or {}
  local session = opts.session_id and M.get_session(opts.session_id) or nil
  if not session and opts.selection then
    session = session_for_selection(opts.selection, { new_session = opts.new_session == true })
  end
  if not session then
    session = active_session()
  end
  if not session then
    vim.notify("No nvime selection discussion is open", vim.log.levels.INFO)
    return
  end
  local next_provider = opts.provider or session.provider or provider()
  local next_mode = opts.mode or session.mode or mode()
  local focus_input = opts.focus_input == true
  local open_panel = opts.open ~= false
  session.provider_sessions = session.provider_sessions or {}
  session.pending_input = {
    provider = next_provider,
    mode = next_mode,
    selection = opts.selection or session.selection,
    on_submit = opts.on_submit,
  }
  session.provider = next_provider
  session.mode = next_mode
  if opts.selection then
    session.selection = M.snapshot(opts.selection)
    session.key = selection_key(opts.selection)
  end
  touch_session(session)

  if not open_panel then
    return
  end

  state.selection.pending_input = session.pending_input
  state.selection.provider = next_provider
  state.selection.mode = next_mode
  state.selection.active_selection = session.selection
  M.open({
    provider = session.pending_input.provider,
    mode = session.pending_input.mode,
    selection = session.selection,
    session_id = session.id,
    focus_input = focus_input,
  })
  reset_input("")
end

function M.insert_prompt(text)
  text = vim.trim(text or "")
  M.open()
  reset_input(text, { force_follow = true })
  M.focus_input({ cursor = "end" })
end

function M.choose_prompt()
  prompts.choose("selection", function(text)
    M.insert_prompt(text)
  end)
end

function M.focus_input(opts)
  opts = opts or {}
  M.open()
  local panel = state.panels.selection
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end
  panel.input_active = true
  set_locked(panel.input_bufnr, false)
  vim.api.nvim_set_current_win(panel.winid)
  local lnum = prompt_lnum(panel)
  local append = opts.cursor == "end"
  local end_col = prompt_end_col(panel)
  local empty_prompt = end_col <= #prompt_prefix()
  local col = (append or empty_prompt) and math.max(0, end_col - 1) or #prompt_prefix()
  pcall(vim.api.nvim_win_set_cursor, panel.winid, { lnum, col })
  pcall(vim.api.nvim_win_call, panel.winid, function()
    vim.fn.winrestview({ topline = math.max(1, lnum - vim.api.nvim_win_get_height(panel.winid) + 2) })
  end)
  pcall(vim.cmd, (append or empty_prompt) and "startinsert!" or "startinsert")
end

function M.submit_current()
  local session = active_session()
  local pending = (session and session.pending_input) or state.selection.pending_input
  if not pending or type(pending.on_submit) ~= "function" then
    M.focus_input()
    return
  end

  local panel = state.panels.selection
  local lnum = prompt_lnum(panel)
  local line = vim.api.nvim_buf_get_lines(panel.input_bufnr, lnum - 1, lnum, false)[1] or ""
  local text = vim.trim(extract_prompt_text(line))
  reset_input("")
  if text == "" then
    M.focus_input()
    return
  end
  local on_submit = pending.on_submit
  local selected_provider = state.selection.provider or pending.provider
  if session then
    session.pending_input = nil
    touch_session(session)
  end
  state.selection.pending_input = nil
  on_submit(text, selected_provider)
end

function M.same_range(left, right)
  if not left or not right then
    return false
  end
  return left.path == right.path
    and tonumber(left.line1) == tonumber(right.line1)
    and tonumber(left.line2) == tonumber(right.line2)
end

local function same_file(left, right)
  return left and right and left.path ~= nil and left.path == right.path
end

function M.snapshot(selection)
  return {
    bufnr = selection.bufnr,
    path = selection.path,
    line1 = selection.line1,
    line2 = selection.line2,
    source = selection.source,
  }
end

function M.get_session(id)
  if not id then
    return nil
  end
  for _, session in ipairs(ensure_sessions()) do
    if session.id == id then
      return session
    end
  end
  return nil
end

function M.matching_sessions(selection)
  local key = selection_key(selection)
  local matches = {}
  if not key then
    return matches
  end
  for _, session in ipairs(ensure_sessions()) do
    if session.key == key then
      matches[#matches + 1] = session
    end
  end
  table.sort(matches, function(left, right)
    if (left.updated_at or 0) == (right.updated_at or 0) then
      return (left.id or 0) > (right.id or 0)
    end
    return (left.updated_at or 0) > (right.updated_at or 0)
  end)
  return matches
end

function M.active_session_id()
  return state.selection and state.selection.active_session_id
end

function M.is_open(session_id)
  return panel_is_open(session_id)
end

function M.notify_finished(lane, session_id, code)
  notify_finished(lane, session_id, code or 0)
end

function M.sessions()
  local items = vim.deepcopy(ensure_sessions())
  table.sort(items, function(left, right)
    if (left.updated_at or 0) == (right.updated_at or 0) then
      return (left.id or 0) > (right.id or 0)
    end
    return (left.updated_at or 0) > (right.updated_at or 0)
  end)
  return items
end

function M.session_count()
  return #ensure_sessions()
end

function M.save_sessions()
  save_pending = false
  save_sessions_now()
end

function M.reload_sessions()
  sessions_loaded = false
  state.selection.sessions = {}
  state.selection.next_session_id = 1
  state.selection.active_session_id = nil
  state.selection.pending_input = nil
  load_sessions()
  return state.selection.sessions
end

function M.sessions_path()
  return sessions_path()
end

function M.delete_sessions(ids)
  if not ids or #ids == 0 then
    return 0
  end
  local remove = {}
  for _, id in ipairs(ids) do
    remove[tonumber(id)] = true
  end

  local kept = {}
  local deleted = 0
  for _, session in ipairs(ensure_sessions()) do
    if remove[tonumber(session.id)] then
      deleted = deleted + 1
      if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
        pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
      else
        delete_named_buffer(session_buffer_name(session))
      end
      if state.selection.active_session_id == session.id then
        state.selection.active_session_id = nil
        state.selection.pending_input = nil
        local panel = state.panels.selection
        if panel and panel.session_id == session.id and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
          pcall(vim.api.nvim_win_close, panel.winid, true)
        end
        state.panels.selection = nil
      end
    else
      kept[#kept + 1] = session
    end
  end
  state.selection.sessions = kept
  if deleted > 0 then
    save_sessions_now()
  end
  return deleted
end

function M.open_session(id, opts)
  opts = opts or {}
  local session = M.get_session(id)
  if not session then
    vim.notify("nvime discussion no longer exists", vim.log.levels.WARN)
    return nil
  end
  return M.open({
    session_id = session.id,
    provider = session.provider,
    mode = session.mode,
    selection = session.selection,
    focus_input = opts.focus_input == true and session.pending_input ~= nil,
  })
end

local function format_choice(session, provider_name, scope)
  local selected = session.selection or {}
  local session_provider = session.provider or provider_name
  local native = session.provider_sessions and session.provider_sessions[session_provider]
  local suffix = native and "native resume" or "local transcript"
  return string.format(
    "Continue %-9s #%s  %s  %s:%s-%s  %s",
    scope or "session",
    tostring(session.id),
    session_provider or "?",
    selected.path or "(unknown)",
    tostring(selected.line1 or "?"),
    tostring(selected.line2 or "?"),
    suffix
  )
end

function M.choose_session(selection, opts, callback)
  opts = opts or {}
  local provider_name = opts.provider or provider()
  local sessions = M.sessions()
  if #sessions == 0 then
    callback({ new_session = true })
    return
  end

  local choices = {
    {
      label = "Start new " .. (opts.mode or "selection") .. " session for current selection",
      new_session = true,
    },
  }

  local seen = {}
  local function add_choice(session, scope)
    if not session or seen[session.id] then
      return
    end
    seen[session.id] = true
    choices[#choices + 1] = {
      label = format_choice(session, provider_name, scope),
      session_id = session.id,
      provider = session.provider,
    }
  end

  for _, session in ipairs(sessions) do
    if M.same_range(selection, session.selection) then
      add_choice(session, "exact")
    end
  end
  for _, session in ipairs(sessions) do
    if not M.same_range(selection, session.selection) and same_file(selection, session.selection) then
      add_choice(session, "same file")
    end
  end
  for _, session in ipairs(sessions) do
    if not same_file(selection, session.selection) then
      add_choice(session, "recent")
    end
  end

  vim.ui.select(choices, {
    prompt = "nvime " .. (opts.mode or "selection") .. " discussion",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

function M.mark_provider_session(session_id, provider_name, provider_session_id)
  if not provider_session_id or provider_session_id == "" then
    return
  end
  local session = M.get_session(session_id)
  if not session then
    return
  end
  session.provider_sessions = session.provider_sessions or {}
  session.provider_sessions[provider_name] = provider_session_id
  touch_session(session)
end

function M.agent_run_opts(session_id, provider_name)
  local session = M.get_session(session_id)
  local resume_id = session and session.provider_sessions and session.provider_sessions[provider_name] or nil
  return {
    persist_session = true,
    resume_session_id = resume_id,
    on_session_id = function(provider_session_id)
      M.mark_provider_session(session_id, provider_name, provider_session_id)
    end,
  }
end

function M.mark_last_ask(session_id, ask)
  local session = M.get_session(session_id)
  if session then
    session.last_ask = ask
    touch_session(session)
  end
  state.selection.last_ask = ask
end

function M.last_ask_for(selection)
  if selection then
    for _, session in ipairs(ensure_sessions()) do
      if session.last_ask and M.same_range(selection, session.selection) then
        return session.last_ask
      end
    end
  end
  local ask = state.selection.last_ask
  if ask and selection and M.same_range(selection, ask.selection) then
    return ask
  end
  return nil
end

return M
