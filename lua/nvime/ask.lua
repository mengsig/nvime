local agents = require("nvime.agents")
local diff = require("nvime.diff")
local git = require("nvime.git")
local selection_state = require("nvime.selection")
local state = require("nvime.state")
local ts = require("nvime.treesitter")
local usage = require("nvime.usage")

local M = {}

local function current_path(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.fn.filereadable(name) ~= 1 then
    return nil
  end
  return git.repo_relative_path(name)
end

local function build_prompt(selection, question)
  local lines = ts.lines(selection)
  local body = table.concat(lines, "\n")
  local max_run = 2
  for run in body:gmatch("`+") do
    if #run > max_run then
      max_run = #run
    end
  end
  local fence = string.rep("`", max_run + 1)
  return table.concat({
    "NVIME READ-ONLY SELECTION CHAT — look, don't touch.",
    "You are the read-only blade inside Neovim: sharp eyes, hands tied.",
    "Answer the user's question about the selected code. You may use read/search, web fetch/search, and shell commands such as curl for inspection, external docs, or tests when available.",
    "Do not edit files directly. Do not produce a patch unless you are only narrating what a future patch would do.",
    "",
    "File: " .. selection.path,
    "Selected range: "
      .. tostring(selection.line1)
      .. "-"
      .. tostring(selection.line2)
      .. " ("
      .. (selection.source or "range")
      .. ")",
    "Question: " .. question,
    "",
    "Selected code:",
    fence,
    body,
    fence,
  }, "\n")
end

local EDIT_KEYWORDS = {
  "proceed",
  "go ahead",
  "fix",
  "change",
  "update",
  "apply",
  "implement",
  "refactor",
  "rename",
  "convert",
  "replace",
  "remove",
  "add",
  "patch",
  "diff",
  "make it",
}

local NEGATION_PATTERNS = {
  "don'?t",
  "do not",
  "doesn'?t",
  "does not",
  "shouldn'?t",
  "should not",
  "no need",
  "never",
}

local function has_word(text, phrase)
  if phrase:find(" ", 1, true) then
    return text:find(phrase, 1, true) ~= nil
  end
  return text:find("%f[%w]" .. phrase .. "%f[%W]") ~= nil
end

local function has_negation(text)
  for _, pattern in ipairs(NEGATION_PATTERNS) do
    if text:find(pattern) then
      return true
    end
  end
  return false
end

local function wants_edit_followup(input)
  local text = (input or ""):lower()
  if text == "" then
    return false
  end
  if text:match("^%s*/edit%f[%W]") or text:match("^%s*/edit$") then
    return true
  end
  if text:match("^%s*what%s") or text:match("^%s*why%s") or text:match("^%s*how%s") then
    return false
  end
  if has_negation(text) then
    return false
  end
  if text:find("approv", 1, true) and (text:find("diff", 1, true) or text:find("patch", 1, true)) then
    return true
  end
  for _, keyword in ipairs(EDIT_KEYWORDS) do
    if has_word(text, keyword) then
      return true
    end
  end
  return false
end

local function response_has_patch(body)
  body = body or ""
  return body:find("NVIME_DIFF", 1, true) ~= nil
    or body:find("NVIME_REPLACEMENT", 1, true) ~= nil
    or body:find("```diff", 1, true) ~= nil
    or body:find("--- a/", 1, true) ~= nil
end

local run

local function arm_followup(selection, provider, session_id, open_panel)
  selection_state.prompt({
    provider = provider,
    mode = "ask",
    selection = selection,
    session_id = session_id,
    focus_input = false,
    open = open_panel ~= false,
    on_submit = function(input, selected_provider)
      selected_provider = selected_provider or provider
      if wants_edit_followup(input) then
        require("nvime.edit").start({
          selection = selection,
          provider = selected_provider,
          intent = input,
          session_id = session_id,
        })
      else
        run(selection, input, selected_provider, { session_id = session_id })
      end
    end,
  })
end

run = function(selection, question, provider, session_opts)
  session_opts = session_opts or {}
  selection_state.open({
    provider = provider,
    mode = "ask",
    selection = selection,
    session_id = session_opts.session_id,
    new_session = session_opts.new_session,
  })
  local session_id = selection_state.active_session_id()
  selection_state.append_user(provider, "ask", question, session_id)
  selection_state.append_response_header(provider, "ask", session_id)
  -- Mark the conversation's persona as read-only so a later switch to edit mode
  -- re-establishes the full edit contract instead of resuming read-only.
  selection_state.mark_run_mode(session_id, "ask")

  local response = {}
  local prompt = build_prompt(selection, question)
  local agent_session = selection_state.agent_run_opts(session_id, provider)
  local model = require("nvime.provider").current_model({ scope = "selection" })
  local max_turns = tonumber(((state.config or {}).edit or {}).max_turns)
  selection_state.set_busy(true, session_id)
  local handle
  handle = agents.run({
    provider = provider,
    lane = "ask",
    prompt = prompt,
    model = model,
    max_turns = max_turns,
    persist_session = agent_session.persist_session,
    resume_session_id = agent_session.resume_session_id,
    on_session_id = agent_session.on_session_id,
    on_text = function(text)
      response[#response + 1] = text
      selection_state.append(text, session_id)
    end,
    on_progress = function(text)
      selection_state.set_progress(text, session_id)
      if ((state.config or {}).edit or {}).show_tool_log ~= false then
        selection_state.append(text, session_id)
      end
    end,
    on_handle = function(agent_handle)
      handle = agent_handle
      selection_state.attach_process(session_id, agent_handle, {
        lane = "ask",
        provider = provider,
      })
    end,
    on_exit = function(result)
      local was_open = selection_state.is_open(session_id)
      local session = selection_state.get_session(session_id)
      local cancelled = session
        and (
          (handle and session.cancelled_handles and session.cancelled_handles[handle] == true)
          or (not handle and session.cancelled == true)
        )
      if session and handle and session.cancelled_handles then
        session.cancelled_handles[handle] = nil
      end
      selection_state.clear_process(session_id, handle)
      selection_state.set_busy(false, session_id)
      if session and cancelled then
        session.cancelled = false
      end
      if cancelled then
        return
      end
      if result.nvime_usage then
        local label = usage.run_summary(result.nvime_usage)
        if label then
          selection_state.append("\n[nvime] " .. label .. "\n", session_id)
        end
      end
      local answer = vim.trim(table.concat(response))
      selection_state.mark_last_ask(session_id, {
        selection = selection_state.snapshot(selection),
        provider = provider,
        question = question,
        answer = answer,
      })
      local opened_diff = false
      if result.code ~= 0 then
        selection_state.append("\n[nvime] ask failed with code " .. tostring(result.code) .. "\n", session_id)
      elseif response_has_patch(answer) then
        local ok, diff_result = pcall(diff.start_session, selection, answer, provider, prompt)
        if not ok then
          selection_state.append("\n[nvime] " .. tostring(diff_result) .. "\n", session_id)
        elseif diff_result and diff_result.status == "no_change" then
          selection_state.append("\n[nvime] no patch opened.\n", session_id)
        elseif diff_result and diff_result.session then
          diff_result.session.selection_session_id = session_id
          opened_diff = true
        end
      end
      arm_followup(
        selection,
        provider,
        session_id,
        not opened_diff and was_open and selection_state.active_session_id() == session_id
      )
      if not opened_diff and not was_open then
        selection_state.notify_finished("ask", session_id, result.code)
      end
      if opened_diff then
        selection_state.close()
      end
    end,
  })
  if not handle then
    selection_state.set_busy(false, session_id)
  end
end

function M.start(opts)
  opts = opts or {}
  local selection, err
  if opts.selection then
    selection = opts.selection
  else
    selection, err = ts.range_from_command(opts)
  end
  if not selection then
    vim.notify(err or "nvime ask needs a visual range or a Tree-sitter function at the cursor", vim.log.levels.ERROR)
    return
  end

  selection.path = selection.path or current_path(selection.bufnr)
  if not selection.path then
    vim.notify("nvime ask requires a named file buffer", vim.log.levels.ERROR)
    return
  end

  local provider = opts.provider or require("nvime.state").config.provider
  local question = opts.question or opts.prompt
  local function proceed(session_opts)
    session_opts = session_opts or {}
    local proceed_provider = session_opts.provider or provider
    if not question or question == "" then
      selection_state.prompt({
        provider = proceed_provider,
        mode = "ask",
        selection = selection,
        session_id = session_opts.session_id,
        new_session = session_opts.new_session,
        on_submit = function(input, selected_provider)
          run(
            selection,
            input,
            selected_provider or proceed_provider,
            { session_id = selection_state.active_session_id() }
          )
        end,
      })
      return
    end

    run(selection, question, proceed_provider, session_opts)
  end

  if opts.choose_session then
    selection_state.choose_session(selection, {
      mode = "ask",
      provider = provider,
    }, proceed)
    return
  end

  if not question or question == "" then
    selection_state.prompt({
      provider = provider,
      mode = "ask",
      selection = selection,
      session_id = opts.session_id,
      new_session = opts.new_session,
      on_submit = function(input, selected_provider)
        run(selection, input, selected_provider or provider, { session_id = selection_state.active_session_id() })
      end,
    })
    return
  end

  run(selection, question, provider, { session_id = opts.session_id, new_session = opts.new_session })
end

-- Re-arm the panel's input for ask mode on an existing session, preserving the
-- selection/session. Used by the in-panel ask⇄edit toggle (nvime.selection).
M.arm_prompt = arm_followup

M._build_prompt = build_prompt
M._wants_edit_followup = wants_edit_followup

return M
