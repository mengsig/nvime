-- nvime.chat
--
-- General chat/review conversation panel. The scratch-buffer panel mechanism
-- (persistence, window, input guard, spinner, streaming append, session list
-- surface) lives in nvime.panel; this module supplies the chat-specific policy
-- (freeform conversation sessions, the flat `state.chat.*` legacy mirror,
-- review/docs lane, hand-rolled input decoration) and the bespoke
-- submit/prompt flow that drives the provider agent.

local agents = require("nvime.agents")
local panel = require("nvime.panel")
local prompts = require("nvime.prompts")
local spinner = require("nvime.spinner")
local state = require("nvime.state")
local usage = require("nvime.usage")

local M = {}

-- Forward refs, assigned right after panel.create() returns.
local P, ctx

local function chat_config()
  return ((state.config or {}).chat or {})
end

-- The flat `state.chat.*` fields are a legacy mirror that other modules
-- (agents/usage/dashboard) still read. We keep them in sync with the active
-- session's fields whenever it changes.
local function sync_legacy_to_session(session)
  if not session then
    return
  end
  if state.chat._legacy_session_id ~= session.id then
    return
  end
  if type(state.chat.history) == "table" and state.chat.history ~= session.history then
    session.history = state.chat.history
  end
  if type(state.chat.provider_sessions) == "table" and state.chat.provider_sessions ~= session.provider_sessions then
    session.provider_sessions = state.chat.provider_sessions
  end
  if
    type(state.chat.provider_workspaces) == "table" and state.chat.provider_workspaces ~= session.provider_workspaces
  then
    session.provider_workspaces = state.chat.provider_workspaces
  end
  if state.chat.last_provider ~= nil and state.chat.last_provider ~= session.last_provider then
    session.last_provider = state.chat.last_provider
  end
end

local function sync_session_to_legacy(session)
  if not session then
    return
  end
  state.chat.history = session.history or {}
  state.chat.provider_sessions = session.provider_sessions or {}
  state.chat.provider_workspaces = session.provider_workspaces or {}
  state.chat.last_provider = session.last_provider
  state.chat.provider = session.provider
  state.chat.busy = session.busy == true
  state.chat.progress = session.progress
  state.chat._legacy_session_id = session.id
end

local function summarize_title(text)
  text = vim.trim((text or ""):gsub("%s+", " "))
  if text == "" then
    return nil
  end
  if #text > 58 then
    text = text:sub(1, 55) .. "..."
  end
  return text
end

local function create_session(opts)
  opts = opts or {}
  return ctx.new_session({
    provider = opts.provider or (state.config and state.config.provider) or "claude",
    title = opts.title,
    history = {},
    provider_workspaces = {},
    last_provider = nil,
  })
end

