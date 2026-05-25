-- nvime.risk
--
-- Blast-radius scoring for a diff session. Reads the session's hunks, the
-- bracket-drift summary that diff.lua already computes, the attribution
-- ledger for the file, and a configurable list of sensitive-path globs.
-- Returns a compact table the diff banner renders as a `risk <level>` row:
--
--   risk medium · +42 −7 · brace +2 · ai 31% · migrations
--
-- This is not a security policy. Risk is *advisory*; only the `gA!` force
-- prompt at the `high` threshold actually adds friction. The audit event
-- `risk_force` fires whenever a high-risk diff is force-accepted, so the
-- digest can surface those decisions later.

local state = require("nvime.state")

local M = {}

local DEFAULT_SENSITIVE = {
  "migrations/**",
  "**/migrations/**",
  "*.lock",
  "**/*.lock",
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
  "Cargo.lock",
  "secrets/**",
  "**/secrets/**",
  "**/.env",
  "**/.env.*",
  "**/*.pem",
  "**/*.key",
}

local DEFAULT_GENERATED = {
  "**/*.pb.go",
  "**/*_pb2.py",
  "**/*_generated.*",
  "**/generated/**",
}

local DEFAULT_THRESHOLDS = {
  lines = { medium = 40, high = 120 },
  ai_share = { high = 0.5 },
}

local function cfg()
  return (state.config or {}).risk or {}
end

local function enabled()
  return cfg().enabled ~= false
end

local function sensitive_paths()
  local override = cfg().sensitive_paths
  if type(override) == "table" then
    return override
  end
  return DEFAULT_SENSITIVE
end

local function generated_globs()
  local override = cfg().generated_globs
  if type(override) == "table" then
    return override
  end
  return DEFAULT_GENERATED
end

local function thresholds()
  local override = cfg().thresholds or {}
  return {
    lines = vim.tbl_extend("force", vim.deepcopy(DEFAULT_THRESHOLDS.lines), override.lines or {}),
    ai_share = vim.tbl_extend("force", vim.deepcopy(DEFAULT_THRESHOLDS.ai_share), override.ai_share or {}),
  }
end

-- Reuse the basename-aware glob matcher from verify so risk and verify
-- agree on what "*.py" / "migrations/**" mean.
local function path_matches_any(path, globs)
  local ok, verify = pcall(require, "nvime.verify")
  if ok and verify and type(verify._path_matches_any) == "function" then
    return verify._path_matches_any(path, globs)
  end
  -- Fallback: substring match if verify is unavailable.
  if not path or not globs then
    return false
  end
  for _, glob in ipairs(globs) do
    if path:find(glob, 1, true) then
      return true
    end
  end
  return false
end

