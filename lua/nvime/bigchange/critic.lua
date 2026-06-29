-- nvime.bigchange.critic
--
-- F1: a devil's-advocate critic pass for the Big Change autonomous build — the
-- lane with the MOST AI latitude, which otherwise gets no adversarial read
-- before the human starts the forced-comprehension review (the edit lane has
-- had one via nvime.critic since day one). After the build's diff is grouped
-- into review blocks, this runs ONE fresh, read-only critic turn that annotates
-- each gradeable block with an APPROVE / FLAG / REJECT verdict.
--
-- It is purely ADVISORY: it never blocks the merge and never grades the user.
-- The verdict rides along in the review tree so the reviewer sees "this block:
-- REJECT — removes the nil guard at line 42" before they explain it.

local agent = require("nvime.bigchange.agent")
local audit = require("nvime.audit")
local blocks = require("nvime.bigchange.blocks")
local state = require("nvime.state")
local store = require("nvime.bigchange.store")

local M = {}

local VALID = { APPROVE = true, FLAG = true, REJECT = true }

-- True when the devil's-advocate pass is enabled. Off by default: it costs one
-- extra agent call per build and the human review is the real gate.
function M.enabled()
  local cfg = ((state.config or {}).bigchange or {}).critic or {}
  return cfg.enabled == true
end

local function critic_prompt(session, gradeable)
  local lines = {
    "You are an adversarial code reviewer — a DEVIL'S ADVOCATE — for a feature that",
    "another agent built fully autonomously. You did NOT write this code and have no",
    "stake in whether it lands. Find genuine reasons each block should not merge.",
    "",
    "For EACH block below, return exactly one verdict:",
    "  APPROVE — you can name what the block does correctly and see no real problem.",
    "  FLAG    — it may be fine, but something needs a closer human look (name it).",
    "  REJECT  — it is unambiguously wrong (name the bug or the contract it breaks).",
    "",
    "Your verdict is ADVISORY ONLY: it never blocks the merge and never grades the",
    "user — it rides along in the human's review to focus their attention. Bias",
    "toward FLAG over REJECT unless a block is clearly broken; choose APPROVE only",
    "when you can say what it does right. Read the worktree freely to ground each",
    "verdict; you are read-only and cannot edit anything.",
    "",
    "Output ONLY a JSON array wrapped in <JSON></JSON>, no prose:",
    '  [{"id": <int>, "decision": "APPROVE"|"FLAG"|"REJECT", "justification": "one sentence"}]',
    "",
    "Blocks:",
  }
  for _, b in ipairs(gradeable) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("### Block %d — %s (%s)", b.id, b.title, b.file)
    for _, h in ipairs(blocks.block_hunks(session, b)) do
      lines[#lines + 1] = h.header
      for _, l in ipairs(h.lines) do
        local sigil = (l.kind == "add" and "+") or (l.kind == "del" and "-") or " "
        lines[#lines + 1] = sigil .. l.text
      end
    end
  end
  return table.concat(lines, "\n")
end

M._critic_prompt = critic_prompt

-- Apply a decoded JSON result array onto the gradeable blocks. Returns the
-- number of verdicts applied. Exposed for tests.
function M.apply_verdicts(gradeable, results)
  local by_id = {}
  if type(results) == "table" then
    for _, r in ipairs(results) do
      if type(r) == "table" and r.id ~= nil then
        by_id[tonumber(r.id)] = r
      end
    end
  end
  local applied = 0
  for _, b in ipairs(gradeable) do
    local r = by_id[b.id]
    if type(r) == "table" then
      local decision = type(r.decision) == "string" and r.decision:upper() or nil
      if decision and VALID[decision] then
        b.critic = { decision = decision, justification = vim.trim(tostring(r.justification or "")) }
        applied = applied + 1
      end
    end
  end
  return applied
end

-- Run the devil's-advocate pass over a built session's blocks, then cb(ran):
-- ran is true when a critic turn actually ran. No-op (cb(false)) when disabled
-- or there is nothing gradeable. Never blocks; a failed/empty turn just leaves
-- blocks un-annotated.
function M.review_blocks(session, cb)
  cb = cb or function() end
  if not M.enabled() then
    cb(false)
    return
  end
  -- Trivial auto-clears and un-gradeable meta rows (binary/rename) carry no
  -- content worth a verdict, so the pass skips them.
  local gradeable = {}
  for _, b in ipairs(session.blocks or {}) do
    if not b.trivial and not b.meta_kind then
      gradeable[#gradeable + 1] = b
    end
  end
  if #gradeable == 0 then
    cb(false)
    return
  end

  audit.write({
    event = "critic_start",
    lane = "bigchange",
    project = session.id or session.title,
    blocks = #gradeable,
  })

  agent.turn({
    session = session,
    -- Read-only, fresh session: the critic must have no stake in the build.
    lane = "critic",
    cwd = session.worktree,
    prompt = critic_prompt(session, gradeable),
    resume = false,
    scope = "critic",
    on_done = function(text)
      local results = agent.extract_json(text)
      local applied = M.apply_verdicts(gradeable, results)
      store.touch(session)
      audit.write({
        event = "critic_exit",
        lane = "bigchange",
        project = session.id or session.title,
        graded = applied,
      })
      cb(true)
    end,
  })
end

return M
