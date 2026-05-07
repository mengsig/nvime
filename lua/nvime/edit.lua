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

local function selection_body_and_fence(selection)
  local lines = ts.lines(selection)
  local selected_body = table.concat(lines, "\n")
  local selected_display = selected_body
  if vim.trim(selected_body) == "" then
    selected_display = "(selected range is empty or blank)"
  end
  return selected_display, code_fence_for(selected_display)
end

local function build_perf_prompt(selection, intent)
  local selected_display, fence = selection_body_and_fence(selection)
  return table.concat({
    "NVIME PERF EDIT MODE.",
    "You are a constrained patch worker focused on computational cost and scalability.",
    "Goal: produce a measurably faster or more memory-frugal version of the selected code, with behavior preserved on all inputs the original accepts.",
    "If you cannot prove a real win with numbers, return NVIME_NO_CHANGE.",
    "",
    "Mandatory workflow before answering:",
    "  1. Read the selected code carefully. Identify the asymptotic and constant-factor cost.",
    "  2. Pick at least one representative bench input (small, medium, large where appropriate).",
    "  3. Use Bash to create a scratch directory under /tmp (e.g. mktemp -d /tmp/nvime-bench.XXXXXX). NEVER write inside the user's repository.",
    "  4. Write the original selected code and your candidate replacement to two separate files in that scratch dir.",
    "  5. Construct a behavior parity check: feed both implementations the same fixed and randomized inputs and assert outputs are equal (and exception-shape if the function is documented to raise).",
    "  6. Run a microbenchmark appropriate for the language (python -m timeit, hyperfine, time, perf_hooks, os.clock) with at least 3 trials per side. Use sufficiently large input that timing dominates noise.",
    "  7. Compare. Only if candidate is correct AND faster by at least the threshold the intent implies (default ~30% wallclock or asymptotic improvement), produce NVIME_DIFF.",
    "  8. If correctness fails, behavior diverges, candidate is slower, or the gain is within measurement noise, return NVIME_NO_CHANGE with the measured numbers.",
    "",
    "Keep the candidate minimal. Your replacement must be the SMALLEST change that achieves the goal. Do not preserve undocumented edge cases (unhashable elements, exotic exception shapes, non-list iterables when the docstring talks about lists) at the cost of code complexity. Prefer one or two lines over ten.",
    "Match the original's documented behavior, not its accidental behavior. If the original raises X on empty input and the docstring/intent does not require it, do not write fallback code in the candidate just to keep raising X.",
    "Forbidden:",
    "  - writing to any path under the repo root or any ancestor directory (use only /tmp/nvime-bench.* paths);",
    "  - deleting any file you did not create in the scratch dir;",
    "  - importing heavy external dependencies (numpy/numba/etc.) unless the intent explicitly authorizes them;",
    "  - changes outside the selected range or in another file;",
    "  - any change whose only justification is style;",
    "  - candidates with try/except / type-dispatch fallbacks added solely to preserve corner cases the original happened to support.",
    "",
    "Response format:",
    "  - You MAY emit one short summary line BEFORE the NVIME_* marker, of the form:",
    "      BENCH: orig=<t1>s cand=<t2>s speedup=<x>x n=<size>",
    "    No other prose anywhere.",
    "  - Then exactly one machine-readable response block:",
    "",
    "NVIME_NO_CHANGE",
    "<one short reason; include the measured numbers if available>",
    "",
    "NVIME_REPLACEMENT",
    "```",
    "<full replacement for the selected range only, with surrounding indentation preserved>",
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
    "",
    "Selected code:",
    fence,
    selected_display,
    fence,
  }, "\n")
end

