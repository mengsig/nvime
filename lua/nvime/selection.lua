-- nvime.selection
--
-- Ask/edit/discuss panel for a highlighted code range. The scratch-buffer
-- panel mechanism (persistence, window, input guard, spinner, streaming
-- append, session list surface) lives in nvime.panel; this module supplies
-- the selection-specific policy (sessions keyed by file+range, ask/edit/
-- discuss modes, last_ask handoff, choose_session) and the bespoke
-- prompt/submit flow.

local panel = require("nvime.panel")
local prompts = require("nvime.prompts")
local state = require("nvime.state")

local M = {}

-- Forward refs: the panel instance and its internal helper table. Assigned
-- right after panel.create() returns, before any policy/module function runs.
local P, ctx

local function mode()
  return (state.selection and state.selection.mode) or "selection"
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

function M.same_range(left, right)
  if not left or not right then
    return false
  end
  return left.path == right.path
    and tonumber(left.line1) == tonumber(right.line1)
    and tonumber(left.line2) == tonumber(right.line2)
end

local function create_session(selection, key)
  return ctx.new_session({
    key = key or selection_key(selection),
    selection = M.snapshot(selection),
    mode = "selection",
  })
end

local function session_for_selection(selection, opts)
  opts = opts or {}
  if not selection then
    return nil
  end
  local key = selection_key(selection)
  if not opts.new_session then
    for _, session in ipairs(ctx.ensure_sessions()) do
      if session.key == key then
        session.selection = M.snapshot(selection)
        session.provider_sessions = session.provider_sessions or {}
        ctx.touch_session(session)
        return session
      end
    end
  end
  return create_session(selection, key)
end

-- ---------------------------------------------------------------------------
-- policy
-- ---------------------------------------------------------------------------
local policy = {
  kind = "selection",
  state_key = "selection",
  ns_prefix = "nvime.selection",
  augroup_name = "nvime.selection.focus",
  guard_key = "nvime_selection_guard_attached",
  module_name = "nvime.selection",
  input_buffer_name = "nvime://selection-input",
  buffer_name_prefix = "nvime://selection/",
  footer = " i input | e ask⇄edit | ? prompts | <CR> send | p provider | m model | q close ",
  zindex = 52,
  supports_mode_toggle = true,
  provider_scope = "selection",
  enter_input_method = "focus_input",
  persist_filename = "selection-sessions.json",
  persist_error_label = "sessions",
  newer_version_label = "nvime selection sessions were written by a newer nvime version:",
  seed_fresh_buffer = true,

  provider = function()
    return (state.selection and state.selection.provider) or (state.config and state.config.provider) or "claude"
  end,

  prompt_prefix = function(c)
    return "[" .. c.provider() .. " " .. mode() .. "]$ "
  end,

  serialize_session = function(session, persisted_lines)
    return {
      id = session.id,
      key = session.key,
      title = session.title,
      selection = persisted_selection(session.selection),
      provider = session.provider,
      mode = session.mode,
      last_run_mode = session.last_run_mode,
      input_start = session.input_start,
      provider_sessions = session.provider_sessions or {},
      last_ask = persisted_last_ask(session.last_ask),
      lines = persisted_lines(session),
      created_at = session.created_at,
      updated_at = session.updated_at,
    }
  end,

  item_is_valid = function(item)
    return item.selection ~= nil
  end,

  normalize_item = function(item)
    if type(item.selection) == "table" then
      item.selection.bufnr = nil
    end
    if type(item.last_ask) == "table" and type(item.last_ask.selection) == "table" then
      item.last_ask.selection.bufnr = nil
    end
    item.provider_sessions = type(item.provider_sessions) == "table" and item.provider_sessions or {}
    item.lines = type(item.lines) == "table" and item.lines or nil
    item.pending_input = nil
  end,

  on_set_busy = function(value)
    state.selection.busy = value
  end,

  decorate_input = function(bufnr, c)
    local p = c.panel()
    if not p or not p.input_start then
      return
    end
    local busy_status = nil
    local session = c.active_session()
    if session and session.busy then
      local provider_name = session.provider or "agent"
      local detail = c.progress.compact(session.progress or "")
      detail = detail:gsub("^" .. vim.pesc(provider_name) .. "%s*", "")
      if detail == "" then
        detail = "working"
      end
      busy_status = c.render.spinner_text() .. "  " .. detail
    end
    c.render.input(bufnr, c.input_ns, c.prompt_prefix(), p.input_start, { busy_status = busy_status })
  end,

  resolve_session = function(opts, c)
    local session = nil
    if opts.session_id then
      session = c.get_session(opts.session_id)
    elseif opts.selection then
      session = session_for_selection(opts.selection, { new_session = opts.new_session == true })
    else
      session = c.active_session()
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
    c.touch_session(session)

    state.selection.active_session_id = session.id
    state.last_session = { kind = "selection", id = session.id }
    state.selection.mode = session.mode
    state.selection.provider = session.provider
    state.selection.active_selection = session.selection
    state.selection.pending_input = session.pending_input
    return session
  end,

  cancel_message = function(session)
    return "\n[nvime] " .. (session.mode or "selection") .. " cancelled.\n"
  end,

  cancel_audit_extra = function(session)
    return { mode = session.mode }
  end,

  finished_label = function(_, lane)
    return lane or "selection"
  end,

  winbar_lane = function(session)
    return (session and session.mode) or mode()
  end,

  winbar_provider = function(session, provider_name)
    local model_name = (session and session.model) or (state.selection and state.selection.model)
    return model_name and (provider_name .. "/" .. model_name) or provider_name
  end,

  on_delete_active = function()
    state.selection.pending_input = nil
  end,

  reset_extra_state = function(store)
    store.pending_input = nil
  end,
}

