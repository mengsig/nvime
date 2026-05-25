-- nvime.policy_rules
--
-- Per-path policy: declarative rules that gate which files/ranges nvime
-- lanes are allowed to touch. Distinct from `lua/nvime/policy.lua`, which
-- installs Neovim-process guards around vim.system / jobstart / etc.; this
-- module reads `.nvime/policy.json` and returns rules consumed by
-- edit.start, diff.accept_blocks, and friends.
--
-- Rule shape (schema v1):
--   {
--     "version": 1,
--     "rules": [
--       { "match": "migrations/**", "require_human": true },
--       { "match": "**/*.lock",     "require_human": true },
--       { "match": "secrets/**",    "require_human": true,
--         "allow_lanes": [] },
--       { "match": "**/*.py",
--         "max_changed_lines": 80,
--         "allow_lanes": ["ask", "edit", "plan"] }
--     ]
--   }
--
-- Built-in defaults apply only when `.nvime/policy.json` is missing or
-- empty. When the project file exists, it fully replaces the defaults —
-- no silent merge. This is deliberate: the user's policy is the source of
-- truth and surprises are worse than verbose configs.

local audit = require("nvime.audit")
local state = require("nvime.state")

local M = {}

local SCHEMA_VERSION = 1

local DEFAULT_RULES = {
  { match = "migrations/**", require_human = true, reason = "default: migrations require human edits" },
  { match = "**/migrations/**", require_human = true, reason = "default: migrations require human edits" },
  { match = "*.lock", require_human = true, reason = "default: lockfiles require human edits" },
  { match = "**/*.lock", require_human = true, reason = "default: lockfiles require human edits" },
  { match = "package-lock.json", require_human = true, reason = "default: lockfile" },
  { match = "yarn.lock", require_human = true, reason = "default: lockfile" },
  { match = "pnpm-lock.yaml", require_human = true, reason = "default: lockfile" },
  { match = "Cargo.lock", require_human = true, reason = "default: lockfile" },
  { match = "secrets/**", require_human = true, reason = "default: secrets are human-only", allow_lanes = {} },
  { match = "**/secrets/**", require_human = true, reason = "default: secrets are human-only", allow_lanes = {} },
  { match = "**/.env", require_human = true, reason = "default: env file is human-only", allow_lanes = {} },
  { match = "**/.env.*", require_human = true, reason = "default: env file is human-only", allow_lanes = {} },
  { match = "**/*.pem", require_human = true, reason = "default: private key", allow_lanes = {} },
  { match = "**/*.key", require_human = true, reason = "default: private key", allow_lanes = {} },
}

local function cfg()
  return (state.config or {}).policy_rules or {}
end

local function enabled()
  return cfg().enabled ~= false
end

local function repo_root()
  local ok, git = pcall(require, "nvime.git")
  if ok and git and type(git.root) == "function" then
    return git.root((vim.uv or vim.loop).cwd())
  end
  return (vim.uv or vim.loop).cwd()
end

local function policy_path()
  local override = cfg().path
  if type(override) == "string" and override ~= "" then
    return vim.fn.fnamemodify(override, ":p")
  end
  local root = repo_root()
  if root then
    return root .. "/.nvime/policy.json"
  end
  return vim.fn.stdpath("state") .. "/nvime/policy.json"
end

local cached_rules
local cached_rules_signature

local function rules_signature()
  local uv = vim.uv or vim.loop
  local path = policy_path()
  local stat = uv.fs_stat(path)
  if not stat then
    return "default::no-file"
  end
  return string.format("%s::%d::%d", path, stat.mtime.sec or 0, stat.size or 0)
end