local function build_prompt(selection, intent)
  local selected_display, selected_fence = selection_body_and_fence(selection)
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
    "Return exactly one machine-readable response block. The ONLY prose allowed before the block is a single `RATIONALE:` line (described below) — no analysis, caveats, or summaries beyond that.",
    "You may only propose changes for the selected range in the current file.",
    "You may use read/search, web fetch/search, and shell commands such as curl for inspection, external docs, or tests when available.",
    "Do not edit files directly. Do not mention patches for other files or ranges.",
    "A 'concrete change' means: a fix for an actual bug, an implementation for a documented-but-missing feature, or a literal textual change the intent asks for. Defensive code, type checks, comments, error-class additions, idiom polish, value-type substitutions (e.g. 0 vs 0.0, '' vs str()), and other speculative improvements are NOT concrete changes.",
    "If, after reading the selected code carefully, you cannot point to a specific incorrect behavior or a specific request the intent makes, return NVIME_NO_CHANGE with one short reason. NVIME_NO_CHANGE is the right answer when the code already meets its documented behavior.",
    "When the intent mixes review-style language ('check', 'verify', 'iterate through', 'make sure') with fix-style language ('fix', 'proceed'), still require a real bug before patching. Review framing alone never authorizes speculative edits.",
    "When the intent describes a bug ('crashes on X', 'hangs on Y', 'returns wrong value for Z') but the selected code already handles that exact case correctly, return NVIME_NO_CHANGE and briefly note that the described case is already handled. Do NOT silently re-implement a guard or fix that is already present.",
    "Before producing NVIME_DIFF, re-read the selected code: do not insert a line that already exists, do not duplicate an existing return/break/continue, and verify your hunk's context lines match the selected text exactly.",
    "Prefer NVIME_DIFF for any change to existing nonblank text. Use NVIME_DIFF with the smallest changed hunks only. NVIME_DIFF is required for Markdown, large selections, and selections containing code fences.",
    "NVIME_REPLACEMENT is only acceptable for blank or near-blank selected ranges or tiny whole-range rewrites. The replacement is inserted verbatim at the selected range; no indentation is added for you. If the selection is a blank line inside an indented block (e.g. a Python function body), include the exact leading whitespace of the surrounding scope on every non-empty replacement line.",
    "NVIME_DIFF must include --- a/"
      .. selection.path
      .. ", +++ b/"
      .. selection.path
      .. ", and ranged @@ -line,count +line,count @@ headers.",
    "",
    "RATIONALIZATION (mandatory before NVIME_DIFF or NVIME_REPLACEMENT):",
    "Before emitting a patch you must convince yourself the change is correct. Walk through it as a self-check:",
    "  1. What is the bug, missing feature, or literal request? State it in one clause.",
    "  2. What does the patch do? State it in one clause.",
    "  3. Does the patch actually fix step 1 — and only that — without breaking other behavior visible from the selected range?",
    "If you cannot answer all three to your own satisfaction, emit NVIME_NO_CHANGE instead. If you CAN, emit ONE rationale line of the form:",
    "  RATIONALE: <one sentence: bug → patch → why it's correct>",
    "directly above the NVIME_* marker. The user sees this verbatim in the diff review header before they accept any block, so be honest. No multi-line essays; one line. nvime drops the rationale if you over-explain.",
    "",
    "Use one response form:",
    "",
    "NVIME_NO_CHANGE",
    "<brief explanation>",
    "",
    "RATIONALE: <one-line self-check>",
    "NVIME_REPLACEMENT",
    "```",
    "<full replacement for the selected range only>",
    "```",
    "",
    "RATIONALE: <one-line self-check>",
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

