-- nvime.test_loop
--
-- After every nvime diff session resolves with at least one accepted
-- block, run a project test command. On non-zero exit, capture the tail
-- of stdout+stderr and either auto-launch a follow-up edit run with the
-- failure (when state.config.test_loop.auto_fix is true) or prompt the
-- user for a yes/no.
--
-- Recursion is bounded by max_retries per (file, plan_id) pair so a
-- broken test can't drive an infinite fix loop.

local audit = require("nvime.audit")
local git = require("nvime.git")
local state = require("nvime.state")

local M = {}

local in_flight = {}
local retry_counters = {}

local function cfg()
  return (state.config or {}).test_loop or {}
end

local function enabled()
  if state.disabled then
    return false
  end
  return cfg().enabled == true
end

local function plan_test_runner()
  local plan_cfg = (state.config or {}).plan or {}
  if plan_cfg.test_runner and plan_cfg.test_runner ~= "" then
    return plan_cfg.test_runner
  end
  local ok, plan = pcall(require, "nvime.plan")
  if ok and type(plan.detect_test_runner) == "function" then
    return plan.detect_test_runner()
  end
  return nil
end

local function resolve_runner()
  local cmd = cfg().runner
  if cmd and cmd ~= "" then
    return cmd
  end
  return plan_test_runner()
end

local function repo_root()
  return git.root((vim.uv or vim.loop).cwd()) or (vim.uv or vim.loop).cwd()
end

local function counter_key(payload)
  local file = payload.path or "?"
  local plan_id = payload.plan_id or "ad-hoc"
  return file .. "::" .. plan_id
end

local function reset_counter(payload)
  retry_counters[counter_key(payload)] = nil
end

local function bump_counter(payload)
  local key = counter_key(payload)
  retry_counters[key] = (retry_counters[key] or 0) + 1
  return retry_counters[key]
end

local function tail_lines(text, limit)
  limit = limit or 200
  if not text or text == "" then
    return ""
  end
  local lines = vim.split(text, "\n", { plain = true })
  if #lines <= limit then
    return text
  end
  local out = {}
  for i = #lines - limit + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return "[truncated " .. tostring(#lines - limit) .. " earlier lines]\n" .. table.concat(out, "\n")
end

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("nvime tests: " .. msg, level or vim.log.levels.INFO)
  end)
end

local function build_followup_prompt(payload, runner, captured)
  local plan_meta = ""
  if payload.plan_id then
    plan_meta = string.format("\nplan: %s · step %s\n", payload.plan_id, tostring(payload.plan_step_id or "?"))
  end
  return table.concat({
    "NVIME TEST-FEEDBACK FOLLOWUP.",
    "The patch you just helped land caused the project test runner to fail.",
    "Read the failure tail below, identify the smallest correct fix, and propose a focused patch.",
    plan_meta,
    "Test runner: `" .. runner .. "`",
    "",
    "Failure tail (last lines of stdout+stderr):",
    "----",
    captured,
    "----",
    "",
    "Constraints:",
    "  - Stay inside the file you just modified unless the failure clearly points elsewhere.",
    "  - Make the smallest reviewable change.",
    "  - Re-run the same test command, or use the nvime test_run MCP tool if it is available.",
    "  - If the test is wrong (rather than the code), say so explicitly and propose updating the test instead.",
  }, "\n")
end

local CONTEXT_MARGIN = 5

