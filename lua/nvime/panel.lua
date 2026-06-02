-- nvime.panel
--
-- Shared mechanism for the scratch-buffer conversation panels (chat + the
-- ask/edit/discuss selection panel). chat.lua and selection.lua were ~70%
-- identical: session persistence, the floating scrollback+prompt buffer, the
-- input guard, the spinner timer, window-view bookkeeping, and the public
-- M.* surface (open/refresh/set_busy/append/cancel/sessions/...).
--
-- `panel.create(policy)` returns one instance. Everything that genuinely
-- diverges between the two panels is a field on `policy`; everything else is
-- shared here. The per-instance namespaces/augroup/spinner timer/loaded flags
-- are CLOSED OVER per create() call so the two panels never collide (the chat
-- panel must keep the literal "nvime.chat"/"nvime.chat.input" namespaces that
-- the test suite asserts on — those come from policy.ns_prefix).
--
-- The returned table exposes the public surface directly, plus a `ctx` table
-- of internal helpers so each owning module can build its bespoke
-- submit/prompt flows (chat.M.submit, selection.M.focus_input, ...) on top.

local buffer_guard = require("nvime.buffer_guard")
local git = require("nvime.git")
local progress = require("nvime.progress")
local provider_api = require("nvime.provider")
local render = require("nvime.render")
local spinner = require("nvime.spinner")
local state = require("nvime.state")
local ui = require("nvime.ui")
local version = require("nvime.version")

local M = {}

local INPUT_PROMPT_LINE = 1
local SESSION_VERSION = 1

