local agents = require("nvime.agents")
local diff = require("nvime.diff")
local git = require("nvime.git")
local selection_state = require("nvime.selection")
local state = require("nvime.state")
local ts = require("nvime.treesitter")
local usage = require("nvime.usage")

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

local function edit_config()
  return (state.config or {}).edit or {}
end

local function context_enabled()
  return edit_config().inject_context ~= false
end

local function root_dir(selection)
  if selection and selection.bufnr and vim.api.nvim_buf_is_valid(selection.bufnr) then
    local name = vim.api.nvim_buf_get_name(selection.bufnr)
    if name and name ~= "" then
      return git.repo_root(vim.fn.fnamemodify(name, ":p:h"))
    end
  end
  return git.repo_root()
end

local function rel_join(dir, name)
  if not dir or dir == "" or dir == "." then
    return name
  end
  return dir .. "/" .. name
end

local function normalize_rel(rel)
  if not rel or rel == "" then
    return nil
  end
  rel = rel:gsub("\\", "/"):gsub("^%./", "")
  if rel:sub(1, 1) == "/" then
    return nil
  end
  for segment in rel:gmatch("[^/]+") do
    if segment == ".." then
      return nil
    end
  end
  return rel
end

local function root_relative(root, path)
  if not path or path == "" then
    return nil
  end
  path = path:gsub("\\", "/")
  if path:sub(1, 1) ~= "/" then
    return normalize_rel(path)
  end
  local abs_root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "")
  local abs_path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  if vim.fs and vim.fs.relpath then
    local rel = vim.fs.relpath(abs_root, abs_path)
    if rel and rel ~= "" then
      return normalize_rel(rel)
    end
  end
  if abs_path:sub(1, #abs_root + 1) == abs_root .. "/" then
    return normalize_rel(abs_path:sub(#abs_root + 2))
  end
  return nil
end

local function readable_rel(root, rel)
  rel = normalize_rel(rel)
  if not rel then
    return false
  end
  return vim.fn.filereadable(root .. "/" .. rel) == 1
end

local function add_unique(out, seen, root, rel)
  rel = normalize_rel(rel)
  if not rel or seen[rel] or not readable_rel(root, rel) then
    return
  end
  seen[rel] = true
  out[#out + 1] = rel
end

local function related_test_files(selection, root)
  local limit = math.max(0, tonumber(edit_config().related_test_limit) or 4)
  if limit == 0 or not selection or not selection.path then
    return {}
  end
  local out, seen = {}, {}
  local path = root_relative(root, selection.path)
  if not path then
    return out
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  local base = vim.fn.fnamemodify(path, ":t:r")
  local ext = vim.fn.fnamemodify(path, ":e")
  local suffix = ext ~= "" and ("." .. ext) or ""
  local candidates = {
    "test_" .. base .. suffix,
    base .. "_test" .. suffix,
    base .. "_spec" .. suffix,
    rel_join(dir, "test_" .. base .. suffix),
    rel_join(dir, base .. "_test" .. suffix),
    rel_join(dir, base .. "_spec" .. suffix),
    "tests/test_" .. base .. suffix,
    "tests/" .. base .. "_test" .. suffix,
    "tests/" .. base .. "_spec" .. suffix,
    "test/test_" .. base .. suffix,
    "test/" .. base .. "_test" .. suffix,
    "spec/" .. base .. "_spec" .. suffix,
  }
  for _, rel in ipairs(candidates) do
    add_unique(out, seen, root, rel)
    if #out >= limit then
      return out
    end
  end
  local ok_plan, plan = pcall(require, "nvime.plan")
  if ok_plan and type(plan.detect_test_file) == "function" then
    add_unique(out, seen, root, plan.detect_test_file())
  end
  while #out > limit do
    out[#out] = nil
  end
  return out
end

local function detected_test_runner(related, root)
  local cfg = state.config or {}
  local configured = (cfg.test_loop or {}).runner or (cfg.plan or {}).test_runner
  local ok_plan, plan = pcall(require, "nvime.plan")
  if ok_plan and type(plan.detect_test_runner) == "function" then
    return plan.detect_test_runner({
      configured = configured,
      root = root or root_dir(),
      related = related,
    })
  end
  if configured and configured ~= "" then
    return configured
  end
  return nil
end

local function append_file_excerpt(lines, root, rel, max_file_lines)
  if not readable_rel(root, rel) then
    return
  end
  local ok, file_lines = pcall(vim.fn.readfile, root .. "/" .. rel)
  if not ok or type(file_lines) ~= "table" then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Related test file: " .. rel
  lines[#lines + 1] = "```"
  local cap = math.min(#file_lines, max_file_lines or 120)
  for i = 1, cap do
    lines[#lines + 1] = file_lines[i]
  end
  if #file_lines > cap then
    lines[#lines + 1] = "... [truncated " .. tostring(#file_lines - cap) .. " lines]"
  end
  lines[#lines + 1] = "```"
end

local function append_symbol_context(lines, selection)
  local limit = math.max(0, tonumber(edit_config().symbol_limit) or 24)
  if limit == 0 or not selection or not selection.bufnr then
    return
  end
  local ok, symbols = pcall(ts.walk_symbols, selection.bufnr)
  if not ok or type(symbols) ~= "table" or #symbols == 0 then
    return
  end
  local selected, fallback = {}, {}
  for _, sym in ipairs(symbols) do
    local row = string.format(
      "- %s `%s` lines %s-%s%s",
      sym.kind or "symbol",
      sym.name or "?",
      tostring(sym.line_start or "?"),
      tostring(sym.line_end or "?"),
      sym.parent and (" parent " .. sym.parent) or ""
    )
    if
      sym.line_start
      and sym.line_end
      and sym.line_end >= (selection.line1 or 1) - 20
      and sym.line_start <= (selection.line2 or selection.line1 or 1) + 20
    then
      selected[#selected + 1] = row
    elseif #fallback < limit then
      fallback[#fallback + 1] = row
    end
  end
  local source = #selected > 0 and selected or fallback
  if #source == 0 then
    return
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Current file symbol context:"
  for i = 1, math.min(limit, #source) do
    lines[#lines + 1] = source[i]
  end
end

-- Tail-scanning audit.jsonl cost grows with the file (already ~800 KB on
-- this checkout). Cache the most recent N "diff_resolved" formatted rows
-- keyed by (path, mtime, size); invalidated automatically when audit.write
-- appends a new line.
local recent_diff_cache = { key = nil, rows = nil }

local function append_recent_diff_context(lines)
  local limit = math.max(0, tonumber(edit_config().recent_diff_limit) or 5)
  if limit == 0 then
    return
  end
  local ok_audit, audit = pcall(require, "nvime.audit")
  if not ok_audit or type(audit.path) ~= "function" then
    return
  end
  local path = audit.path()
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat then
    return
  end
  local cache_key = string.format("%s\0%d\0%d", path, stat.mtime.sec or 0, stat.size or 0)
  local rows
  if recent_diff_cache.key == cache_key and recent_diff_cache.rows then
    rows = recent_diff_cache.rows
  else
    local ok, raw = pcall(vim.fn.readfile, path)
    if not ok or type(raw) ~= "table" then
      return
    end
    local found = {}
    -- Walk back, keep up to a generous cap so per-prompt limit changes
    -- don't force a re-scan.
    local cap = math.max(limit, 16)
    for i = #raw, 1, -1 do
      local decoded_ok, item = pcall(vim.json.decode, raw[i])
      if decoded_ok and type(item) == "table" and item.event == "diff_resolved" then
        found[#found + 1] = string.format(
          "- %s accepted %s/%s%s%s",
          item.path or "?",
          tostring(item.accepted or "?"),
          tostring(item.total or "?"),
          item.rationale and (" rationale: " .. tostring(item.rationale):sub(1, 160)) or "",
          item.verdict and (" verdict: " .. tostring(item.verdict)) or ""
        )
        if #found >= cap then
          break
        end
      end
    end
    recent_diff_cache.key = cache_key
    recent_diff_cache.rows = found
    rows = found
  end
  if #rows == 0 then
    return
  end
  local n = math.min(limit, #rows)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Recent accepted nvime diffs:"
  for i = n, 1, -1 do
    lines[#lines + 1] = rows[i]
  end
end

local function build_project_context(selection)
  if not context_enabled() then
    return nil
  end
  local root = root_dir(selection)
  local related = related_test_files(selection, root)
  local runner = detected_test_runner(related, root)
  local lines = {
    "Precomputed nvime project context.",
    "Use this before broad exploration; if it conflicts with live source, trust live source.",
    "Repo root: " .. root,
    "Detected test runner: " .. (runner or "(none detected)"),
  }
  if #related > 0 then
    lines[#lines + 1] = "Related test paths: " .. table.concat(related, ", ")
  else
    lines[#lines + 1] = "Related test paths: (none detected)"
  end
  append_symbol_context(lines, selection)
  for _, rel in ipairs(related) do
    append_file_excerpt(lines, root, rel, 120)
  end
  append_recent_diff_context(lines)
  local text = table.concat(lines, "\n")
  local max_chars = math.max(1000, tonumber(edit_config().context_max_chars) or 6000)
  if #text > max_chars then
    text = text:sub(1, max_chars) .. "\n... [precomputed context truncated]"
  end
  return text
end

local function build_quick_prompt(selection, intent)
  local selected_display, fence = selection_body_and_fence(selection)
  return table.concat({
    "NVIME QUICK FIX. Minimal patch worker — no tools, no file exploration.",
    "Fix the selected code based on the intent using ONLY what is shown below.",
    "If you cannot fix it without seeing more code, return NVIME_NO_CHANGE and state exactly what context you need.",
    "",
    "Response format (pick one):",
    "",
    "NVIME_NO_CHANGE",
    "<reason or what context you need>",
    "",
    "NVIME_REPLACEMENT",
    "```",
    "<full replacement for the selected range>",
    "```",
    "",
    "NVIME_DIFF",
    "```diff",
    "--- a/" .. (selection.path or "file"),
    "+++ b/" .. (selection.path or "file"),
    "@@ -<line>,<count> +<line>,<count> @@",
    "<hunks>",
    "```",
    "",
    "File: " .. (selection.path or "unknown"),
    "Range: " .. tostring(selection.line1 or 1) .. "-" .. tostring(selection.line2 or selection.line1 or 1),
    "Intent: " .. intent,
    "",
    "Selected code:",
    fence,
    selected_display,
    fence,
  }, "\n")
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
    "Allowed range: "
      .. tostring(selection.line1 or 1)
      .. "-"
      .. tostring(selection.line2 or selection.line1 or 1)
      .. " ("
      .. (selection.source or "range")
      .. ")",
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
  local project_context = build_project_context(selection)
  local context_fence = project_context and code_fence_for(project_context) or "```"
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
    "Do not narrate tool use or investigation steps. No 'I'll read...', no progress updates, no markdown outside the response block.",
    "You may only propose changes for the selected range in the current file.",
    "You may use read/search, web fetch/search, and shell commands such as curl for inspection, external docs, or tests when available.",
    "If nvime MCP tools are available, prefer their read-only project context helpers (symbols, recent diffs, session search, usage, git metadata) and bounded test runner before broad shell exploration.",
    "Before patching, you MUST do a verification pass. For each explicit requirement in the user's intent, simulate at least one edge case against the candidate. When tests/examples are available or a fast runner is obvious, inspect or run them before final output.",
    "For parsers, validators, normalizers, and path helpers: consume/validate the full input, preserve token boundaries, and reject or handle leftovers explicitly. Partial regex matches that ignore invalid text are bugs.",
    "Do not edit files directly. Do not mention patches for other files or ranges.",
    "A 'concrete change' means: a fix for an actual bug, an implementation for a documented-but-missing feature, or a literal textual change the intent asks for. Defensive code, type checks, comments, error-class additions, idiom polish, value-type substitutions (e.g. 0 vs 0.0, '' vs str()), and other speculative improvements are NOT concrete changes.",
    "If, after reading the selected code carefully, you cannot point to a specific incorrect behavior or a specific request the intent makes, return NVIME_NO_CHANGE with one short reason. NVIME_NO_CHANGE is the right answer when the code already meets its documented behavior.",
    "When the intent mixes review-style language ('check', 'verify', 'iterate through', 'make sure') with fix-style language ('fix', 'proceed'), still require a real bug before patching. Review framing alone never authorizes speculative edits.",
    "When the intent describes a bug ('crashes on X', 'hangs on Y', 'returns wrong value for Z') but the selected code already handles that exact case correctly, return NVIME_NO_CHANGE and briefly note that the described case is already handled. Do NOT silently re-implement a guard or fix that is already present.",
    "Before producing NVIME_DIFF, re-read the selected code: do not insert a line that already exists, do not duplicate an existing return/break/continue, and verify your hunk's context lines match the selected text exactly.",
    "Prefer NVIME_DIFF for any change to existing nonblank text. Use NVIME_DIFF with the smallest changed hunks only. NVIME_DIFF is required for Markdown, large selections, and selections containing code fences.",
    "NVIME_REPLACEMENT is acceptable for blank or near-blank selected ranges, tiny whole-range rewrites, or small selected ranges where several nearby lines must change and a minimal hunk would be brittle. The replacement is inserted verbatim at the selected range; no indentation is added for you. If the selection is a blank line inside an indented block (e.g. a Python function body), include the exact leading whitespace of the surrounding scope on every non-empty replacement line.",
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
    "VERIFY: (optional but encouraged when MCP is available).",
    "If the nvime MCP tools are available, call `nvime.verify_file` on the proposed full-file content BEFORE emitting NVIME_DIFF / NVIME_REPLACEMENT. Pass {file: <selected file>, content: <the file after applying your patch>} and report the result:",
    "  VERIFY: ok                     — parse clean, no checks reported issues",
    "  VERIFY: <N> findings           — checks reported issues; emit only if you have read them and still believe the patch is correct",
    "  VERIFY: skipped (<reason>)     — verify_file unavailable or no checks shipped for this language",
    "Place the VERIFY: line on its own row, next to RATIONALE: and above the NVIME_* marker. If verify reports a parse error, do not emit a patch — fix the proposal until it parses or return NVIME_NO_CHANGE.",
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
    "Allowed range: "
      .. tostring(selection.line1 or 1)
      .. "-"
      .. tostring(selection.line2 or selection.line1 or 1)
      .. " ("
      .. (selection.source or "range")
      .. ")",
    "Intent: " .. intent,
    table.concat(prior_context, "\n"),
    project_context and table.concat({
      "",
      "Precomputed context:",
      context_fence,
      project_context,
      context_fence,
    }, "\n") or "",
    "",
    "Selected code:",
    selected_fence,
    selected_display,
    selected_fence,
  }, "\n")
end

local run_edit

local edit_keywords = {
  "make",
  "change",
  "fix",
  "add",
  "remove",
  "replace",
  "implement",
  "refactor",
  "rename",
  "convert",
  "update",
  "handle",
  "delete",
  "move",
  "extract",
  "inline",
  "wrap",
  "unwrap",
  "rewrite",
}

local function has_edit_keyword(text)
  for _, kw in ipairs(edit_keywords) do
    local pattern = "%f[%w]" .. kw .. "%f[%W]"
    if text:find(pattern) then
      return true
    end
  end
  return false
end

local function looks_like_question(intent)
  local text = (intent or ""):lower()
  if text == "" then
    return false
  end
  if has_edit_keyword(text) then
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
  run_edit(selection, input, selected_provider, { session_id = active_session_id, lane = lane })
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
  local prior_session = session_opts.session_id and selection_state.get_session(session_opts.session_id)
  -- The persona of the conversation we may resume is set by its LAST agent run,
  -- not the panel's display mode (a UI toggle can flip `mode` to "edit" before
  -- any edit run has happened). Use the run persona so a resumed read-only ask
  -- conversation is correctly re-armed with the full edit contract.
  local prior_run_mode = prior_session and prior_session.last_run_mode
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
  local lane = session_opts.lane == "perf" and "perf" or session_opts.lane == "quick" and "quick" or "edit"
  -- Tag the conversation's persona for the NEXT turn's resume decision (read
  -- above for prior_run_mode). Set after prior_run_mode was captured, so this
  -- never clobbers the value the switch detection just used.
  selection_state.mark_run_mode(session_id, lane)
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

  local resuming = effective_resume and effective_resume ~= ""
  -- Only an edit-family persona already carries the patch contract. Resuming an
  -- ask (read-only), unknown, or any non-edit conversation means the agent still
  -- believes it must not patch — so re-send the FULL edit contract with an
  -- explicit override, not a terse "prior rules still apply" follow-up (which
  -- would re-assert the read-only persona and yield narrated, unappliable diffs).
  local edit_family = { edit = true, perf = true, quick = true }
  local prompt
  if resuming and not edit_family[prior_run_mode or ""] then
    prompt = table.concat({
      "MODE SWITCH — the earlier read-only instructions NO LONGER APPLY.",
      "You are now in nvime EDIT MODE. You MUST answer with a patch block",
      "(NVIME_DIFF or NVIME_REPLACEMENT) or NVIME_NO_CHANGE — never a narrated or",
      "fenced ```diff. Reuse anything you already learned about this code above.",
      "",
    }, "\n") .. build_prompt(selection, intent)
  elseif resuming then
    prompt = table.concat({
      "Follow-up on the same selection.",
      "The file, range, edit rules, and response format from the prior turn still apply.",
      "New intent: " .. intent,
    }, "\n")
  elseif lane == "perf" then
    prompt = build_perf_prompt(selection, intent)
  elseif lane == "quick" then
    prompt = build_quick_prompt(selection, intent)
  else
    prompt = build_prompt(selection, intent)
  end
  state.selection.last_edit_prompt = prompt
  local model = require("nvime.provider").current_model({ scope = "selection" })
  selection_state.set_busy(true, session_id)
  local handle
  handle = agents.run({
    provider = provider,
    lane = lane,
    prompt = prompt,
    model = model,
    max_turns = tonumber(edit_config().max_turns),
    persist_session = agent_session.persist_session,
    resume_session_id = effective_resume,
    previous_cumulative_usage = agent_session.previous_cumulative_usage,
    on_cumulative_usage = agent_session.on_cumulative_usage,
    on_session_id = effective_on_session_id,
    on_text = function(text)
      response[#response + 1] = text
      selection_state.append(text, session_id)
    end,
    on_progress = function(text)
      selection_state.set_progress(text, session_id)
      if edit_config().show_tool_log ~= false then
        selection_state.append(text, session_id)
      end
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
      if result.nvime_usage then
        local label = usage.run_summary(result.nvime_usage)
        if label then
          selection_state.append("\n[nvime] " .. label .. "\n", session_id)
        end
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

  -- Per-path policy gate. Migrations, lockfiles, and secrets default to
  -- `require_human`; the lane refuses with a policy_block audit event
  -- before any prompt is built.
  local ok_policy, policy_rules = pcall(require, "nvime.policy_rules")
  if ok_policy and policy_rules and type(policy_rules.guard) == "function" then
    local proceed_lane = opts.lane or "edit"
    if not policy_rules.guard(selection.path, proceed_lane) then
      return
    end
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

    -- Question-shaped intents are read-only by nature; route them to the
    -- ask lane instead of producing a patch. `force_edit` (plan executor)
    -- skips this so plan-context headers can't trip the heuristic.
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

    -- Intent linter. Vague prompts get a confirmation; questionable
    -- prompts get a notice and proceed. The plan executor (force_edit)
    -- prefixes a structured plan-context header that may itself look
    -- vague to the heuristic, so we skip the gate for plan steps.
    if not force_edit then
      local ok_intent, intent_mod = pcall(require, "nvime.intent")
      if ok_intent and intent_mod and type(intent_mod.guard) == "function" then
        if not intent_mod.guard(intent, { lane = "edit", assume_yes = opts.assume_yes }) then
          return
        end
      end
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
    local prefill = opts.prefill
    selection_state.prompt({
      provider = provider,
      mode = "edit",
      selection = selection,
      session_id = opts.session_id,
      new_session = opts.new_session,
      on_submit = function(input, selected_provider, lane)
        run_edit(selection, input, selected_provider or provider, {
          session_id = selection_state.active_session_id(),
          lane = lane,
          on_resolved = opts.on_resolved,
          on_run_failed = opts.on_run_failed,
          devils_advocate = opts.devils_advocate,
          plan_continuity = opts.plan_continuity,
          plan_id = opts.plan_id,
          plan_step_id = opts.plan_step_id,
        })
      end,
    })
    if prefill and prefill ~= "" then
      selection_state.insert_prompt(prefill)
    end
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
  local session = diff.current_session()
  if not session then
    vim.notify("No active nvime diff for the current buffer", vim.log.levels.WARN)
    return
  end
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
      local discuss_model = require("nvime.provider").current_model({ scope = "selection" })
      local handle
      handle = agents.run({
        provider = selected_provider,
        lane = "edit",
        prompt = prompt,
        input = remaining,
        model = discuss_model,
        persist_session = agent_session.persist_session,
        resume_session_id = agent_session.resume_session_id,
        on_session_id = agent_session.on_session_id,
        on_text = function(text)
          response[#response + 1] = text
          selection_state.append(text, selection_session_id)
        end,
        on_progress = function(text)
          selection_state.set_progress(text, selection_session_id)
          if edit_config().show_tool_log ~= false then
            selection_state.append(text, selection_session_id)
          end
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
          if result.nvime_usage then
            local label = usage.run_summary(result.nvime_usage)
            if label then
              selection_state.append("\n[nvime] " .. label .. "\n", selection_session_id)
            end
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

function M.quick_fix(opts)
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
    vim.notify("nvime quick fix requires a named file buffer", vim.log.levels.ERROR)
    return
  end
  local provider = opts.provider or state.config.provider
  local intent = opts.intent
  if not intent or intent == "" then
    selection_state.prompt({
      provider = provider,
      mode = "edit",
      selection = selection,
      on_submit = function(input, selected_provider)
        run_edit(selection, input, selected_provider or provider, { lane = "quick", new_session = true })
      end,
    })
    return
  end
  run_edit(selection, intent, provider, { lane = "quick", new_session = true })
end

-- Re-arm the panel's input for edit mode on an existing session, preserving the
-- selection/session. Used by the in-panel ask⇄edit toggle (nvime.selection).
M.arm_prompt = arm_edit_followup

M._build_prompt = build_prompt
M._build_perf_prompt = build_perf_prompt
M._build_quick_prompt = build_quick_prompt
M._looks_like_question = looks_like_question

return M
