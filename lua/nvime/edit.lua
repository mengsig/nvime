local agents = require("nvime.agents")
local diff = require("nvime.diff")
local git = require("nvime.git")
local selection_state = require("nvime.selection")
local state = require("nvime.state")
local ts = require("nvime.treesitter")

local M = {}

local function code_fence_for(text)
  local max_run = 2
  for run in (text or ""):gmatch("`+") do
    if #run > max_run then
      max_run = #run
    end
  end
  return string.rep("`", max_run + 1)
end

local function current_path(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return git.repo_relative_path(name)
end

local function build_prompt(selection, intent)
  local lines = ts.lines(selection)
  local selected_body = table.concat(lines, "\n")
  local selected_display = selected_body
  if vim.trim(selected_body) == "" then
    selected_display = "(selected range is empty or blank)"
  end
  local selected_fence = code_fence_for(selected_display)
  local ask = selection_state.last_ask_for(selection)
  local prior_context = {}
  if ask and selection_state.same_range(selection, ask.selection) then
    prior_context = {
      "",
      "Previous read-only reviewer context for this exact selection:",
      "Question: " .. ask.question,
      "Answer:",
      ask.answer ~= "" and ask.answer or "(empty)",
    }
  end

  return table.concat({
    "NVIME EDIT MODE.",
    "You are a constrained patch worker, not a reviewer.",
    "Return exactly one machine-readable response block. Do not write analysis, caveats, summaries, or prose outside the block.",
    "You may only propose changes for the selected range in the current file.",
    "You may use read/search, web fetch/search, and shell commands such as curl for inspection, external docs, or tests when available.",
    "Do not edit files directly. Do not mention patches for other files or ranges.",
    "If no concrete change is needed, return NVIME_NO_CHANGE with one short reason.",
    "For existing nonblank text, return NVIME_DIFF with the smallest changed hunks only. This is required for Markdown, large selections, and selections containing code fences.",
    "For blank insertions or tiny whole-range replacements, NVIME_REPLACEMENT is allowed.",
    "A user request that says both review/check and fix/proceed means: silently make only the concrete fixes you are confident about.",
    "NVIME_DIFF must include --- a/" .. selection.path .. ", +++ b/" .. selection.path .. ", and ranged @@ -line,count +line,count @@ headers.",
    "Use one response form:",
    "",
    "NVIME_NO_CHANGE",
    "<brief explanation>",
    "",
    "NVIME_REPLACEMENT",
    "```",
    "<full replacement for the selected range only>",
    "```",
    "",
    "NVIME_DIFF",
    "```diff",
    "--- a/" .. selection.path,
    "+++ b/" .. selection.path,
    "@@ -<line>,<count> +<line>,<count> @@",
    "<minimal changed hunk lines only>",
    "```",
    "",
    "File: " .. selection.path,
    "Allowed range: " .. selection.line1 .. "-" .. selection.line2 .. " (" .. selection.source .. ")",
    "Intent: " .. intent,
    table.concat(prior_context, "\n"),
    "",
    "Selected code:",
    selected_fence,
    selected_display,
    selected_fence,
  }, "\n")
end

local run_edit

local function looks_like_question(intent)
  local text = (intent or ""):lower()
  if text == "" then
    return false
  end
  if text:match("%f[%w](make|change|fix|add|remove|replace|implement|refactor|rename|convert|update|handle)%f[%W]") then
    return false
  end
  return text:find("?", 1, true)
    or text:find("look right", 1, true)
    or text:find("looks right", 1, true)
    or text:find("does this", 1, true)
    or text:find("is this", 1, true)
    or text:find("check ", 1, true)
    or text:find("verify", 1, true)
    or text:find("inspect", 1, true)
    or text:find("audit", 1, true)
    or text:find("iterate throughout", 1, true)
    or text:find("correctness", 1, true)
    or text:find("nitpick", 1, true)
    or text:find("appropriate", 1, true)
    or text:find("what ", 1, true)
    or text:find("why ", 1, true)
    or text:find("explain", 1, true)
    or text:find("review", 1, true)
end

local function submit_edit(selection, fallback_provider, input, selected_provider, session_id)
  selected_provider = selected_provider or fallback_provider
  local active_session_id = session_id or selection_state.active_session_id()
  if looks_like_question(input) then
    require("nvime.ask").start({
      selection = selection,
      provider = selected_provider,
      question = input,
      session_id = active_session_id,
    })
  else
    run_edit(selection, input, selected_provider, { session_id = active_session_id })
  end
end

local function arm_edit_followup(selection, provider, session_id, open_panel)
  selection_state.prompt({
    provider = provider,
    mode = "edit",
    selection = selection,
    session_id = session_id,
    focus_input = false,
    open = open_panel ~= false,
    on_submit = function(input, selected_provider)
      submit_edit(selection, provider, input, selected_provider, session_id)
    end,
  })
end

run_edit = function(selection, intent, provider, session_opts)
  session_opts = session_opts or {}
  selection_state.open({
    provider = provider,
    mode = "edit",
    selection = selection,
    session_id = session_opts.session_id,
    new_session = session_opts.new_session,
  })
  local session_id = selection_state.active_session_id()
  selection_state.append_user(provider, "edit", intent, session_id)
  selection_state.append_response_header(provider, "edit", session_id)

  local response = {}
  local prompt = build_prompt(selection, intent)
  local agent_session = selection_state.agent_run_opts(session_id, provider)
  state.selection.last_edit_prompt = prompt
  selection_state.set_busy(true, session_id)
  agents.run({
    provider = provider,
    lane = "edit",
    prompt = prompt,
    persist_session = agent_session.persist_session,
    resume_session_id = agent_session.resume_session_id,
    on_session_id = agent_session.on_session_id,
    on_text = function(text)
      response[#response + 1] = text
      selection_state.append(text, session_id)
    end,
    on_progress = function(text)
      selection_state.set_progress(text, session_id)
    end,
    on_exit = function(result)
      local was_open = selection_state.is_open(session_id)
      selection_state.set_busy(false, session_id)
      local opened_diff = false
      if result.code ~= 0 then
        selection_state.append("\n[nvime] edit failed with code " .. tostring(result.code) .. "\n", session_id)
      else
        local ok, diff_result = pcall(diff.start_session, selection, table.concat(response), provider, prompt)
        if not ok then
          selection_state.append("\n[nvime] " .. tostring(diff_result) .. "\n", session_id)
        elseif diff_result and diff_result.status == "no_change" then
          selection_state.append("\n[nvime] no patch opened: " .. diff_result.message .. "\n", session_id)
        elseif diff_result and diff_result.session then
          diff_result.session.selection_session_id = session_id
          opened_diff = true
        end
      end
      arm_edit_followup(selection, provider, session_id, not opened_diff and was_open and selection_state.active_session_id() == session_id)
      if not opened_diff and not was_open then
        selection_state.notify_finished("edit", session_id, result.code)
      end
      if opened_diff then
        selection_state.close()
      end
    end,
  })
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
    vim.notify(err or "nvime needs a visual range or a Tree-sitter function at the cursor", vim.log.levels.ERROR)
    return
  end

  selection.path = selection.path or current_path(selection.bufnr)
  if not selection.path then
    vim.notify("nvime edit requires a named file buffer", vim.log.levels.ERROR)
    return
  end

  local provider = opts.provider or require("nvime.state").config.provider
  local intent = opts.intent
  local function proceed(session_opts)
    session_opts = session_opts or {}
    local proceed_provider = session_opts.provider or provider
    if not intent or intent == "" then
      selection_state.prompt({
        provider = proceed_provider,
        mode = "edit",
        selection = selection,
        session_id = session_opts.session_id,
        new_session = session_opts.new_session,
        on_submit = function(input, selected_provider)
          submit_edit(selection, proceed_provider, input, selected_provider, selection_state.active_session_id())
        end,
      })
      return
    end

    if looks_like_question(intent) then
      require("nvime.ask").start({
        selection = selection,
        provider = proceed_provider,
        question = intent,
        session_id = session_opts.session_id,
        new_session = session_opts.new_session,
      })
      return
    end

    run_edit(selection, intent, proceed_provider, session_opts)
  end

  if opts.choose_session then
    selection_state.choose_session(selection, {
      mode = "edit",
      provider = provider,
    }, proceed)
    return
  end

  if not intent or intent == "" then
    selection_state.prompt({
      provider = provider,
      mode = "edit",
      selection = selection,
      session_id = opts.session_id,
      new_session = opts.new_session,
      on_submit = function(input, selected_provider)
        submit_edit(selection, provider, input, selected_provider, selection_state.active_session_id())
      end,
    })
    return
  end

  if looks_like_question(intent) then
    require("nvime.ask").start({
      selection = selection,
      provider = provider,
      question = intent,
      session_id = opts.session_id,
      new_session = opts.new_session,
    })
    return
  end

  run_edit(selection, intent, provider, { session_id = opts.session_id, new_session = opts.new_session })
end

function M.continue_remaining()
  local remaining = diff.remaining_text()
  if not remaining or remaining == "" then
    vim.notify("No remaining nvime diff to discuss", vim.log.levels.WARN)
    return
  end
  local session = require("nvime.state").current_diff
  selection_state.prompt({
    provider = session.provider,
    mode = "discuss",
    selection = session.selection,
    session_id = session.selection_session_id,
    on_submit = function(input, selected_provider)
      if not input or input == "" then
        return
      end
      selected_provider = selected_provider or session.provider
      selection_state.open({
        provider = selected_provider,
        mode = "discuss",
        selection = session.selection,
        session_id = session.selection_session_id,
      })
      local selection_session_id = selection_state.active_session_id()
      selection_state.append_user(selected_provider, "discuss", input, selection_session_id)
      selection_state.append_response_header(selected_provider, "discuss", selection_session_id)
      selection_state.set_busy(true, selection_session_id)
      local response = {}
      local agent_session = selection_state.agent_run_opts(selection_session_id, selected_provider)
      local prompt = table.concat({
        "NVIME DIFF DISCUSSION MODE.",
        "You are discussing an active in-file nvime diff review.",
        "The user may have accepted some blocks, rejected others, and left unresolved blocks pending.",
        "You may explain the state or propose an updated current-file patch.",
        "Do not edit files directly. If proposing a concrete update, use NVIME_DIFF or NVIME_REPLACEMENT.",
        "",
        "User question: " .. input,
      }, "\n")
      agents.run({
        provider = selected_provider,
        lane = "edit",
        prompt = prompt,
        input = remaining,
        persist_session = agent_session.persist_session,
        resume_session_id = agent_session.resume_session_id,
        on_session_id = agent_session.on_session_id,
        on_text = function(text)
          response[#response + 1] = text
          selection_state.append(text, selection_session_id)
        end,
        on_progress = function(text)
          selection_state.set_progress(text, selection_session_id)
        end,
        on_exit = function(result)
          local was_open = selection_state.is_open(selection_session_id)
          selection_state.set_busy(false, selection_session_id)
          local body = table.concat(response)
          local opened_diff = false
          if body:find("NVIME_DIFF", 1, true)
            or body:find("NVIME_REPLACEMENT", 1, true)
            or body:find("```diff", 1, true)
            or body:match("^%s*%-%-%- a/")
          then
            local ok, diff_result = pcall(diff.start_session, session.selection, body, selected_provider, prompt)
            if not ok then
              selection_state.append("\n[nvime] " .. tostring(diff_result) .. "\n", selection_session_id)
            elseif diff_result and diff_result.status == "no_change" then
              selection_state.append("\n[nvime] no updated patch opened: " .. diff_result.message .. "\n", selection_session_id)
            elseif diff_result and diff_result.session then
              diff_result.session.selection_session_id = selection_session_id
              opened_diff = true
            end
          end
          if result.code ~= 0 then
            selection_state.append("\n[nvime] discuss failed with code " .. tostring(result.code) .. "\n", selection_session_id)
          end
          if opened_diff then
            selection_state.close()
          elseif not was_open then
            selection_state.notify_finished("edit", selection_session_id, result.code)
          end
        end,
      })
    end,
  })
end

return M