local function submit_edit(selection, fallback_provider, input, selected_provider, session_id, lane)
  selected_provider = selected_provider or fallback_provider
  local active_session_id = session_id or selection_state.active_session_id()
  if lane ~= "perf" and looks_like_question(input) then
    require("nvime.ask").start({
      selection = selection,
      provider = selected_provider,
      question = input,
      session_id = active_session_id,
    })
  else
    run_edit(selection, input, selected_provider, { session_id = active_session_id, lane = lane })
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
    on_submit = function(input, selected_provider, lane)
      submit_edit(selection, provider, input, selected_provider, session_id, lane)
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
  local lane = (session_opts.lane == "perf") and "perf" or "edit"
  local prompt = (lane == "perf") and build_perf_prompt(selection, intent) or build_prompt(selection, intent)
  local agent_session = selection_state.agent_run_opts(session_id, provider)
  -- Plan-level continuity override: when the caller passes a plan_continuity
  -- table, its resume_session_id wins over the selection-session one (so all
  -- steps of one plan share a provider conversation), and its on_session_id
  -- callback is layered on top so the plan's stored session id rotates
  -- naturally as the agent emits new ids.
  local plan_continuity = session_opts.plan_continuity
  local effective_resume = agent_session.resume_session_id
  local effective_on_session_id = agent_session.on_session_id
  if plan_continuity then
    -- Plan continuity is AUTHORITATIVE for plan-driven runs. A nil
    -- resume_session_id here means "the user explicitly reset; start
    -- fresh", not "fall back to selection state". Otherwise gN wouldn't
    -- actually clear the conversation.
    if plan_continuity.resume_session_id and plan_continuity.resume_session_id ~= "" then
      effective_resume = plan_continuity.resume_session_id
    else
      effective_resume = nil
    end
    if type(plan_continuity.on_session_id) == "function" then
      local selection_cb = agent_session.on_session_id
      effective_on_session_id = function(id)
        if selection_cb then
          selection_cb(id)
        end
        plan_continuity.on_session_id(id)
      end
    end
  end
  state.selection.last_edit_prompt = prompt
  selection_state.set_busy(true, session_id)
  local handle
  handle = agents.run({
    provider = provider,
    lane = lane,
    prompt = prompt,
    persist_session = agent_session.persist_session,
    resume_session_id = effective_resume,
    on_session_id = effective_on_session_id,
    on_text = function(text)
      response[#response + 1] = text
      selection_state.append(text, session_id)
    end,
    on_progress = function(text)
      selection_state.set_progress(text, session_id)
    end,
    on_handle = function(agent_handle)
      handle = agent_handle
      selection_state.attach_process(session_id, agent_handle, {
        lane = lane,
        provider = provider,
      })
    end,
    on_exit = function(result)
      local was_open = selection_state.is_open(session_id)
      local run_session = selection_state.get_session(session_id)
      local cancelled = run_session
        and (
          (handle and run_session.cancelled_handles and run_session.cancelled_handles[handle] == true)
          or (not handle and run_session.cancelled == true)
        )
      if run_session and handle and run_session.cancelled_handles then
        run_session.cancelled_handles[handle] = nil
      end
      selection_state.clear_process(session_id, handle)
      selection_state.set_busy(false, session_id)
      if run_session and cancelled then
        run_session.cancelled = false
      end
      if cancelled then
        return
      end
      local opened_diff = false
      if result.code ~= 0 then
        selection_state.append("\n[nvime] edit failed with code " .. tostring(result.code) .. "\n", session_id)
        -- Detect the "stale resume id" failure mode (claude/codex reject a
        -- session id we tried to --resume) and notify the caller via
        -- session_opts.on_run_failed so it can clear the bad id. This
        -- prevents the infinite-retry loop where each failed resume
        -- rotates a new bad id that we then resume against.
        local response_text = table.concat(response or {})
        local stale_resume = response_text:find("No conversation found", 1, true) ~= nil
          or response_text:find("session not found", 1, true) ~= nil
          or response_text:find("session_id", 1, true) ~= nil
            and response_text:lower():find("not found", 1, true) ~= nil
        if type(session_opts.on_run_failed) == "function" then
          pcall(session_opts.on_run_failed, {
            code = result.code,
            stale_resume = stale_resume,
            response_excerpt = response_text:sub(1, 500),
          })
        end
      else
        local ok, diff_result = pcall(diff.start_session, selection, table.concat(response), provider, prompt)
        if not ok then
          selection_state.append("\n[nvime] " .. tostring(diff_result) .. "\n", session_id)
        elseif diff_result and diff_result.status == "no_change" then
          selection_state.append("\n[nvime] no patch opened.\n", session_id)
        elseif diff_result and diff_result.session then
          diff_result.session.selection_session_id = session_id
          -- Plan linkage: when the run was launched by plan.execute_step,
          -- tag the diff session with the plan + step id so attribution
          -- entries persist that linkage when blocks are accepted.
          if session_opts.plan_id then
            diff_result.session.plan_id = session_opts.plan_id
            diff_result.session.plan_step_id = session_opts.plan_step_id
          end
          -- Plumb the caller's on_resolved hook onto the new diff session.
          -- Used by plan.execute_step to auto-run step.tests when the user
          -- accepts/rejects every block.
          if type(session_opts.on_resolved) == "function" then
            diff_result.session.on_resolved = session_opts.on_resolved
          end
          -- Devil's-advocate critic: opt-in. Fire async; the verdict banner
          -- appears in the diff review when it lands. Never blocks the user.
          local cfg_diff = (state.config or {}).diff or {}
          local enable_critic = session_opts.devils_advocate
          if enable_critic == nil then
            enable_critic = cfg_diff.devils_advocate == true
          end
          if enable_critic then
            local ok_critic, critic = pcall(require, "nvime.critic")
            if ok_critic and critic and type(critic.review) == "function" then
              critic.review(diff_result.session, {
                provider = provider,
                intent = intent,
                rationale = diff_result.session.rationale,
              })
            end
          end
          opened_diff = true
        end
      end
      arm_edit_followup(
        selection,
        provider,
        session_id,
        not opened_diff and was_open and selection_state.active_session_id() == session_id
      )
      if not opened_diff and not was_open then
        selection_state.notify_finished("edit", session_id, result.code)
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
  -- `force_edit = true` skips the question-shaped reroute. Used by the plan
  -- executor where the agent ALWAYS needs to be the patch worker, regardless
  -- of words like "review" / "verify" / "?" appearing in the plan-context
  -- header that we prepend to the intent.
  local force_edit = opts.force_edit == true
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
        on_submit = function(input, selected_provider, lane)
          submit_edit(selection, proceed_provider, input, selected_provider, selection_state.active_session_id(), lane)
        end,
      })
      return
    end

    if not force_edit and looks_like_question(intent) then
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
      on_submit = function(input, selected_provider, lane)
        submit_edit(selection, provider, input, selected_provider, selection_state.active_session_id(), lane)
      end,
    })
    return
  end

  if not force_edit and looks_like_question(intent) then
    require("nvime.ask").start({
      selection = selection,
      provider = provider,
      question = intent,
      session_id = opts.session_id,
      new_session = opts.new_session,
    })
    return
  end

  run_edit(selection, intent, provider, {
    session_id = opts.session_id,
    new_session = opts.new_session,
    on_resolved = opts.on_resolved,
    on_run_failed = opts.on_run_failed,
    devils_advocate = opts.devils_advocate,
    plan_continuity = opts.plan_continuity,
    plan_id = opts.plan_id,
    plan_step_id = opts.plan_step_id,
  })
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
      local handle
      handle = agents.run({
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
        on_handle = function(agent_handle)
          handle = agent_handle
          selection_state.attach_process(selection_session_id, agent_handle, {
            lane = "discuss",
            provider = selected_provider,
          })
        end,
        on_exit = function(result)
          local was_open = selection_state.is_open(selection_session_id)
          local run_session = selection_state.get_session(selection_session_id)
          local cancelled = run_session
            and (
              (handle and run_session.cancelled_handles and run_session.cancelled_handles[handle] == true)
              or (not handle and run_session.cancelled == true)
            )
          if run_session and handle and run_session.cancelled_handles then
            run_session.cancelled_handles[handle] = nil
          end
          selection_state.clear_process(selection_session_id, handle)
          selection_state.set_busy(false, selection_session_id)
          if run_session and cancelled then
            run_session.cancelled = false
          end
          if cancelled then
            return
          end
          local body = table.concat(response)
          local opened_diff = false
          if
            body:find("NVIME_DIFF", 1, true)
            or body:find("NVIME_REPLACEMENT", 1, true)
            or body:find("```diff", 1, true)
            or body:match("^%s*%-%-%- a/")
          then
            local ok, diff_result = pcall(diff.start_session, session.selection, body, selected_provider, prompt)
            if not ok then
              selection_state.append("\n[nvime] " .. tostring(diff_result) .. "\n", selection_session_id)
            elseif diff_result and diff_result.status == "no_change" then
              selection_state.append("\n[nvime] no updated patch opened.\n", selection_session_id)
            elseif diff_result and diff_result.session then
              diff_result.session.selection_session_id = selection_session_id
              opened_diff = true
            end
          end
          if result.code ~= 0 then
            selection_state.append(
              "\n[nvime] discuss failed with code " .. tostring(result.code) .. "\n",
              selection_session_id
            )
          end
          if opened_diff then
            selection_state.close()
          elseif not was_open then
            selection_state.notify_finished("edit", selection_session_id, result.code)
          end
        end,
      })
      if not handle then
        selection_state.set_busy(false, selection_session_id)
      end
    end,
  })
end

return M
