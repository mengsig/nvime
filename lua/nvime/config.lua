local M = {}

M.defaults = {
  provider = "claude",
  providers = {
    claude = {
      cmd = "claude",
      models = { "opus", "sonnet", "haiku" },
    },
    codex = {
      cmd = "codex",
      models = { "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark" },
      reasoning_effort = nil,
    },
  },
  ui = {
    layout = "float",
    side = "right",
    width = 82,
    height = 24,
    float_width = 0.82,
    float_height = 0.72,
    dashboard_width = 0.86,
    dashboard_height = 0.9,
    border = "rounded",
    backdrop = 60,
    completion = "notify",
    nerd_font = true,
    ascii_icons = false,
    icons = {},
    spinner_frames = nil,
  },
  audit = {
    enabled = true,
    path = nil,
    log_prompts = false,
    -- Size-based rotation cap for the append-only audit log. When the live
    -- .nvime/audit.jsonl exceeds this many bytes, it is rotated to
    -- audit.jsonl.1 (one backup) and a fresh file is started, bounding disk
    -- use at ~2x this value. Set to 0 to disable rotation.
    max_bytes = 5 * 1024 * 1024,
  },
  attribution = {
    -- Per-line ledger: every accepted nvime diff block writes one entry to
    -- .nvime/attribution.json (in the git root) with rationale, critic
    -- verdict, plan + step linkage, and a content anchor so the entry
    -- survives later edits that shift line numbers.
    enabled = true,
    path = nil, -- defaults to .nvime/attribution.json in a git repo
    max = 500, -- oldest entries trimmed when the ledger exceeds this count
  },
  recap = {
    -- :NvimeRecap takes a git diff and asks the plan-lane agent to write
    -- a plan.md narrative explaining what changed, why, and what is
    -- untested. Output lands in .nvime/plans/recap-<hash>/.
    auto_open = true, -- open the recap in the plan view after it's drafted
  },
  guard = {
    enabled = true,
    strict = true,
    notify = true,
    wrap_vim_system = true,
    wrap_jobstart = true,
    wrap_termopen = true,
    wrap_system_functions = true,
    wrap_uv_spawn = true,
    kill_blocked_terminals = true,
    block_cmdline = true,
  },
  review = {
    allow_shell = true,
    allow_web = true,
    allow_markdown_writes = true,
  },
  selection = {
    allow_shell = true,
    allow_web = true,
  },
  edit = {
    context_lines = 0,
    inject_context = true,
    context_max_chars = 6000,
    related_test_limit = 4,
    symbol_limit = 24,
    recent_diff_limit = 5,
  },
  diff = {
    max_visual_block_lines = 12,
    -- Hunk @@-count drift detection. parse_hunks tolerates agent miscounts so
    -- the patch still applies, but a header that declares far fewer/more lines
    -- than it emits is surfaced (review banner + a hunk_count_mismatch audit
    -- event) instead of being absorbed silently. Drift is flagged when it
    -- exceeds max(hunk_count_tolerance_lines, ceil(hunk_count_tolerance_pct *
    -- declared)). Set hunk_count_tolerance_lines = 0 to disable.
    hunk_count_tolerance_lines = 3,
    hunk_count_tolerance_pct = 0.2,
    -- Devil's-advocate critic. When true, every accepted-into-review patch
    -- triggers a separate read-only agent that returns APPROVE / FLAG /
    -- REJECT in one sentence. The verdict is advisory and never blocks the
    -- user. Costs roughly one extra agent call per diff.
    devils_advocate = false,
  },
  verify = {
    -- Pre-accept verification lane. When a diff session opens, run cheap
    -- deterministic checks (tree-sitter parse + configured linters/type
    -- checkers) against the *proposed* full-file content. Findings render
    -- in the diff banner.
    enabled = true,
    -- Tree-sitter parses the proposed content; any ERROR node trips the
    -- gate.
    treesitter_parse = true,
    -- When the proposed content has a tree-sitter parse error, refuse
    -- silent ga/gA accept. gA!/`:NvimeAccept!` still works and writes a
    -- `verify_force` audit event.
    block_on_parse_error = true,
    -- Per-check timeout (milliseconds).
    timeout_ms = 8000,
    -- User-defined checks: each value is { match = { glob, ... }, cmd =
    -- function(tempfile) return { argv } end, parse = function(stdout,
    -- stderr) return findings end, kind = "lint"|"type"|"parse" }.
    -- See lua/nvime/verify.lua for the built-in shape and shipped checks
    -- (ruff/shellcheck/luacheck/selene/gofmt/zig ast-check/mypy).
    checks = {},
    -- Run the built-in / user-configured external linters & type-checkers
    -- (ruff, shellcheck, luacheck, gofmt, mypy, plus verify.checks). When
    -- false, only the tree-sitter parse gate runs; lint/type findings are
    -- suppressed entirely.
    external_checks = false,
    -- When true, the diff banner adds a collapsed per-tool breakdown row under
    -- the verify summary (e.g. "ruff 2 (E501) · shellcheck 1"). Off by default
    -- so the banner stays one line; only meaningful with external_checks = true.
    detail_in_banner = false,
  },
  risk = {
    -- Blast-radius badge in the diff banner. Computes lines added/removed,
    -- bracket drift (reused from diff.lua), ai-share from the attribution
    -- ledger, and sensitive/generated path tags from globs. Advisory; only
    -- `gA!` at the `high` level prompts a confirmation.
    enabled = true,
    sensitive_paths = nil, -- defaults: migrations/lockfiles/secrets/keys
    generated_globs = nil, -- defaults: protobuf/_generated/generated dirs
    thresholds = {
      lines = { medium = 40, high = 120 },
      ai_share = { high = 0.5 },
    },
    -- When true (default), force-accept on a high-risk diff prompts a
    -- confirmation; `risk_force` audit event fires on proceed.
    confirm_on_force_high = true,
  },
  policy_rules = {
    -- Per-path policy. Reads .nvime/policy.json (schema v1); when absent,
    -- a small built-in default flags migrations, lockfiles, secrets, and
    -- private keys as `require_human`. The project file fully replaces
    -- defaults rather than merging into them, so the active rule set is
    -- always exactly what the user has on disk.
    enabled = true,
    path = nil, -- defaults to .nvime/policy.json in the git root
  },
  intent = {
    -- Local intent linter. Refuses or warns on vague prompts BEFORE the
    -- model sees them. The default classifier is pure heuristic and runs
    -- inside Neovim with no network calls.
    enabled = true,
    -- Intents with fewer words than this are flagged as vague.
    min_words = 4,
    -- "heuristic" or "model".
    --   "heuristic" — pure local check, no network.
    --   "model"     — heuristic runs first; only when it returns
    --                 "questionable" does nvime consult a cheap model
    --                 (via the read-only critic lane) to disambiguate.
    --                 Verdicts are cached on disk under
    --                 .nvime/intent-cache.json keyed by intent hash.
    classifier = "heuristic",
    -- Model timeout (ms). Times out fall through to the heuristic
    -- verdict and do not block.
    model_timeout_ms = 5000,
  },
  pr = {
    -- :NvimePr renders .nvime/pr.md — a reviewer-facing summary of every
    -- AI-attributed hunk on the current branch, plus any review-first
    -- events (force-accepts, policy overrides, intent overrides).
    enabled = true,
    path = nil, -- defaults to .nvime/pr.md in the git root
    base_branch = nil, -- nil = auto-detect (origin/main → main → HEAD~1)
    include_unattributed = true,
  },
  chat = {
    max_history_messages = 24,
  },
  bigchange = {
    -- Forced-comprehension review relaxation for self-evident blocks. When a
    -- review block is only imports/requires, documentation/markdown prose,
    -- comments, or version/config bumps, it is auto-cleared (no explanation).
    -- Disabled implicitly on `extreme` difficulty, where everything must be
    -- explained. Never applies on `vibe` (which already auto-clears).
    trivial = {
      enabled = true,
      doc_globs = {
        "*.md",
        "*.markdown",
        "*.rst",
        "*.txt",
        "**/*.md",
        "**/*.markdown",
        "**/*.rst",
        "**/*.txt",
        "docs/**",
        "doc/**",
      },
    },
  },
  plan = {
    enabled = true,
    dir = nil, -- defaults to <git-root>/.nvime/plans
    auto_open = true, -- open the rendered plan view after authoring
    auto_in_progress = true, -- mark a step in_progress when its edit lane fires
    inject_context_chars = 480, -- per-step plan context block budget
    -- Devil's-advocate critic for plan executions. Defaults to true here
    -- (overrides diff.devils_advocate) because plan steps are structured,
    -- pre-approved by the user via the plan, and a critical second pass is
    -- worth the extra latency. Set to false to disable.
    devils_advocate = true,
    -- Default test file for the test scaffolder. Auto-detected when nil.
    test_file = nil,
    -- Default test runner shell command (e.g. "cargo test", "pytest -q",
    -- "zig build test", "./scripts/test"). Auto-detected from project
    -- markers (Cargo.toml, build.zig, go.mod, pyproject.toml,
    -- package.json, pom.xml, build.gradle, CMakeLists.txt, Makefile,
    -- scripts/test) when nil.
    test_runner = nil,
    -- Provider session continuity:
    --   "plan" : all steps of one plan share a provider conversation; the
    --            session id rotates and is persisted on plan.json. Press
    --            gN in the plan view to clear it.
    --   "none" : every step starts a fresh conversation (older nvime
    --            behavior; safer for very large plans where the session
    --            could blow past the context window).
    session_continuity = "plan",
  },
  sessions = {
    enabled = true,
    path = nil,
    chat_path = nil,
    max = 100,
  },
  usage = {
    -- Per-run token+cost ledger. When enabled, every agent_exit records the
    -- provider's usage envelope (claude `result.usage`, codex
    -- `turn.completed.usage`) into .nvime/usage.json. Costs are taken from
    -- claude's `total_cost_usd` when present; otherwise computed from
    -- per-million-token rates below (override per-model in `rates`).
    enabled = true,
    path = nil, -- defaults to .nvime/usage.json in a git repo
    max_days = 90,
    statusline = true,
    rates = {},
  },
  test_loop = {
    -- After every diff session resolves with at least one accepted block,
    -- run `runner` (or fall back to plan.test_runner). On non-zero exit,
    -- either auto-launch a follow-up edit prompt (auto_fix=true) or
    -- prompt the user. Capped at max_retries to prevent loops.
    enabled = false,
    runner = nil, -- shell command string; nil means use plan.test_runner / autodetect
    auto_fix = false,
    max_retries = 2,
    capture_lines = 200,
  },
  mcp = {
    -- MCP servers exposed to the agent. nvime synthesizes a config
    -- combining `servers` (user-defined) with `expose_self` (the built-in
    -- nvime MCP server when true). See lua/nvime/mcp_server.lua.
    enabled = true,
    config_path = nil, -- defaults to .nvime/mcp.json in a git repo
    servers = {},
    expose_self = true,
    self_command = nil, -- defaults to `nvim --headless --cmd "lua require('nvime.mcp_server').run()"`
    -- Codex's non-interactive `exec` mode auto-cancels every MCP tool
    -- call unless --dangerously-bypass-approvals-and-sandbox is set,
    -- which also disables codex's OS-level sandbox. Opt in here only
    -- when you want codex agents to use MCP tools and trust the
    -- shellguard layer to police the resulting shell access.
    codex_bypass_for_mcp = false,
  },
  keys = {
    enabled = true,
    prefix = "<leader>n",
    -- Warn (once at setup) when nvime overrides an existing mapping at one of
    -- its `<leader>n*` lhs — so a clobbered user binding is discovered at setup
    -- rather than silently. Set false to silence.
    warn_conflicts = true,
    normal = {
      dashboard = "<Space>",
      chat = "c",
      review = "r",
      edit = "e",
      ask = "q",
      audit = "a",
      discuss = "d",
      diff = "v",
      last = "n",
      provider = "p",
      model = "m",
      plan = "P",
      blame = "b",
      usage = "u",
      quick_fix = "f",
      send = "s",
      bigchange = "B",
    },
    visual = {
      edit = "e",
      ask = "q",
      quick_fix = "f",
      send = "s",
    },
  },
  prompts = {
    general = {
      {
        label = "Review repository",
        prompt = "Please review this repository for correctness, maintainability, and documentation drift. Run relevant read-only checks and summarize concrete findings.",
      },
      {
        label = "Update docs",
        prompt = "Please inspect the repository and ensure the Markdown documentation is accurate, complete, and easy for future agents to use.",
      },
      {
        label = "Explain architecture",
        prompt = "Please explain the repository architecture, important modules, data flow, and the safest places to make changes.",
      },
      {
        label = "Run tests",
        prompt = "Please run the relevant tests/checks, explain failures if any, and recommend the smallest next fix.",
      },
    },
    selection = {
      {
        label = "Review selection",
        prompt = "Please review this selection for correctness, maintainability, edge cases, and whether it fits the surrounding code.",
      },
      {
        label = "Explain selection",
        prompt = "Please explain what this selected code does and how it interacts with the rest of the repository.",
      },
      {
        label = "Suggest minimal diff",
        prompt = "Please suggest the smallest approvable diff for this selection, and avoid changing unrelated lines.",
      },
      {
        label = "Proceed with fix",
        prompt = "Please proceed with the concrete fix for this selection, keeping the change minimal and inside the selected range.",
      },
      {
        label = "Benchmark and optimize",
        prompt = "Profile this selection on representative inputs, propose a faster candidate, verify behavior parity, and only patch if there is a measurable speedup. Include a one-line BENCH summary above the response block.",
        lane = "perf",
      },
    },
    plan = {
      {
        label = "Investigate before planning",
        prompt = "Before drafting steps, read the relevant files, run any cheap checks (./scripts/test, lints), and confirm the actual code path. Cite real files and line ranges in the plan.",
      },
      {
        label = "Refactor with diff budget",
        prompt = "Decompose this refactor into the smallest reviewable steps. Each step must touch one file and stay under ~80 changed lines. Acceptance criteria must be checkable shell commands.",
      },
      {
        label = "Bug investigation plan",
        prompt = "Identify the root cause, the exact files and ranges to change, and a regression test. Steps should be ordered fix-first, test-second.",
      },
    },
  },
}

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local optional_types = {
  ["audit.path"] = { "string", "nil" },
  ["attribution.path"] = { "string", "nil" },
  ["sessions.path"] = { "string", "nil" },
  ["sessions.chat_path"] = { "string", "nil" },
  ["ui.spinner_frames"] = { "table", "nil" },
  ["plan.dir"] = { "string", "nil" },
  ["plan.test_file"] = { "string", "nil" },
  ["plan.test_runner"] = { "string", "nil" },
  ["edit.context_max_chars"] = { "number" },
  ["edit.related_test_limit"] = { "number" },
  ["edit.symbol_limit"] = { "number" },
  ["edit.recent_diff_limit"] = { "number" },
  ["usage.path"] = { "string", "nil" },
  ["usage.rates"] = { "table" },
  ["test_loop.runner"] = { "string", "nil" },
  ["mcp.config_path"] = { "string", "nil" },
  ["mcp.self_command"] = { "string", "nil" },
  ["mcp.servers"] = { "table" },
  ["verify.checks"] = { "table" },
  ["risk.sensitive_paths"] = { "list", "nil" },
  ["risk.generated_globs"] = { "list", "nil" },
}

