local agents = require("nvime.agents")
local diff = require("nvime.diff")
local selection_state = require("nvime.selection")
local state = require("nvime.state")
local ts = require("nvime.treesitter")

local M = {}

local function current_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local root = vim.fn.systemlist({ "git", "-C", vim.fn.fnamemodify(name, ":h"), "rev-parse", "--show-toplevel" })[1]
  if vim.v.shell_error == 0 and root and root ~= "" then
    return vim.fn.fnamemodify(name, ":p"):sub(#root + 2)
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function build_prompt(selection, intent)
  local lines = ts.lines(selection)
  local selected_body = table.concat(lines, "\n")
  local selected_display = selected_body
  if vim.trim(selected_body) == "" then
    selected_display = "(selected range is empty or blank)"
  end
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
    "You are a constrained patch worker. You may only propose a change for exactly one selected range in exactly one current file.",
    "The selected range can be existing code, plain text, config text, comments, blank lines, or an intentionally empty insertion area.",
    "If the selected range is blank and the intent asks you to add, generate, complete, or insert something, produce the requested replacement for that range.",
    "Non-code files are allowed when the selected range is in the current file; for example .gitignore, README snippets, config fragments, and comments.",
    "Do not edit files directly. Do not use tools. Do not mention other file patches. Do not produce a whole-repo refactor.",
    "If the user is asking a question, asking for review, or the existing selected range already satisfies the intent, do not produce code.",
    "When producing a replacement, return the complete new contents for the selected range only. Do not include surrounding unselected lines.",
    "Use exactly one of these response forms:",
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
    "<unified diff for this file only>",
    "```",
    "",
    "File: " .. selection.path,
    "Allowed range: " .. selection.line1 .. "-" .. selection.line2 .. " (" .. selection.source .. ")",
    "Intent: " .. intent,
    table.concat(prior_context, "\n"),
    "",
    "Selected code:",
    "```",
    selected_display,
    "```",
  }, "\n")
end

local function run_edit(selection, intent, provider, session_opts)
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
      selection_state.append(text, session_id)
    end,
    on_exit = function(result)
      selection_state.set_busy(false, session_id)
      if result.code ~= 0 then
        selection_state.append("\n[nvime] edit failed with code " .. tostring(result.code) .. "\n", session_id)
        return
      end
      local ok, result = pcall(diff.start_session, selection, table.concat(response), provider, prompt)
      if not ok then
        selection_state.append("\n[nvime] " .. tostring(result) .. "\n", session_id)
      elseif result and result.status == "no_change" then
        selection_state.append("\n[nvime] no patch opened: " .. result.message .. "\n", session_id)
      elseif result and result.session then
        result.session.selection_session_id = session_id
      end
    end,
  })
end

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
    or text:find("what ", 1, true)
    or text:find("why ", 1, true)
    or text:find("explain", 1, true)
    or text:find("review", 1, true)
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
    if not intent or intent == "" then
      selection_state.prompt({
        provider = provider,
        mode = "edit",
        selection = selection,
        session_id = session_opts.session_id,
        new_session = session_opts.new_session,
        on_submit = function(input, selected_provider)
          selected_provider = selected_provider or provider
          local active_session_id = selection_state.active_session_id()
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
        end,
      })
      return
    end

    if looks_like_question(intent) then
      require("nvime.ask").start({
        selection = selection,
        provider = provider,
        question = intent,
        session_id = session_opts.session_id,
        new_session = session_opts.new_session,
      })
      return
    end

    run_edit(selection, intent, provider, session_opts)
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
        selected_provider = selected_provider or provider
        local active_session_id = selection_state.active_session_id()
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
          selection_state.append(text, selection_session_id)
        end,
        on_exit = function(result)
          selection_state.set_busy(false, selection_session_id)
          local body = table.concat(response)
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
            end
          end
          if result.code ~= 0 then
            selection_state.append("\n[nvime] discuss failed with code " .. tostring(result.code) .. "\n", selection_session_id)
          end
        end,
      })
    end,
  })
end

return M