P = panel.create(policy)
ctx = P.ctx

-- ---------------------------------------------------------------------------
-- shared surface
-- ---------------------------------------------------------------------------
M.open = P.open
M.refresh = P.refresh
M.close = P.close
M.set_busy = P.set_busy
M.set_progress = P.set_progress
M.append = P.append
M.cancel_session = P.cancel_session
M.cancel_active = P.cancel_active
M.cancel_all = P.cancel_all
M.attach_process = P.attach_process
M.clear_process = P.clear_process
M.sessions = P.sessions
M.session_count = P.session_count
M.save_sessions = P.save_sessions
M.flush_sessions = P.flush_sessions
M.reload_sessions = P.reload_sessions
M.sessions_path = P.sessions_path
M.is_open = P.is_open
M.active_session_id = P.active_session_id
M.get_session = P.get_session
M.rename_session = P.rename_session
M.delete_sessions = P.delete_sessions
M.winbar_text = P.winbar_text

-- ---------------------------------------------------------------------------
-- selection-specific surface
-- ---------------------------------------------------------------------------
function M.append_user(provider_name, lane, text, session_id)
  M.append("\n\n[" .. provider_name .. " " .. lane .. "]$ " .. text .. "\n\n", session_id)
end

function M.append_response_header(provider_name, lane, session_id)
  M.append("[" .. provider_name .. " " .. lane .. " response]\n\n", session_id)
end

function M.notify_finished(lane, session_id, code)
  local session = session_id and ctx.get_session(session_id) or ctx.active_session()
  ctx.notify_finished(session, code or 0, lane)
end

-- Record the lane of the agent run a session most recently launched. A resumed
-- provider conversation carries the SYSTEM/persona framing of that last run, so
-- callers (edit.run_edit) use this — not the display `mode`, which a UI toggle
-- can flip ahead of any run — to decide whether the resumed agent still thinks
-- it is read-only and needs the full edit contract re-established.
function M.mark_run_mode(session_id, run_mode)
  local session = session_id and ctx.get_session(session_id) or ctx.active_session()
  if session then
    session.last_run_mode = run_mode
    ctx.touch_session(session)
  end
end

function M.last_run_mode(session_id)
  local session = session_id and ctx.get_session(session_id) or ctx.active_session()
  return session and session.last_run_mode or nil
end

function M.matching_sessions(selection)
  local key = selection_key(selection)
  local matches = {}
  if not key then
    return matches
  end
  for _, session in ipairs(ctx.ensure_sessions()) do
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