local function load_rules()
  local signature = rules_signature()
  if cached_rules and cached_rules_signature == signature then
    return cached_rules
  end
  local path = policy_path()
  if vim.fn.filereadable(path) ~= 1 then
    cached_rules = vim.deepcopy(DEFAULT_RULES)
    cached_rules_signature = signature
    return cached_rules
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    cached_rules = vim.deepcopy(DEFAULT_RULES)
    cached_rules_signature = signature
    return cached_rules
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.rules) ~= "table" then
    vim.schedule(function()
      vim.notify("nvime policy: " .. path .. " is malformed; using defaults", vim.log.levels.WARN)
    end)
    cached_rules = vim.deepcopy(DEFAULT_RULES)
    cached_rules_signature = signature
    return cached_rules
  end
  cached_rules = decoded.rules
  cached_rules_signature = signature
  return cached_rules
end

-- Reuse the verify glob matcher so policy and verify agree on glob shapes.
local function path_matches(path, glob)
  local ok, verify = pcall(require, "nvime.verify")
  if ok and verify and type(verify._path_matches_any) == "function" then
    return verify._path_matches_any(path, { glob })
  end
  return false
end

-- Public: list the active rule set (for :NvimePolicy list / check).
function M.rules()
  return load_rules()
end

function M.path()
  return policy_path()
end

-- Public: evaluate(path, lane, ctx) → { allowed, reason, rule, require_human, max_changed_lines, allow_lanes }.
-- `lane` is one of "ask", "edit", "plan", "accept" — gate callers pass the
-- nearest sensible value. `ctx` is an optional table with extra signals
-- (e.g. ctx.changed_lines used by max_changed_lines).
function M.evaluate(path, lane, ctx)
  ctx = ctx or {}
  if not enabled() then
    return { allowed = true, reason = "policy disabled" }
  end
  if not path or path == "" then
    return { allowed = true, reason = "no path" }
  end
  local rules = load_rules()
  local matched
  -- Longest glob wins; on tie, last-written wins. This lets project rules
  -- override broad built-in defaults by being more specific.
  local best_specificity = -1
  local best_index = -1
  for index, rule in ipairs(rules) do
    if type(rule) == "table" and type(rule.match) == "string" then
      if path_matches(path, rule.match) then
        local specificity = #rule.match
        if specificity > best_specificity or (specificity == best_specificity and index > best_index) then
          matched = rule
          best_specificity = specificity
          best_index = index
        end
      end
    end
  end
  if not matched then
    return { allowed = true, reason = "no matching rule", rule = nil }
  end
  local out = {
    allowed = true,
    rule = matched,
    require_human = matched.require_human == true,
    require_rationale_typed_by_user = matched.require_rationale_typed_by_user == true,
    max_changed_lines = tonumber(matched.max_changed_lines),
    allow_lanes = matched.allow_lanes,
  }
  if matched.require_human then
    out.allowed = false
    out.reason = matched.reason or "rule requires human edits"
    return out
  end
  if type(matched.allow_lanes) == "table" and lane then
    local found = false
    for _, allowed_lane in ipairs(matched.allow_lanes) do
      if allowed_lane == lane then
        found = true
        break
      end
    end
    if not found then
      out.allowed = false
      out.reason = string.format("lane %s not in allow_lanes for %s", lane, matched.match)
      return out
    end
  end
  if out.max_changed_lines and ctx.changed_lines and ctx.changed_lines > out.max_changed_lines then
    out.allowed = false
    out.reason = string.format(
      "diff changes %d lines, exceeds rule limit %d",
      ctx.changed_lines,
      out.max_changed_lines
    )
    return out
  end
  out.reason = "ok"
  return out
end

-- Public: refuse-or-allow helper used by lane entry points. Returns true
-- when the lane should proceed; writes a `policy_block` audit event and
-- notifies otherwise.
function M.guard(path, lane, ctx)
  local result = M.evaluate(path, lane, ctx)
  if result.allowed then
    return true, result
  end
  audit.write({
    event = "policy_block",
    file = path,
    lane = lane,
    reason = result.reason,
    rule = result.rule and result.rule.match or nil,
  })
  vim.schedule(function()
    vim.notify("nvime policy: " .. (result.reason or "blocked"), vim.log.levels.WARN)
  end)
  return false, result
end

M._default_rules = DEFAULT_RULES

return M