local function type_label(value)
  if type(value) == "table" and is_list(value) then
    return "list"
  end
  return type(value)
end

local function matches_type(value, expected)
  if type(expected) == "table" then
    for _, item in ipairs(expected) do
      if matches_type(value, item) then
        return true
      end
    end
    return false
  end
  if expected == "list" then
    return is_list(value)
  end
  if expected == "integer" then
    return type(value) == "number" and value % 1 == 0
  end
  return type(value) == expected
end

local function validate_with_vim(path, value, expected)
  local validator = expected
  if expected == "integer" then
    validator = function(item)
      return matches_type(item, "integer")
    end
  elseif expected == "list" then
    validator = function(item)
      return is_list(item)
    end
  elseif type(expected) == "table" then
    validator = function(item)
      return matches_type(item, expected)
    end
  end
  if pcall(vim.validate, { [path] = { value, validator } }) then
    return true
  end
  if pcall(vim.validate, path, value, validator) then
    return true
  end
  return false
end

local function warn(warnings, message)
  warnings[#warnings + 1] = message
end

local function validate_leaf(warnings, path, value, expected)
  if not validate_with_vim(path, value, expected) or not matches_type(value, expected) then
    local label = type(expected) == "table" and table.concat(expected, "|") or expected
    warn(warnings, path .. " should be " .. label .. ", got " .. type_label(value))
  end
end

local function validate_provider(warnings, name, value)
  local path = "providers." .. tostring(name)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for key, item in pairs(value) do
    local child = path .. "." .. tostring(key)
    if key == "cmd" then
      validate_leaf(warnings, child, item, "string")
    elseif key == "model" then
      validate_leaf(warnings, child, item, "string")
    elseif key == "models" then
      if type(item) ~= "table" then
        validate_leaf(warnings, child, item, "table")
      end
    elseif key == "reasoning_effort" then
      validate_leaf(warnings, child, item, { "string", "nil" })
    else
      warn(warnings, "unknown nvime config key: " .. child)
    end
  end
end

local function validate_prompt_entry(warnings, path, value)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for key, item in pairs(value) do
    local child = path .. "." .. tostring(key)
    if key == "label" or key == "prompt" or key == "lane" then
      validate_leaf(warnings, child, item, "string")
    else
      warn(warnings, "unknown nvime config key: " .. child)
    end
  end
end

local function validate_prompts(warnings, path, value)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for name, items in pairs(value) do
    local child = path .. "." .. tostring(name)
    if not is_list(items) then
      validate_leaf(warnings, child, items, "list")
    else
      for index, item in ipairs(items) do
        validate_prompt_entry(warnings, child .. "." .. tostring(index), item)
      end
    end
  end
end

local function validate_icons(warnings, path, value)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for name, item in pairs(value) do
    validate_leaf(warnings, path .. "." .. tostring(name), item, "string")
  end
end

local function validate_table(warnings, user, schema, path)
  if type(user) ~= "table" then
    validate_leaf(warnings, path ~= "" and path or "opts", user, "table")
    return
  end
  for key, value in pairs(user) do
    if not (path == "" and key == "force") then
      local child = path ~= "" and (path .. "." .. tostring(key)) or tostring(key)
      if child == "providers" then
        if type(value) ~= "table" then
          validate_leaf(warnings, child, value, "table")
        else
          for provider_name, provider_opts in pairs(value) do
            validate_provider(warnings, provider_name, provider_opts)
          end
        end
      elseif child == "prompts" then
        validate_prompts(warnings, child, value)
      elseif child == "ui.icons" then
        validate_icons(warnings, child, value)
      elseif optional_types[child] then
        validate_leaf(warnings, child, value, optional_types[child])
      elseif schema[key] == nil then
        warn(warnings, "unknown nvime config key: " .. child)
      elseif type(schema[key]) == "table" and not is_list(schema[key]) then
        validate_table(warnings, value, schema[key], child)
      else
        validate_leaf(warnings, child, value, type_label(schema[key]))
      end
    end
  end
end

function M.validate(opts)
  local warnings = {}
  validate_table(warnings, opts or {}, M.defaults, "")
  for _, message in ipairs(warnings) do
    vim.notify(message, vim.log.levels.WARN)
  end
  return warnings
end

local function merge(base, override)
  local out = vim.deepcopy(base)
  for key, value in pairs(override or {}) do
    if type(value) == "table" and type(out[key]) == "table" and not is_list(value) then
      out[key] = merge(out[key], value)
    else
      out[key] = value
    end
  end
  return out
end

function M.resolve(opts)
  M.validate(opts or {})
  return merge(M.defaults, opts or {})
end

return M