function M.prompt(opts)
  opts = opts or {}
  local session = opts.session_id and ctx.get_session(opts.session_id) or nil
  if not session and opts.selection then
    session = session_for_selection(opts.selection, { new_session = opts.new_session == true })
  end
  if not session then
    session = ctx.active_session()
  end
  if not session then
    vim.notify("No nvime selection discussion is open", vim.log.levels.INFO)
    return
  end
  local next_provider = opts.provider or session.provider or ctx.provider()
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
  ctx.touch_session(session)

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
  ctx.reset_input("")
end

function M.insert_prompt(text)
  text = vim.trim(text or "")
  M.open()
  ctx.reset_input(text, { force_follow = true })
end

-- Append `text` to whatever is staged in a selection discussion's input,
-- preserving the in-progress prompt. `session_id` targets a specific session
-- (used by nvime.send to reach the last-opened conversation); omit to use the
-- active one. Mirrors nvime.chat.append_prompt.
function M.append_prompt(text, session_id)
  text = vim.trim(text or "")
  if text == "" then
    return
  end
  if session_id and ctx.get_session(session_id) then
    M.open_session(session_id)
  else
    M.open()
  end
  local existing = vim.trim(ctx.current_input_text() or "")
  local combined = existing ~= "" and (existing .. "\n" .. text) or text
  ctx.reset_input(combined, { force_follow = true })
end

-- Switch the active selection chat between ask (read-only) and edit modes in
-- place, keeping the same session, selection, provider, and any prompt you've
-- already typed. Bound to `e` in the panel.
function M.toggle_mode()
  local session = ctx.active_session()
  if not session then
    vim.notify("nvime: no selection chat open to switch", vim.log.levels.INFO)
    return
  end
  if session.busy then
    vim.notify("nvime: wait for the current run to finish before switching modes", vim.log.levels.WARN)
    return
  end
  local current = (session.mode == "edit") and "edit" or "ask"
  local next_mode = (current == "ask") and "edit" or "ask"
  local selection = session.selection
  if not selection then
    vim.notify("nvime: this chat has no selection to switch", vim.log.levels.INFO)
    return
  end
  local provider = session.provider
  local session_id = session.id
  -- Preserve whatever is staged so toggling never eats an in-progress prompt.
  local staged = vim.trim(ctx.current_input_text() or "")

  if next_mode == "edit" then
    require("nvime.edit").arm_prompt(selection, provider, session_id)
  else
    require("nvime.ask").arm_prompt(selection, provider, session_id)
  end
  if staged ~= "" then
    ctx.reset_input(staged, { force_follow = true })
  end
  vim.notify(
    "nvime: " .. next_mode .. (next_mode == "ask" and " (read-only)" or " (can edit files)"),
    vim.log.levels.INFO
  )
end

function M.choose_prompt()
  prompts.choose("selection", function(text, lane)
    if lane and lane ~= "" then
      local session = ctx.active_session()
      if session then
        session.pending_lane = lane
      end
      state.selection.pending_lane = lane
    end
    M.insert_prompt(text)
  end)
end