-- Convert applied_history (per-block deltas) into a single (start, end)
-- range in the post-application buffer, anchored around the lines the
-- accepted blocks landed on. Falls back to the whole buffer when history
-- is missing. The margin gives the follow-up agent room to look at
-- surrounding code without handing it the whole file.
local function followup_range(payload)
  local bufnr = payload.target_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, nil
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  local history = payload.applied_history
  if type(history) ~= "table" or #history == 0 then
    return 1, last
  end
  -- Walk blocks in order and track cumulative delta from earlier blocks.
  table.sort(history, function(a, b)
    return ((a.block or {}).old_start or 0) < ((b.block or {}).old_start or 0)
  end)
  local delta = 0
  local lo, hi
  for _, entry in ipairs(history) do
    local block = entry.block or {}
    local start = (block.old_start or 1) + delta
    local span = math.max(block.old_count or 0, #(entry.new_lines or {}))
    local stop = start + math.max(span - 1, 0)
    lo = lo and math.min(lo, start) or start
    hi = hi and math.max(hi, stop) or stop
    delta = delta + ((entry.new_lines and #entry.new_lines) or 0) - (block.old_count or 0)
  end
  if not lo or not hi then
    return 1, last
  end
  lo = math.max(1, lo - CONTEXT_MARGIN)
  hi = math.min(last, hi + CONTEXT_MARGIN)
  return lo, hi
end

local function launch_followup(payload, runner, captured)
  local edit_intent = build_followup_prompt(payload, runner, captured)
  vim.schedule(function()
    local ok, edit = pcall(require, "nvime.edit")
    if not ok then
      notify("could not load nvime.edit for follow-up", vim.log.levels.ERROR)
      return
    end
    if not payload.target_bufnr or not vim.api.nvim_buf_is_valid(payload.target_bufnr) then
      notify("buffer for follow-up was closed", vim.log.levels.WARN)
      return
    end
    local lo, hi = followup_range(payload)
    if not lo or not hi then
      notify("could not resolve follow-up range", vim.log.levels.WARN)
      return
    end
    edit.start({
      selection = {
        bufnr = payload.target_bufnr,
        path = payload.path,
        line1 = lo,
        line2 = hi,
        source = "test_loop",
      },
      provider = payload.provider,
      intent = edit_intent,
      force_edit = true,
      plan_id = payload.plan_id,
      plan_step_id = payload.plan_step_id,
    })
  end)
end

local function detect_venv_path(cwd)
  local candidates = { ".venv/bin", "venv/bin", ".env/bin", "env/bin" }
  for _, rel in ipairs(candidates) do
    local bin = cwd .. "/" .. rel
    if vim.fn.isdirectory(bin) == 1 then
      return bin
    end
  end
  local venv = vim.env.VIRTUAL_ENV
  if venv and venv ~= "" and vim.fn.isdirectory(venv .. "/bin") == 1 then
    return venv .. "/bin"
  end
  return nil
end

local function run_runner(runner, cwd, on_done)
  local stdout_chunks = {}
  local stderr_chunks = {}
  local env = nil
  local venv_bin = detect_venv_path(cwd)
  if venv_bin then
    env = vim.fn.environ()
    env.PATH = venv_bin .. ":" .. (env.PATH or "/usr/bin:/bin")
  end
  -- sh -c, NOT -lc: a login shell sources the user's profile and may cd
  -- to $HOME, which would defeat the cwd we set explicitly.
  local handle = vim.system({ "sh", "-c", runner }, {
    text = true,
    cwd = cwd,
    env = env,
    stdout = function(_, data)
      if data then
        stdout_chunks[#stdout_chunks + 1] = data
      end
    end,
    stderr = function(_, data)
      if data then
        stderr_chunks[#stderr_chunks + 1] = data
      end
    end,
  }, function(result)
    vim.schedule(function()
      on_done(result.code or -1, table.concat(stdout_chunks), table.concat(stderr_chunks))
    end)
  end)
  return handle
end

local function format_decision(payload, runner, retries, code, tail)
  local plan_label = payload.plan_id and (" · plan " .. payload.plan_id) or ""
  notify(
    string.format(
      "%s exit=%d (retry %d/%d%s)\n%s",
      runner,
      code,
      retries,
      tonumber(cfg().max_retries) or 2,
      plan_label,
      tail:sub(1, 1500)
    ),
    code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
  )
end

function M.maybe_run(payload)
  if not enabled() or not payload then
    return
  end
  if not payload.accepted or payload.accepted == 0 then
    return
  end
  if payload.session and payload.session.test_loop_skip then
    return
  end
  local runner = resolve_runner()
  if not runner or runner == "" then
    return
  end
  local key = counter_key(payload)
  if in_flight[key] then
    return
  end
  in_flight[key] = true

  audit.write({
    event = "test_loop_start",
    runner = runner,
    path = payload.path,
    plan_id = payload.plan_id,
    plan_step_id = payload.plan_step_id,
  })

  -- Resolve cwd at fire time. Anchor to the patched buffer's git root
  -- (or its directory when no git root is available) so external code
  -- that mutates the process cwd between calls cannot derail us.
  -- Crucially: if the buffer's directory is NOT inside a git repo, we
  -- use the directory itself rather than letting git.root walk up to a
  -- spurious upstream repo (the test workspace creates throwaway dirs
  -- under /tmp where unrelated `git init` runs may have happened).
  local cwd
  if payload.target_bufnr and vim.api.nvim_buf_is_valid(payload.target_bufnr) then
    local name = vim.api.nvim_buf_get_name(payload.target_bufnr)
    if name and name ~= "" then
      local dir = vim.fn.fnamemodify(name, ":h")
      local file_root = git.root(dir)
      if file_root and (dir == file_root or dir:sub(1, #file_root + 1) == file_root .. "/") then
        cwd = file_root
      else
        cwd = dir
      end
    end
  end
  cwd = cwd or repo_root()

  notify("running `" .. runner .. "` ...")
  -- vim.system throws synchronously if cwd no longer exists (e.g. the patched
  -- buffer lived in a throwaway /tmp dir that was removed). Without this guard
  -- the throw escapes maybe_run with in_flight[key] still set, permanently
  -- blocking the test loop for this (file, plan) pair for the rest of the
  -- session. Reset the flag and surface the failure instead.
  local spawn_ok, spawn_err = pcall(run_runner, runner, cwd, function(code, stdout, stderr)
    in_flight[key] = nil
    local combined = tail_lines((stdout or "") .. (stderr or ""), tonumber(cfg().capture_lines) or 200)
    audit.write({
      event = "test_loop_done",
      runner = runner,
      code = code,
      path = payload.path,
      plan_id = payload.plan_id,
      plan_step_id = payload.plan_step_id,
    })
    if code == 0 then
      reset_counter(payload)
      notify("`" .. runner .. "` passed.", vim.log.levels.INFO)
      return
    end
    local retries = bump_counter(payload)
    local cap = tonumber(cfg().max_retries) or 2
    format_decision(payload, runner, retries, code, combined)
    if retries > cap then
      notify(string.format("max_retries (%d) reached. Stopping.", cap), vim.log.levels.WARN)
      reset_counter(payload)
      return
    end
    if cfg().auto_fix == true then
      launch_followup(payload, runner, combined)
      return
    end
    vim.schedule(function()
      local choice = vim.fn.confirm("Tests failed. Ask agent to fix?", "&Yes\n&No", 2)
      if choice == 1 then
        launch_followup(payload, runner, combined)
      else
        -- Decline ends the loop for this (file, plan) pair; clear the
        -- counter so the next genuine failure starts fresh.
        reset_counter(payload)
      end
    end)
  end)
  if not spawn_ok then
    in_flight[key] = nil
    audit.write({
      event = "test_loop_done",
      runner = runner,
      code = -1,
      path = payload.path,
      plan_id = payload.plan_id,
      plan_step_id = payload.plan_step_id,
      spawn_error = tostring(spawn_err),
    })
    notify("could not start `" .. runner .. "`: " .. tostring(spawn_err), vim.log.levels.WARN)
  end
end

local registered = false

function M.setup()
  if registered then
    return
  end
  state.diff_post_resolve_hooks = state.diff_post_resolve_hooks or {}
  table.insert(state.diff_post_resolve_hooks, function(payload)
    M.maybe_run(payload)
  end)
  registered = true
end

function M.reset_counters()
  retry_counters = {}
  in_flight = {}
end

return M
