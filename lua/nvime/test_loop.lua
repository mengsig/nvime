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

local uv = vim.uv or vim.loop

local DEFAULT_TIMEOUT_MS = 120000

-- Grace added on top of the configured timeout for vim.system's NATIVE timeout,
-- used purely as a backstop killer (see run_runner). Our own uv timer fires at
-- exactly `limit` and SIGTERMs the runner from the main loop; the native timeout
-- only matters if that main-loop kill never lands (it didn't reliably terminate
-- the runner from the fast-event context on CI). The grace guarantees our timer
-- sets the authoritative `timed_out` flag before any kill-provoked exit callback.
local TIMEOUT_BACKSTOP_GRACE_MS = 2000

-- Boundary slop for the wall-clock timeout verdict. The killers fire at-or-after
-- `limit`, but libuv's oneshot timer can fire a hair shy of it, so a process
-- SIGTERMed at the deadline may report elapsed a touch under `limit`. This
-- margin absorbs that jitter; at the default 120s limit the false-positive
-- window (a genuine pass finishing within 50ms of the limit) is negligible.
local TIMEOUT_SLOP_MS = 50

local in_flight = {}
local retry_counters = {}

local function cfg()
  return (state.config or {}).test_loop or {}
end

-- Per-run wall-clock timeout. nil falls back to the default; 0 disables it
-- (no timeout). A hanging runner would otherwise never fire vim.system's exit
-- callback, leaving in_flight[key] set forever and wedging the (file, plan)
-- pair for the rest of the session.
local function timeout_ms()
  local v = tonumber(cfg().timeout_ms)
  if v == nil then
    return DEFAULT_TIMEOUT_MS
  end
  return v
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
  local limit = timeout_ms()
  local sys_opts = {
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
  }
  -- Own the timeout DECISION instead of inferring it from the exit code:
  -- vim.system's termination surfaces in build-dependent encodings (code 124,
  -- or code 0 with signal 15, or code 143 with signal 0, …) and reverse-
  -- engineering which one means "timed out" is not portable. So an authoritative
  -- `timed_out` flag is set by our own one-shot timer at exactly `limit`.
  --
  -- Owning the KILL from that fast-event timer callback, however, did NOT
  -- reliably terminate the runner on CI's neovim build (the exit callback then
  -- never fired within budget and the loop looked wedged). So the kill is
  -- issued from the MAIN loop (vim.schedule) AND vim.system's native `timeout`
  -- is armed as a backstop killer — it provably SIGTERMs the runner and fires
  -- the exit callback on every build. The native timeout is set a grace above
  -- `limit` so our timer always records `timed_out` first; the verdict still
  -- depends only on our flag, never on the native timeout's exit encoding. The
  -- exit callback ALWAYS fires, so in_flight is always cleared and a hanging
  -- test can never wedge the loop.
  if limit and limit > 0 then
    sys_opts.timeout = limit + TIMEOUT_BACKSTOP_GRACE_MS
  end
  local timer
  local timed_out = false
  local handle
  local function stop_timer()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end
  local started = uv.hrtime()
  -- sh -c, NOT -lc: a login shell sources the user's profile and may cd
  -- to $HOME, which would defeat the cwd we set explicitly.
  handle = vim.system({ "sh", "-c", runner }, sys_opts, function(result)
    stop_timer()
    local code = result.code or -1
    -- Decide "timed out" from WALL-CLOCK elapsed, not from whether the fast-
    -- context timer callback above won the race to set `timed_out` first. During
    -- vim.wait on CI's neovim build that uv timer callback does NOT reliably fire
    -- before the native-timeout backstop reaps the runner, so reading the flag
    -- alone reported a hang as a plain failure. The killers (our scheduled kill
    -- and vim.system's native timeout) both fire at-or-after `limit`, so a hang
    -- always has elapsed >= limit by the time this exit callback runs — which it
    -- always does (clearing in_flight). The flag stays as a fast-path OR.
    local elapsed_ms = (uv.hrtime() - started) / 1e6
    local hit_timeout = timed_out or (limit and limit > 0 and elapsed_ms >= limit - TIMEOUT_SLOP_MS)
    vim.schedule(function()
      on_done(code, table.concat(stdout_chunks), table.concat(stderr_chunks), hit_timeout)
    end)
  end)
  if limit and limit > 0 then
    timer = uv.new_timer()
    -- The timer fires on a later loop tick, so `handle` is assigned by then.
    -- Set the authoritative flag here, then issue the kill from the main loop
    -- (the fast-context kill was unreliable on CI). If the process already
    -- exited the kill is a harmless no-op (pcall guards the nil-self /
    -- already-reaped cases). The native `timeout` backstop above guarantees the
    -- runner is reaped even if this scheduled kill never lands.
    timer:start(limit, 0, function()
      timed_out = true
      vim.schedule(function()
        pcall(handle.kill, handle, "sigterm")
      end)
    end)
  end
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
  local spawn_ok, spawn_err = pcall(run_runner, runner, cwd, function(code, stdout, stderr, timed_out)
    in_flight[key] = nil
    local combined = tail_lines((stdout or "") .. (stderr or ""), tonumber(cfg().capture_lines) or 200)
    audit.write({
      event = "test_loop_done",
      runner = runner,
      code = code,
      timed_out = timed_out or nil,
      path = payload.path,
      plan_id = payload.plan_id,
      plan_step_id = payload.plan_step_id,
    })
    -- A timeout is a hang, not a failing test: don't launch a "fix the
    -- failure" follow-up (there is no captured failure to fix). Free the loop
    -- and reset the retry counter so the next genuine run starts fresh.
    if timed_out then
      notify(
        string.format("`%s` timed out after %dms; stopping (not a code failure).", runner, timeout_ms()),
        vim.log.levels.WARN
      )
      reset_counter(payload)
      return
    end
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
