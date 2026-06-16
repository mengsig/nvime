-- nvime.diff.shared
--
-- The common core shared by every diff submodule: the inline extmark
-- namespace, small list helpers, the block model (parse_hunk_blocks /
-- build_blocks), and the live-content reconciliation / conflict-detection
-- engine plus the extmark geometry helpers. Everything here is self-contained
-- (depends only on `audit` + vim) so parser/registry/render/ops can all import
-- it without cycles.
--
-- The namespace name "nvime.diff.inline" is load-bearing: the test suite reads
-- extmarks by that exact name, so it must be created here exactly once.

local audit = require("nvime.audit")

local M = {}

M.ns = vim.api.nvim_create_namespace("nvime.diff.inline")
local ns = M.ns

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end
  for i = 1, #left do
    if left[i] ~= right[i] then
      return false
    end
  end
  return true
end

local function line_slice(lines, first, last)
  local out = {}
  for index = first, last do
    if lines[index] ~= nil then
      out[#out + 1] = lines[index]
    end
  end
  return out
end

local function copy_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    out[#out + 1] = line
  end
  return out
end

local function sorted_session_blocks(session)
  local blocks = {}
  for _, block in ipairs((session and session.blocks) or {}) do
    blocks[#blocks + 1] = block
  end
  table.sort(blocks, function(a, b)
    if a.old_start == b.old_start then
      return a.id < b.id
    end
    return a.old_start < b.old_start
  end)
  return blocks
end

local function lines_match_at(lines, start_index, expected)
  if #expected == 0 then
    return true
  end
  if start_index < 0 or start_index + #expected > #lines then
    return false
  end
  for index = 1, #expected do
    if lines[start_index + index] ~= expected[index] then
      return false
    end
  end
  return true
end

local function is_unresolved(block)
  return block and (block.status == "pending" or block.status == "conflict")
end

local function group_summary(group)
  local first_id = group.blocks[1].id
  local last_id = group.blocks[#group.blocks].id
  local id_text = first_id == last_id and tostring(first_id) or (first_id .. "-" .. last_id)
  local old_total = 0
  local new_total = 0
  local has_conflict = false
  for _, block in ipairs(group.blocks) do
    old_total = old_total + block.old_count
    new_total = new_total + #block.new_lines
    has_conflict = has_conflict or block.status == "conflict"
  end
  local range_text = group.first == group.last and ("line " .. group.first)
    or ("lines " .. group.first .. "-" .. group.last)
  local segment = ""
  if group.index and group.total and group.total > 1 then
    segment = string.format("block %d/%d  ", group.index, group.total)
  end
  local kind = has_conflict and "conflict" or "change"
  return string.format("nvime %s%s %s  %s  -%d +%d", segment, kind, id_text, range_text, old_total, new_total)
end

local function parse_hunk_blocks(hunk, next_id)
  local blocks = {}
  local old_line = hunk.old_start
  local block = nil

  local function flush()
    if block and (#block.old_lines > 0 or #block.new_lines > 0) then
      local count = math.max(#block.old_lines, #block.new_lines)
      for index = 1, count do
        local old_line = block.old_lines[index]
        local new_line = block.new_lines[index]
        local old_start
        if old_line then
          old_start = block.old_start + index - 1
        elseif #block.old_lines == 0 then
          old_start = block.old_start
        else
          old_start = block.old_start + #block.old_lines
        end
        blocks[#blocks + 1] = {
          id = block.id + index - 1,
          old_start = old_start,
          old_lines = old_line and { old_line } or {},
          new_lines = new_line and { new_line } or {},
          old_count = old_line and 1 or 0,
          new_count = new_line and 1 or 0,
          status = "pending",
          hunk = hunk,
        }
      end
      next_id = next_id + count - 1
    end
    block = nil
  end

  local function ensure_block()
    if not block then
      block = {
        id = next_id,
        old_start = old_line,
        old_lines = {},
        new_lines = {},
      }
      next_id = next_id + 1
    end
    return block
  end

  for i = 2, #hunk.lines do
    local line = hunk.lines[i]
    local prefix = line:sub(1, 1)
    if prefix == " " then
      flush()
      old_line = old_line + 1
    elseif prefix == "-" then
      ensure_block().old_lines[#block.old_lines + 1] = line:sub(2)
      old_line = old_line + 1
    elseif prefix == "+" then
      ensure_block().new_lines[#block.new_lines + 1] = line:sub(2)
    end
  end
  flush()
  return blocks, next_id
end

local function build_blocks(session)
  local next_id = 1
  session.blocks = {}
  for _, hunk in ipairs(session.hunks) do
    local blocks
    blocks, next_id = parse_hunk_blocks(hunk, next_id)
    hunk.blocks = blocks
    for _, block in ipairs(blocks) do
      block.session = session
      session.blocks[#session.blocks + 1] = block
    end
  end
end

local function update_hunk_status(hunk)
  local pending = 0
  local accepted = 0
  local rejected = 0
  local conflict = 0
  for _, block in ipairs(hunk.blocks or {}) do
    if block.status == "pending" then
      pending = pending + 1
    elseif block.status == "accepted" then
      accepted = accepted + 1
    elseif block.status == "rejected" then
      rejected = rejected + 1
    elseif block.status == "conflict" then
      conflict = conflict + 1
    end
  end
  if conflict > 0 then
    hunk.status = "conflict"
  elseif pending > 0 then
    hunk.status = "pending"
  elseif accepted > 0 and rejected > 0 then
    hunk.status = "mixed"
  elseif accepted > 0 then
    hunk.status = "accepted"
  elseif rejected > 0 then
    hunk.status = "rejected"
  else
    hunk.status = "pending"
  end
end

local function target_line_count(session)
  return vim.api.nvim_buf_line_count(session.target_bufnr)
end

local function current_changedtick(session)
  if session and session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    return vim.api.nvim_buf_get_changedtick(session.target_bufnr)
  end
  return nil
end

local function mark_model_synced(session)
  session.model_changedtick = current_changedtick(session)
end

local function accepted_delta(block)
  return #(block.new_lines or {}) - (block.old_count or 0)
end

-- Above this fraction of matching surrounding context, a deletion is trusted
-- as applied; below it (but with *some* matching context) the deletion is
-- ambiguous and escalates to a conflict for the human to resolve, instead of
-- being silently accepted at a possibly-wrong location.
local DELETION_CONFIDENCE_THRESHOLD = 0.7

-- Confidence in [0,1] that the deletion described by `block` actually happened
-- at `start_index` in the live buffer. Checks the original lines immediately
-- BEFORE the deleted block (leading context) and immediately AFTER it
-- (trailing context): a deletion whose trailing context recurs elsewhere could
-- otherwise match the wrong location and be accepted silently. Confidence is
-- the fraction of available context lines (both sides combined) that match.
-- When the original has no surrounding context at all (e.g. the whole file was
-- deleted) only a deletion landing at the true end of the buffer scores 1.0.
local function deletion_confidence(session, block, live_lines, start_index)
  local original = (session and session.original_lines) or {}
  if #original == 0 and session and session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    original = vim.api.nvim_buf_get_lines(session.target_bufnr, 0, -1, false)
  end

  local old_count = math.max(block.old_count or 0, 1)
  local del_start = block.old_start or 1

  local trailing = {}
  local first_trailing = del_start + old_count
  for index = first_trailing, math.min(#original, first_trailing + 2) do
    trailing[#trailing + 1] = original[index]
  end

  local leading = {}
  for index = math.max(1, del_start - 3), del_start - 1 do
    leading[#leading + 1] = original[index]
  end

  local available = #leading + #trailing
  if available == 0 then
    return (start_index >= #live_lines) and 1.0 or 0.0
  end

  local matched = 0
  -- Trailing context must appear starting exactly at the deletion point.
  if #trailing > 0 and lines_match_at(live_lines, start_index, trailing) then
    matched = matched + #trailing
  end
  -- Leading context must appear ending exactly at the deletion point.
  if #leading > 0 and lines_match_at(live_lines, start_index - #leading, leading) then
    matched = matched + #leading
  end
  return matched / available
end

-- Backwards-compatible boolean view used by callers that only need a yes/no.
local function deletion_context_matches(session, block, live_lines, start_index)
  return deletion_confidence(session, block, live_lines, start_index) >= DELETION_CONFIDENCE_THRESHOLD
end

local function live_block_status(session, block, live_lines, offset)
  if block.status == "rejected" then
    return "rejected"
  end

  local old_lines = block.old_lines or {}
  local new_lines = block.new_lines or {}
  local start_index = math.max(0, math.min((block.old_start or 1) - 1 + offset, #live_lines))

  if #old_lines == 0 then
    if #new_lines > 0 and lines_match_at(live_lines, start_index, new_lines) then
      return "accepted"
    end
    return "pending"
  end

  if #new_lines > 0 and lines_match_at(live_lines, start_index, new_lines) then
    return "accepted"
  end
  if lines_match_at(live_lines, start_index, old_lines) then
    return "pending"
  end
  if #new_lines == 0 then
    -- The original lines are gone from this spot. Decide whether the deletion
    -- truly landed here (accept), might be misplaced (conflict → human), or
    -- left no trace (nil → unchanged status).
    local confidence = deletion_confidence(session, block, live_lines, start_index)
    if confidence >= DELETION_CONFIDENCE_THRESHOLD then
      return "accepted"
    elseif confidence > 0 then
      return "conflict"
    end
    return nil
  end

  return nil
end

local function rebuild_applied_tracking(session)
  local applied = {}
  local accepted = {}
  local accepted_start_indexes = {}
  local offset = 0

  for _, block in ipairs(sorted_session_blocks(session)) do
    local start_index = math.max(0, (block.old_start or 1) - 1 + offset)
    if block.status == "accepted" then
      accepted[block.id] = block
      accepted_start_indexes[block.id] = start_index
      applied[#applied + 1] = {
        block_id = block.id,
        old_start = block.old_start,
        delta = accepted_delta(block),
      }
      offset = offset + accepted_delta(block)
    end
  end

  session.applied = applied

  local history = {}
  local seen = {}
  for _, entry in ipairs(session.applied_history or {}) do
    if entry.block_id and accepted[entry.block_id] and not seen[entry.block_id] then
      history[#history + 1] = entry
      seen[entry.block_id] = true
    end
  end

  for _, block in ipairs(sorted_session_blocks(session)) do
    if accepted[block.id] and not seen[block.id] then
      history[#history + 1] = {
        block = block,
        block_id = block.id,
        start_index = accepted_start_indexes[block.id] or 0,
        old_lines = copy_lines(block.old_lines),
        new_lines = copy_lines(block.new_lines),
        synthetic = true,
      }
      seen[block.id] = true
    end
  end

  session.applied_history = history
end

local function reconcile_live_state(session)
  if not (session and session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr)) then
    return
  end
  local changedtick = current_changedtick(session)
  if session.model_changedtick and session.model_changedtick == changedtick then
    return
  end
  if not session.blocks then
    build_blocks(session)
  end

  local live_lines = vim.api.nvim_buf_get_lines(session.target_bufnr, 0, -1, false)
  local offset = 0
  local changed = false
  local reopened = false

  for _, block in ipairs(sorted_session_blocks(session)) do
    local status = live_block_status(session, block, live_lines, offset)
    if status and status ~= block.status then
      local previous = block.status
      block.status = status
      if status ~= "conflict" then
        block.conflict = nil
      end
      if previous == "accepted" and is_unresolved(block) then
        reopened = true
      end
      block.mark_id = nil
      changed = true
      -- An ambiguous deletion (some but not enough matching context) lands here
      -- as a conflict instead of a silent accept. Record it so the digest's
      -- risky bucket and the audit trail surface the human decision point.
      if status == "conflict" then
        audit.write({
          event = "block_conflict",
          reason = "ambiguous_deletion",
          file = session.file,
          block_id = block.id,
        })
      end
    end
    if (status or block.status) == "accepted" then
      offset = offset + accepted_delta(block)
    end
  end

  for _, hunk in ipairs(session.hunks or {}) do
    update_hunk_status(hunk)
  end
  rebuild_applied_tracking(session)
  session.model_changedtick = changedtick

  if changed then
    if reopened then
      session.on_resolved_fired = false
    end
    session.visual_groups = nil
    audit.write({
      event = "diff_live_state_reconciled",
      path = session.file,
      changedtick = changedtick,
    })
  end
end

local function block_start_line(session, block)
  if block.mark_id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(session.target_bufnr, ns, block.mark_id, {})
    if mark and mark[1] then
      return mark[1] + 1
    end
  end
  local offset = 0
  for _, applied in ipairs(session.applied) do
    if applied.old_start < block.old_start then
      offset = offset + applied.delta
    end
  end
  return block.old_start + offset
end

local function block_range(session, block)
  local start_line = block_start_line(session, block)
  local old_count = math.max(block.old_count, 1)
  return start_line, start_line + old_count - 1
end

M.same_lines = same_lines
M.line_slice = line_slice
M.copy_lines = copy_lines
M.sorted_session_blocks = sorted_session_blocks
M.lines_match_at = lines_match_at
M.is_unresolved = is_unresolved
M.group_summary = group_summary
M.parse_hunk_blocks = parse_hunk_blocks
M.build_blocks = build_blocks
M.update_hunk_status = update_hunk_status
M.target_line_count = target_line_count
M.current_changedtick = current_changedtick
M.mark_model_synced = mark_model_synced
M.accepted_delta = accepted_delta
M.deletion_context_matches = deletion_context_matches
M.deletion_confidence = deletion_confidence
M.live_block_status = live_block_status
M.rebuild_applied_tracking = rebuild_applied_tracking
M.reconcile_live_state = reconcile_live_state
M.block_start_line = block_start_line
M.block_range = block_range

return M
