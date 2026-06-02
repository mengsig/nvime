-- nvime.bigchange.blocks
--
-- Stage 4 (logic): capture the worktree diff vs the base commit and ask the
-- agent to group its hunks into AGENT-CHOSEN semantic blocks — the units the
-- forced-comprehension review gates on. Also handles re-capture after a
-- grading round that revised code, carrying cleared/graded state forward for
-- blocks whose content is unchanged so the user doesn't re-explain everything.

local agent = require("nvime.bigchange.agent")
local diffparse = require("nvime.bigchange.diffparse")
local git = require("nvime.git")
local store = require("nvime.bigchange.store")

local M = {}

local PREVIEW_LIMIT = 60 -- max diff lines shown per hunk in the grouping prompt

-- Capture the full diff of the worktree against its base commit, including
-- untracked files (via intent-to-add).
function M.capture_diff(session)
  local wt = session.worktree
  if not wt or vim.fn.isdirectory(wt) ~= 1 then
    return nil
  end
  store.with_trusted(function()
    git.systemlist({ "git", "-C", wt, "add", "-A", "-N" })
  end)
  local out = git.systemlist({ "git", "-C", wt, "diff", "--no-color", session.base_commit or "HEAD" })
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- block assembly
-- ---------------------------------------------------------------------------
-- Cached id→hunk map, keyed by the diff_hunks table itself (weak keys, so a
-- replaced/GC'd diff drops its entry). Avoids rebuilding the map on every
-- block_hunks/block_signature call — those run per-block on every render.
local hunk_map_cache = setmetatable({}, { __mode = "k" })

function M.hunks_by_id(session)
  local hunks = session.diff_hunks or {}
  local cached = hunk_map_cache[hunks]
  if cached then
    return cached
  end
  local map = {}
  for _, h in ipairs(hunks) do
    map[h.id] = h
  end
  hunk_map_cache[hunks] = map
  return map
end

function M.block_hunks(session, block)
  local map = M.hunks_by_id(session)
  local out = {}
  for _, id in ipairs(block.hunk_ids or {}) do
    if map[id] then
      out[#out + 1] = map[id]
    end
  end
  return out
end

local function block_signature(session, hunk_ids)
  local map = M.hunks_by_id(session)
  local parts = {}
  for _, id in ipairs(hunk_ids) do
    if map[id] then
      parts[#parts + 1] = diffparse.hunk_signature(map[id])
    end
  end
  return table.concat(parts, "\n//\n")
end

local function group_prompt(hunks)
  local lines = {
    "Group the following diff hunks into semantic REVIEW BLOCKS — meaningful",
    "units of change (a new function, a wired-up call site, a config change, a",
    "migration, etc.). Rules:",
    "- Each block groups hunks from ONE file only.",
    "- Every hunk must belong to exactly one block.",
    "- Give each block a SHORT descriptive title (<= 60 chars). Do NOT explain the code.",
    '- Mark a block "trivial": true ONLY when it is self-evident and needs no comprehension check — import/require/use lines, documentation/markdown prose, comment-only edits, or version/config value bumps. Otherwise omit it or set false.',
    "- Output ONLY a JSON array wrapped in <JSON></JSON>, no prose:",
    '  [{"title": "...", "file": "path", "hunk_ids": ["path#1"], "trivial": false}]',
    "",
    "Hunks:",
  }
  for _, h in ipairs(hunks) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[" .. h.id .. "] " .. h.file
    lines[#lines + 1] = h.header
    local shown = 0
    for _, l in ipairs(h.lines) do
      if shown >= PREVIEW_LIMIT then
        lines[#lines + 1] = "  … (truncated)"
        break
      end
      local sigil = (l.kind == "add" and "+") or (l.kind == "del" and "-") or " "
      lines[#lines + 1] = sigil .. l.text
      shown = shown + 1
    end
  end
  return table.concat(lines, "\n")
end

-- Fallback grouping: one block per file (used when the agent returns nothing
-- parseable). Guarantees the review is never empty.
local function fallback_blocks(hunks)
  local by_file, order = {}, {}
  for _, h in ipairs(hunks) do
    if not by_file[h.file] then
      by_file[h.file] = {}
      order[#order + 1] = h.file
    end
    table.insert(by_file[h.file], h.id)
  end
  local blocks = {}
  for _, file in ipairs(order) do
    blocks[#blocks + 1] =
      { title = vim.fn.fnamemodify(file, ":t") .. " changes", file = file, hunk_ids = by_file[file] }
  end
  return blocks
end

-- Validate/normalize the agent's grouping; assign any unassigned hunks to a
-- per-file catch-all so every hunk is always covered.
local function normalize_groups(groups, hunks)
  local valid_ids = {}
  for _, h in ipairs(hunks) do
    valid_ids[h.id] = h.file
  end
  local seen = {}
  local out = {}
  for _, g in ipairs(groups or {}) do
    if type(g) == "table" and type(g.hunk_ids) == "table" then
      local ids = {}
      for _, id in ipairs(g.hunk_ids) do
        if valid_ids[id] and not seen[id] then
          ids[#ids + 1] = id
          seen[id] = true
        end
      end
      if #ids > 0 then
        out[#out + 1] = {
          title = tostring(g.title or "block"),
          file = g.file or valid_ids[ids[1]],
          hunk_ids = ids,
          trivial = g.trivial == true,
        }
      end
    end
  end
  -- Sweep unassigned hunks into per-file catch-alls.
  local leftover = {}
  for _, h in ipairs(hunks) do
    if not seen[h.id] then
      leftover[#leftover + 1] = h
    end
  end
  if #leftover > 0 then
    for _, b in ipairs(fallback_blocks(leftover)) do
      out[#out + 1] = b
    end
  end
  return out
end

-- Carry cleared/graded state from a previous round onto freshly-grouped blocks
-- whose content signature is unchanged.
local function carry_state(session, new_blocks, prior_blocks)
  local by_sig = {}
  for _, b in ipairs(prior_blocks or {}) do
    if b.signature then
      by_sig[b.signature] = b
    end
  end
  for _, b in ipairs(new_blocks) do
    local prior = by_sig[b.signature]
    if prior and prior.state == "cleared" then
      b.state = "cleared"
      b.grade = prior.grade
      b.comment = prior.comment
      b.action = prior.action
      -- Keep a previously trivial-cleared, content-unchanged block flagged so a
      -- re-capture does not silently downgrade it to an earned 100% clear.
      if prior.action == "auto_trivial" then
        b.trivial = prior.trivial
        b.trivial_category = prior.trivial_category
        b.trivial_source = prior.trivial_source
      end
    end
  end
end

local function assemble(session, groups, prior_blocks)
  local hunks = session.diff_hunks or {}
  local normalized = normalize_groups(groups, hunks)
  if #normalized == 0 then
    normalized = fallback_blocks(hunks)
  end
  local blocks = {}
  for index, g in ipairs(normalized) do
    blocks[#blocks + 1] = {
      id = index,
      title = g.title,
      file = g.file,
      hunk_ids = g.hunk_ids,
      signature = block_signature(session, g.hunk_ids),
      state = "pending",
      action = nil,
      comment = nil,
      grade = nil,
      hint = nil,
      agent_response = nil,
      agent_trivial = g.trivial == true,
    }
  end
  carry_state(session, blocks, prior_blocks)
  -- Auto-clear self-evident blocks (imports/docs/comments/config bumps) so the
  -- user never writes a graded explanation for them.
  local triviality = require("nvime.bigchange.triviality")
  for _, b in ipairs(blocks) do
    if b.state ~= "cleared" then
      local res = triviality.classify(session, b, M.block_hunks(session, b))
      if res.trivial then
        b.state, b.action = "cleared", "auto_trivial"
        b.trivial, b.trivial_category, b.trivial_source = true, res.category, res.source
        b.grade, b.comment, b.hint, b.agent_response = nil, nil, nil, nil
      end
    end
  end
  session.blocks = blocks
end

-- Capture the diff, parse it, and ask the agent to group it into blocks.
-- cb(ok, err). On success session.diff_hunks and session.blocks are populated.
function M.extract(session, cb)
  cb = cb or function() end
  local diff = M.capture_diff(session)
  if not diff or vim.trim(diff) == "" then
    cb(false, "no changes detected in worktree")
    return
  end
  local hunks = diffparse.parse(diff)
  if #hunks == 0 then
    cb(false, "diff produced no hunks")
    return
  end
  local prior_blocks = session.blocks
  session.diff_hunks = hunks
  store.touch(session)

  agent.turn({
    session = session,
    lane = "critic",
    cwd = session.worktree,
    prompt = group_prompt(hunks),
    resume = true,
    scope = "worktree",
    on_done = function(text)
      local groups = agent.extract_json(text)
      assemble(session, groups, prior_blocks)
      store.touch(session)
      cb(true)
    end,
  })
end

-- Re-capture after a code revision, preserving cleared blocks.
function M.recapture(session, cb)
  M.extract(session, cb)
end

return M
