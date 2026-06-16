-- nvime.diff.hunkmeta
--
-- Surfaces hunk @@-count drift. parse_hunks is deliberately lenient about the
-- agent's declared "@@ -a,b +c,d @@" counts — it recounts and corrects them so
-- the patch still applies — which means a header that declares "+1,3" while
-- emitting 10 added lines is silently absorbed. This module reports that drift
-- so it becomes a visible review signal (banner + audit), never a blocker.

local state = require("nvime.state")

local M = {}

local DEFAULT_TOLERANCE_LINES = 3
local DEFAULT_TOLERANCE_PCT = 0.2

local function diff_cfg()
  return (state.config or {}).diff or {}
end

-- True when a hunk's declared-vs-actual line count diverges beyond tolerance.
-- Returns false (detection disabled) when hunk_count_tolerance_lines <= 0.
local function exceeds(declared_new, divergence)
  local cfg = diff_cfg()
  local tol_lines = tonumber(cfg.hunk_count_tolerance_lines)
  if tol_lines == nil then
    tol_lines = DEFAULT_TOLERANCE_LINES
  end
  if tol_lines <= 0 then
    return false
  end
  local pct = tonumber(cfg.hunk_count_tolerance_pct) or DEFAULT_TOLERANCE_PCT
  local threshold = math.max(tol_lines, math.ceil(pct * (declared_new or 0)))
  return (divergence or 0) > threshold
end

M.exceeds = exceeds

-- List of mismatched hunks with declared/actual counts, for the audit payload
-- and the banner. Empty when nothing drifts beyond tolerance.
function M.mismatches(hunks)
  local out = {}
  for index, hunk in ipairs(hunks or {}) do
    local declared_new = tonumber(hunk.declared_new)
    local divergence = tonumber(hunk.count_divergence) or 0
    if declared_new ~= nil and exceeds(declared_new, divergence) then
      out[#out + 1] = {
        index = index,
        declared_new = declared_new,
        actual_new = hunk.new_count,
        declared_old = tonumber(hunk.declared_old),
        actual_old = hunk.old_count,
        divergence = divergence,
      }
    end
  end
  return out
end

-- Banner row { text, hl } when any hunk drifts, else nil. Joins the existing
-- badge row stack; adds no always-on line.
function M.banner_row(session, icon_fn)
  local list = M.mismatches((session and session.hunks) or {})
  if #list == 0 then
    return nil
  end
  local first = list[1]
  local icon = (icon_fn and icon_fn("warning")) or ""
  local extra = ""
  if #list > 1 then
    extra = string.format(" (+%d more hunk%s)", #list - 1, (#list - 1 == 1) and "" or "s")
  end
  local text = string.format(
    "  %s count drift: hunk %d declared +%d, emitted +%d%s",
    icon,
    first.index,
    first.declared_new or 0,
    first.actual_new or 0,
    extra
  )
  return { text, "NvimeStatusWarn" }
end

return M