function M.create(policy)
  assert(type(policy) == "table", "panel.create requires a policy table")
  local state_key = policy.state_key
  local module_name = policy.module_name

  -- Per-instance namespaces / augroup / flags. Never shared across instances.
  local scroll_ns = vim.api.nvim_create_namespace(policy.ns_prefix)
  local input_ns = vim.api.nvim_create_namespace(policy.ns_prefix .. ".input")
  local focus_group = vim.api.nvim_create_augroup(policy.augroup_name, { clear = false })
  local sessions_loaded = false
  local save_pending = false
  local spinner_timer = nil

  local P = {}
  local ctx = {}
  -- Forward declarations for helpers referenced before definition.
  local get_session, active_session, ensure_session_buffer, decorate_input
  local touch_session, reset_input, current_input_text, scroll_to_bottom
  local sync_active_panel_to_session, append_scrollback, refresh_input_indicator
  local ensure_spinner_timer, panel_is_open, prompt_prefix, provider

  -- ---------------------------------------------------------------------------
  -- state accessors
  -- ---------------------------------------------------------------------------
  local function store()
    return state[state_key]
  end

  -- ---------------------------------------------------------------------------
  -- config / persistence
  -- ---------------------------------------------------------------------------
  local function sessions_config()
    return (state.config or {}).sessions or {}
  end

  local function sessions_enabled()
    return not state.disabled and sessions_config().enabled ~= false
  end

  local function sessions_path()
    if policy.sessions_path then
      return policy.sessions_path()
    end
    local cfg = sessions_config()
    if cfg.path and cfg.path ~= "" then
      return vim.fn.fnamemodify(cfg.path, ":p")
    end
    local root = git.root()
    if root then
      return root .. "/.nvime/" .. policy.persist_filename
    end
    return vim.fn.stdpath("state") .. "/nvime/" .. policy.persist_filename
  end

  local function notify_persist_error(err)
    vim.schedule(function()
      vim.notify("nvime could not persist " .. policy.persist_error_label .. ": " .. tostring(err), vim.log.levels.WARN)
    end)
  end

  local function now()
    return os.time()
  end

  local function persisted_lines(session)
    if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
      return vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
    end
    return session.lines or {}
  end

  local function serializable_session(session)
    return policy.serialize_session(session, persisted_lines)
  end

  local function public_session(session)
    local out = serializable_session(session)
    out.busy = session.busy == true
    out.progress = session.progress
    return out
  end

  local function save_sessions_now()
    if not sessions_enabled() then
      return
    end
    -- Refuse to write when load_sessions has never run, or a run that opens
    -- nvime but never opens this panel would overwrite the on-disk file with
    -- the empty in-memory default at VimLeavePre, destroying prior sessions.
    if not sessions_loaded then
      return
    end
    local sessions = store() and store().sessions or {}
    local max_sessions = tonumber(sessions_config().max) or 100
    local out = {}
    local sorted = {}
    for index, _ in ipairs(sessions) do
      sorted[#sorted + 1] = index
    end
    table.sort(sorted, function(left, right)
      return ((sessions[left] or {}).updated_at or 0) > ((sessions[right] or {}).updated_at or 0)
    end)
    for index, session_index in ipairs(sorted) do
      if index > max_sessions then
        break
      end
      out[#out + 1] = serializable_session(sessions[session_index])
    end

    local path = sessions_path()
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local fd, err = io.open(path, "w")
    if not fd then
      notify_persist_error(err)
      return
    end
    local ok, write_err = pcall(function()
      local envelope = {
        version = SESSION_VERSION,
        next_session_id = store().next_session_id or 1,
        sessions = out,
      }
      if policy.save_meta then
        policy.save_meta(envelope, store())
      end
      local encoded = vim.json.encode(envelope)
      local wrote, err1 = fd:write(encoded)
      if not wrote then
        error(err1 or "write failed")
      end
      wrote, err1 = fd:write("\n")
      if not wrote then
        error(err1 or "write failed")
      end
    end)
    local close_ok, closed, close_err = pcall(function()
      return fd:close()
    end)
    if not ok then
      notify_persist_error(write_err)
    elseif not close_ok then
      notify_persist_error(closed)
    elseif not closed then
      notify_persist_error(close_err)
    end
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

  local function migrate_sessions(decoded, path)
    local version_value = tonumber(decoded.version or 1)
    if version_value > SESSION_VERSION then
      vim.notify(policy.newer_version_label .. " " .. path, vim.log.levels.WARN)
      return nil
    end
    if type(decoded.sessions) ~= "table" then
      return nil
    end
    decoded.version = SESSION_VERSION
    return decoded
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
    decoded = migrate_sessions(decoded, path)
    if not decoded then
      return
    end

    store().sessions = {}
    local max_id = 0
    for _, item in ipairs(decoded.sessions) do
      if type(item) == "table" and item.id and (not policy.item_is_valid or policy.item_is_valid(item)) then
        item.id = tonumber(item.id)
        if item.id then
          policy.normalize_item(item)
          item.busy = false
          item.cancelled = false
          item.process = nil
          item.input_active = false
          item.bufnr = nil
          max_id = math.max(max_id, item.id)
          store().sessions[#store().sessions + 1] = item
        end
      end
    end
    store().next_session_id = math.max(tonumber(decoded.next_session_id) or 1, max_id + 1)
    if policy.restore_meta then
      policy.restore_meta(decoded, store(), ctx)
    end
  end

  -- ---------------------------------------------------------------------------
  -- providers / prompt
  -- ---------------------------------------------------------------------------
  provider = function()
    return policy.provider(ctx)
  end

  prompt_prefix = function()
    return policy.prompt_prefix(ctx)
  end

  -- ---------------------------------------------------------------------------
  -- buffers
  -- ---------------------------------------------------------------------------
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

  local function session_buffer_name(session)
    return policy.buffer_name_prefix .. tostring(session.id)
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
    buffer_guard.sync(bufnr, sync_panel or state.panels[state_key])
    return result
  end

  ensure_session_buffer = function(session)
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

  -- ---------------------------------------------------------------------------
  -- sessions
  -- ---------------------------------------------------------------------------
  local function ensure_sessions()
    load_sessions()
    store().sessions = store().sessions or {}
    store().next_session_id = store().next_session_id or 1
    return store().sessions
  end

  touch_session = function(session)
    if session then
      session.updated_at = now()
      if policy.on_touch then
        policy.on_touch(session)
      end
      schedule_save_sessions()
    end
  end

  -- Allocate a fresh session. `extra` supplies the policy-specific fields
  -- (chat: history/provider_workspaces; selection: key/selection/mode).
  local function new_session(extra)
    local sessions = ensure_sessions()
    local id = store().next_session_id
    store().next_session_id = id + 1
    local session = vim.tbl_extend("force", {
      id = id,
      provider = provider(),
      input_start = nil,
      input_active = false,
      busy = false,
      provider_sessions = {},
      created_at = now(),
      updated_at = now(),
    }, extra or {})
    ensure_session_buffer(session)
    table.insert(sessions, session)
    if policy.after_create then
      policy.after_create(session, ctx)
    end
    schedule_save_sessions()
    return session
  end

  get_session = function(id)
    if not id then
      return nil
    end
    for _, session in ipairs(ensure_sessions()) do
      if session.id == tonumber(id) then
        return session
      end
    end
    return nil
  end

  active_session = function()
    local session = get_session(store() and store().active_session_id)
    if session and policy.on_activate then
      policy.on_activate(session)
    end
    return session
  end

  local function ensure_active_session()
    if policy.ensure_active_session then
      return policy.ensure_active_session(ctx)
    end
    return active_session()
  end

  sync_active_panel_to_session = function()
    local panel = state.panels[state_key]
    local session = active_session()
    if not panel or not session then
      return
    end
    if panel.session_id ~= session.id then
      return
    end
    session.input_start = panel.input_start
    session.input_active = panel.input_active == true
    session.bufnr = panel.bufnr or session.bufnr
    if policy.sync_panel_touches then
      touch_session(session)
    end
  end

  local function panel_for_session(session)
    local panel = state.panels[state_key]
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

  -- ---------------------------------------------------------------------------
  -- window geometry / view
  -- ---------------------------------------------------------------------------
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
    return "nvime.nvim"
  end

  local function scroll_config()
    local dim = dimensions()
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
      footer = policy.footer,
      footer_pos = "center",
      zindex = policy.zindex,
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
      "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,WinBar:NvimeNormal"
    vim.wo[winid].winbar = "%{%v:lua.require'" .. module_name .. "'.winbar_text()%}"
  end

  local function extract_prompt_text(line)
    line = line or ""
    local modern = line:match("^%[[^%]]+%]%$%s*(.*)$")
    if modern then
      return modern
    end
    return vim.trim(line)
  end

  local function current_input_text_impl()
    local panel = state.panels[state_key]
    local bufnr = panel and panel.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return ""
    end
    local plnum = (panel.input_start or line_count(bufnr)) + INPUT_PROMPT_LINE - 1
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, plnum - 1, -1, false)
    if #all_lines == 0 then
      return ""
    end
    all_lines[1] = extract_prompt_text(all_lines[1])
    return table.concat(all_lines, "\n")
  end
  current_input_text = current_input_text_impl

  local function prompt_has_submit_text(panel)
    if not panel or not panel.input_bufnr or not vim.api.nvim_buf_is_valid(panel.input_bufnr) then
      return false
    end
    if not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
      return false
    end
    local lnum = panel.input_start or 1
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
    if not ok or cursor[1] < lnum then
      return false
    end
    local all_lines = vim.api.nvim_buf_get_lines(panel.input_bufnr, lnum - 1, -1, false)
    if #all_lines == 0 then
      return false
    end
    all_lines[1] = extract_prompt_text(all_lines[1])
    return vim.trim(table.concat(all_lines, "\n")) ~= ""
  end

  local function decorate_scrollback(bufnr)
    render.scrollback(bufnr, scroll_ns)
  end

  decorate_input = function(bufnr)
    policy.decorate_input(bufnr, ctx)
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

  scroll_to_bottom = function()
    local panel = state.panels[state_key]
    if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
      return
    end
    local target = math.max(1, (panel.input_start or line_count(panel.bufnr)))
    local col = 0
    if panel.input_active then
      local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
      if ok then
        col = cursor[2]
      end
    end
    vim.api.nvim_win_set_cursor(panel.winid, { target, col })
  end

  reset_input = function(text, opts)
    opts = opts or {}
    local panel = state.panels[state_key]
    local bufnr = panel and panel.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    text = text or ""
    local follow = opts.force_follow == true or should_auto_scroll(panel)
    local view = follow and nil or save_window_view(panel.winid)
    with_writable(bufnr, function()
      local start = panel.input_start
      local count = line_count(bufnr)
      if not start or start < 1 or start > count then
        local existing = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local fresh = count == 1 and existing[1] == ""
        if fresh and policy.seed_fresh_buffer then
          -- The streaming append assumes >= 2 blank lines above the prompt;
          -- seed the fresh buffer with that headroom so appends merge cleanly.
          local text_lines = vim.split(text or "", "\n", { plain = true })
          local seed = { "", "", prompt_prefix() .. (text_lines[1] or "") }
          for i = 2, #text_lines do
            seed[#seed + 1] = text_lines[i]
          end
          vim.api.nvim_buf_set_lines(bufnr, 0, count, false, seed)
          panel.input_start = 3
          return
        elseif fresh then
          start = 1
        else
          start = count + 1
        end
      end
      local text_lines = vim.split(text or "", "\n", { plain = true })
      local new_lines = { prompt_prefix() .. (text_lines[1] or "") }
      for i = 2, #text_lines do
        new_lines[#new_lines + 1] = text_lines[i]
      end
      vim.api.nvim_buf_set_lines(bufnr, start - 1, count, false, new_lines)
      panel.input_start = start
    end, decorate_input)
    if policy.after_reset then
      policy.after_reset(ctx)
    end
    if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      if follow then
        local prompt_lnum = panel.input_start + INPUT_PROMPT_LINE - 1
        pcall(vim.api.nvim_win_set_cursor, panel.winid, { prompt_lnum, #prompt_prefix() })
        pcall(vim.api.nvim_win_call, panel.winid, function()
          vim.fn.winrestview({ topline = math.max(1, prompt_lnum - vim.api.nvim_win_get_height(panel.winid) + 2) })
        end)
      else
        restore_window_view(panel.winid, view)
      end
    end
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
    local panel = state.panels[state_key]
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

  panel_is_open = function(session_id)
    local panel = state.panels[state_key]
    return panel
      and panel.winid
      and vim.api.nvim_win_is_valid(panel.winid)
      and (not session_id or panel.session_id == session_id)
  end

  local function completion_behavior()
    local ui_cfg = (state.config or {}).ui or {}
    if ui_cfg.completion == "open" or ui_cfg.completion == "popup" then
      return "open"
    end
    return "notify"
  end

  -- session may be nil; lane is optional (selection labels by lane).
  local function notify_finished(session, code, lane)
    if not session or panel_is_open(session.id) then
      return
    end
    state.last_session = { kind = policy.kind, id = session.id }
    if completion_behavior() == "open" then
      require(module_name).open_session(session.id)
      return
    end
    local level = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
    local status = code == 0 and "finished" or ("failed with code " .. tostring(code))
    local label = policy.finished_label and policy.finished_label(session, lane) or policy.kind
    vim.notify("nvime " .. label .. " " .. status .. ". Reopen with :NvimeLast or <leader>nn.", level)
  end

  local function in_input_window(panel)
    return panel
      and panel.input_active == true
      and panel.winid
      and vim.api.nvim_win_is_valid(panel.winid)
      and vim.api.nvim_get_current_win() == panel.winid
  end

  local function focus_scrollback()
    local panel = state.panels[state_key]
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
        local panel = state.panels[state_key]
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
      key = policy.guard_key,
      panel = function()
        return state.panels[state_key]
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
    local enter = policy.enter_input_method
    vim.keymap.set("n", "<CR>", function()
      if in_input_window(state.panels[state_key]) or prompt_has_submit_text(state.panels[state_key]) then
        require(module_name).submit_current()
      else
        require(module_name)[enter]()
      end
    end, opts)
    vim.keymap.set("n", "i", function()
      require(module_name)[enter]({ preserve_cursor = true })
    end, opts)
    vim.keymap.set("n", "I", function()
      require(module_name)[enter]()
    end, opts)
    vim.keymap.set("n", "a", function()
      require(module_name)[enter]({ preserve_cursor = true, after = true })
    end, opts)
    vim.keymap.set("n", "A", function()
      require(module_name)[enter]({ cursor = "eol", preserve_cursor = true })
    end, opts)
    vim.keymap.set("n", "o", function()
      require(module_name)[enter]({ cursor = "end" })
    end, opts)
    vim.keymap.set("n", "O", function()
      require(module_name)[enter]({ cursor = "end" })
    end, opts)
    vim.keymap.set("n", "p", function()
      provider_api.cycle({ scope = policy.provider_scope })
    end, opts)
    vim.keymap.set("n", "<Tab>", function()
      provider_api.cycle({ scope = policy.provider_scope })
    end, opts)
    vim.keymap.set("n", "P", function()
      provider_api.choose({ scope = policy.provider_scope })
    end, opts)
    vim.keymap.set("n", "m", function()
      provider_api.cycle_model({ scope = policy.provider_scope })
    end, opts)
    vim.keymap.set("n", "M", function()
      provider_api.choose_model({ scope = policy.provider_scope })
    end, opts)
    vim.keymap.set("n", "?", function()
      require(module_name).choose_prompt()
    end, opts)
    if policy.supports_mode_toggle then
      vim.keymap.set("n", "e", function()
        require(module_name).toggle_mode()
      end, opts)
    end
    vim.keymap.set("n", "<C-c>", function()
      require(module_name).cancel_active()
    end, opts)
    vim.keymap.set("i", "<CR>", function()
      vim.cmd.stopinsert()
    end, opts)
    vim.keymap.set("i", "<C-c>", function()
      vim.cmd.stopinsert()
      require(module_name).cancel_active()
    end, opts)
    local function insert_newline()
      local panel = state.panels[state_key]
      if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
        return
      end
      local winid = panel.winid
      if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
      end
      local row, col = unpack(vim.api.nvim_win_get_cursor(winid))
      if row < (panel.input_start or 1) then
        return
      end
      buffer_guard.suspend(panel.bufnr, function()
        vim.api.nvim_buf_set_text(panel.bufnr, row - 1, col, row - 1, col, { "", "" })
      end)
      buffer_guard.sync(panel.bufnr, panel)
      pcall(vim.api.nvim_win_set_cursor, winid, { row + 1, 0 })
      decorate_input(panel.bufnr)
    end
    vim.keymap.set("i", "<C-j>", insert_newline, opts)
    vim.keymap.set("i", "<S-CR>", insert_newline, opts)
    vim.keymap.set("i", "<C-CR>", insert_newline, opts)
    vim.keymap.set("i", "<C-U>", function()
      local panel = state.panels[state_key]
      if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
        return
      end
      local lnum = prompt_lnum(panel)
      local prefix = prompt_prefix()
      buffer_guard.suspend(panel.bufnr, function()
        vim.api.nvim_buf_set_lines(panel.bufnr, lnum - 1, -1, false, { prefix })
      end)
      buffer_guard.sync(panel.bufnr, panel)
      if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
        pcall(vim.api.nvim_win_set_cursor, panel.winid, { lnum, #prefix })
      end
    end, opts)
    vim.keymap.set("n", "<Esc>", function()
      focus_scrollback()
    end, opts)
    vim.keymap.set("n", "q", close_panel, opts)
  end

  -- ---------------------------------------------------------------------------
  -- open / refresh
  -- ---------------------------------------------------------------------------
  function P.open(opts)
    opts = opts or {}
    ui.ensure_highlights()
    delete_named_buffer(policy.input_buffer_name)
    sync_active_panel_to_session()

    local session = policy.resolve_session(opts, ctx)
    if not session then
      return nil
    end

    local panel = state.panels[state_key] or {}
    local was_open = panel.winid and vim.api.nvim_win_is_valid(panel.winid)
    if panel.input_winid and panel.input_winid ~= panel.winid and vim.api.nvim_win_is_valid(panel.input_winid) then
      pcall(vim.api.nvim_win_close, panel.input_winid, true)
    end
    local scroll_buf = ensure_session_buffer(session)

    local scroll_win =
      open_or_configure_window(scroll_buf, panel.winid, scroll_config(), configure_scrollback_window, true)

    state.panels[state_key] = {
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
    if not state.panels[state_key].input_active then
      set_locked(scroll_buf, true)
    end
    decorate_scrollback(scroll_buf)
    decorate_input(scroll_buf)

    if opts.focus_input then
      require(module_name)[policy.enter_input_method]()
    end

    return scroll_buf
  end

  function P.refresh(bufnr)
    local panel = state.panels[state_key]
    if not panel then
      return
    end
    if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      vim.api.nvim_win_set_config(panel.winid, scroll_config())
      configure_scrollback_window(panel.winid)
    end
    bufnr = bufnr or panel.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      refresh_header(bufnr)
    end
    reset_input(current_input_text())
    if not panel.input_active then
      set_locked(panel.bufnr, true)
    end
    sync_active_panel_to_session()
  end

  function P.close()
    close_panel()
  end

  -- ---------------------------------------------------------------------------
  -- spinner
  -- ---------------------------------------------------------------------------
  local function stop_spinner_timer()
    if spinner_timer then
      spinner_timer:stop()
      spinner_timer:close()
      spinner_timer = nil
    end
  end

  -- Flush a targeted repaint of a single window. Used after timer-driven
  -- extmark updates, which otherwise don't reach the screen until some other
  -- event (e.g. cursor movement) triggers a redraw.
  local function force_redraw(winid)
    if not winid or not vim.api.nvim_win_is_valid(winid) then
      return
    end
    if vim.api.nvim__redraw then
      pcall(vim.api.nvim__redraw, { win = winid, flush = true })
    end
  end

  refresh_input_indicator = function()
    local panel = state.panels[state_key]
    if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
      return
    end
    decorate_input(panel.bufnr)
  end

  ensure_spinner_timer = function()
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
        local panel = state.panels[state_key]
        local open = panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid)
        if not session or not session.busy or not open then
          stop_spinner_timer()
          refresh_input_indicator()
          force_redraw(panel and panel.winid)
          return
        end
        refresh_input_indicator()
        -- The status spinner lives in virt_lines extmarks. Unlike buffer-line
        -- edits, extmark changes from a timer tick don't force a screen flush,
        -- so the frame looks frozen until the next cursor move. Nudge the panel
        -- window to repaint each tick.
        force_redraw(panel.winid)
      end)
    end)
  end

  function P.set_busy(value, session_id)
    if vim.in_fast_event and vim.in_fast_event() then
      vim.schedule(function()
        P.set_busy(value, session_id)
      end)
      return
    end
    local session = session_id and get_session(session_id) or ensure_active_session()
    if session then
      session.busy = value == true
      if not session.busy then
        session.progress = nil
      else
        ensure_spinner_timer()
      end
      touch_session(session)
    end
    if policy.on_set_busy then
      policy.on_set_busy(value == true)
    end
    if not session_id or (store() and store().active_session_id == session_id) then
      refresh_input_indicator()
    end
    spinner.update()
  end

  function P.set_progress(text, session_id)
    if vim.in_fast_event and vim.in_fast_event() then
      vim.schedule(function()
        P.set_progress(text, session_id)
      end)
      return
    end
    local compact = progress.compact(text)
    if compact == "" then
      return
    end
    local session = session_id and get_session(session_id) or ensure_active_session()
    if not session then
      return
    end
    session.progress = compact
    touch_session(session)
    if store() and store().active_session_id == session.id then
      refresh_input_indicator()
    end
    spinner.update()
  end

  -- ---------------------------------------------------------------------------
  -- streaming append (scrollback)
  -- ---------------------------------------------------------------------------
  append_scrollback = function(text, session_id)
    if not text or text == "" then
      return
    end
    if vim.in_fast_event and vim.in_fast_event() then
      vim.schedule(function()
        append_scrollback(text, session_id)
      end)
      return
    end

    local session = session_id and get_session(session_id) or ensure_active_session()
    if not session then
      return
    end
    local bufnr = ensure_session_buffer(session)
    if not bufnr then
      return
    end

    vim.schedule(function()
      local panel = panel_for_session(session)
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
      if not panel.input_active then
        set_locked(bufnr, true)
      end
      local active_panel = state.panels[state_key]
      if
        store()
        and store().active_session_id == session.id
        and active_panel
        and active_panel.session_id == session.id
      then
        active_panel.input_start = session.input_start
        if policy.on_append_synced then
          policy.on_append_synced(session)
        end
        if follow then
          scroll_to_bottom()
        else
          restore_window_view(panel.winid, view)
        end
      end
    end)
  end

  -- ---------------------------------------------------------------------------
  -- process tracking / cancel
  -- ---------------------------------------------------------------------------
  local function clear_session_process(session, handle)
    if not session then
      return
    end
    if not handle or session.process == handle then
      session.process = nil
      state.running[policy.kind .. ":" .. tostring(session.id)] = nil
    end
  end

  local function remember_session_process(session, handle, meta)
    if not session or not handle then
      return
    end
    session.process = handle
    state.running[policy.kind .. ":" .. tostring(session.id)] = vim.tbl_extend("force", {
      kind = policy.kind,
      id = session.id,
      handle = handle,
    }, meta or {})
  end

  local function kill_process(handle)
    if not handle or type(handle.kill) ~= "function" then
      return false
    end
    local ok = pcall(handle.kill, handle, "sigterm")
    if not ok then
      ok = pcall(handle.kill, handle, 15)
    end
    return ok
  end

  function P.attach_process(session_id, handle, meta)
    local session = session_id and get_session(session_id) or active_session()
    remember_session_process(session, handle, meta)
  end

  function P.clear_process(session_id, handle)
    local session = session_id and get_session(session_id) or active_session()
    clear_session_process(session, handle)
  end

  function P.cancel_session(session_id)
    local session = session_id and get_session(session_id) or active_session()
    if not session or not session.busy then
      return false
    end
    session.cancelled = true
    local handle = session.process
    if handle then
      session.cancelled_handles = session.cancelled_handles or {}
      session.cancelled_handles[handle] = true
    end
    clear_session_process(session, handle)
    kill_process(handle)
    session.busy = false
    session.progress = nil
    touch_session(session)
    local event = vim.tbl_extend("force", {
      event = "agent_cancelled",
      kind = policy.kind,
      session_id = session.id,
    }, policy.cancel_audit_extra and policy.cancel_audit_extra(session) or {})
    require("nvime.audit").write(event)
    P.append((policy.cancel_message and policy.cancel_message(session)) or "\n[nvime] cancelled.\n", session.id)
    if store().active_session_id == session.id then
      refresh_input_indicator()
    end
    spinner.update()
    return true
  end

  function P.cancel_active()
    return P.cancel_session(store() and store().active_session_id)
  end

  function P.cancel_all()
    local count = 0
    for _, session in ipairs(ensure_sessions()) do
      if P.cancel_session(session.id) then
        count = count + 1
      end
    end
    return count
  end

  -- Default streaming append; chat wraps this (fast-event guard already inside).
  function P.append(text, session_id)
    append_scrollback(text, session_id)
  end

  -- ---------------------------------------------------------------------------
  -- session list surface
  -- ---------------------------------------------------------------------------
  function P.active_session_id()
    return store() and store().active_session_id
  end

  function P.is_open(session_id)
    return panel_is_open(session_id)
  end

  function P.get_session(id)
    return get_session(id)
  end

  function P.sessions()
    local items = {}
    for _, session in ipairs(ensure_sessions()) do
      items[#items + 1] = public_session(session)
    end
    table.sort(items, function(left, right)
      if (left.updated_at or 0) == (right.updated_at or 0) then
        return (left.id or 0) > (right.id or 0)
      end
      return (left.updated_at or 0) > (right.updated_at or 0)
    end)
    return items
  end

  function P.session_count()
    return #ensure_sessions()
  end

  function P.save_sessions()
    P.flush_sessions()
  end

  function P.flush_sessions()
    save_pending = false
    save_sessions_now()
  end

  function P.reload_sessions()
    sessions_loaded = false
    store().sessions = {}
    store().next_session_id = 1
    store().active_session_id = nil
    if policy.reset_extra_state then
      policy.reset_extra_state(store())
    end
    load_sessions()
    return store().sessions
  end

  function P.sessions_path()
    return sessions_path()
  end

  function P.rename_session(id, title_text)
    local session = get_session(id)
    if not session then
      return false
    end
    title_text = vim.trim(title_text or "")
    if title_text == "" then
      return false
    end
    session.title = title_text
    touch_session(session)
    save_sessions_now()
    return true
  end

  function P.delete_sessions(ids)
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
        if store().active_session_id == session.id then
          store().active_session_id = nil
          if policy.on_delete_active then
            policy.on_delete_active(session)
          end
          local panel = state.panels[state_key]
          if panel and panel.session_id == session.id and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
            pcall(vim.api.nvim_win_close, panel.winid, true)
          end
          state.panels[state_key] = nil
        end
        if state.last_session and state.last_session.kind == policy.kind and state.last_session.id == session.id then
          state.last_session = nil
        end
      else
        kept[#kept + 1] = session
      end
    end
    store().sessions = kept
    if policy.after_delete then
      policy.after_delete(store(), ctx)
    end
    if deleted > 0 then
      save_sessions_now()
    end
    return deleted
  end

  function P.winbar_text()
    ui.ensure_highlights()
    local session = active_session()
    local provider_name = (session and session.provider) or provider()
    local provider_hl = provider_name == "claude" and "NvimeProviderClaude" or "NvimeProviderCodex"
    local busy = session and session.busy
    local status_hl = busy and "NvimeStatusRunning" or "NvimeStatusIdle"
    local status_text = busy and (render.spinner_text() .. " running") or (ui.icon("idle") .. " idle")
    local lane = policy.winbar_lane(session, ctx)
    local provider_display = policy.winbar_provider and policy.winbar_provider(session, provider_name) or provider_name

    local nvime_label = " nvime.nvim "
    local version_label = " " .. version.label() .. " "
    local sep = "  "
    local visible = nvime_label .. sep .. version_label .. sep .. provider_display .. sep .. lane .. sep .. status_text
    local visible_width = vim.fn.strdisplaywidth(visible)

    local panel = state.panels[state_key]
    local win_width = vim.o.columns
    if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      win_width = vim.api.nvim_win_get_width(panel.winid)
    end
    local pad = math.max(0, math.floor((win_width - visible_width) / 2))

    return string.rep(" ", pad)
      .. "%#NvimeHeaderBlock#"
      .. nvime_label
      .. "%*"
      .. sep
      .. "%#NvimeHeaderBlockSecondary#"
      .. version_label
      .. "%*"
      .. sep
      .. "%#"
      .. provider_hl
      .. "#"
      .. provider_display
      .. "%*"
      .. sep
      .. "%#NvimeMuted#"
      .. lane
      .. "%*"
      .. sep
      .. "%#"
      .. status_hl
      .. "#"
      .. status_text
      .. "%*"
  end

  local function mark_provider_session(session, provider_name, provider_session_id)
    if not provider_session_id or provider_session_id == "" then
      return
    end
    session = session or ensure_active_session()
    if not session then
      return
    end
    session.provider_sessions = session.provider_sessions or {}
    session.provider_sessions[provider_name] = provider_session_id
    touch_session(session)
  end

  -- ---------------------------------------------------------------------------
  -- ctx: internal helpers for the owning module's bespoke flows
  -- ---------------------------------------------------------------------------
  ctx.state = state
  ctx.store = store
  ctx.policy = policy
  ctx.now = now
  ctx.SESSION_VERSION = SESSION_VERSION
  ctx.INPUT_PROMPT_LINE = INPUT_PROMPT_LINE
  ctx.scroll_ns = scroll_ns
  ctx.input_ns = input_ns
  ctx.get_session = get_session
  ctx.active_session = active_session
  ctx.ensure_active_session = ensure_active_session
  ctx.ensure_sessions = ensure_sessions
  ctx.ensure_session_buffer = ensure_session_buffer
  ctx.session_buffer_name = session_buffer_name
  ctx.new_session = new_session
  ctx.touch_session = touch_session
  ctx.schedule_save_sessions = schedule_save_sessions
  ctx.save_sessions_now = save_sessions_now
  ctx.panel = function()
    return state.panels[state_key]
  end
  ctx.panel_for_session = panel_for_session
  ctx.panel_is_open = panel_is_open
  ctx.sync_active_panel_to_session = sync_active_panel_to_session
  ctx.reset_input = reset_input
  ctx.current_input_text = current_input_text
  ctx.scroll_to_bottom = scroll_to_bottom
  ctx.append_scrollback = append_scrollback
  ctx.set_locked = set_locked
  ctx.with_writable = with_writable
  ctx.decorate_scrollback = decorate_scrollback
  ctx.decorate_input = decorate_input
  ctx.refresh_input_indicator = refresh_input_indicator
  ctx.ensure_spinner_timer = ensure_spinner_timer
  ctx.prompt_prefix = prompt_prefix
  ctx.prompt_end_col = prompt_end_col
  ctx.prompt_lnum = prompt_lnum
  ctx.extract_prompt_text = extract_prompt_text
  ctx.prompt_has_submit_text = prompt_has_submit_text
  ctx.in_input_window = in_input_window
  ctx.focus_scrollback = focus_scrollback
  ctx.line_count = line_count
  ctx.save_window_view = save_window_view
  ctx.restore_window_view = restore_window_view
  ctx.should_auto_scroll = should_auto_scroll
  ctx.provider = provider
  ctx.mark_provider_session = mark_provider_session
  ctx.remember_session_process = remember_session_process
  ctx.clear_session_process = clear_session_process
  ctx.notify_finished = notify_finished
  ctx.spinner_text = render.spinner_text
  ctx.render = render
  ctx.progress = progress

  P.ctx = ctx
  return P
end

return M