local function append_user_message(bufnr, text, session)
  local p = ctx.panel_for_session(session)
  ctx.with_writable(bufnr, function()
    local insert_at = math.max(0, (p.input_start or (ctx.line_count(bufnr) + 1)) - 1)
    local text_lines = vim.split(text or "", "\n", { plain = true })
    local lines = { "", ctx.prompt_prefix() .. (text_lines[1] or "") }
    for i = 2, #text_lines do
      lines[#lines + 1] = text_lines[i]
    end
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
    p.input_start = insert_at + #lines + 1
    if session then
      session.input_start = p.input_start
      ctx.touch_session(session)
    end
  end, ctx.decorate_scrollback, p)
  if not p.input_active then
    ctx.set_locked(bufnr, true)
  end
  if session and state.chat.active_session_id == session.id then
    state.panels.chat.input_start = session.input_start
    ctx.scroll_to_bottom()
  end
end

local function append_response_header(bufnr, session)
  local p = ctx.panel_for_session(session)
  ctx.with_writable(bufnr, function()
    local insert_at = math.max(0, (p.input_start or (ctx.line_count(bufnr) + 1)) - 1)
    local lines = {
      "",
      "[" .. ctx.provider() .. " response]",
      "",
    }
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
    p.input_start = insert_at + #lines + 1
    if session then
      session.input_start = p.input_start
      ctx.touch_session(session)
    end
  end, ctx.decorate_scrollback, p)
  if not p.input_active then
    ctx.set_locked(bufnr, true)
  end
  if session and state.chat.active_session_id == session.id then
    state.panels.chat.input_start = session.input_start
    ctx.scroll_to_bottom()
  end
end

local function trim_history(session)
  session = session or ctx.ensure_active_session()
  local max = chat_config().max_history_messages or 24
  session.history = session.history or {}
  while #session.history > max do
    table.remove(session.history, 1)
  end
  sync_session_to_legacy(session)
end

local function append_transcript(lines, session)
  session = session or ctx.ensure_active_session()
  lines[#lines + 1] = "Conversation so far:"
  if #(session.history or {}) == 0 then
    lines[#lines + 1] = "(empty)"
  else
    for _, message in ipairs(session.history or {}) do
      lines[#lines + 1] = string.upper(message.role) .. ": " .. message.content
    end
  end
end

local function build_conversation_prompt(text, opts)
  opts = opts or {}
  local session = opts.session or ctx.ensure_active_session()
  local markdown_policy = "Markdown writes are disabled in this lane."
  if ((state.config or {}).review or {}).allow_markdown_writes == true then
    markdown_policy =
      "You may create or update Markdown documentation files only (*.md, *.markdown). Do not edit source/config files directly."
  end
  local shell_policy = "Shell commands are disabled."
  if ((state.config or {}).review or {}).allow_shell == true then
    shell_policy = "You may run shell commands, including curl, for inspection, external docs, and tests."
  end
  local web_policy = "Native web fetch/search tools are disabled."
  if ((state.config or {}).review or {}).allow_web ~= false then
    web_policy = "You may use web fetch/search tools for external documentation and current information."
  end

  local lines = {
    "NVIME CHAT MODE.",
    "You are the side agent inside Neovim.",
    "You may answer questions, review code, and suggest changes.",
    "Do not narrate tool use or progress. Answer with the final findings, reasoning, or next action after inspection.",
    markdown_policy,
    shell_policy,
    web_policy,
    "Never edit non-Markdown files from this lane. Source changes must go through NVIME EDIT MODE and reviewed diffs.",
  }

  if opts.resume_session_id then
    lines[#lines + 1] =
      "You are continuing this provider's native conversation via resume. Use that native context for prior turns."
  else
    lines[#lines + 1] = "Continue the conversation using the transcript below."
  end

  lines[#lines + 1] = ""
  if not opts.resume_session_id or opts.include_transcript then
    append_transcript(lines, session)
  elseif opts.native_context_only then
    lines[#lines + 1] = "Conversation so far: available from the resumed native provider session."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "USER: " .. text
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Answer the latest user message with the prior conversation in mind."
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- policy
-- ---------------------------------------------------------------------------
local policy = {
  kind = "chat",
  state_key = "chat",
  ns_prefix = "nvime.chat",
  augroup_name = "nvime.chat.focus",
  guard_key = "nvime_chat_guard_attached",
  module_name = "nvime.chat",
  input_buffer_name = "nvime://chat-input",
  buffer_name_prefix = "nvime://chat/",
  footer = " i input | ? prompts | <CR> send on prompt | p provider | P choose | q close ",
  zindex = 50,
  provider_scope = "chat",
  enter_input_method = "prompt",
  persist_filename = "chat-sessions.json",
  persist_error_label = "chat sessions",
  newer_version_label = "nvime chat sessions were written by a newer nvime version:",
  seed_fresh_buffer = false,
  sync_panel_touches = true,

  sessions_path = function()
    local cfg = (state.config or {}).sessions or {}
    if cfg.chat_path and cfg.chat_path ~= "" then
      return vim.fn.fnamemodify(cfg.chat_path, ":p")
    end
    if cfg.path and cfg.path ~= "" then
      return vim.fn.fnamemodify(cfg.path, ":p:h") .. "/chat-sessions.json"
    end
    local root = require("nvime.git").root()
    if root then
      return root .. "/.nvime/chat-sessions.json"
    end
    return vim.fn.stdpath("state") .. "/nvime/chat-sessions.json"
  end,

  provider = function()
    local active_id = state.chat and state.chat.active_session_id
    for _, session in ipairs(state.chat and state.chat.sessions or {}) do
      if session.id == active_id and session.provider then
        return session.provider
      end
    end
    return (state.chat and state.chat.provider) or (state.config and state.config.provider) or "claude"
  end,

  prompt_prefix = function(c)
    return "[" .. c.provider() .. "]$ "
  end,

  serialize_session = function(session, persisted_lines)
    return {
      id = session.id,
      title = session.title,
      provider = session.provider,
      history = session.history or {},
      input_start = session.input_start,
      provider_sessions = session.provider_sessions or {},
      provider_workspaces = session.provider_workspaces or {},
      last_provider = session.last_provider,
      lines = persisted_lines(session),
      created_at = session.created_at,
      updated_at = session.updated_at,
    }
  end,

  save_meta = function(envelope, store)
    envelope.active_session_id = store.active_session_id
  end,

  normalize_item = function(item)
    item.title = item.title or ("Chat #" .. tostring(item.id))
    item.history = type(item.history) == "table" and item.history or {}
    item.provider_sessions = type(item.provider_sessions) == "table" and item.provider_sessions or {}
    item.provider_workspaces = type(item.provider_workspaces) == "table" and item.provider_workspaces or {}
    item.lines = type(item.lines) == "table" and item.lines or nil
    item.progress = nil
  end,

  restore_meta = function(decoded, store, c)
    local restored = tonumber(decoded.active_session_id)
    if restored and c.get_session(restored) then
      store.active_session_id = restored
    end
  end,

  after_create = function(session)
    session.title = session.title or ("Chat #" .. tostring(session.id))
    state.chat.active_session_id = session.id
    state.last_session = { kind = "chat", id = session.id }
    sync_session_to_legacy(session)
  end,

  on_touch = function(session)
    sync_session_to_legacy(session)
  end,

  on_activate = function(session)
    sync_legacy_to_session(session)
  end,

  ensure_active_session = function(c)
    return c.active_session() or create_session()
  end,

  after_reset = function(c)
    c.sync_active_panel_to_session()
  end,

  on_append_synced = function(session)
    sync_session_to_legacy(session)
  end,

  decorate_input = function(bufnr, c)
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_clear_namespace(bufnr, c.input_ns, 0, -1)
    local p = c.panel()
    local start = p and p.input_start
    if not start then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local prompt_lnum = start + c.INPUT_PROMPT_LINE - 1
    local prompt_line = lines[prompt_lnum] or ""
    local prefix = c.prompt_prefix()
    if vim.startswith(prompt_line, prefix) then
      vim.api.nvim_buf_set_extmark(bufnr, c.input_ns, prompt_lnum - 1, 0, {
        end_col = #prefix,
        hl_group = "NvimeInputPrompt",
      })
      if #prompt_line > #prefix then
        vim.api.nvim_buf_set_extmark(bufnr, c.input_ns, prompt_lnum - 1, #prefix, {
          end_col = #prompt_line,
          hl_group = "NvimeUserText",
        })
      end
      local rule_width = vim.o.columns
      if p.winid and vim.api.nvim_win_is_valid(p.winid) then
        rule_width = vim.api.nvim_win_get_width(p.winid)
      end
      rule_width = math.max(20, rule_width - 2)
      local virt_lines = {}
      local session_for_status = c.active_session()
      if session_for_status and session_for_status.busy then
        local provider_name = session_for_status.provider or "agent"
        local detail = c.progress.compact(session_for_status.progress or "")
        detail = detail:gsub("^" .. vim.pesc(provider_name) .. "%s*", "")
        if detail == "" then
          detail = "working"
        end
        local status_text = c.render.spinner_text() .. "  " .. detail
        local pad = math.max(0, rule_width - vim.fn.strdisplaywidth(status_text))
        virt_lines[#virt_lines + 1] = {
          { string.rep(" ", pad), "" },
          { status_text, "NvimeStatusRunning" },
        }
      end
      virt_lines[#virt_lines + 1] = { { string.rep("─", rule_width), "NvimeRule" } }
      vim.api.nvim_buf_set_extmark(bufnr, c.input_ns, prompt_lnum - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        priority = 80,
      })
    end
    if #prompt_line <= #prefix then
      vim.api.nvim_buf_set_extmark(bufnr, c.input_ns, prompt_lnum - 1, #prefix, {
        virt_text = { { "type a review/docs prompt", "NvimeInputGhost" } },
        virt_text_pos = "eol",
        priority = 90,
      })
    end
  end,

  resolve_session = function(opts, c)
    local session = opts.session_id and c.get_session(opts.session_id) or c.active_session()
    if not session and not opts.session_id then
      local newest = M.sessions()[1]
      if newest then
        state.chat.active_session_id = newest.id
        session = c.get_session(newest.id)
      end
    end
    if not session then
      session = create_session()
    end
    session.provider = opts.provider or session.provider or (state.config and state.config.provider) or "claude"
    c.touch_session(session)
    state.chat.active_session_id = session.id
    sync_session_to_legacy(session)
    return session
  end,

  cancel_message = function()
    return "\n[nvime] chat cancelled.\n"
  end,

  finished_label = function()
    return "chat"
  end,

  winbar_lane = function()
    return "review/docs"
  end,

  after_delete = function(store)
    if not store.active_session_id then
      local next_session = store.sessions[1]
      if next_session then
        store.active_session_id = next_session.id
        sync_session_to_legacy(next_session)
      else
        sync_session_to_legacy({
          history = {},
          provider_sessions = {},
          provider_workspaces = {},
        })
      end
    end
  end,

  reset_extra_state = function(store)
    store.history = {}
    store.provider_sessions = {}
    store.provider_workspaces = {}
    store.last_provider = nil
    store._legacy_session_id = nil
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
-- chat-specific surface
-- ---------------------------------------------------------------------------
function M.agent_run_opts(provider_name, session_id)
  provider_name = provider_name or ctx.provider()
  local session = session_id and ctx.get_session(session_id) or ctx.ensure_active_session()
  session.provider_sessions = session.provider_sessions or {}
  session.provider_workspaces = session.provider_workspaces or {}
  if not session.provider_workspaces[provider_name] then
    session.provider_workspaces[provider_name] = vim.fn.tempname() .. "/workspace"
  end
  local resume_id = session.provider_sessions[provider_name]
  ctx.touch_session(session)
  return {
    persist_session = true,
    resume_session_id = resume_id,
    markdown_workspace = session.provider_workspaces[provider_name],
    on_session_id = function(provider_session_id)
      ctx.mark_provider_session(session, provider_name, provider_session_id)
    end,
  }
end

function M.append_user(text, session_id)
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function()
      M.append_user(text, session_id)
    end)
    return
  end
  local session = session_id and ctx.get_session(session_id) or ctx.ensure_active_session()
  local bufnr = M.open({ session_id = session.id })
  append_user_message(bufnr, text, session)
end

function M.append_response_header(session_id)
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function()
      M.append_response_header(session_id)
    end)
    return
  end
  local session = session_id and ctx.get_session(session_id) or ctx.ensure_active_session()
  local bufnr = M.open({ session_id = session.id })
  append_response_header(bufnr, session)
end

function M.submit(text, opts)
  opts = opts or {}
  local session = opts.session_id and ctx.get_session(opts.session_id) or ctx.ensure_active_session()
  state.chat.active_session_id = session.id
  sync_session_to_legacy(session)
  local bufnr = M.open({ session_id = session.id })
  text = vim.trim(text or "")
  if text == "" then
    ctx.reset_input("")
    return
  end

  session.busy = true
  session.cancelled = false
  session.progress = nil
  ctx.touch_session(session)
  ctx.ensure_spinner_timer()
  M.refresh(bufnr)
  spinner.update()

  if opts.display_user ~= false then
    append_user_message(bufnr, text, session)
  end
  append_response_header(bufnr, session)

  session.history = session.history or {}
  session.history[#session.history + 1] = {
    role = "user",
    content = text,
  }
  if not session.title or session.title:match("^Chat #%d+$") then
    session.title = summarize_title(text) or session.title
  end
  trim_history(session)

  local provider_name = ctx.provider()
  session.provider = provider_name

  local agent_session = M.agent_run_opts(provider_name, session.id)
  local include_transcript = not agent_session.resume_session_id or session.last_provider ~= provider_name
  local prompt = build_conversation_prompt(text, {
    session = session,
    resume_session_id = agent_session.resume_session_id,
    include_transcript = include_transcript,
    native_context_only = true,
  })
  local response = {}
  local chat_model = require("nvime.provider").current_model({ scope = "chat" })
  local handle
  handle = agents.run({
    provider = provider_name,
    lane = "review",
    prompt = prompt,
    model = chat_model,
    persist_session = agent_session.persist_session,
    resume_session_id = agent_session.resume_session_id,
    markdown_workspace = agent_session.markdown_workspace,
    on_session_id = agent_session.on_session_id,
    on_text = function(chunk)
      response[#response + 1] = chunk
      ctx.append_scrollback(chunk, session.id)
    end,
    on_progress = function(chunk)
      M.set_progress(chunk, session.id)
      if ((state.config or {}).edit or {}).show_tool_log ~= false then
        ctx.append_scrollback(chunk, session.id)
      end
    end,
    on_handle = function(agent_handle)
      handle = agent_handle
      ctx.remember_session_process(session, agent_handle)
    end,
    on_exit = function(result)
      local cancelled = (handle and session.cancelled_handles and session.cancelled_handles[handle] == true)
        or (not handle and session.cancelled == true)
      if handle and session.cancelled_handles then
        session.cancelled_handles[handle] = nil
      end
      ctx.clear_session_process(session, handle)
      local assistant_text = vim.trim(table.concat(response))
      if not cancelled and assistant_text ~= "" then
        session.history = session.history or {}
        session.history[#session.history + 1] = {
          role = "assistant",
          content = assistant_text,
        }
        trim_history(session)
      end
      session.last_provider = provider_name
      session.busy = false
      if cancelled then
        session.cancelled = false
      end
      if not cancelled and result.nvime_usage then
        local label = usage.run_summary(result.nvime_usage)
        if label then
          ctx.append_scrollback("\n[nvime] " .. label .. "\n", session.id)
        end
      end
      session.progress = nil
      ctx.touch_session(session)
      spinner.update()
      local synced = result.nvime_synced_markdown or {}
      if #synced > 0 then
        vim.notify("nvime synced markdown: " .. table.concat(synced, ", "), vim.log.levels.INFO)
      end
      if result.code ~= 0 and not cancelled then
        ctx.append_scrollback("\n[nvime] chat failed with code " .. tostring(result.code) .. "\n", session.id)
      end
      if not cancelled then
        ctx.notify_finished(session, result.code)
      end
      vim.schedule(function()
        ctx.refresh_input_indicator()
        if state.chat.active_session_id == session.id and ctx.panel_is_open(session.id) then
          M.refresh(bufnr)
        end
      end)
    end,
  })
  if not handle then
    session.busy = false
    session.progress = nil
    ctx.touch_session(session)
    spinner.update()
    ctx.refresh_input_indicator()
  end
end

function M.insert_prompt(text)
  text = vim.trim(text or "")
  M.open()
  ctx.reset_input(text, { force_follow = true })
  M.prompt({ cursor = "end" })
end

-- Append `text` to whatever is already staged in a chat's input, preserving
-- the user's in-progress prompt. `session_id` targets a specific session (used
-- by nvime.send to reach the last-opened conversation); omit to use the active
-- one. Used by <leader>ns to stack @path references without clobbering it.
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
  M.prompt({ cursor = "end" })
end

function M.choose_prompt()
  prompts.choose("general", function(text)
    M.insert_prompt(text)
  end)
end

function M.prompt(opts)
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
  local prompt_lnum = p.input_start or 1
  local prefix_col = #ctx.prompt_prefix()
  local end_col = ctx.prompt_end_col(p)
  if saved_cursor then
    if saved_cursor[1] >= prompt_lnum and (saved_cursor[1] > prompt_lnum or saved_cursor[2] >= prefix_col) then
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
  pcall(vim.api.nvim_win_set_cursor, p.winid, { prompt_lnum, col })
  pcall(vim.fn.winrestview, { topline = math.max(1, prompt_lnum - vim.api.nvim_win_get_height(p.winid) + 2) })
  pcall(vim.cmd, (append or empty_prompt) and "startinsert!" or "startinsert")
end

function M.submit_current()
  local p = ctx.panel()
  if not p or not p.input_bufnr or not vim.api.nvim_buf_is_valid(p.input_bufnr) then
    M.prompt()
    return
  end

  local prompt_lnum = p.input_start or 1
  local all_lines = vim.api.nvim_buf_get_lines(p.input_bufnr, prompt_lnum - 1, -1, false)
  if #all_lines == 0 then
    M.prompt()
    return
  end
  all_lines[1] = ctx.extract_prompt_text(all_lines[1])
  local text = vim.trim(table.concat(all_lines, "\n"))
  ctx.reset_input("")
  if text == "" then
    M.prompt()
    return
  end
  M.submit(text)
end

function M.new_session(opts)
  opts = opts or {}
  ctx.sync_active_panel_to_session()
  local session = create_session({
    provider = opts.provider,
    title = opts.title,
  })
  return M.open({
    session_id = session.id,
    focus_input = opts.focus_input == true,
  })
end

function M.open_session(id, opts)
  opts = opts or {}
  local session = ctx.get_session(id)
  if not session then
    vim.notify("nvime chat no longer exists", vim.log.levels.WARN)
    return nil
  end
  state.chat.active_session_id = session.id
  sync_session_to_legacy(session)
  return M.open({
    session_id = session.id,
    focus_input = opts.focus_input == true,
  })
end

M._build_conversation_prompt = build_conversation_prompt

return M