local function sensitive_tags(path)
  if not path or path == "" then
    return {}
  end
  local tags = {}
  if path_matches_any(path, sensitive_paths()) then
    tags[#tags + 1] = "sensitive"
  end
  if path_matches_any(path, generated_globs()) then
    tags[#tags + 1] = "generated"
  end
  return tags
end

-- Count added/removed lines across every hunk. Diff lines start with " ",
-- "+", "-"; we ignore hunk header lines (already stripped before they reach
-- session.hunks[].lines, but we be defensive about it).
local function count_diff_lines(session)
  local added, removed = 0, 0
  for _, hunk in ipairs(session.hunks or {}) do
    for _, line in ipairs(hunk.lines or {}) do
      local prefix = line:sub(1, 1)
      if prefix == "+" then
        added = added + 1
      elseif prefix == "-" then
        removed = removed + 1
      end
    end
  end
  return added, removed
end

local function bracket_drift_summary(drift)
  if not drift then
    return nil
  end
  local parts = {}
  if (drift.brace or 0) ~= 0 then
    parts[#parts + 1] = string.format("{}: %+d", drift.brace)
  end
  if (drift.paren or 0) ~= 0 then
    parts[#parts + 1] = string.format("(): %+d", drift.paren)
  end
  if (drift.bracket or 0) ~= 0 then
    parts[#parts + 1] = string.format("[]: %+d", drift.bracket)
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " ")
end

-- Sum line_count of every attribution entry for this file. This is a rough
-- proxy for "lines authored by an agent"; anchors can have stale line
-- counts after big edits, but it tracks the right direction without
-- materializing a live buffer-anchor map.
local function ai_lines_for_file(file)
  if not file or file == "" then
    return 0
  end
  local ok, attribution = pcall(require, "nvime.attribution")
  if not ok or not attribution or type(attribution.for_file) ~= "function" then
    return 0
  end
  local entries = attribution.for_file(file) or {}
  local total = 0
  for _, entry in ipairs(entries) do
    local anchor = entry.anchor or {}
    total = total + (tonumber(anchor.line_count) or 1)
  end
  return total
end

local function file_total_lines(session)
  if session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    return vim.api.nvim_buf_line_count(session.target_bufnr)
  end
  return #(session.original_lines or {})
end

local function classify(score_inputs)
  local thr = thresholds()
  local total_changed = (score_inputs.lines_added or 0) + (score_inputs.lines_removed or 0)
  local breaches = {}
  local level = "low"
  if total_changed >= thr.lines.high then
    level = "high"
    breaches[#breaches + 1] = "lines"
  elseif total_changed >= thr.lines.medium then
    level = "medium"
  end
  if (score_inputs.ai_share or 0) >= (thr.ai_share.high or 1) then
    if level ~= "high" then
      level = "high"
    end
    breaches[#breaches + 1] = "ai_share"
  end
  if #(score_inputs.sensitive_tags or {}) > 0 then
    if level == "low" then
      level = "medium"
    end
    if score_inputs.sensitive_tags[1] == "sensitive" then
      level = "high"
      breaches[#breaches + 1] = "sensitive"
    end
  end
  if score_inputs.bracket_drift_summary then
    if level == "low" then
      level = "medium"
    end
    breaches[#breaches + 1] = "bracket_drift"
  end
  return level, breaches
end

-- Public: compute risk for a session. Side-effect free.
function M.score(session)
  if not enabled() or not session then
    return nil
  end
  if session.risk and session.risk_signature == tostring(session.target_changedtick or 0) then
    return session.risk
  end

  local added, removed = count_diff_lines(session)
  local total = file_total_lines(session)
  local ai_lines = ai_lines_for_file(session.file)
  local ai_share = total > 0 and math.min(1.0, ai_lines / total) or 0
  local drift_summary = bracket_drift_summary(session.bracket_drift)
  local tags = sensitive_tags(session.file)
  local inputs = {
    lines_added = added,
    lines_removed = removed,
    ai_share = ai_share,
    bracket_drift_summary = drift_summary,
    sensitive_tags = tags,
  }
  local level, breaches = classify(inputs)
  local out = {
    level = level,
    breaches = breaches,
    lines_added = added,
    lines_removed = removed,
    ai_lines = ai_lines,
    ai_share = ai_share,
    bracket_drift_summary = drift_summary,
    sensitive_tags = tags,
  }
  session.risk = out
  session.risk_signature = tostring(session.target_changedtick or 0)
  return out
end

-- Public: render a single banner row { text, highlight } for the diff
-- review header. Always returns one row; the caller decides whether to
-- display it. icon_fn is the existing ui.icon helper.
function M.banner_row(session, icon_fn)
  local r = M.score(session)
  if not r then
    return nil
  end
  local parts = {}
  parts[#parts + 1] = string.format("+%d −%d", r.lines_added or 0, r.lines_removed or 0)
  if r.bracket_drift_summary then
    parts[#parts + 1] = r.bracket_drift_summary
  end
  parts[#parts + 1] = string.format("ai %d%%", math.floor((r.ai_share or 0) * 100 + 0.5))
  for _, tag in ipairs(r.sensitive_tags or {}) do
    parts[#parts + 1] = tag
  end
  local icon_name = (r.level == "high" and "warning") or (r.level == "medium" and "review") or "review"
  local hl = (r.level == "high" and "NvimeStatusError")
    or (r.level == "medium" and "NvimeStatusWarn")
    or "NvimeMuted"
  local text = string.format("  %s risk %s · %s", icon_fn and icon_fn(icon_name) or "", r.level, table.concat(parts, " · "))
  return { text, hl }
end

-- Public: confirm a high-risk force-accept. Returns true to proceed,
-- false to cancel. Writes a `risk_force` audit event on proceed (mirroring
-- the verify_force pattern).
function M.confirm_force_accept(session)
  local r = M.score(session)
  if not r or r.level ~= "high" then
    return true
  end
  if cfg().confirm_on_force_high == false then
    return true
  end
  local audit = require("nvime.audit")
  local choice = vim.fn.confirm(
    string.format(
      "nvime risk: %s — proceed with force-accept?\n  +%d −%d  ai %d%%  %s",
      r.level,
      r.lines_added,
      r.lines_removed,
      math.floor((r.ai_share or 0) * 100 + 0.5),
      table.concat(r.sensitive_tags or {}, " ")
    ),
    "&Force-accept\n&Cancel",
    2
  )
  if choice == 1 then
    audit.write({
      event = "risk_force",
      file = session.file,
      level = r.level,
      lines_added = r.lines_added,
      lines_removed = r.lines_removed,
      ai_share = r.ai_share,
      sensitive_tags = r.sensitive_tags,
    })
    return true
  end
  return false
end

M._classify = classify
M._sensitive_tags = sensitive_tags

return M