function M.focus_input(opts)
  opts = opts or {}
  local saved_cursor
  if opts.preserve_cursor then
    local p = ctx.panel()
    if p and p.winid and vim.api.nvim_win_is_valid(p.winid) then
      local ok, cur = pcall(vim.api.nvim_win_get_cursor, p.winid)
      if ok then
        saved_cursor = cur
      end
    end
  end
  M.open()
  local p = ctx.panel()
  if not p or not p.winid or not vim.api.nvim_win_is_valid(p.winid) then
    return
  end
  p.input_active = true
  ctx.set_locked(p.input_bufnr, false)
  vim.api.nvim_set_current_win(p.winid)
  local lnum = ctx.prompt_lnum(p)
  local prefix_col = #ctx.prompt_prefix()
  local end_col = ctx.prompt_end_col(p)
  if saved_cursor then
    if saved_cursor[1] >= lnum and (saved_cursor[1] > lnum or saved_cursor[2] >= prefix_col) then
      if opts.cursor == "eol" then
        local line = vim.api.nvim_buf_get_lines(p.input_bufnr, saved_cursor[1] - 1, saved_cursor[1], false)[1] or ""
        pcall(vim.api.nvim_win_set_cursor, p.winid, { saved_cursor[1], #line })
        pcall(vim.cmd, "startinsert!")
      elseif opts.after then
        local line = vim.api.nvim_buf_get_lines(p.input_bufnr, saved_cursor[1] - 1, saved_cursor[1], false)[1] or ""
        local col = math.min(saved_cursor[2] + 1, #line)
        pcall(vim.api.nvim_win_set_cursor, p.winid, { saved_cursor[1], col })
        pcall(vim.cmd, col >= #line and "startinsert!" or "startinsert")
      else
        pcall(vim.api.nvim_win_set_cursor, p.winid, saved_cursor)
        pcall(vim.cmd, "startinsert")
      end
      return
    end
  end
  local append = opts.cursor == "end" or opts.cursor == "eol"
  local empty_prompt = end_col <= prefix_col
  local col = (append or empty_prompt) and math.max(0, end_col - 1) or prefix_col
  pcall(vim.api.nvim_win_set_cursor, p.winid, { lnum, col })
  pcall(vim.api.nvim_win_call, p.winid, function()
    vim.fn.winrestview({ topline = math.max(1, lnum - vim.api.nvim_win_get_height(p.winid) + 2) })
  end)
  pcall(vim.cmd, (append or empty_prompt) and "startinsert!" or "startinsert")
end

function M.submit_current()
  local session = ctx.active_session()
  local pending = (session and session.pending_input) or state.selection.pending_input
  if not pending or type(pending.on_submit) ~= "function" then
    M.focus_input()
    return
  end

  local p = ctx.panel()
  local lnum = ctx.prompt_lnum(p)
  local total = ctx.line_count(p.input_bufnr)
  local lines = vim.api.nvim_buf_get_lines(p.input_bufnr, lnum - 1, total, false)
  if lines and #lines > 0 then
    lines[1] = ctx.extract_prompt_text(lines[1])
  end
  local text = vim.trim(table.concat(lines or {}, "\n"))
  ctx.reset_input("")
  if text == "" then
    M.focus_input()
    return
  end
  local on_submit = pending.on_submit
  local selected_provider = state.selection.provider or pending.provider
  local lane = (session and session.pending_lane) or state.selection.pending_lane
  if session then
    session.pending_input = nil
    session.pending_lane = nil
    ctx.touch_session(session)
  end
  state.selection.pending_input = nil
  state.selection.pending_lane = nil
  on_submit(text, selected_provider, lane)
end

function M.open_session(id, opts)
  opts = opts or {}
  local session = ctx.get_session(id)
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
  local provider_name = opts.provider or ctx.provider()
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
  local session = ctx.get_session(session_id)
  if not session then
    return
  end
  session.provider_sessions = session.provider_sessions or {}
  session.provider_sessions[provider_name] = provider_session_id
  ctx.touch_session(session)
end

function M.agent_run_opts(session_id, provider_name)
  local session = ctx.get_session(session_id)
  local resume_id = session and session.provider_sessions and session.provider_sessions[provider_name] or nil
  local cumulative_key = provider_name .. "_cumulative_usage"
  local prev_cumulative = session and session[cumulative_key] or nil
  return {
    persist_session = true,
    resume_session_id = resume_id,
    previous_cumulative_usage = prev_cumulative,
    on_session_id = function(provider_session_id)
      M.mark_provider_session(session_id, provider_name, provider_session_id)
    end,
    on_cumulative_usage = function(cumulative)
      if session and cumulative then
        session[cumulative_key] = cumulative
      end
    end,
  }
end

function M.mark_last_ask(session_id, ask)
  local session = ctx.get_session(session_id)
  if session then
    session.last_ask = ask
    ctx.touch_session(session)
  end
  state.selection.last_ask = ask
end

function M.last_ask_for(selection)
  if selection then
    for _, session in ipairs(ctx.ensure_sessions()) do
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
